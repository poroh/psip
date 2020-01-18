%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP stack handler
%%%

-module(psip_handler).

-export([new/2,
         transp_request/2,
         transaction/3,
         transaction_stop/3,
         uas_request/3,
         uas_cancel/2,
         process_ack/2
        ]).

-callback transp_request(ersip_msg:message(), any()) -> process_transaction | noreply.
-callback transaction(psip_trans:trans(), ersip_sipmsg:sipmsg(), any()) -> process_uas | ok.
-callback transaction_stop(psip_trans:trans(), any(), any()) -> ok.
-callback uas_request(psip_uas:uas(), ersip_sipmsg:sipmsg(), any()) -> ok.
-callback uas_cancel(psip_uas:id(), any()) -> ok.
-callback process_ack(ersip_sipmsg:sipmsg(), any()) -> ok.

-export_type([handler/0,
              transp_request_ret/0
             ]).

%%===================================================================
%% Types
%%===================================================================

-record(handler, {module :: module(),
                  args   :: term()
                 }).
-type handler() :: #handler{}.
-type transp_request_ret() :: noreply
                            | process_transaction.

%%===================================================================
%% API
%%===================================================================

-spec new(module(), any()) -> handler().
new(Module, Args) ->
    #handler{module = Module,
             args = Args
            }.

-spec transp_request(ersip_msg:message(), handler()) -> transp_request_ret().
transp_request(Msg, #handler{module = Mod, args = Args}) ->
    Mod:transp_request(Msg, Args).

-spec transaction(psip_trans:trans(), ersip_sipmsg:sipmsg(), handler()) -> ok | process_uas.
transaction(Trans, SipMsg, #handler{module = Mod, args = Args}) ->
    Mod:transaction(Trans, SipMsg, Args).

-spec transaction_stop(psip_trans:trans(), term(), handler()) -> ok.
transaction_stop(Trans, TransResult, #handler{module = Mod, args = Args}) ->
    Mod:transaction_stop(Trans, TransResult, Args).

-spec uas_request(psip_uas:uas(), ersip_sipmsg:sipmsg(), handler()) -> ok.
uas_request(UAS, ReqSipMsg, #handler{module = Mod, args = Args}) ->
    Mod:uas_request(UAS, ReqSipMsg, Args).

-spec uas_cancel(psip_uas:id(), handler()) -> ok.
uas_cancel(UASId, #handler{module = Mod, args = Args}) ->
    Mod:uas_cancel(UASId, Args).

-spec process_ack(ersip_sipmsg:sipmsg(), handler()) -> any().
process_ack(SipMsg, #handler{module = Mod, args = Args}) ->
    Mod:process_ack(SipMsg, Args).

