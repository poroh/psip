%%%
%%% Copyright (c) 2020 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% SIP transport Table
%%%

-module(psip_tport_table).

-export([register/3,
         find/1,
         find_by_transport/1
        ]).

%%===================================================================
%% API
%%===================================================================

-spec register(psip_tport:id(), ersip_transport:transport(), module()) -> ok.
register(TPortId, Transport, Module) ->
    Name = {?MODULE, TPortId},
    gproc:add_local_name(Name),
    gproc:add_local_property({?MODULE, transport, Transport}, Module),
    gproc:set_attributes({n, l, Name}, [{module, Module}]).


-spec find(psip_tport:id()) -> {ok, module(), pid()} | not_found.
find(TPortId) ->
    Name = {?MODULE, TPortId},
    case gproc:lookup_local_name(Name) of
        undefined ->
            not_found;
        Pid when is_pid(Pid) ->
            Module = gproc:get_attribute({n, l, Name}, Pid, module),
            {ok, Module, Pid}
    end.

-spec find_by_transport(ersip_transport:transport()) -> [{module(), pid()}].
find_by_transport(TPort) ->
    Props = gproc:lookup_local_properties({?MODULE, transport, TPort}),
    [{Mod, Pid} || {Pid, Mod} <- Props].
