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
         ack_request/1,
         cancel/1
        ]).

%%===================================================================
%% Types
%%===================================================================

-type callback() :: fun((client_trans_result()) -> any()).
-type client_trans_result() :: psip_trans:client_result().
-type id() :: {uac_id, ersip_trans:trans()}.

%%===================================================================
%% API
%%===================================================================

-spec request(ersip_sipmsg:sipmsg(), ersip_host:host(), callback()) -> id().
request(SipMsg, Nexthop, UACCallBack) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch, Nexthop),
    CallbackFun = make_transaction_handler(OutReq, UACCallBack),
    Trans = psip_trans:client_new(OutReq, CallbackFun),
    {uac_id, Trans}.

-spec request(ersip_sipmsg:sipmsg(), callback()) -> ok.
request(SipMsg, UACCallBack) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch),
    CallbackFun = make_transaction_handler(OutReq, UACCallBack),
    psip_trans:client_new(OutReq, CallbackFun).

-spec ack_request(ersip_sipmsg:sipmsg()) -> ok.
ack_request(SipMsg) ->
    Branch = ersip_branch:make_random(6),
    OutReq = ersip_request:new(SipMsg, Branch),
    psip_udp_port:send_request(OutReq).

-spec cancel(id()) -> ok.
cancel({uac_id, Trans}) ->
    psip_trans:client_cancel(Trans).

%%===================================================================
%% Internal Implementation
%%===================================================================

-spec make_transaction_handler(ersip_request:request(), callback()) -> callback().
make_transaction_handler(OutReq, CB) ->
    fun(TransResult) ->
            psip_dialog:uac_result(OutReq, TransResult),
            CB(TransResult)
    end.

