%%%
%%% Copyright (c) 2019 Dmitry Poroh
%%% All rights reserved.
%%% Distributed under the terms of the MIT License. See the LICENSE file.
%%%
%%% Piraha SIP Stack
%%% B2BUA Suprvisor
%%%

-module(psip_b2bua_sup).

-behaviour(supervisor).

%% API
-export([start_link/0,
         start_child/1
        ]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% Types
%%====================================================================

-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type startchild_err() :: 'already_present'
			| {'already_started', Child :: child()} | term().
-type startchild_ret() :: {'ok', Child :: child()}
                        | {'ok', Child :: child(), Info :: term()}
			| {'error', startchild_err()}.
-type child() :: pid().

%%====================================================================
%% API functions
%%====================================================================

-spec start_link() -> start_link_ret().
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

-spec start_child(term()) -> startchild_ret().
start_child(Args) ->
    supervisor:start_child(?SERVER, Args).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

-spec init(term()) ->
    {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}
    | ignore.
init([]) ->
    SupFlags =
        #{strategy  => simple_one_for_one,
          intensity => 1000,
          period    => 1
         },
    ChildSpecs =
        [#{id      => psip_b2bua,
           start   => {psip_b2bua, start_link, []},
           type    => worker,
           restart => temporary
          }
        ],
    {ok, {SupFlags, ChildSpecs}}.
