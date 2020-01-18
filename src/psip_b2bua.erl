%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP Back-to-back user agent
%%%

-module(psip_b2bua).

-export([start_link/1,
         join_dialogs/2,
         process/1,
         process_ack/1
        ]).

%% gen_server
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%%===================================================================
%% Types
%%===================================================================

-record(state, {ids :: {ersip_dialog:id(), ersip_dialog:id()}}).
-type state() :: #state{}.

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.

%%===================================================================
%% API
%%===================================================================

-spec start_link(term()) -> start_link_ret().
start_link(Args) ->
    gen_server:start_link(?MODULE, Args, []).

-spec join_dialogs(ersip_dialog:id(), ersip_dialog:id()) -> ok.
join_dialogs(DialogId1, DialogId2) ->
    Args = {DialogId1, DialogId2},
    {ok, _} = psip_b2bua_sup:start_child([Args]),
    ok.

-spec process(psip_uas:uas()) -> ok | not_found.
process(UAS) ->
    SipMsg = psip_uas:sipmsg(UAS),
    case ersip_sipmsg:dialog_id(uas, SipMsg) of
        no_dialog -> not_found;
        {ok, DialogId} ->
            case find_b2bua(DialogId) of
                {ok, Pid} ->
                    gen_server:cast(Pid, {pass, DialogId, UAS});
                not_found ->
                    not_found
            end
    end.

-spec process_ack(ersip_sipmsg:sipmsg()) -> ok | not_found.
process_ack(SipMsg) ->
    case ersip_sipmsg:dialog_id(uas, SipMsg) of
        no_dialog -> not_found;
        {ok, DialogId} ->
            case find_b2bua(DialogId) of
                {ok, Pid} ->
                    gen_server:cast(Pid, {pass_ack, DialogId, SipMsg});
                not_found ->
                    not_found
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

init({DialogId1, DialogId2}) ->
    gproc:add_local_name({b2bua, DialogId1}),
    gproc:add_local_name({b2bua, DialogId2}),
    psip_log:debug("b2bua: started by with ids: ~p ~p", [DialogId1, DialogId2]),
    State = #state{ids = {DialogId1, DialogId2}},
    {ok, State}.

handle_call(Request, _From, State) ->
    psip_log:error("b2bua: unexpected call: ~p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({pass_ack, SrcDialogId, AckSipMsg0}, #state{} = State) ->
    DstDialogId = another_dialog_id(SrcDialogId, State#state.ids),
    psip_log:debug("b2bua: passing ACK to: ~p", [DstDialogId]),
    AckSipMsg = pass_request(AckSipMsg0),
    case psip_dialog:uac_request(DstDialogId, AckSipMsg) of
        {ok, DstAckSipMsg} ->
            psip_uac:ack_request(DstAckSipMsg);
        {error, _} = Error ->
            psip_log:warning("b2bua: cannot pass message: ~p", [Error])
    end,
    {noreply, State};
handle_cast({pass, SrcDialogId, UAS}, #state{} = State) ->
    DstDialogId = another_dialog_id(SrcDialogId, State#state.ids),
    SipMsg0 = psip_uas:sipmsg(UAS),
    SipMsg = pass_request(SipMsg0),
    psip_log:debug("b2bua: passing ~s to: ~p", [ersip_sipmsg:method_bin(SipMsg), DstDialogId]),
    case psip_dialog:uac_request(DstDialogId, SipMsg) of
        {ok, DstSipMsg} ->
            psip_uac:request(DstSipMsg, make_req_callback(UAS));
        {error, _} = Error ->
            psip_log:warning("b2bua: cannot pass message: ~p", [Error])
    end,
    case ersip_sipmsg:method(SipMsg) == ersip_method:bye() of
        true ->
            {stop, normal, State};
        false ->
            {noreply, State}
    end;
handle_cast(Request, State) ->
    psip_log:error("b2bua: unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info(Msg, State) ->
    psip_log:error("b2bua: unexpected info: ~p", [Msg]),
    {noreply, State}.

terminate(Reason, #state{}) ->
    case Reason of
        normal ->
            psip_log:debug("b2bua: finished", []);
        _ ->
            psip_log:error("b2bua: finished with error: ~p", [Reason])
    end,
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%===================================================================
%% Internal implementation
%%===================================================================

-spec find_b2bua(ersip_dialog:id()) -> {ok, pid()} | not_found.
find_b2bua(DialogId) ->
    case gproc:lookup_local_name({b2bua, DialogId}) of
        Pid when is_pid(Pid) ->
            {ok, Pid};
        undefined ->
            not_found
    end.

-spec another_dialog_id(ersip_dialog:id(), {ersip_dialog:id(), ersip_dialog:id()}) -> ersip_dialog:id().
another_dialog_id(A, {A, B}) ->
    B;
another_dialog_id(B, {A, B}) ->
    A.

-spec make_req_callback(psip_uas:uas()) -> psip_uas:uas().
make_req_callback(UAS) ->
    fun({message, RespSipMsg}) ->
            OutResp = pass_response(RespSipMsg, UAS),
            psip_uas:response(OutResp, UAS);
       ({stop, _}) ->
            ok
    end.


-spec pass_response(ersip_sipmsg:sipmsg(), psip_uas:uas()) -> ersip_sipmsg:sipmsg().
pass_response(InResp, UAS) ->
    InitialReq = psip_uas:sipmsg(UAS),
    Reply = psip_uas:make_reply(ersip_sipmsg:status(InResp),
                                ersip_sipmsg:reason(InResp),
                                UAS),
    OutResp0 = ersip_sipmsg:reply(Reply, InitialReq),
    FilterHdrs = [ersip_hnames:make_key(<<"route">>),
                  ersip_hnames:make_key(<<"record-route">>)
                  | ersip_sipmsg:header_keys(OutResp0)],
    CopyHdrs = ersip_sipmsg:header_keys(InResp) -- FilterHdrs,
    OutResp1 = lists:foldl(fun(Hdr, OutR) ->
                                   ersip_sipmsg:copy(Hdr, InResp, OutR)
                           end,
                           OutResp0,
                           CopyHdrs),

    URI = psip_udp_port:local_uri(),
    Contact = ersip_hdr_contact:new(URI),
    OutResp2 = ersip_sipmsg:set(contact, [Contact], OutResp1),

    Body = ersip_sipmsg:body(InResp),
    ersip_sipmsg:set_body(Body, OutResp2).

-spec pass_request(ersip_sipmsg:sipmsg()) -> ersip_sipmsg:sipmsg().
pass_request(SipMsg0) ->
    %% Remove routing info
    SipMsg1 = ersip_sipmsg:remove_list([<<"via">>, route, record_route], SipMsg0),
    %% Generate Contact:
    URI = psip_udp_port:local_uri(),
    Contact = ersip_hdr_contact:new(URI),
    ersip_sipmsg:set(contact, [Contact], SipMsg1).
