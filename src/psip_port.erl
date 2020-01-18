%%%
%%% Copyright (c) 2020 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP transport
%%%

-module(psip_port).

-export([start_udp/1,
         local_uri/1,
         send_request/1]).
-export([start_link/2]).

%%===================================================================
%% Types
%%===================================================================

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.

%%===================================================================
%% API
%%===================================================================

-spec start_udp(psip_port_udp:start_opts()) -> start_link_ret().
start_udp(UdpStartOpts) ->
    psip_port_sup:start_child([udp, UdpStartOpts]).

-spec local_uri(ersip_sipmsg:sipmsg()) -> ersip_uri:uri().
local_uri(_SipMsg) ->
    psip_port_udp:local_uri().

-spec send_request(ersip_request:request()) -> ok.
send_request(OutReq) ->
    psip_port_udp:send_request(OutReq).

%%===================================================================
%% Called from supervisor
%%===================================================================

-spec start_link(term(), []) -> start_link_ret().
start_link(udp, StartOpts) ->
    psip_port_udp:start_link(StartOpts).
