%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% UAC
%%%

-module(psip_uac).

-export([request/3,
         request/2,
         request_with_opts/3,
         ack_request/1,
         cancel/1
        ]).

-export_type([options/0]).

%%===================================================================
%% Types
%%===================================================================

-type callback() :: fun((client_trans_result()) -> any()).
-type client_trans_result() :: psip_trans:client_result().
-type id() :: {uac_id, psip_trans:trans()}.
-type options() :: #{sip => ersip:sip_options()}.

-export_type([id/0, callback/0]).

%%===================================================================
%% API
%%===================================================================

-spec request(ersip_sipmsg:sipmsg(), ersip_uri:uri(), callback()) -> id().
request(SipMsg, Nexthop, UACCallBack) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch, Nexthop),
    CallbackFun = make_transaction_handler(OutReq, UACCallBack),
    Trans = psip_trans:client_new(OutReq, #{}, CallbackFun),
    {uac_id, Trans}.

-spec request(ersip_sipmsg:sipmsg(), callback()) -> id().
request(SipMsg, UACCallBack) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch),
    CallbackFun = make_transaction_handler(OutReq, UACCallBack),
    Trans = psip_trans:client_new(OutReq, #{}, CallbackFun),
    {uac_id, Trans}.

-spec request_with_opts(ersip_sipmsg:sipmsg(), options(), callback()) -> id().
request_with_opts(SipMsg, UACOptions, UACCallBack) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch),
    CallbackFun = make_transaction_handler(OutReq, UACCallBack),
    Trans = psip_trans:client_new(OutReq, UACOptions, CallbackFun),
    {uac_id, Trans}.

-spec ack_request(ersip_sipmsg:sipmsg()) -> ok.
ack_request(SipMsg) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch),
    psip_tport:send_request(OutReq).

-spec cancel(id()) -> ok.
cancel({uac_id, Trans}) ->
    psip_trans:client_cancel(Trans).

%%===================================================================
%% Internal Implementation
%%===================================================================

-spec make_transaction_handler(ersip_request:request(), callback()) -> callback().
make_transaction_handler(OutReq, CB) ->
    fun({stop, normal}) ->
            ok;
       (TransResult) ->
            psip_dialog:uac_result(OutReq, TransResult),
            CB(TransResult)
    end.

