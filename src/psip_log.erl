%%
%% Copyright (c) 2019 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Piraha SIP Stack
%% Log
%%

-module(psip_log).

-export([debug/2,
         info/2,
         notice/2,
         warning/2,
         error/2
        ]).

%%%===================================================================
%%% API
%%%===================================================================

-spec debug(io:format(), [term()]) -> ok.
debug(Format, Args) ->
    logger:log(debug, Format, Args).

-spec info(io:format(), [term()]) -> ok.
info(Format, Args) ->
    logger:log(info, Format, Args).

-spec notice(io:format(), [term()]) -> ok.
notice(Format, Args) ->
    logger:log(notice, Format, Args).

-spec warning(io:format(), [term()]) -> ok.
warning(Format, Args) ->
    logger:log(warning, Format, Args).

-spec error(io:format(), [term()]) -> ok.
error(Format, Args) ->
    logger:log(error, Format, Args).
