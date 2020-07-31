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
         uac_result/2,
         count/0,
         set_owner/2
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
                local_contact :: [ersip_hdr_contact:contact()],
                early_branch  :: ersip_branch:branch() | undefined,
                log_id :: string(),
                dialog_type :: type(),
                need_cleanup = true :: boolean(),
                owner_mon  :: reference() | undefined
               }).
-type state() :: #state{}.

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type trans() :: {trans, pid()}.
-type dialog_handle() :: pid().
-type type() :: invite | notify.

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
    gen_server:start_link(?MODULE, Args, [{hibernate_after, 1000}]).

-spec uas_request(ersip_sipmsg:sipmsg()) -> process | {reply, ersip_sipmsg:sipmsg()}.
uas_request(SipMsg) ->
    case ersip_dialog:uas_dialog_id(SipMsg) of
        no_dialog ->
            uas_validate_request(SipMsg);
        {ok, DialogId} ->
            case find_dialog(DialogId) of
                not_found ->
                    psip_log:warning("dialog ~s: cannot find dialog", [uas_log_id(SipMsg)]),
                    Resp = ersip_sipmsg:reply(481, SipMsg),
                    {reply, Resp};
                {ok, DialogPid} ->
                    try
                        gen_server:call(DialogPid, {uas_request, SipMsg})
                    catch
                        exit:{X, _} when X == normal; X == noproc ->
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

-spec uac_result(ersip_request:request(), ersip_trans:result()) -> ok.
uac_result(OutReq, TransResult) ->
    case ersip_request:dialog_id(OutReq) of
        no_dialog ->
            %% Out of dialog request, maybe creates new dialog...
            uac_no_dialog_result(OutReq, TransResult);
        {ok, DialogId} ->
            case find_dialog(DialogId) of
                not_found ->
                    SipMsg = ersip_request:sipmsg(OutReq),
                    psip_log:warning("dialog: ~s is not found for request ~s", [uac_log_id(SipMsg), ersip_sipmsg:method_bin(SipMsg)]),
                    ok;
                {ok, DialogPid} ->
                    uac_trans_result(DialogPid, TransResult)
            end
    end.

-spec set_owner(pid(), ersip_dialog:id()) -> ok.
set_owner(Pid, DialogId) when is_pid(Pid) ->
    case find_dialog(DialogId) of
        {ok, DialogPid} ->
            gen_server:cast(DialogPid, {set_owner, Pid});
        not_found ->
            ok
    end.

-spec count() -> non_neg_integer().
count() ->
    psip_dialog_sup:num_active().

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
    gproc:add_local_name({?MODULE, DialogId}),
    State = #state{id     = DialogId,
                   dialog = ersip_dialog:uas_create(ReqSipMsg, RespSipMsg),
                   local_contact = ersip_sipmsg:get(contact, RespSipMsg),
                   log_id = uas_log_id(RespSipMsg),
                   dialog_type = dialog_type(ReqSipMsg)
                  },
    log_info(State, "started by UAS", []),
    {ok, State};
init({uac, OutReq, RespSipMsg}) ->
    {ok, DialogId} = ersip_sipmsg:dialog_id(uac, RespSipMsg),
    EarlyBranch =
        case ersip_status:response_type(ersip_sipmsg:status(RespSipMsg)) of
            provisional ->
                Branch = ersip_request:branch(OutReq),
                BranchKey = ersip_branch:make_key(Branch),
                gproc:add_local_name({?MODULE, BranchKey}),
                Branch;
            _ ->
                undefined
        end,
    case ersip_dialog:uac_new(OutReq, RespSipMsg) of
        {ok, Dialog} ->
            OutSipMsg = ersip_request:sipmsg(OutReq),
            gproc:add_local_name({?MODULE, DialogId}),
            State = #state{id           = DialogId,
                           dialog       = Dialog,
                           local_contact = ersip_sipmsg:get(contact, OutSipMsg),
                           early_branch = EarlyBranch,
                           log_id       = uac_log_id(RespSipMsg),
                           dialog_type  = dialog_type(OutSipMsg)
                          },
            log_info(State, "started by UAC", []),
            {ok, State};
        {error, _} = Error ->
            psip_log:warning("dialog ~s: cannot create dialog, error: ~0p", [uac_log_id(RespSipMsg), Error]),
            {stop, Error}
    end.

handle_call({uas_request, SipMsg}, _From, #state{dialog = Dialog} = State) ->
    ReqType = request_type(SipMsg),
    case ersip_dialog:uas_process(SipMsg, ReqType, Dialog) of
        {ok, Dialog1} ->
            NewState =
                State#state{dialog = Dialog1,
                            need_cleanup = update_need_cleanup(State, SipMsg)},
            {reply, process, NewState};
        {reply, _} = Reply ->
            {reply, Reply, State}
    end;
handle_call({uas_pass_response, RespSipMsg, ReqSipMsg}, _From, #state{dialog = Dialog} = State) ->
    {NewDialog, Resp} = ersip_dialog:uas_pass_response(ReqSipMsg, RespSipMsg, Dialog),
    NewState  = State#state{dialog = NewDialog},
    Resp1 = maybe_set_contact(Resp, State),
    case ersip_sipmsg:method(Resp1) == ersip_method:bye() of
        true ->
            log_info(State, "finished after response on BYE ", []),
            {stop, normal, Resp1, NewState};
        false ->
            {reply, Resp1, NewState}
    end;
handle_call({uac_request, SipMsg}, _From, #state{dialog = Dialog} = State) ->
    {NewDialog, DlgSipMsg1} = ersip_dialog:uac_request(SipMsg, Dialog),
    NewState =
        State#state{dialog = NewDialog,
                    need_cleanup = update_need_cleanup(State, SipMsg)
                   },
    {reply, {ok, DlgSipMsg1}, NewState};
handle_call(Request, _From, State) ->
    log_error(State, "unexpected call: ~0p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({uac_early_trans_result, {stop, timeout}}, #state{} = State) ->
    log_warning(State, "stopped because timeout", []),
    {stop, normal, State};
handle_cast({uac_early_trans_result, {stop, _}}, #state{} = State) ->
    {noreply, State};
handle_cast({uac_early_trans_result, {message, RespSipMsg}}, #state{dialog = Dialog} = State) ->
    case ersip_dialog:uac_update(RespSipMsg, Dialog) of
        terminate_dialog ->
            log_info(State, "early dialog finished", []),
            {stop, normal, State};
        {ok, NewDialog} ->
            NewState =
                case need_unregister_branch_name(NewDialog, State) of
                    false -> State#state{dialog = NewDialog};
                    true ->
                        BranchKey = ersip_branch:make_key(State#state.early_branch),
                        gproc:unregister_name({n, l, {?MODULE, BranchKey}}),
                        State#state{dialog = NewDialog, early_branch = undefined}
                end,
            {noreply, NewState}
    end;
handle_cast({uac_trans_result, {stop, timeout}}, #state{} = State) ->
    log_warning(State, "stopped because timeout", []),
    {stop, normal, State};
handle_cast({uac_trans_result, {stop, _}}, #state{} = State) ->
    {noreply, State};
handle_cast({uac_trans_result, {message, RespSipMsg}}, #state{dialog = Dialog} = State) ->
    ReqType = request_type(RespSipMsg),
    log_debug(State, "transaction result: ~s: ~b ~s", [ersip_sipmsg:method_bin(RespSipMsg), ersip_sipmsg:status(RespSipMsg), ersip_sipmsg:reason(RespSipMsg)]),
    case ersip_dialog:uac_trans_result(RespSipMsg, ReqType, Dialog) of
        terminate_dialog ->
            log_info(State, "dialog by response", []),
            {stop, normal, State};
        {ok, Dialog1} ->
            NewState = State#state{dialog = Dialog1},
            case ersip_sipmsg:method(RespSipMsg) == ersip_method:bye() of
                true ->
                    log_info(State, "dialog on BYE request", []),
                    {stop, normal, NewState};
                false ->
                    {noreply, NewState}
            end
    end;
handle_cast({set_owner, Pid}, #state{} = State) ->
    log_debug(State, "set owner to ~p", [Pid]),
    OwnerMon = erlang:monitor(process, Pid),
    {noreply, State#state{owner_mon = OwnerMon}};
handle_cast(Request, State) ->
    log_error(State, "unexpected cast: ~0p", [Request]),
    {noreply, State}.

handle_info({'DOWN', Ref, process, Pid, _}, #state{owner_mon = Ref, need_cleanup = true} = State) ->
    case ersip_dialog:is_early(State#state.dialog) of
        true ->
            log_warning(State, "owner of early dialog is died: ~p; stop dialog", [Pid]),
            {noreply, State};
        false ->
            log_warning(State, "owner of confirmed dialog is died: ~p; destroy dialog gracefully", [Pid]),
            case State#state.dialog_type of
                invite ->
                    ByeReq0 = create_bye(),
                    {NewDialog, ByeReq} = ersip_dialog:uac_request(ByeReq0, State#state.dialog),
                    _ = psip_uac:request(ByeReq, fun(_) -> ok end),
                    {noreply, State#state{dialog = NewDialog}};
                notify -> error(not_supported_yet)
            end
    end;
handle_info({'DOWN', _Ref, process, _Pid, _}, #state{owner_mon = _} = State) ->
    {noreply, State};
handle_info(Msg, State) ->
    log_error(State, "unexpected info: ~0p", [Msg]),
    {noreply, State}.

terminate(Reason, #state{} = State) ->
    case Reason of
        normal ->
            log_debug(State, "finished", []);
        _ ->
            log_error(State, "finished with error: ~0p", [Reason])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal implementation
%%===================================================================

-spec find_dialog(ersip_dialog:id() | ersip_branch:branch_key()) -> {ok, pid()} | not_found.
find_dialog(Id) ->
    case gproc:lookup_local_name({?MODULE, Id}) of
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
            psip_log:error("dialog ~s: failed to start ~0p", [uas_log_id(RespSipMsg), Error]),
            RespSipMsg
    end.

-spec uac_start_dialog(ersip_request:request(), ersip_sipmsg:sipmsg()) -> ok.
uac_start_dialog(OutReq, RespSipMsg) ->
    InitArgs = {uac, OutReq, RespSipMsg},
    case psip_dialog_sup:start_child([InitArgs]) of
        {ok, _} -> ok;
        {error, _} = Error ->
            psip_log:error("dialog ~s: failed to start dialog ~0p", [uac_log_id(RespSipMsg), Error]),
            ok
    end.

-spec uas_pass_response(pid(), ersip_sipmsg:sipmsg(), ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
uas_pass_response(DialogPid, RespSipMsg, ReqSipMsg) ->
    try
        gen_server:call(DialogPid, {uas_pass_response, RespSipMsg, ReqSipMsg})
    catch
        exit:{X, _} when X == normal; X == noproc ->
            psip_log:warning("dialog ~0p is finished, pass response without dialog processing", [DialogPid]),
            RespSipMsg
    end.

-spec need_create_dialog(ersip_sipmsg:sipmsg()) -> boolean().
need_create_dialog(ReqSipMsg) ->
    ersip_sipmsg:method(ReqSipMsg) == ersip_method:invite().

-spec uac_trans_result(pid(), psip_trans:client_result()) -> ok.
uac_trans_result(DialogPid, TransResult) ->
    gen_server:cast(DialogPid, {uac_trans_result, TransResult}).

-spec uac_early_trans_result(pid(), psip_trans:client_result()) -> ok.
uac_early_trans_result(DialogPid, TransResult) ->
    gen_server:cast(DialogPid, {uac_early_trans_result, TransResult}).

-spec uac_no_dialog_result(ersip_request:request(), psip_trans:client_result()) -> ok.
uac_no_dialog_result(OutReq, {stop, timeout} = TransResult) ->
    ReqSipMsg = ersip_request:sipmsg(OutReq),
    case need_create_dialog(ReqSipMsg) of
        true ->
            Branch = ersip_request:branch(OutReq),
            BranchKey = ersip_branch:make_key(Branch),
            case find_dialog(BranchKey) of
                not_found -> ok;
                {ok, DialogPid} ->
                    uac_early_trans_result(DialogPid, TransResult)
            end;
        false -> ok
    end;
uac_no_dialog_result(_, {stop, _}) ->
    ok;
uac_no_dialog_result(OutReq, {message, RespSipMsg}) ->
    case ersip_sipmsg:status(RespSipMsg) of
        Status when Status > 100, Status =< 299 ->
            case need_create_dialog(RespSipMsg) of
                true  -> uac_ensure_dialog(OutReq, RespSipMsg);
                false -> ok
            end;
        _ -> ok
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
            psip_log:error("dialog: overriding SIP message has bad contact: ~0p", [Error]),
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

-spec need_unregister_branch_name(ersip_dialog:dialog(), state()) -> boolean().
need_unregister_branch_name(_Dialog, #state{early_branch = undefined}) ->
    false;
need_unregister_branch_name(Dialog, #state{}) ->
    not ersip_dialog:is_early(Dialog).


-spec log_tag(ersip_hdr_fromto:fromto()) -> binary().
log_tag(FromOrTo) ->
    case ersip_hdr_fromto:tag(FromOrTo) of
        undefined ->
            <<"<undefined>">>;
        {tag, T} ->
            T
    end.

-spec uac_log_id(ersip_sipmsg:sipmsg()) -> string().
uac_log_id(SipMsg) ->
    CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(SipMsg)),
    RemoteTag = log_tag(ersip_sipmsg:to(SipMsg)),
    LocalTag  = log_tag(ersip_sipmsg:from(SipMsg)),
    io_lib:format("~s ~s ~s", [CallId, LocalTag, RemoteTag]).

-spec uas_log_id(ersip_sipmsg:sipmsg()) -> string().
uas_log_id(SipMsg) ->
    CallId = ersip_hdr_callid:assemble(ersip_sipmsg:callid(SipMsg)),
    RemoteTag = log_tag(ersip_sipmsg:from(SipMsg)),
    LocalTag  = log_tag(ersip_sipmsg:to(SipMsg)),
    io_lib:format("~s ~s ~s", [CallId, LocalTag, RemoteTag]).

-spec dialog_type(ersip_sipmsg:sipmsg()) -> type().
dialog_type(SipMsg) ->
    INVITE = ersip_method:invite(),
    NOTIFY = ersip_method:notify(),
    case ersip_sipmsg:method(SipMsg) of
        INVITE -> invite;
        NOTIFY -> notify;
        M -> error({unexpected_method, M})
    end.

-spec create_bye() -> ersip_sipmsg:sipmsg().
create_bye() ->
    SipMsg0 = ersip_sipmsg:new_request(ersip_method:bye(), ersip_uri:make(<<"sip:domain.invalid">>)),
    ersip_sipmsg:set(maxforwards, ersip_hdr_maxforwards:make(70), SipMsg0).

-spec update_need_cleanup(state(), ersip_sipmsg:sipmsg()) -> boolean().
update_need_cleanup(#state{need_cleanup = false}, _SipMsg) ->
    false;
update_need_cleanup(#state{need_cleanup = true, dialog_type = invite}, SipMsg) ->
    ersip_sipmsg:method(SipMsg) /= ersip_method:bye();
update_need_cleanup(#state{need_cleanup = true, dialog_type = notify}, SipMsg) ->
    case ersip_sipmsg:find(subscription_state, SipMsg) of
        {ok, SubsState} ->
            ersip_hdr_subscription_state:value(SubsState) /= terminated;
        _ ->
            true
    end.




-spec log_debug(state(), string(), list()) -> ok.
log_debug(#state{log_id = LogId}, Format, Args) ->
    psip_log:debug("dialog: ~s: " ++ Format, [LogId | Args]).

-spec log_info(state(), string(), list()) -> ok.
log_info(#state{log_id = LogId}, Format, Args) ->
    psip_log:info("dialog: ~s: " ++ Format, [LogId | Args]).

-spec log_warning(state(), string(), list()) -> ok.
log_warning(#state{log_id = LogId}, Format, Args) ->
    psip_log:warning("dialog: ~s: " ++ Format, [LogId | Args]).

-spec log_error(state(), string(), list()) -> ok.
log_error(#state{log_id = LogId}, Format, Args) ->
    psip_log:error("dialog: ~s: " ++ Format, [LogId | Args]).


