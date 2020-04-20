%%
%% Copyright (c) 2019 Dmitry Poroh
%% All rights reserved.
%% Distributed under the terms of the MIT License. See the LICENSE file.
%%
%% Piraha SIP Stack
%% SIP port
%%

-module(psip_tport_udp).

-behaviour(gen_server).
-behaviour(psip_source).

%% API
-export([start_link/1,
         stop/0,
         set_handler/1,
         local_uri/0,
         send_request/1
        ]).

-export_type([start_opts/0]).

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
                handler      :: psip_handler:handler() | undefined,
                log_messages :: boolean()
               }).
-type state() :: #state{}.
-type start_link_ret() :: {ok, pid()} |
                          {error, {already_started, pid()}} |
                          {error, term()}.
-type source_options() :: {inet:ip_address(), inet:port_number()}.
-type start_opts() :: #{
    listen_addr  => inet:ip_address(),
    listen_port  => inet:port_number(),
    exposed_addr => inet:ip_address(),
    exposed_port => inet:port_number(),
    handler      => psip_handler:handler(),
    log_messages => boolean()
}.

%%%===================================================================
%%% API
%%%===================================================================

-spec start_link(start_opts()) -> start_link_ret().
start_link(StartOpts) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, StartOpts, []).

-spec stop() -> ok.
stop() ->
    gen_server:stop(?SERVER).

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

init(StartOpts) ->
    IPAddress = maps:get(listen_addr, StartOpts, psip_inet:first_non_loopack_address()),
    Port = maps:get(listen_port, StartOpts, 5060),
    psip_log:notice("udp port: starting at ~s:~p", [inet:ntoa(IPAddress), Port]),
    ExposedIP = maps:get(exposed_addr, StartOpts, IPAddress),
    ExposedPort = maps:get(exposed_port, StartOpts, Port),
    Handler = maps:get(handler, StartOpts, undefined),
    psip_log:notice("udp port: using ~s:~p as external address", [inet:ntoa(ExposedIP), ExposedPort]),
    case gen_udp:open(Port, [binary, {ip, IPAddress}, {active, once}]) of
        {error, _} = Error ->
            psip_log:error("udp port: failed to open port: ~0p", [Error]),
            {stop, Error};
        {ok, Socket} ->
            State = #state{local_ip = ExposedIP,
                           local_port = ExposedPort,
                           socket = Socket,
                           handler = Handler,
                           log_messages = maps:get(log_messages, StartOpts, false)
                          },
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
    psip_log:error("udp port: unexpected call: ~0p", [Request]),
    {reply, {error, {unexpected_call, Request}}, State}.

handle_cast({send_response, SipMsg, RemoteAddr, RemotePort}, State) ->
    Msg = ersip_sipmsg:assemble(SipMsg),
    case State#state.log_messages of
        true ->  psip_log:debug("udp port: send: ~s:~b:~n~s", [inet:ntoa(RemoteAddr), RemotePort, Msg]);
        false -> psip_log:debug("udp port: send: ~s:~b: ~b ~s", [inet:ntoa(RemoteAddr), RemotePort, ersip_sipmsg:status(SipMsg), ersip_sipmsg:reason(SipMsg)])
    end,
    case gen_udp:send(State#state.socket, RemoteAddr, RemotePort, Msg) of
        ok -> ok;
        {error, _} = Error ->
            psip_log:warning("udp port: failed to send message: ~0p", [Error]),
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
                        psip_log:warning("udp port: srv DNS lookup is not supported yet", []),
                        {{240, 0, 0, 1}, 5060};
                    Port ->
                        HostStr = binary_to_list(ersip_host:assemble_bin(Host)),
                        case inet_res:lookup(HostStr, in, a) of
                            [IP | _Rest] ->
                                {IP, Port};
                            [] ->
                                psip_log:warning("udp port: DNS lookup failed: ~s", [HostStr]),
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
    case State#state.log_messages of
        true -> psip_log:debug("udp port: send: ~s:~p:~n~s", [inet:ntoa(RemoteIP), RemotePort, Msg]);
        false ->
            SipMsg = ersip_request:sipmsg(OutReq),
            psip_log:debug("udp port: send: ~s:~b; ~s ~s", [inet:ntoa(RemoteIP), RemotePort, ersip_sipmsg:method_bin(SipMsg), ersip_uri:assemble_bin(ersip_sipmsg:ruri(SipMsg))])
    end,
    case gen_udp:send(State#state.socket, RemoteIP, RemotePort, Msg) of
        ok -> ok;
        {error, _} = Error ->
            psip_log:warning("udp port: failed to send message: ~0p", [Error]),
            ok
    end,
    {noreply, State};
handle_cast(Request, State) ->
    psip_log:error("udp port: unexpected cast: ~0p", [Request]),
    {noreply, State}.

handle_info({udp, Socket, IP, Port, Msg}, #state{socket=Socket} = State) ->
    case State#state.log_messages of
        true  -> psip_log:debug("udp port: recv: ~s:~b~n~s", [inet:ntoa(IP), Port, Msg]);
        false -> ok
    end,
    recv_message(IP, Port, Msg, State),
    ok = inet:setopts(Socket, [{active, once}]),
    {noreply, State};
handle_info(Msg, State) ->
    psip_log:error("udp port: unexpected info: ~0p", [Msg]),
    {noreply, State}.

terminate(normal, #state{socket = Socket}) ->
    psip_log:notice("udp port: stopped", []),
    gen_udp:close(Socket);
terminate(Reason, #state{socket = Socket}) ->
    psip_log:error("udp port: stopped with reason ~0p", [Reason]),
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
    psip_log:warning("udp port: bad message received: ~0p~n~s", [Error, Data]);
process_side_effect({bad_message, Data, Error}, _State) ->
    psip_log:warning("udp port: bad message received: ~0p~n~s", [Error, ersip_msg:serialize(Data)]);
process_side_effect({new_request, Msg}, State) ->
    case State#state.log_messages of
        false ->
            {Host, Port} = ersip_source:remote(ersip_msg:source(Msg)),
            Method = ersip_method:to_binary(ersip_msg:get(method, Msg)),
            RURI   = ersip_msg:get(ruri, Msg),
            psip_log:debug("udp port: recv: ~s:~b: ~s ~s", [ersip_host:assemble_bin(Host), Port, Method, RURI]);
        true  -> ok
    end,
    case State#state.handler of
        undefined ->
            psip_log:warning("udp port: no handlers defined for requests", []),
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
process_side_effect({new_response, Via, Msg}, State) ->
    case State#state.log_messages of
        false ->
            {Host, Port} = ersip_source:remote(ersip_msg:source(Msg)),
            Status = ersip_msg:get(status, Msg),
            Reason = ersip_msg:get(reason, Msg),
            psip_log:debug("udp port: recv: ~s:~b: ~b ~s", [ersip_host:assemble_bin(Host), Port, Status, Reason]);
        true  -> ok
    end,
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
            psip_log:warning("udp port: cannot parse message: ~0p", [Error])
    end.
