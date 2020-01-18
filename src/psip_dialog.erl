%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP Dialog
%%%

-module(psip_dialog).

-behaviour(gen_server).

-export([uas_find/1,
         start_link/1,
         uas_request/1,
         uas_response/2,
         uac_request/2,
         uac_result/2
        ]).

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

-record(state, {id :: ersip_dialog:id(),
                dialog :: ersip_dialog:dialog(),
                local_contact :: [ersip_hdr_contact:contact()]
               }).
-type state() :: #state{}.

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type trans() :: {trans, pid()}.
-type dialog_handle() :: pid().

%%===================================================================
%% API
%%===================================================================

-spec uas_find(ersip_sipmsg:sipmsg()) -> {ok, dialog_handle()} | not_found.
uas_find(ReqSipMsg) ->
    case ersip_dialog:uas_dialog_id(ReqSipMsg) of
        no_dialog -> not_found;
        {ok, DialogId} ->
            find_dialog(DialogId)
    end.

-spec start_link(term()) -> start_link_ret().
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec uas_request(ersip_sipmsg:sipmsg()) -> process | {reply, ersip_sipmsg:sipmsg()}.
uas_request(SipMsg) ->
    case ersip_dialog:uas_dialog_id(SipMsg) of
        no_dialog ->
            uas_validate_request(SipMsg);
        {ok, DialogId} ->
            case find_dialog(DialogId) of
                not_found ->
                    psip_log:warning("psip dialog: cannot find dialog ~p", [DialogId]),
                    Resp = ersip_sipmsg:reply(481, SipMsg),
                    {reply, Resp};
                {ok, DialogPid} ->
                    try
                        gen_server:call(DialogPid, {uas_request, SipMsg})
                    catch
                        exit:{noproc, _} ->
                            Resp = ersip_sipmsg:reply(481, SipMsg),
                            {reply, Resp}
                    end
            end
    end.

-spec uas_response(ersip_sipmsg:sipmsg(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
uas_response(RespSipMsg, ReqSipMsg) ->
    case ersip_sipmsg:dialog_id(uas, RespSipMsg) of
        no_dialog -> RespSipMsg;
        {ok, DialogId} ->
            case find_dialog(DialogId) of
                not_found ->
                    uas_maybe_create_dialog(RespSipMsg, ReqSipMsg);
                {ok, DialogPid} ->
                    uas_pass_response(DialogPid, RespSipMsg, ReqSipMsg)
            end
    end.

-spec uac_request(ersip_dialog:id(), ersip_sipmsg:sipmsg())
                 -> {ok, ersip_sipmsg:sipmsg()} | {error, no_dialog}.
uac_request(DialogId, SipMsg) ->
    case find_dialog(DialogId) of
        {ok, DialogPid} ->
            gen_server:call(DialogPid, {uac_request, SipMsg});
        not_found ->
            {error, no_dialog}
    end.

-spec uac_result(ersip_request:request(), ersip_trans:trans_result()) -> ok.
uac_result(OutReq, TransResult) ->
    case ersip_request:dialog_id(OutReq) of
        no_dialog ->
            %% Out of dialog request, maybe creates new dialog...
            uac_no_dialog_result(OutReq, TransResult);
        {ok, DialogId} ->
            case find_dialog(DialogId) of
                not_found ->
                    psip_log:warning("dialog ~p is not found", [DialogId]),
                    ok;
                {ok, DialogPid} ->
                    uac_trans_result(DialogPid, TransResult)
            end
    end.


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

init({uas, RespSipMsg, ReqSipMsg}) ->
    {ok, DialogId} = ersip_sipmsg:dialog_id(uas, RespSipMsg),
    gproc:add_local_name(DialogId),
    State = #state{id     = DialogId,
                   dialog = ersip_dialog:uas_create(ReqSipMsg, RespSipMsg),
                   local_contact = ersip_sipmsg:get(contact, RespSipMsg)
                  },
    psip_log:debug("psip dialog: started by UAS with id: ~p", [DialogId]),
    {ok, State};
init({uac, OutReq, RespSipMsg}) ->
    {ok, DialogId} = ersip_sipmsg:dialog_id(uac, RespSipMsg),
    case ersip_dialog:uac_new(OutReq, RespSipMsg) of
        {ok, Dialog} ->
            OutSipMsg = ersip_request:sipmsg(OutReq),
            gproc:add_local_name(DialogId),
            State = #state{id           = DialogId,
                           dialog       = Dialog,
                           local_contact = ersip_sipmsg:get(contact, OutSipMsg)
                          },
            psip_log:debug("psip dialog: started by UAC with id: ~p", [DialogId]),
            {ok, State};
        {error, _} = Error ->
            psip_log:warning("psip dialog: cannot create dialog ~p", [Error]),
            {stop, Error}
    end.

handle_call({uas_request, SipMsg}, _From, #state{dialog = Dialog} = State) ->
    ReqType = request_type(SipMsg),
    case ersip_dialog:uas_process(SipMsg, ReqType, Dialog) of
        {ok, Dialog1} ->
            {reply, process, State#state{dialog = Dialog1}};
        {reply, _} = Reply ->
            {reply, Reply, State}
    end;
handle_call({uas_pass_response, RespSipMsg, ReqSipMsg}, _From, #state{dialog = Dialog} = State) ->
    {NewDialog, Resp} = ersip_dialog:uas_pass_response(ReqSipMsg, RespSipMsg, Dialog),
    NewState  = State#state{dialog = NewDialog},
    Resp1 = maybe_set_contact(Resp, State),
    case ersip_sipmsg:method(Resp1) == ersip_method:bye() of
        true ->
            {stop, normal, Resp1, NewState};
        false ->
            {reply, Resp1, NewState}
    end;
handle_call({uac_request, SipMsg}, _From, #state{dialog = Dialog} = State) ->
    {NewDialog, DlgSipMsg1} = ersip_dialog:uac_request(SipMsg, Dialog),
    NewState  = State#state{dialog = NewDialog},
    {reply, {ok, DlgSipMsg1}, NewState};
handle_call(Request, _From, State) ->
    psip_log:error("psip dialog: unexpected call: ~p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({uac_early_trans_result, {stop, timeout}}, #state{} = State) ->
    psip_log:warning("psip dialog: stopped because timeout", []),
    {stop, normal, State};
handle_cast({uac_early_trans_result, {stop, _}}, #state{} = State) ->
    {noreply, State};
handle_cast({uac_early_trans_result, {message, RespSipMsg}}, #state{dialog = Dialog} = State) ->
    case ersip_dialog:uac_update(RespSipMsg, Dialog) of
        terminate_dialog ->
            {stop, normal, State};
        {ok, Dialog1} ->
            NewState = State#state{dialog = Dialog1},
            {noreply, NewState}
    end;
handle_cast({uac_trans_result, {stop, timeout}}, #state{} = State) ->
    psip_log:warning("psip dialog: stopped because timeout", []),
    {stop, normal, State};
handle_cast({uac_trans_result, {stop, _}}, #state{} = State) ->
    {noreply, State};
handle_cast({uac_trans_result, {message, RespSipMsg}}, #state{dialog = Dialog} = State) ->
    ReqType = request_type(RespSipMsg),
    psip_log:debug("psip dialog: transaction result ~p", [ReqType]),
    case ersip_dialog:uac_trans_result(RespSipMsg, ReqType, Dialog) of
        terminate_dialog ->
            {stop, normal, State};
        {ok, Dialog1} ->
            NewState = State#state{dialog = Dialog1},
            case ersip_sipmsg:method(RespSipMsg) == ersip_method:bye() of
                true ->
                    {stop, normal, NewState};
                false ->
                    {noreply, NewState}
            end
    end;
handle_cast(Request, State) ->
    psip_log:error("psip dialog: unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info(Msg, State) ->
    psip_log:error("psip dialog: unexpected info: ~p", [Msg]),
    {noreply, State}.

terminate(Reason, #state{}) ->
    case Reason of
        normal ->
            psip_log:debug("psip dialog: finished", []);
        _ ->
            psip_log:error("psip dialog: finished with error: ~p", [Reason])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal implementation
%%===================================================================

-spec find_dialog(ersip_dialog:id()) -> {ok, pid()} | not_found.
find_dialog(DialogId) ->
    case gproc:lookup_local_name(DialogId) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            not_found
    end.


-spec uas_validate_request(ersip_sipmsg:sipmsg()) -> process | {reply, ersip_sipmsg:sipmsg()}.
uas_validate_request(ReqSipMsg) ->
    case need_create_dialog(ReqSipMsg) of
        false -> process;
        true ->
            case ersip_dialog:uas_verify(ReqSipMsg) of
                ok -> process;
                {reply, _} = Reply -> Reply
            end
    end.

-spec uas_maybe_create_dialog(ersip_sipmsg:sipmsg(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
uas_maybe_create_dialog(RespSipMsg, ReqSipMsg) ->
    case ersip_sipmsg:status(RespSipMsg) of
        Status when Status > 100, Status =< 299 ->
            case need_create_dialog(ReqSipMsg) of
                true  -> uas_start_dialog(RespSipMsg, ReqSipMsg);
                false -> RespSipMsg
            end;
        _ ->
            RespSipMsg
    end.


-spec uas_start_dialog(ersip_sipmsg:sipmsg(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
uas_start_dialog(RespSipMsg, ReqSipMsg) ->
    Args = {uas, RespSipMsg, ReqSipMsg},
    case psip_dialog_sup:start_child([Args]) of
        {ok, DialogPid} ->
            uas_pass_response(DialogPid, RespSipMsg, ReqSipMsg);
        {error, _} = Error ->
            psip_log:error("failed to start dialog ~p", [Error]),
            RespSipMsg
    end.

-spec uac_start_dialog(ersip_request:request(), ersip_sipmsg:sipmsg()) -> ok.
uac_start_dialog(OutReq, RespSipMsg) ->
    InitArgs = {uac, OutReq, RespSipMsg},
    case psip_dialog_sup:start_child([InitArgs]) of
        {ok, _} -> ok;
        {error, _} = Error ->
            psip_log:error("failed to start dialog ~p", [Error]),
            ok
    end.

-spec uas_pass_response(pid(), ersip_sipmsg:sipmsg(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
uas_pass_response(DialogPid, RespSipMsg, ReqSipMsg) ->
    try
        gen_server:call(DialogPid, {uas_pass_response, RespSipMsg, ReqSipMsg})
    catch
        exit:{noproc, _} ->
            psip_log:warning("dialog ~p is finished, pass response without dialog processing", [DialogPid]),
            RespSipMsg
    end.

-spec need_create_dialog(ersip_sipmsg:sipmsg()) -> boolean().
need_create_dialog(ReqSipMsg) ->
    ersip_sipmsg:method(ReqSipMsg) == ersip_method:invite().

-spec uac_trans_result(pid(), psip_trans:trans_result()) -> ok.
uac_trans_result(DialogPid, TransResult) ->
    gen_server:cast(DialogPid, {uac_trans_result, TransResult}).

-spec uac_early_trans_result(pid(), psip_trans:trans_result()) -> ok.
uac_early_trans_result(DialogPid, TransResult) ->
    gen_server:cast(DialogPid, {uac_early_trans_result, TransResult}).

-spec uac_no_dialog_result(ersip_request:request(), psip_trans:trans_result()) -> ok.
uac_no_dialog_result(OutReq, {stop, timeout} = TransResult) ->
    ReqSipMsg = ersip_request:sipmsg(OutReq),
    case need_create_dialog(ReqSipMsg) of
        true ->
            Branch = ersip_request:branch(OutReq),
            case find_dialog(Branch) of
                not_found -> ok;
                {ok, DialogPid} ->
                    uac_early_trans_result(DialogPid, TransResult)
            end;
        false -> ok
    end;
uac_no_dialog_result(_, {stop, _}) ->
    ok;
uac_no_dialog_result(OutReq, {message, RespSipMsg}) ->
    ReqSipMsg = ersip_request:sipmsg(OutReq),
    case need_create_dialog(ReqSipMsg) of
        true  -> uac_ensure_dialog(OutReq, RespSipMsg);
        false -> ok
    end.

-spec uac_ensure_dialog(ersip_request:request(), ersip_sipmsg:sipmsg()) -> ok.
uac_ensure_dialog(OutReq, RespSipMsg) ->
    case ersip_sipmsg:dialog_id(uac, RespSipMsg) of
        no_dialog ->
            CallId = ersip_sipmsg:callid(RespSipMsg),
            From = ersip_sipmsg:from(RespSipMsg),
            To   = ersip_sipmsg:to(RespSipMsg),
            psip_log:warning("dialog: no to-tag in response: callid: ~s; from: ~s; to: ~s",
                             [ersip_hdr_callid:assemble(CallId),
                              ersip_hdr_fromto:assemble(From),
                              ersip_hdr_fromto:assemble(To)
                             ]),
            ok;
        {ok, DialogId} ->
            case find_dialog(DialogId) of
                not_found ->
                    case ersip_sipmsg:status(RespSipMsg) of
                        Status when Status > 100, Status =< 299 ->
                            psip_log:debug("dialog ~p not found, create new one", [DialogId]),
                            uac_start_dialog(OutReq, RespSipMsg);
                        _ -> ok
                    end;
                {ok, DialogPid} ->
                    uac_early_trans_result(DialogPid, {message, RespSipMsg})
            end
    end.

-spec maybe_set_contact(ersip_sipmsg:sipmsg(), state()) -> ersip_sipmsg:sipmsg().
maybe_set_contact(SipMsg, #state{local_contact = LocalContact}) ->
    case ersip_sipmsg:find(contact, SipMsg) of
        {ok, _} ->
            SipMsg;
        not_found ->
            ersip_sipmsg:set(contact, LocalContact, SipMsg);
        {error, _} = Error ->
            psip_log:error("overriding SIP message has bad contact: ~p", [Error]),
            ersip_sipmsg:set(contact, LocalContact, SipMsg)
    end.

-spec request_type(ersip_sipmsg:sipmsg()) -> ersip_dialog:request_type().
request_type(SipMsg) ->
    case ersip_sipmsg:method(SipMsg) == ersip_method:invite() of
        true ->
            target_refresh;
        false ->
            regular
    end.
