%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP message source
%%%

-module(psip_source).

-export([make_source_id/2,
         send_response/2
        ]).

-export_type([options/0]).

-callback send_response(ersip_sipmsg:sipmsg(), options()) -> any().

%%===================================================================
%% Types
%%===================================================================

-type source_id() :: {psip_source, module(), options()}.
-type options() :: term().

%%===================================================================
%% API
%%===================================================================

-spec make_source_id(module(), options()) -> source_id().
make_source_id(Module, Args) ->
    {psip_source, Module, Args}.

-spec send_response(ersip_sipmsg:sipmsg(), ersip_sipmsg:sipmsg()) -> ok.
send_response(Resp, Req) ->
    {psip_source, Module, Args} = ersip_sipmsg:source_id(Req),
    Module:send_response(Resp, Args).
