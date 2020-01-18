%%%
%%% Copyright (c) 2020 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% Inet-related functions
%%%

-module(psip_inet).

-export([first_non_loopack_address/0]).

%%===================================================================
%% API
%%===================================================================

-spec first_non_loopack_address() -> inet:ip_address().
first_non_loopack_address() ->
    {ok, IfAddrs} = inet:getifaddrs(),
    Candidates = [proplists:get_value(addr, Props) || {_IfName, Props} <- IfAddrs,
                                                      not is_loopback(Props),
                                                      has_address(Props)],
    [First | _ ] = lists:sort(Candidates),
    First.

%%===================================================================
%% API
%%===================================================================

-spec is_loopback(inet:getifaddrs_ifopts()) -> boolean().
is_loopback(Props) ->
    Flags = proplists:get_value(flags, Props),
    lists:member(loopback, Flags).

-spec has_address(inet:getifaddrs_ifopts()) -> boolean().
has_address(Props) ->
    proplists:get_value(addr, Props) /= undefined.

