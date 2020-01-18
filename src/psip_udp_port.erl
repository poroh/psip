%%
%% Copyright (c) 2019 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Piraha SIP Stack
%% SIP port
%%

-module(psip_udp_port).

-behaviour(gen_server).
-behaviour(psip_source).

%% API
-export([start_link/0,
         set_handler/1,
         local_uri/0,
         send_request/1
        ]).

%% gen_server
-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

%% psip_source
-export([send_response/2]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% Types
%%%===================================================================

-record(state, {local_ip     :: inet:ip_address(),
                local_port   :: inet:port_number(),
                socket       :: gen_udp:socket(),
                handler      :: psip_handler:handler() | undefined
               }).
-type state() :: #state{}.
-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type source_options() :: {inet:ip_address(), inet:port_number()}.

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link() -> start_link_ret().
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

-spec set_handler(psip_handler:handler()) -> ok.
set_handler(Handler) ->
    gen_server:call(?SERVER, {set_handler, Handler}).

-spec local_uri() -> ersip_uri:uri().
local_uri() ->
    gen_server:call(?SERVER, local_uri).

-spec send_request(ersip_request:request()) -> ok.
send_request(OutReq) ->
    gen_server:cast(?SERVER, {send_request, OutReq}).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

-spec init(Args :: term()) ->
    {ok, State :: state()} | {ok, State :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term()} | ignore.
-spec handle_call(Request :: term(), From :: {pid(), Tag :: term()},
                      State :: state()) ->
    {reply, Reply :: term(), NewState :: state()} |
    {reply, Reply :: term(), NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), Reply :: term(), NewState :: state()} |
    {stop, Reason :: term(), NewState :: state()}.
-spec handle_cast(Request :: term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: state()}.
-spec handle_info(Info :: timeout | term(), State :: state()) ->
    {noreply, NewState :: state()} |
    {noreply, NewState :: state(), timeout() | hibernate | {continue, term()}} |
    {stop, Reason :: term(), NewState :: state()}.
-spec terminate(Reason :: (normal | shutdown | {shutdown, term()} |
                               term()),
                    State :: state()) ->
    term().
-spec code_change(OldVsn :: (term() | {down, term()}), State :: state(),
                      Extra :: term()) ->
    {ok, NewState :: state()} | {error, Reason :: term()}.

init([]) ->
    IPAddress = psip_config:listen_address(),
    Port = psip_config:listen_port(),
    psip_log:notice("psip udp port: starting at ~s:~p", [inet:ntoa(IPAddress), Port]),
    ExposedIP = psip_config:exposed_address(),
    ExposedPort = psip_config:exposed_port(),
    psip_log:notice("psip udp port: using ~s:~p as external address", [inet:ntoa(ExposedIP), ExposedPort]),
    case gen_udp:open(Port, [binary, {ip, IPAddress}, {active, once}]) of
        {error, _} = Error ->
            psip_log:error("psip udp port: failed to open port: ~p", [Error]),
            {stop, Error};
        {ok, Socket} ->
            State = #state{local_ip = ExposedIP,
                           local_port = ExposedPort,
                           socket = Socket},
            {ok, State}
    end.

handle_call({set_handler, Handler}, _From, State) ->
    NewState = State#state{handler = Handler},
    {reply, ok, NewState};
handle_call(local_uri, _From, #state{local_ip = LocalIP, local_port = LocalPort} = State) ->
    URI = ersip_uri:make([{host, ersip_host:make(LocalIP)},
                          {port, LocalPort}]),
    {reply, URI, State};
handle_call(Request, _From, State) ->
    psip_log:error("psip udp port: unexpected call: ~p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({send_response, SipMsg, RemoteAddr, RemotePort}, State) ->
    Msg = ersip_sipmsg:assemble(SipMsg),
    psip_log:debug("psip udp port: send message to ~s:~p:~n~s",
                   [inet:ntoa(RemoteAddr), RemotePort, Msg]),
    case gen_udp:send(State#state.socket, RemoteAddr, RemotePort, Msg) of
        ok -> ok;
        {error, _} = Error ->
            psip_log:warning("psip udp port: failed to send message: ~p", [Error]),
            ok
    end,
    {noreply, State};
handle_cast({send_request, OutReq}, State) ->
    NextHop = ersip_request:nexthop(OutReq),
    Host  = ersip_uri:host(NextHop),
    {RemoteIP, RemotePort} =
        case ersip_host:is_ip_address(Host) of
            true ->
                Port = case ersip_uri:port(NextHop) of
                           undefined -> 5060;
                           X -> X
                       end,
                {ersip_host:ip_address(Host), Port};
            false ->
                case ersip_uri:port(NextHop) of
                    undefined ->
                        psip_log:warning("psip udp port: srv DNS lookup is not supported yet", []),
                        {{240, 0, 0, 1}, 5060};
                    Port ->
                        HostStr = binary_to_list(ersip_host:assemble_bin(Host)),
                        case inet_res:lookup(HostStr, in, a) of
                            [IP | _Rest] ->
                                {IP, Port};
                            [] ->
                                psip_log:warning("psip udp port: DNS lookup failed: ~s", [HostStr]),
                                {{240, 0, 0, 1}, 5060}
                        end
                end
        end,
    Conn = ersip_conn:new(State#state.local_ip,
                          State#state.local_port,
                          RemoteIP,
                          RemotePort,
                          ersip_transport:udp(),
                          #{}),
    Msg = ersip_request:send_via_conn(OutReq, Conn),
    psip_log:debug("psip udp port: send message to ~s:~p:~n~s",
                   [inet:ntoa(RemoteIP), RemotePort, Msg]),
    case gen_udp:send(State#state.socket, RemoteIP, RemotePort, Msg) of
        ok -> ok;
        {error, _} = Error ->
            psip_log:warning("psip udp port: failed to send message: ~p", [Error]),
            ok
    end,
    {noreply, State};
handle_cast(Request, State) ->
    psip_log:error("psip udp port: unexpected cast: ~p", [Request]),
    {noreply, State}.

handle_info({udp, Socket, IP, Port, Msg}, #state{socket=Socket} = State) ->
    psip_log:debug("psip udp port: new message:~n~s", [Msg]),
    recv_message(IP, Port, Msg, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
handle_info(Msg, State) ->
    psip_log:error("psip udp port: unexpected info: ~p", [Msg]),
    {noreply, State}.

terminate(normal, #state{socket = Socket}) ->
    psip_log:notice("psip udp port: stopped", []),
    gen_udp:close(Socket);
terminate(Reason, #state{socket = Socket}) ->
    psip_log:error("psip udp port: stopped with reason ~p", [Reason]),
    gen_udp:close(Socket).

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% psip_source callbacks
%%%===================================================================

-spec send_response(ersip_sipmsg:sipmsg(), source_options()) -> ok.
send_response(SipMsg, {RemoteAddr, RemotePort}) ->
    gen_server:cast(?SERVER, {send_response, SipMsg, RemoteAddr, RemotePort}).

%%%===================================================================
%%% Internal implementation
%%%===================================================================

-spec recv_message(inet:ip_address(), inet:port_number(), binary(), state()) -> ok.
recv_message(RemoteIP, RemotePort, Message, State) ->
    SourceOpts = make_source_options(RemoteIP, RemotePort),
    SourceId = psip_source:make_source_id(?MODULE, SourceOpts),
    Conn = ersip_conn:new(State#state.local_ip,
                          State#state.local_port,
                          RemoteIP,
                          RemotePort,
                          ersip_transport:udp(),
                          #{source_id => SourceId}),
    {_, ConnSE} = ersip_conn:conn_data(Message, Conn),
    process_side_effects(ConnSE, State),
    ok.

-spec process_side_effects([ersip_conn_se:side_effect()], state()) -> ok.
process_side_effects([], _State) ->
    ok;
process_side_effects([E|Rest], State) ->
    process_side_effect(E, State),
    process_side_effects(Rest, State).

-spec process_side_effect(ersip_conn_se:side_effect(), state()) -> ok.
process_side_effect({bad_message, Data, Error}, _State) when is_binary(Data) ->
    psip_log:warning("psip udp port: bad message received: ~p~n~s", [Error, Data]);
process_side_effect({bad_message, Data, Error}, _State) ->
    psip_log:warning("psip udp port: bad message received: ~p~n~s", [Error, ersip_msg:serialize(Data)]);
process_side_effect({new_request, Msg}, State) ->
    psip_log:debug("psip udp port: process new request", []),
    case State#state.handler of
        undefined ->
            psip_log:warning("psip udp port: no handlers defined for requests", []),
            %% Send 503, expect that handler will appear
            unavailable_resp(Msg),
            ok;
        Handler ->
            case psip_handler:transp_request(Msg, Handler) of
                noreply -> ok;
                process_transaction ->
                    psip_trans:server_process(Msg, Handler)
            end
    end;
process_side_effect({new_response, Via, Msg}, _State) ->
    psip_log:debug("psip udp port: process new response", []),
    psip_trans:client_response(Via, Msg).


-spec make_source_options(inet:ip_address(), inet:port_number()) -> source_options().
make_source_options(IPAddr, Port) ->
    {IPAddr, Port}.

-spec unavailable_resp(ersip_msg:message()) -> ok.
unavailable_resp(Msg) ->
    case ersip_sipmsg:parse(Msg, all_required) of
        {ok, SipMsg} ->
            Resp = ersip_sipmsg:reply(503, SipMsg),
            psip_source:send_response(Resp, SipMsg);
        {error, _} = Error ->
            psip_log:warning("psip udp port: cannot parse message: ~p", [Error])
    end.
