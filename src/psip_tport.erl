%%%
%%% Copyright (c) 2020 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP transport
%%%

-module(psip_tport).

-export([start_udp/2,
         stop/1,
         local_uri/1,
         send_request/2]).
-export([start_link/3]).

%%===================================================================
%% Types
%%===================================================================

-type id()   :: term().
-type type() :: udp.
-type start_ret() :: ok |
                     {error, {already_started, pid()}} |
                     {error, term()}.
-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type start_opts() :: psip_udp_tport:start_opts().

%%===================================================================
%% API
%%===================================================================

-spec start_udp(id(), psip_tport_udp:start_opts()) -> start_ret().
start_udp(Id, UdpStartOpts) ->
    case psip_tport_sup:start_child([udp, Id, UdpStartOpts]) of
        {ok, _} ->
            ok;
        Error ->
            Error
    end.

-spec stop(id()) -> ok.
stop(Id) ->
    case psip_tport_table:find(Id) of
        {ok, Mod, Pid} ->
            Mod:stop(Pid);
        not_found ->
            psip_log:warning("tport: stop: port is not found; id: ~p", [Id])
    end.

-spec local_uri(id()) -> ersip_uri:uri().
local_uri(Id) ->
    case psip_tport_table:find(Id) of
        {ok, Mod, Pid} ->
            Mod:local_uri(Pid);
        not_found ->
            error("Cannot find transport")
    end.

-spec send_request(id() | undefined, ersip_request:request()) -> ok.
send_request(undefined, OutReq) ->
    NextHopURI = ersip_request:nexthop(OutReq),
    Transport = ersip_transport:make_by_uri(NextHopURI),
    case psip_tport_table:find_by_transport(Transport) of
        [{Mod, Pid} | _] ->
            Mod:send_request(Pid, OutReq);
        not_found ->
            psip_log:warning("tport: send: port is not found; nexthop: ~s", [ersip_uri:assemble(NextHopURI)]),
            ok
    end;
send_request(Id, OutReq) ->
    case psip_tport_table:find(Id) of
        {ok, Mod, Pid} ->
            Mod:send_request(Pid, OutReq);
        not_found ->
            psip_log:warning("tport: send: port is not found; id: ~p", [Id]),
            ok
    end.

%%===================================================================
%% Called from supervisor
%%===================================================================

-spec start_link(type(), id(), start_opts()) -> start_link_ret().
start_link(udp, TPortId, StartOpts) ->
    psip_tport_udp:start_link(TPortId, StartOpts).
