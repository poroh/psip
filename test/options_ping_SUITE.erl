%%%
%%% Copyright (c) 2020 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP OPTIONS ping test
%%%

-module(options_ping_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").

-compile(export_all).
-compile(nowarn_export_all).

all() -> [ping_udp].

init_per_suite(Config) ->
    application:ensure_all_started(psip),
    Config.

end_per_suite(Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    ok = psip_tport:start_udp(#{}),
    Config.

end_per_testcase(_TestCase, _Config) ->
    psip_tport:stop_udp(),
    ok.

ping_udp(_Config) ->
    ok.
