%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%
-module(integration_SUITE).
-compile([export_all,
          nowarn_export_all]).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").

-import(rabbit_ct_broker_helpers, [rabbitmqctl_list/3,
                                   rpc_all/4]).
-import(rabbit_ct_helpers, [eventually/3]).
-import(util, [all_connection_pids/1]).

all() ->
    [
     {group, cluster_size_1},
     {group, cluster_size_3}
    ].

groups() ->
    [
     {cluster_size_1, [],
      [global_counters_v3, global_counters_v4]
      ++ tests()
     },
     {cluster_size_3, [],
      [queue_down_qos1]}
     ++ tests()
    ].

tests() ->
    [quorum_queue_rejects
     ,publish_to_all_queue_types_qos0
     ,publish_to_all_queue_types_qos1
     ,events
     ,event_authentication_failure
    ].

suite() ->
    [{timetrap, {minutes, 5}}].

%% -------------------------------------------------------------------
%% Testsuite setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
    rabbit_ct_helpers:log_environment(),
    rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(cluster_size_1 = Group, Config0) ->
    init_per_group0(Group,
                    rabbit_ct_helpers:set_config(Config0, [{rmq_nodes_count, 1}]));
init_per_group(cluster_size_3 = Group, Config0) ->
    init_per_group0(Group,
                    rabbit_ct_helpers:set_config(Config0, [{rmq_nodes_count, 3}])).

init_per_group0(Group, Config0) ->
    Config = rabbit_ct_helpers:set_config(
               Config0,
               [{rmq_nodename_suffix, Group},
                {rmq_extra_tcp_ports, [tcp_port_mqtt_extra,
                                       tcp_port_mqtt_tls_extra]}]),
    rabbit_ct_helpers:run_steps(
      Config,
      rabbit_ct_broker_helpers:setup_steps() ++
      rabbit_ct_client_helpers:setup_steps()).

end_per_group(_, Config) ->
    rabbit_ct_helpers:run_teardown_steps(
      Config,
      rabbit_ct_client_helpers:teardown_steps() ++
      rabbit_ct_broker_helpers:teardown_steps()).

init_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
    rabbit_ct_helpers:testcase_finished(Config, Testcase).

%% -------------------------------------------------------------------
%% Testsuite cases
%% -------------------------------------------------------------------

quorum_queue_rejects(Config) ->
    {_Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    Name = atom_to_binary(?FUNCTION_NAME),

    ok = rabbit_ct_broker_helpers:set_policy(
           Config, 0, <<"qq-policy">>, Name, <<"queues">>, [{<<"max-length">>, 1},
                                                            {<<"overflow">>, <<"reject-publish">>}]),
    declare_queue(Ch, Name, [{<<"x-queue-type">>, longstr, <<"quorum">>}]),
    bind(Ch, Name, Name),

    {C, _} = connect(Name, Config, [{retry_interval, 1}]),
    {ok, _} = emqtt:publish(C, Name, <<"m1">>, qos1),
    {ok, _} = emqtt:publish(C, Name, <<"m2">>, qos1),
    %% We expect m3 to be rejected and dropped.
    ?assertEqual(puback_timeout, util:publish_qos1_timeout(C, Name, <<"m3">>, 700)),

    ?assertMatch({#'basic.get_ok'{}, #amqp_msg{payload = <<"m1">>}},
                 amqp_channel:call(Ch, #'basic.get'{queue = Name, no_ack = true})),
    ?assertMatch({#'basic.get_ok'{}, #amqp_msg{payload = <<"m2">>}},
                 amqp_channel:call(Ch, #'basic.get'{queue = Name, no_ack = true})),
    %% m3 is re-sent by emqtt.
    ?awaitMatch({#'basic.get_ok'{}, #amqp_msg{payload = <<"m3">>}},
                amqp_channel:call(Ch, #'basic.get'{queue = Name, no_ack = true}),
                2000, 200),

    ok = emqtt:disconnect(C),
    delete_queue(Ch, Name),
    ok = rabbit_ct_broker_helpers:clear_policy(Config, 0, <<"qq-policy">>).

publish_to_all_queue_types_qos0(Config) ->
    publish_to_all_queue_types(Config, qos0).

publish_to_all_queue_types_qos1(Config) ->
    publish_to_all_queue_types(Config, qos1).

publish_to_all_queue_types(Config, QoS) ->
    %% Give only 1/10 of the default credits.
    %% We want to test whether sending many messages work when MQTT connection sometimes gets blocked.
    Result = rpc_all(Config, application, set_env, [rabbit, credit_flow_default_credit, {40, 20}]),
    Result = rpc_all(Config, application, set_env, [rabbit, quorum_commands_soft_limit, 3]),
    Result = rpc_all(Config, application, set_env, [rabbit, stream_messages_soft_limit, 25]),
    ?assert(lists:all(fun(R) -> R =:= ok end, Result)),

    {Conn, Ch} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),

    CQ = <<"classic-queue">>,
    CMQ = <<"classic-mirrored-queue">>,
    QQ = <<"quorum-queue">>,
    SQ = <<"stream-queue">>,
    Topic = <<"mytopic">>,

    declare_queue(Ch, CQ, []),
    bind(Ch, CQ, Topic),

    ok = rabbit_ct_broker_helpers:set_ha_policy(Config, 0, CMQ, <<"all">>),
    declare_queue(Ch, CMQ, []),
    bind(Ch, CMQ, Topic),

    declare_queue(Ch, QQ, [{<<"x-queue-type">>, longstr, <<"quorum">>}]),
    bind(Ch, QQ, Topic),

    declare_queue(Ch, SQ, [{<<"x-queue-type">>, longstr, <<"stream">>}]),
    bind(Ch, SQ, Topic),

    NumMsgs = 2000,
    {C, _} = connect(?FUNCTION_NAME, Config, [{retry_interval, 2}]),
    lists:foreach(fun(_N) ->
                          case QoS of
                              qos0 ->
                                  ok = emqtt:publish(C, Topic, <<"m">>);
                              qos1 ->
                                  {ok, _} = emqtt:publish(C, Topic, <<"m">>, [{qos, 1}])
                          end
                  end, lists:seq(1, NumMsgs)),

    eventually(?_assert(
                  begin
                      L = rabbitmqctl_list(Config, 0, ["list_queues", "messages", "--no-table-headers"]),
                      length(L) =:= 4 andalso
                      lists:all(fun([Bin]) ->
                                        N = binary_to_integer(Bin),
                                        case QoS of
                                            qos0 ->
                                                N =:= NumMsgs;
                                            qos1 ->
                                                %% Allow for some duplicates when client resends
                                                %% a message that gets acked at roughly the same time.
                                                N >= NumMsgs andalso
                                                N < NumMsgs * 2
                                        end
                                end, L)
                  end), 2000, 10),

    delete_queue(Ch, [CQ, CMQ, QQ, SQ]),
    ok = rabbit_ct_broker_helpers:clear_policy(Config, 0, CMQ),
    ok = emqtt:disconnect(C),
    ?awaitMatch([], all_connection_pids(Config), 10_000, 1000),
    ok = rabbit_ct_client_helpers:close_connection_and_channel(Conn, Ch).

events(Config) ->
    ok = rabbit_ct_broker_helpers:add_code_path_to_all_nodes(Config, event_recorder),
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    ok = gen_event:add_handler({rabbit_event, Server}, event_recorder, []),

    ClientId = atom_to_binary(?FUNCTION_NAME),
    {C, _} = connect(ClientId, Config),

    [E0, E1] = get_events(Server),
    assert_event_type(user_authentication_success, E0),
    assert_event_prop([{name, <<"guest">>},
                       {connection_type, network}],
                      E0),
    assert_event_type(connection_created, E1),
    assert_event_prop({protocol, {'MQTT', "3.1.1"}}, E1),

    {ok, _, _} = emqtt:subscribe(C, <<"TopicA">>, qos0),

    [E2, E3] = get_events(Server),
    assert_event_type(queue_created, E2),
    QueueNameBin = <<"mqtt-subscription-", ClientId/binary, "qos0">>,
    QueueName = {resource, <<"/">>, queue, QueueNameBin},
    assert_event_prop([{name, QueueName},
                       {durable, true},
                       {auto_delete, false},
                       {exclusive, true},
                       {type, rabbit_mqtt_qos0_queue},
                       {arguments, []}],
                      E2),
    assert_event_type(binding_created, E3),
    assert_event_prop([{source_name, <<"amq.topic">>},
                       {source_kind, exchange},
                       {destination_name, QueueNameBin},
                       {destination_kind, queue},
                       {routing_key, <<"TopicA">>},
                       {arguments, []}],
                      E3),

    {ok, _, _} = emqtt:unsubscribe(C, <<"TopicA">>),

    [E4] = get_events(Server),
    assert_event_type(binding_deleted, E4),

    ok = emqtt:disconnect(C),

    [E5, E6] = get_events(Server),
    assert_event_type(connection_closed, E5),
    assert_event_type(queue_deleted, E6),
    assert_event_prop({name, QueueName}, E6),

    ok = gen_event:delete_handler({rabbit_event, Server}, event_recorder, []).

event_authentication_failure(Config) ->
    P = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),
    ClientId = atom_to_binary(?FUNCTION_NAME),
    {ok, C} = emqtt:start_link([{username, <<"Trudy">>},
                                {password, <<"fake-password">>},
                                {host, "localhost"},
                                {port, P},
                                {clientid, ClientId},
                                {proto_ver, v4}]),
    true = unlink(C),

    ok = rabbit_ct_broker_helpers:add_code_path_to_all_nodes(Config, event_recorder),
    Server = rabbit_ct_broker_helpers:get_node_config(Config, 0, nodename),
    ok = gen_event:add_handler({rabbit_event, Server}, event_recorder, []),

    ?assertMatch({error, _}, emqtt:connect(C)),

    [E, _ConnectionClosedEvent] = get_events(Server),
    assert_event_type(user_authentication_failure, E),
    assert_event_prop([{name, <<"Trudy">>},
                       {connection_type, network}],
                      E),

    ok = gen_event:delete_handler({rabbit_event, Server}, event_recorder, []).

global_counters_v3(Config) ->
    global_counters(Config, v3).

global_counters_v4(Config) ->
    global_counters(Config, v4).

global_counters(Config, ProtoVer) ->
    Port = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),
    {ok, C} = emqtt:start_link([{host, "localhost"},
                                {port, Port},
                                {proto_ver, ProtoVer},
                                {clientid, atom_to_binary(?FUNCTION_NAME)}]),
    {ok, _Properties} = emqtt:connect(C),

    Topic = <<"test-topic">>,
    {ok, _, [1]} = emqtt:subscribe(C, Topic, [{qos, 1}]),
    {ok, _} = emqtt:publish(C, Topic, <<"testm">>, [{qos, 1}]),
    {ok, _} = emqtt:publish(C, Topic, <<"testm">>, [{qos, 1}]),

    ?assertEqual(#{publishers => 1,
                   consumers => 1,
                   messages_confirmed_total => 2,
                   messages_received_confirm_total => 2,
                   messages_received_total => 2,
                   messages_routed_total => 2,
                   messages_unroutable_dropped_total => 0,
                   messages_unroutable_returned_total => 0},
                 get_global_counters(Config, ProtoVer)),

    ok = emqtt:disconnect(C),

    ?assertEqual(#{publishers => 0,
                   consumers => 0,
                   messages_confirmed_total => 2,
                   messages_received_confirm_total => 2,
                   messages_received_total => 2,
                   messages_routed_total => 2,
                   messages_unroutable_dropped_total => 0,
                   messages_unroutable_returned_total => 0},
                 get_global_counters(Config, ProtoVer)).

queue_down_qos1(Config) ->
    {Conn1, Ch1} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 1),
    CQ = Topic = atom_to_binary(?FUNCTION_NAME),
    declare_queue(Ch1, CQ, []),
    bind(Ch1, CQ, Topic),
    ok = rabbit_ct_client_helpers:close_connection_and_channel(Conn1, Ch1),
    ok = rabbit_ct_broker_helpers:stop_node(Config, 1),

    {C, _} = connect(?FUNCTION_NAME, Config, [{retry_interval, 2}]),
    %% classic queue is down, therefore message is rejected
    ?assertEqual(puback_timeout, util:publish_qos1_timeout(C, Topic, <<"msg">>, 500)),

    ok = rabbit_ct_broker_helpers:start_node(Config, 1),
    %% classic queue is up, therefore message should arrive
    eventually(?_assertEqual([[<<"1">>]],
                             rabbitmqctl_list(Config, 1, ["list_queues", "messages", "--no-table-headers"])),
               500, 20),

    {Conn0, Ch0} = rabbit_ct_client_helpers:open_connection_and_channel(Config, 0),
    delete_queue(Ch0, CQ),
    ok = rabbit_ct_client_helpers:close_connection_and_channel(Conn0, Ch0),
    ok = emqtt:disconnect(C).

%% -------------------------------------------------------------------
%% Internal helpers
%% -------------------------------------------------------------------

connect(ClientId, Config) ->
    connect(ClientId, Config, []).

connect(ClientId, Config, AdditionalOpts) ->
    P = rabbit_ct_broker_helpers:get_node_config(Config, 0, tcp_port_mqtt),
    Options = [{host, "localhost"},
               {port, P},
               {clientid, rabbit_data_coercion:to_binary(ClientId)},
               {proto_ver, v4}
              ] ++ AdditionalOpts,
    {ok, C} = emqtt:start_link(Options),
    {ok, _Properties} = emqtt:connect(C),
    true = unlink(C),
    MRef = monitor(process, C),
    {C, MRef}.

declare_queue(Ch, QueueName, Args)
  when is_pid(Ch), is_binary(QueueName), is_list(Args) ->
    #'queue.declare_ok'{} = amqp_channel:call(
                              Ch, #'queue.declare'{
                                     queue = QueueName,
                                     durable = true,
                                     arguments = Args}).

delete_queue(Ch, QueueNames)
  when is_pid(Ch), is_list(QueueNames) ->
    lists:foreach(
      fun(Q) ->
              delete_queue(Ch, Q)
      end, QueueNames);
delete_queue(Ch, QueueName)
  when is_pid(Ch), is_binary(QueueName) ->
    #'queue.delete_ok'{} = amqp_channel:call(
                             Ch, #'queue.delete'{
                                    queue = QueueName}).

bind(Ch, QueueName, Topic)
  when is_pid(Ch), is_binary(QueueName), is_binary(Topic) ->
    #'queue.bind_ok'{} = amqp_channel:call(
                           Ch, #'queue.bind'{queue       = QueueName,
                                             exchange    = <<"amq.topic">>,
                                             routing_key = Topic}).

get_events(Node) ->
    timer:sleep(100), %% events are sent and processed asynchronously
    Result = gen_event:call({rabbit_event, Node}, event_recorder, take_state),
    ?assert(is_list(Result)),
    Result.

assert_event_type(ExpectedType, #event{type = ActualType}) ->
    ?assertEqual(ExpectedType, ActualType).

assert_event_prop(ExpectedProp = {Key, _Value}, #event{props = Props}) ->
    ?assertEqual(ExpectedProp, lists:keyfind(Key, 1, Props));
assert_event_prop(ExpectedProps, Event)
  when is_list(ExpectedProps) ->
    lists:foreach(fun(P) ->
                          assert_event_prop(P, Event)
                  end, ExpectedProps).

get_global_counters(Config, v3) ->
    get_global_counters0(Config, mqtt301);
get_global_counters(Config, v4) ->
    get_global_counters0(Config, mqtt311).

get_global_counters0(Config, Proto) ->
    maps:get([{protocol, Proto}],
             rabbit_ct_broker_helpers:rpc(Config,
                                          0,
                                          rabbit_global_counters,
                                          overview,
                                          [])).
