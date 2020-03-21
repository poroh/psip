%%%
%%% Copyright (c) 2020 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% Configuration
%%%

-module(psip_config).

-export([init/0,
         allowed_methods/0,
         set_allowed_methods/1,
         uas_options/0,
         set_uas_options/1,
         log_transactions/0
        ]).

%%===================================================================
%% API
%%===================================================================

-spec init() -> ok.
init() ->
    set_allowed_methods(ersip_method_set:invite_set()),
    set_uas_options(default_uas_options()),
    ok.

-spec allowed_methods() -> ersip_method_set:set().
allowed_methods() ->
    {ok, Val} = application:get_env(psip, allowed_methods),
    Val.

-spec set_allowed_methods(ersip_method_set:set()) -> ok.
set_allowed_methods(AllowedSet) ->
    application:set_env(psip, allowed_methods, AllowedSet).

-spec uas_options() -> ersip_uas:options().
uas_options() ->
    {ok, Val} = application:get_env(psip, uas_options),
    Val.

-spec set_uas_options(ersip_uas:options()) -> ok.
set_uas_options(UASOptions) ->
    application:set_env(psip, uas_options, UASOptions).

-spec log_transactions() -> boolean().
log_transactions() ->
    application:get_env(psip, log_transactions, false).

%%===================================================================
%% Internal implementation
%%===================================================================

-spec default_uas_options() -> ersip_uas:options().
default_uas_options() ->
    #{check_scheme => fun check_scheme/1}.

-spec check_scheme(binary()) -> boolean().
check_scheme(<<"sip">>) -> true;
check_scheme(<<"sips">>) -> true;
check_scheme(<<"tel">>) -> true;
check_scheme(_) -> false.
