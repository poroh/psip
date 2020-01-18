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
         client_new/2,
         client_response/2,
         client_cancel/1]).

%% gen_server
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export_type([trans/0]).

%%===================================================================
%% Types
%%===================================================================

-record(state,
        {trans   :: ersip_trans:trans(),
         data    :: server() | client()
        }).
-type state() :: #state{}.

-record(server, {handler :: psip_handler:handler(),
                 origmsg :: ersip_sipmsg:sipmsg()
                }).
-type server() :: #server{}.
-record(client, {outreq   :: ersip_request:request(),
                 callback :: client_callback()
                }).
-type client() :: #client{}.

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type trans() :: {trans, pid()}.
-type client_callback() :: fun((trans_result()) -> any()).
-type trans_result() :: {stop, stop_reason()}
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
                            psip_log:debug("transaction is not found: creating new one", []),
                            Args = [server, Handler, SipMsg],
                            case psip_trans_sup:start_child([Args]) of
                                {ok, _} -> ok;
                                {error, _} = Error ->
                                    psip_log:error("failed to create transaction: ~p", [Error])
                            end
                    end
            end;
        {error, _} = Error ->
            psip_log:warning("failed to parse SIP message: ~p~n~s", [Error, ersip_msg:serialize(Msg)])
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
            psip_log:info("Cannot find transaction to CANCEL: ~p", []),
            Resp = ersip_sipmsg:reply(481, CancelSipMsg),
            {reply, Resp}
    end.

-spec client_new(ersip_request:request(), client_callback()) -> trans().
client_new(OutReq, Callback) ->
    Args = [client, OutReq, Callback],
    case psip_trans_sup:start_child([Args]) of
        {ok, Pid} ->
            {trans, Pid};
        {error, _} = Error ->
            psip_log:error("failed to create transaction: ~p", [Error]),
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
                    psip_log:warning("Cannot find transaction for request: ~p", [Via])
            end;
        {error, _} = Error ->
            psip_log:warning("Failed to parse response: ~p", [Error])
    end.

-spec client_cancel(trans()) -> ok.
client_cancel({trans, Pid}) ->
    gen_server:cast(Pid, cancel).

%%===================================================================
%% gen_server callbacks
%%===================================================================

-spec init(Args :: term()) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term()} | ignore.
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                      State :: state()) ->
    {reply, Reply :: term(), NewState :: state()} |
    {reply, Reply :: term(), NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate | {continue, term()}} |
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
    psip_log:debug("psip trans: starting server transaction with id: ~p", [TransId]),
    gen_server:cast(self(), {process_se, TransSE}),
    State = #state{trans = Trans,
                   data  = #server{handler = Handler,
                                   origmsg = SipMsg}
                  },
    {ok, State};
init([client, OutReq, Callback]) ->
    {Trans, TransSE} = ersip_trans:new_client(OutReq, #{}),
    TransId = ersip_trans:id(Trans),
    gproc:add_local_name(TransId),
    psip_log:debug("psip trans: starting client transaction with id: ~p", [TransId]),
    gen_server:cast(self(), {process_se, TransSE}),
    State = #state{trans   = Trans,
                   data    = #client{outreq = OutReq,
                                     callback = Callback}
                  },
    {ok, State}.


handle_call(Request, _From, State) ->
    psip_log:error("psip trans: unexpected call: ~p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({process_se, SE}, #state{} = State) ->
    case process_se_list(SE, State) of
        continue ->
            {noreply, State};
        stop ->
            {stop, normal, State}
    end;
handle_cast({send, _} = Ev, #state{trans = Trans} = State) ->
    psip_log:debug("psip trans: sending message", []),
    {NewTrans, SE} = ersip_trans:event(Ev, Trans),
    NewState = State#state{trans = NewTrans},
    case process_se_list(SE, State) of
        continue ->
            {noreply, NewState};
        stop ->
            {stop, normal, NewState}
    end;
handle_cast(cancel, #state{data = #server{handler = Handler}} = State) ->
    psip_log:debug("psip trans: canceling server transaction", []),
    psip_uas:process_cancel(make_trans(), Handler),
    {noreply, State};
handle_cast(cancel, #state{data = #client{} = Data} = State) ->
    psip_log:debug("psip trans: canceling client transaction", []),
    #client{outreq = OutReq} = Data,
    CancelReq = ersip_request_cancel:generate(OutReq),
    client_new(CancelReq, fun(_) -> ok end),
    {noreply, State};
handle_cast({received, _} = Ev, #state{trans = Trans} = State) ->
    psip_log:debug("psip trans: received message", []),
    {NewTrans, SE} = ersip_trans:event(Ev, Trans),
    NewState = State#state{trans = NewTrans},
    case process_se_list(SE, State) of
        continue ->
            {noreply, NewState};
        stop ->
            {stop, normal, NewState}
    end;
handle_cast(Request, State) ->
    psip_log:error("psip trans: unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info({event, TimerEvent}, #state{trans = Trans} = State) ->
    psip_log:debug("psip trans: timer fired ~p", [TimerEvent]),
    {NewTrans, SE} = ersip_trans:event(TimerEvent, Trans),
    NewState = State#state{trans = NewTrans},
    case process_se_list(SE, State) of
        continue ->
            {noreply, NewState};
        stop ->
            {stop, normal, NewState}
    end;
handle_info(Msg, State) ->
    psip_log:error("psip trans: unexpected info: ~p", [Msg]),
    {noreply, State}.

terminate(Reason, #state{}) ->
    case Reason of
        normal ->
            psip_log:debug("psip trans: finished", []);
        _ ->
            psip_log:error("psip trans: finished with error: ~p", [Reason])
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

-spec process_se_list([ersip_trans_se:side_effect()], state()) -> continue | stop.
process_se_list([], #state{}) ->
    continue;
process_se_list([SE | Rest], #state{} = State) ->
    case process_se(SE, State) of
        stop -> stop;
        continue ->
            process_se_list(Rest, State)
    end.

-spec process_se(ersip_trans_se:side_effect(), state()) -> continue | stop.
process_se({tu_result, SipMsg}, #state{data = #server{handler = Handler}}) ->
    case psip_handler:transaction(make_trans(), SipMsg, Handler) of
        ok -> ok;
        process_uas ->
            psip_uas:process(make_trans(), SipMsg, Handler)
    end,
    continue;
process_se({tu_result, SipMsg}, #state{data = #client{callback = Callback}}) ->
    Callback({message, SipMsg}),
    continue;
process_se({set_timer, {Timeout, TimerEvent}}, #state{}) ->
    psip_log:debug("psip trans: set timer on ~p ms: ~p", [Timeout, TimerEvent]),
    erlang:send_after(Timeout, self(), {event, TimerEvent}),
    continue;
process_se({clear_trans, normal}, #state{data = #server{}}) ->
    psip_log:debug("psip trans: transaction cleared: normal", []),
    stop;
process_se({clear_trans, Reason}, #state{data = #server{handler = Handler}}) ->
    psip_log:debug("psip trans: transaction cleared: ~p", [Reason]),
    psip_handler:transaction_stop({trans, self()}, Reason, Handler),
    stop;
process_se({clear_trans, Reason}, #state{data = #client{callback = Callback}}) ->
    psip_log:debug("psip trans: client transaction cleared: ~p", [Reason]),
    Callback({stop, Reason}),
    stop;
process_se({send_request, OutReq}, #state{}) ->
    psip_log:debug("psip trans: sending request", []),
    psip_udp_port:send_request(OutReq),
    continue;
process_se({send_response, Response}, #state{data = #server{origmsg = ReqSipMsg}}) ->
    psip_log:debug("psip trans: sending response", []),
    psip_source:send_response(Response, ReqSipMsg),
    continue.

-spec make_trans() -> trans().
make_trans() ->
    {trans, self()}.
