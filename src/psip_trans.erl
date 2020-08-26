%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP transaction
%%%

-module(psip_trans).

-behaviour(gen_server).

-export([start_link/1,
         server_process/2,
         server_response/2,
         server_cancel/1,
         server_set_owner/3,
         client_new/3,
         client_response/2,
         client_cancel/1,
         count/0
        ]).

%% gen_server
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export_type([trans/0, client_result/0]).

%%===================================================================
%% Types
%%===================================================================

-record(state,
        {trans      :: ersip_trans:trans(),
         data       :: server() | client(),
         log        :: boolean(),
         logbranch  :: binary(),
         owner_mon  :: reference() | undefined
        }).
-type state() :: #state{}.

-record(server, {handler :: psip_handler:handler(),
                 origmsg :: ersip_sipmsg:sipmsg(),
                 auto_resp = 500 :: ersip_status:code()
                }).
-type server() :: #server{}.
-record(client, {outreq   :: ersip_request:request(),
                 callback :: client_callback(),
                 cancelled = false :: boolean()
                }).
-type client() :: #client{}.

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type trans() :: {trans, pid()}.
-type client_callback() :: fun((client_result()) -> any()).
-type client_result() :: {stop, stop_reason()}
                       | {message, ersip_sipmsg:sipmsg()}.
-type stop_reason() :: ersip_trans_se:clear_reason().

%%===================================================================
%% API
%%===================================================================

-spec start_link(term()) -> start_link_ret().
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec server_process(ersip_msg:message(), psip_handler:handler()) -> ok.
server_process(Msg, Handler) ->
    case ersip_sipmsg:parse(Msg, all_required) of
        {ok, SipMsg} ->
            case find_server(SipMsg) of
                {ok, Pid} ->
                    gen_server:cast(Pid, {received, SipMsg});
                error ->
                    case ersip_sipmsg:method(SipMsg) == ersip_method:ack() of
                        true ->
                            psip_uas:process_ack(SipMsg, Handler);
                        false ->
                            Args = [server, Handler, SipMsg],
                            case psip_trans_sup:start_child([Args]) of
                                {ok, _} -> ok;
                                {error, _} = Error ->
                                    psip_log:error("failed to create transaction: ~0p", [Error])
                            end
                    end
            end;
        {error, _} = Error ->
            psip_log:warning("failed to parse SIP message: ~0p~n~s", [Error, ersip_msg:serialize(Msg)])
    end.

-spec server_response(ersip_sipmsg:sipmsg(), trans()) -> ok.
server_response(Resp, {trans, Pid}) ->
    gen_server:cast(Pid, {send, Resp}).

-spec server_cancel(ersip_sipmsg:sipmsg()) -> {reply, ersip_sipmsg:sipmsg()}.
server_cancel(CancelSipMsg) ->
    TransId = ersip_trans:server_cancel_id(CancelSipMsg),
    case gproc:lookup_local_name(TransId) of
        Pid when is_pid(Pid) ->
            gen_server:cast(Pid, cancel),
            Resp = ersip_sipmsg:reply(200, CancelSipMsg),
            {reply, Resp};
        _ ->
            psip_log:info("cannot find transaction to CANCEL: ~0p", [TransId]),
            Resp = ersip_sipmsg:reply(481, CancelSipMsg),
            {reply, Resp}
    end.

-spec server_set_owner(ersip_status:code(), pid(), trans()) -> ok.
server_set_owner(Code, OwnerPid, {trans, Pid})
  when is_pid(OwnerPid) andalso is_integer(Code) ->
    gen_server:cast(Pid, {set_owner, Code, OwnerPid}).

-spec client_new(ersip_request:request(), psip_uac:options(), client_callback()) -> trans().
client_new(OutReq, Options, Callback) ->
    Args = [client, OutReq, Options, Callback],
    case psip_trans_sup:start_child([Args]) of
        {ok, Pid} ->
            {trans, Pid};
        {error, _} = Error ->
            psip_log:error("failed to create transaction: ~0p", [Error]),
            {trans, spawn(fun() -> ok end)}
    end.

-spec client_response(ersip_hdr_via:via(), ersip_msg:message()) -> ok.
client_response(Via, Msg) ->
    case ersip_sipmsg:parse(Msg, all_required) of
        {ok, SipMsg} ->
            TransId = ersip_trans:client_id(Via, SipMsg),
            case gproc:lookup_local_name(TransId) of
                Pid when is_pid(Pid) ->
                    gen_server:cast(Pid, {received, SipMsg});
                _ ->
                    psip_log:warning("cannot find transaction for request: ~0p", [Via])
            end;
        {error, _} = Error ->
            psip_log:warning("failed to parse response: ~0p", [Error])
    end.

-spec client_cancel(trans()) -> ok.
client_cancel({trans, Pid}) ->
    gen_server:cast(Pid, cancel).

-spec count() -> non_neg_integer().
count() ->
    psip_trans_sup:num_active().

%%===================================================================
%% gen_server callbacks
%%===================================================================

-spec init(Args :: term()) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term()} | ignore.
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()}, State :: state()) ->
    {reply, Reply :: term(), NewState :: state()} |
    {reply, Reply :: term(), NewState :: state(), timeout() | hibernate} |
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate} |
    {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
    {stop, Reason :: term(), NewState :: state()}.
-spec handle_cast(Request :: term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: state()}.
-spec handle_info(Info :: timeout | term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: state()}.
-spec terminate(Reason :: (normal | shutdown | {shutdown, term()} |
                               term()),
                    State :: state()) ->
    term().
-spec code_change(OldVsn :: (term() | {down, term()}), State :: state(),
                      Extra :: term()) ->
    {ok, NewState :: state()} | {error, Reason :: term()}.

init([server, Handler, SipMsg]) ->
    {Trans, TransSE} = ersip_trans:new_server(SipMsg, #{}),
    TransId = ersip_trans:id(Trans),
    gproc:add_local_name(TransId),
    gen_server:cast(self(), {process_se, TransSE}),

    LogBranch = case ersip_hdr_via:branch(ersip_sipmsg:topmost_via(SipMsg)) of
                    {ok, BVal} -> ersip_branch:assemble(BVal);
                    undefined -> <<"not defined">>
                end,
    State = #state{trans = Trans,
                   data  = #server{handler = Handler,
                                   origmsg = SipMsg},
                   log     = psip_config:log_transactions(),
                   logbranch = LogBranch
                  },
    Method = ersip_sipmsg:method_bin(SipMsg),
    RURI   = ersip_uri:assemble(ersip_sipmsg:ruri(SipMsg)),
    CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(SipMsg)),
    psip_log:info("trans: server: ~s ~s; call-id: ~s; branch: ~s", [Method, RURI, CallId, LogBranch]),
    {ok, State};
init([client, OutReq, Options, Callback]) ->
    SipOptions = maps:get(sip, Options, #{}),
    {Trans, TransSE} = ersip_trans:new_client(OutReq, SipOptions),
    TransId = ersip_trans:id(Trans),
    gproc:add_local_name(TransId),
    gen_server:cast(self(), {process_se, TransSE}),
    Branch = ersip_branch:assemble(ersip_request:branch(OutReq)),
    State = #state{trans   = Trans,
                   data    = #client{outreq = OutReq,
                                     callback = Callback},
                   log     = psip_config:log_transactions(),
                   logbranch = Branch
                  },
    SipMsg = ersip_request:sipmsg(OutReq),
    Method = ersip_sipmsg:method_bin(SipMsg),
    RURI   = ersip_uri:assemble(ersip_sipmsg:ruri(SipMsg)),
    CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(SipMsg)),
    psip_log:info("trans: client: ~s ~s; call-id: ~s; branch: ~s", [Method, RURI, CallId, Branch]),
    case maps:get(owner, Options, undefined) of
        Pid when is_pid(Pid) ->
            OwnerMon = erlang:monitor(process, Pid),
            {ok, State#state{owner_mon = OwnerMon}};
        undefined ->
            {ok, State}
    end.


handle_call(Request, _From, State) ->
    psip_log:error("trans: unexpected call: ~0p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({process_se, SE}, #state{} = State) ->
    case process_se_list(SE, State) of
        continue ->
            {noreply, State};
        stop ->
            {stop, normal, State}
    end;
handle_cast({send, _} = Ev, #state{trans = Trans} = State) ->
    log_trans(State, "trans: sending message", []),
    {NewTrans, SE} = ersip_trans:event(Ev, Trans),
    NewState = State#state{trans = NewTrans},
    case process_se_list(SE, State) of
        continue ->
            {noreply, NewState};
        stop ->
            {stop, normal, NewState}
    end;
handle_cast(cancel, #state{data = #server{handler = Handler}} = State) ->
    log_trans(State, "trans: canceling server transaction", []),
    psip_uas:process_cancel(make_trans(), Handler),
    {noreply, State};
handle_cast(cancel, #state{data = #client{cancelled = true}} = State) ->
    log_trans(State, "trans: transaction is already cancelled", []),
    {noreply, State};
handle_cast(cancel, #state{data = #client{cancelled = false} = Data} = State) ->
    log_trans(State, "trans: canceling client transaction", []),
    #client{outreq = OutReq} = Data,
    CancelReq = ersip_request_cancel:generate(OutReq),
    _ = client_new(CancelReq, #{}, fun(_) -> ok end),
    erlang:send_after(timer:seconds(32), self(), cancel_timeout),
    {noreply, State#state{data = Data#client{cancelled = true}}};
handle_cast({received, SipMsg} = Ev, #state{trans = Trans} = State) ->
    case ersip_sipmsg:type(SipMsg) of
        request -> ok;
        response ->
            CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(SipMsg)),
            Branch = State#state.logbranch,
            Method = ersip_sipmsg:method_bin(SipMsg),
            psip_log:info("trans: client: response on ~s: ~b ~s; call-id: ~s; branch: ~s", [Method, ersip_sipmsg:status(SipMsg), ersip_sipmsg:reason(SipMsg), CallId, Branch])
    end,
    {NewTrans, SE} = ersip_trans:event(Ev, Trans),
    NewState = State#state{trans = NewTrans},
    case process_se_list(SE, State) of
        continue ->
            {noreply, NewState};
        stop ->
            {stop, normal, NewState}
    end;
handle_cast({set_owner, Code, Pid}, #state{data = #server{} = Server} = State) ->
    log_trans(State, "trans: set owner to: ~p with code: ~p", [Pid, Code]),
    OwnerMon = erlang:monitor(process, Pid),
    {noreply, State#state{owner_mon = OwnerMon, data = Server#server{auto_resp = Code}}};
handle_cast(Request, State) ->
    psip_log:error("trans: unexpected cast: ~0p", [Request]),
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, _}, #state{trans = Trans, owner_mon = Ref, data = #server{origmsg = SipMsg}} = State) ->
    case ersip_trans:has_final_response(Trans) of
        true ->
            {noreply, State};
        false ->
            #state{data = #server{origmsg = SipMsg, auto_resp = Code}} = State,
            log_trans(State, "trans: owner is dead: ~p: auto reply with ~p", [Pid, Code]),
            Resp = ersip_sipmsg:reply(Code, SipMsg),
            {NewTrans, SE} = ersip_trans:event({send, Resp}, Trans),
            NewState = State#state{trans = NewTrans},
            case process_se_list(SE, State) of
                continue ->
                    {noreply, NewState};
                stop ->
                    {stop, normal, NewState}
            end
    end;
handle_info({'DOWN', Ref, process, Pid, _}, #state{trans = Trans, owner_mon = Ref, data = #client{outreq = OutReq}} = State) ->
    case ersip_sipmsg:method_bin(ersip_request:sipmsg(OutReq)) of
        <<"INVITE">> ->
            case ersip_trans:has_final_response(Trans) of
                true -> ok;
                false ->
                    log_trans(State, "trans: owner is dead: ~p: cancel transaction", [Pid]),
                    gen_server:cast(self(), cancel)
            end;
        _ -> ok
    end,
    {noreply, State};
handle_info({event, TimerEvent}, #state{trans = Trans} = State) ->
    log_trans(State, "trans: timer fired ~0p", [TimerEvent]),
    {NewTrans, SE} = ersip_trans:event(TimerEvent, Trans),
    NewState = State#state{trans = NewTrans},
    case process_se_list(SE, State) of
        continue ->
            {noreply, NewState};
        stop ->
            {stop, normal, NewState}
    end;
handle_info(cancel_timeout, #state{trans = Trans, data = #client{callback = Callback}} = State) ->
    case ersip_trans:has_final_response(Trans) of
        true -> ok;
        false ->
            psip_log:warning("trans: remote side did not respond after CANCEL request: terminate", []),
            Callback({stop, timeout})
        end,
    {stop, normal, State};
handle_info(Msg, State) ->
    psip_log:error("trans: unexpected info: ~0p", [Msg]),
    {noreply, State}.

terminate(Reason, #state{} = State) ->
    case Reason of
        normal ->
            log_trans(State, "trans: finished", []);
        _ ->
            psip_log:error("trans: finished with error: ~0p", [Reason])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal implementation
%%===================================================================

-spec find_server(ersip_sipmsg:sipmsg()) -> {ok, pid()} | error.
find_server(SipMsg) ->
    TransId = ersip_trans:server_id(SipMsg),
    case gproc:lookup_local_name(TransId) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        _ ->
            error
    end.

-spec process_se_list([ersip_trans_se:effect()], state()) -> continue | stop.
process_se_list([], #state{}) ->
    continue;
process_se_list([SE | Rest], #state{} = State) ->
    case process_se(SE, State) of
        stop -> stop;
        continue ->
            process_se_list(Rest, State)
    end.

-spec process_se(ersip_trans_se:effect(), state()) -> continue | stop.
process_se({tu_result, SipMsg}, #state{data = #server{handler = Handler}} = State) ->
    case psip_handler:transaction(make_trans(), SipMsg, Handler) of
        ok -> ok;
        process_uas ->
            case ersip_sipmsg:method(SipMsg) == ersip_method:ack() of
                true  ->
                    CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(SipMsg)),
                    Branch = State#state.logbranch,
                    psip_log:warning("ACK that matches transaction received: call-id: ~s; branch: ~s", [CallId, Branch]),
                    psip_uas:process_ack(SipMsg, Handler);
                false ->
                    psip_uas:process(make_trans(), SipMsg, Handler)
            end
    end,
    continue;
process_se({tu_result, SipMsg}, #state{data = #client{callback = Callback}}) ->
    Callback({message, SipMsg}),
    continue;
process_se({set_timer, {Timeout, TimerEvent}}, #state{} = State) ->
    log_trans(State, "trans: set timer on ~p ms: ~0p", [Timeout, TimerEvent]),
    erlang:send_after(Timeout, self(), {event, TimerEvent}),
    continue;
process_se({clear_trans, normal}, #state{data = #server{}} = State) ->
    log_trans(State, "trans: transaction cleared: normal", []),
    stop;
process_se({clear_trans, Reason}, #state{data = #server{handler = Handler}} = State) ->
    log_trans(State, "trans: transaction cleared: ~0p", [Reason]),
    psip_handler:transaction_stop({trans, self()}, Reason, Handler),
    stop;
process_se({clear_trans, Reason}, #state{data = #client{callback = Callback}} = State) ->
    log_trans(State, "trans: client transaction cleared: ~0p", [Reason]),
    Callback({stop, Reason}),
    stop;
process_se({send_request, OutReq}, #state{} = State) ->
    log_trans(State, "trans: sending request", []),
    psip_tport:send_request(OutReq),
    continue;
process_se({send_response, Response}, #state{data = #server{origmsg = ReqSipMsg}} = State) ->
    log_trans(State, "trans: sending response", []),
    case ersip_status:response_type(ersip_sipmsg:status(Response)) of
        provisional -> ok;
        final ->
            Method = ersip_sipmsg:method_bin(Response),
            CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(Response)),
            Branch = State#state.logbranch,
            psip_log:info("trans: server: response on ~s: ~b ~s; call-id: ~s; branch: ~s", [Method, ersip_sipmsg:status(Response), ersip_sipmsg:reason(Response), CallId, Branch])
    end,
    psip_source:send_response(Response, ReqSipMsg),
    continue.

-spec make_trans() -> trans().
make_trans() ->
    {trans, self()}.

-spec log_trans(state(), string(), list()) -> ok.
log_trans(#state{log = true}, Format, Args) ->
    psip_log:debug(Format, Args);
log_trans(_, _, _) ->
    ok.

