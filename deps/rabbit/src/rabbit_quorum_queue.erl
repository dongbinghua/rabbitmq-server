%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2018-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_quorum_queue).

-behaviour(rabbit_queue_type).

-export([init/1,
         close/1,
         update/2,
         handle_event/2]).
-export([is_recoverable/1,
         recover/2,
         stop/1,
         start_server/1,
         restart_server/1,
         stop_server/1,
         delete/4,
         delete_immediately/2]).
-export([state_info/1, info/2, stat/1, infos/1]).
-export([settle/4, dequeue/4, consume/3, cancel/5]).
-export([credit/4]).
-export([purge/1]).
-export([stateless_deliver/2, deliver/3, deliver/2]).
-export([dead_letter_publish/5]).
-export([queue_name/1]).
-export([cluster_state/1, status/2]).
-export([update_consumer_handler/8, update_consumer/9]).
-export([cancel_consumer_handler/2, cancel_consumer/3]).
-export([become_leader/2, handle_tick/3, spawn_deleter/1]).
-export([rpc_delete_metrics/1]).
-export([format/1]).
-export([open_files/1]).
-export([peek/2, peek/3]).
-export([add_member/4]).
-export([delete_member/3]).
-export([requeue/3]).
-export([policy_changed/1]).
-export([format_ra_event/3]).
-export([cleanup_data_dir/0]).
-export([shrink_all/1,
         grow/4]).
-export([transfer_leadership/2, get_replicas/1, queue_length/1]).
-export([file_handle_leader_reservation/1,
         file_handle_other_reservation/0]).
-export([file_handle_release_reservation/0]).
-export([list_with_minimum_quorum/0,
         filter_quorum_critical/1,
         filter_quorum_critical/2,
         all_replica_states/0]).
-export([capabilities/0]).
-export([repair_amqqueue_nodes/1,
         repair_amqqueue_nodes/2
         ]).
-export([reclaim_memory/2,
         wal_force_roll_over/1]).
-export([notify_decorators/1,
         notify_decorators/3,
         spawn_notify_decorators/3]).

-export([is_enabled/0,
         is_compatible/3,
         declare/2]).

-import(rabbit_queue_type_util, [args_policy_lookup/3,
                                 qname_to_internal_name/1]).

-include_lib("stdlib/include/qlc.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("rabbit_common/include/rabbit_framing.hrl").
-include("amqqueue.hrl").

-type msg_id() :: non_neg_integer().
-type qmsg() :: {rabbit_types:r('queue'), pid(), msg_id(), boolean(), rabbit_types:message()}.

-define(RA_SYSTEM, quorum_queues).
-define(RA_WAL_NAME, ra_log_wal).

-define(STATISTICS_KEYS,
        [policy,
         operator_policy,
         effective_policy_definition,
         consumers,
         memory,
         state,
         garbage_collection,
         leader,
         online,
         members,
         open_files,
         single_active_consumer_pid,
         single_active_consumer_ctag,
         messages_ram,
         message_bytes_ram,
         messages_dlx,
         message_bytes_dlx
        ]).

-define(INFO_KEYS, [name, durable, auto_delete, arguments, pid, messages, messages_ready,
                    messages_unacknowledged, local_state, type] ++ ?STATISTICS_KEYS).

-define(RPC_TIMEOUT, 1000).
-define(START_CLUSTER_TIMEOUT, 5000).
-define(START_CLUSTER_RPC_TIMEOUT, 7000). %% needs to be longer than START_CLUSTER_TIMEOUT
-define(TICK_TIMEOUT, 5000). %% the ra server tick time
-define(DELETE_TIMEOUT, 5000).
-define(ADD_MEMBER_TIMEOUT, 5000).
-define(SNAPSHOT_INTERVAL, 8192). %% the ra default is 4096

%%----------- rabbit_queue_type ---------------------------------------------

-spec is_enabled() -> boolean().
is_enabled() ->
    true.

-spec is_compatible(boolean(), boolean(), boolean()) -> boolean().
is_compatible(_Durable = true,
              _Exclusive = false,
              _AutoDelete = false) ->
    true;
is_compatible(_, _, _) ->
    false.

-spec init(amqqueue:amqqueue()) -> {ok, rabbit_fifo_client:state()}.
init(Q) when ?is_amqqueue(Q) ->
    {ok, SoftLimit} = application:get_env(rabbit, quorum_commands_soft_limit),
    %% This lookup could potentially return an {error, not_found}, but we do not
    %% know what to do if the queue has `disappeared`. Let it crash.
    {Name, _LeaderNode} = Leader = amqqueue:get_pid(Q),
    Nodes = get_nodes(Q),
    QName = amqqueue:get_name(Q),
    %% Ensure the leader is listed first
    Servers0 = [{Name, N} || N <- Nodes],
    Servers = [Leader | lists:delete(Leader, Servers0)],
    {ok, rabbit_fifo_client:init(QName, Servers, SoftLimit,
                                 fun() -> credit_flow:block(Name) end,
                                 fun() -> credit_flow:unblock(Name), ok end)}.

-spec close(rabbit_fifo_client:state()) -> ok.
close(_State) ->
    ok.

-spec update(amqqueue:amqqueue(), rabbit_fifo_client:state()) ->
    rabbit_fifo_client:state().
update(Q, State) when ?amqqueue_is_quorum(Q) ->
    %% QQ state maintains it's own updates
    State.

-spec handle_event({amqqueue:ra_server_id(), any()},
                   rabbit_fifo_client:state()) ->
    {ok, rabbit_fifo_client:state(), rabbit_queue_type:actions()} |
    eol |
    {protocol_error, Type :: atom(), Reason :: string(), Args :: term()}.
handle_event({From, Evt}, QState) ->
    rabbit_fifo_client:handle_ra_event(From, Evt, QState).

-spec declare(amqqueue:amqqueue(), node()) ->
    {new | existing, amqqueue:amqqueue()} | 
    {protocol_error, Type :: atom(), Reason :: string(), Args :: term()}.
declare(Q, _Node) when ?amqqueue_is_quorum(Q) ->
    case rabbit_queue_type_util:run_checks(
           [fun rabbit_queue_type_util:check_auto_delete/1,
            fun rabbit_queue_type_util:check_exclusive/1,
            fun rabbit_queue_type_util:check_non_durable/1],
           Q) of
        ok ->
            start_cluster(Q);
        Err ->
            Err
    end.

start_cluster(Q) ->
    QName = amqqueue:get_name(Q),
    Durable = amqqueue:is_durable(Q),
    AutoDelete = amqqueue:is_auto_delete(Q),
    Arguments = amqqueue:get_arguments(Q),
    Opts = amqqueue:get_options(Q),
    ActingUser = maps:get(user, Opts, ?UNKNOWN_USER),
    QuorumSize = get_default_quorum_initial_group_size(Arguments),
    RaName = case qname_to_internal_name(QName) of
                 {ok, A} ->
                     A;
                 {error, {too_long, N}} ->
                     rabbit_data_coercion:to_atom(ra:new_uid(N))
             end,
    {Leader, Followers} = rabbit_queue_location:select_leader_and_followers(Q, QuorumSize),
    LeaderId = {RaName, Leader},
    NewQ0 = amqqueue:set_pid(Q, LeaderId),
    NewQ1 = amqqueue:set_type_state(NewQ0, #{nodes => [Leader | Followers]}),

    rabbit_log:debug("Will start up to ~w replicas for quorum ~ts with leader on node '~ts'",
                     [QuorumSize, rabbit_misc:rs(QName), Leader]),
    case rabbit_amqqueue:internal_declare(NewQ1, false) of
        {created, NewQ} ->
            TickTimeout = application:get_env(rabbit, quorum_tick_interval,
                                              ?TICK_TIMEOUT),
            SnapshotInterval = application:get_env(rabbit, quorum_snapshot_interval,
                                                   ?SNAPSHOT_INTERVAL),
            RaConfs = [make_ra_conf(NewQ, ServerId, TickTimeout, SnapshotInterval)
                       || ServerId <- members(NewQ)],
            try erpc_call(Leader, ra, start_cluster,
                          [?RA_SYSTEM, RaConfs, ?START_CLUSTER_TIMEOUT],
                          ?START_CLUSTER_RPC_TIMEOUT) of
                {ok, _, _} ->
                    %% ensure the latest config is evaluated properly
                    %% even when running the machine version from 0
                    %% as earlier versions may not understand all the config
                    %% keys
                    %% TODO: handle error - what should be done if the
                    %% config cannot be updated
                    ok = rabbit_fifo_client:update_machine_state(LeaderId,
                                                                 ra_machine_config(NewQ)),
                    notify_decorators(NewQ, startup),
                    rabbit_event:notify(queue_created,
                                        [{name, QName},
                                         {durable, Durable},
                                         {auto_delete, AutoDelete},
                                         {exclusive, false},
                                         {type, amqqueue:get_type(Q)},
                                         {arguments, Arguments},
                                         {user_who_performed_action,
                                          ActingUser}]),
                    {new, NewQ};
                {error, Error} ->
                    declare_queue_error(Error, QName, Leader, ActingUser)
            catch
                error:Error ->
                    declare_queue_error(Error, QName, Leader, ActingUser)
            end;
        {existing, _} = Ex ->
            Ex
    end.

declare_queue_error(Error, QName, Leader, ActingUser) ->
    _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
    {protocol_error, internal_error,
     "Cannot declare quorum ~ts on node '~ts' with leader on node '~ts': ~255p",
     [rabbit_misc:rs(QName), node(), Leader, Error]}.

ra_machine(Q) ->
    {module, rabbit_fifo, ra_machine_config(Q)}.

ra_machine_config(Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    {Name, _} = amqqueue:get_pid(Q),
    %% take the minimum value of the policy and the queue arg if present
    MaxLength = args_policy_lookup(<<"max-length">>, fun min/2, Q),
    OverflowBin = args_policy_lookup(<<"overflow">>, fun policyHasPrecedence/2, Q),
    Overflow = overflow(OverflowBin, drop_head, QName),
    MaxBytes = args_policy_lookup(<<"max-length-bytes">>, fun min/2, Q),
    MaxMemoryLength = args_policy_lookup(<<"max-in-memory-length">>, fun min/2, Q),
    MaxMemoryBytes = args_policy_lookup(<<"max-in-memory-bytes">>, fun min/2, Q),
    DeliveryLimit = args_policy_lookup(<<"delivery-limit">>, fun min/2, Q),
    Expires = args_policy_lookup(<<"expires">>, fun policyHasPrecedence/2, Q),
    MsgTTL = args_policy_lookup(<<"message-ttl">>, fun min/2, Q),
    #{name => Name,
      queue_resource => QName,
      dead_letter_handler => dead_letter_handler(Q, Overflow),
      become_leader_handler => {?MODULE, become_leader, [QName]},
      max_length => MaxLength,
      max_bytes => MaxBytes,
      max_in_memory_length => MaxMemoryLength,
      max_in_memory_bytes => MaxMemoryBytes,
      single_active_consumer_on => single_active_consumer_on(Q),
      delivery_limit => DeliveryLimit,
      overflow_strategy => Overflow,
      created => erlang:system_time(millisecond),
      expires => Expires,
      msg_ttl => MsgTTL
     }.

policyHasPrecedence(Policy, _QueueArg) ->
    Policy.
queueArgHasPrecedence(_Policy, QueueArg) ->
    QueueArg.

single_active_consumer_on(Q) ->
    QArguments = amqqueue:get_arguments(Q),
    case rabbit_misc:table_lookup(QArguments, <<"x-single-active-consumer">>) of
        {bool, true} -> true;
        _            -> false
    end.

update_consumer_handler(QName, {ConsumerTag, ChPid}, Exclusive, AckRequired,
                        Prefetch, Active, ActivityStatus, Args) ->
    catch local_or_remote_handler(ChPid, rabbit_quorum_queue, update_consumer,
                                  [QName, ChPid, ConsumerTag, Exclusive,
                                   AckRequired, Prefetch, Active,
                                   ActivityStatus, Args]).

update_consumer(QName, ChPid, ConsumerTag, Exclusive, AckRequired, Prefetch,
                Active, ActivityStatus, Args) ->
    catch rabbit_core_metrics:consumer_updated(ChPid, ConsumerTag, Exclusive,
                                               AckRequired,
                                               QName, Prefetch, Active,
                                               ActivityStatus, Args).

cancel_consumer_handler(QName, {ConsumerTag, ChPid}) ->
    catch local_or_remote_handler(ChPid, rabbit_quorum_queue, cancel_consumer,
                                  [QName, ChPid, ConsumerTag]).

cancel_consumer(QName, ChPid, ConsumerTag) ->
    catch rabbit_core_metrics:consumer_deleted(ChPid, ConsumerTag, QName),
    emit_consumer_deleted(ChPid, ConsumerTag, QName, ?INTERNAL_USER).

local_or_remote_handler(ChPid, Module, Function, Args) ->
    Node = node(ChPid),
    case Node == node() of
        true ->
            erlang:apply(Module, Function, Args);
        false ->
            %% this could potentially block for a while if the node is
            %% in disconnected state or tcp buffers are full
            erpc:cast(Node, Module, Function, Args)
    end.

become_leader(QName, Name) ->
    Node = node(),
    Fun = fun (Q1) ->
                  amqqueue:set_state(
                    amqqueue:set_pid(Q1, {Name, Node}),
                    live)
          end,
    %% as this function is called synchronously when a ra node becomes leader
    %% we need to ensure there is no chance of blocking as else the ra node
    %% may not be able to establish its leadership
    spawn(fun() ->
                  rabbit_amqqueue:update(QName, Fun),
                  case rabbit_amqqueue:lookup(QName) of
                      {ok, Q0} when ?is_amqqueue(Q0) ->
                          Nodes = get_nodes(Q0),
                          [_ = erpc_call(N, ?MODULE, rpc_delete_metrics,
                                         [QName], ?RPC_TIMEOUT)
                           || N <- Nodes, N =/= node()];
                      _ ->
                          ok
                  end
          end).

-spec all_replica_states() -> {node(), #{atom() => atom()}}.
all_replica_states() ->
    Rows = ets:tab2list(ra_state),
    {node(), maps:from_list(Rows)}.

-spec list_with_minimum_quorum() -> [amqqueue:amqqueue()].
list_with_minimum_quorum() ->
    filter_quorum_critical(
      rabbit_amqqueue:list_local_quorum_queues()).

-spec filter_quorum_critical([amqqueue:amqqueue()]) -> [amqqueue:amqqueue()].
filter_quorum_critical(Queues) ->
    %% Example map of QQ replica states:
    %%    #{rabbit@warp10 =>
    %%      #{'%2F_qq.636' => leader,'%2F_qq.243' => leader,
    %%        '%2F_qq.1939' => leader,'%2F_qq.1150' => leader,
    %%        '%2F_qq.1109' => leader,'%2F_qq.1654' => leader,
    %%        '%2F_qq.1679' => leader,'%2F_qq.1003' => leader,
    %%        '%2F_qq.1593' => leader,'%2F_qq.1765' => leader,
    %%        '%2F_qq.933' => leader,'%2F_qq.38' => leader,
    %%        '%2F_qq.1357' => leader,'%2F_qq.1345' => leader,
    %%        '%2F_qq.1694' => leader,'%2F_qq.994' => leader,
    %%        '%2F_qq.490' => leader,'%2F_qq.1704' => leader,
    %%        '%2F_qq.58' => leader,'%2F_qq.564' => leader,
    %%        '%2F_qq.683' => leader,'%2F_qq.386' => leader,
    %%        '%2F_qq.753' => leader,'%2F_qq.6' => leader,
    %%        '%2F_qq.1590' => leader,'%2F_qq.1363' => leader,
    %%        '%2F_qq.882' => leader,'%2F_qq.1161' => leader,...}}
    ReplicaStates = maps:from_list(
                        rabbit_misc:append_rpc_all_nodes(rabbit_nodes:all_running(),
                            ?MODULE, all_replica_states, [])),
    filter_quorum_critical(Queues, ReplicaStates).

-spec filter_quorum_critical([amqqueue:amqqueue()], #{node() => #{atom() => atom()}}) -> [amqqueue:amqqueue()].

filter_quorum_critical(Queues, ReplicaStates) ->
    lists:filter(fun (Q) ->
                    MemberNodes = rabbit_amqqueue:get_quorum_nodes(Q),
                    {Name, _Node} = amqqueue:get_pid(Q),
                    AllUp = lists:filter(fun (N) ->
                                            {Name, _} = amqqueue:get_pid(Q),
                                            case maps:get(N, ReplicaStates, undefined) of
                                                #{Name := State} when State =:= follower orelse State =:= leader ->
                                                    true;
                                                _ -> false
                                            end
                                         end, MemberNodes),
                    MinQuorum = length(MemberNodes) div 2 + 1,
                    length(AllUp) =< MinQuorum
                 end, Queues).

capabilities() ->
    #{unsupported_policies => [%% Classic policies
                               <<"max-priority">>, <<"queue-mode">>,
                               <<"single-active-consumer">>, <<"ha-mode">>, <<"ha-params">>,
                               <<"ha-sync-mode">>, <<"ha-promote-on-shutdown">>, <<"ha-promote-on-failure">>,
                               <<"queue-master-locator">>,
                               %% Stream policies
                               <<"max-age">>, <<"stream-max-segment-size-bytes">>, <<"initial-cluster-size">>],
      queue_arguments => [<<"x-dead-letter-exchange">>, <<"x-dead-letter-routing-key">>,
                          <<"x-dead-letter-strategy">>, <<"x-expires">>, <<"x-max-length">>,
                          <<"x-max-length-bytes">>, <<"x-max-in-memory-length">>,
                          <<"x-max-in-memory-bytes">>, <<"x-overflow">>,
                          <<"x-single-active-consumer">>, <<"x-queue-type">>,
                          <<"x-quorum-initial-group-size">>, <<"x-delivery-limit">>,
                          <<"x-message-ttl">>, <<"x-queue-leader-locator">>],
      consumer_arguments => [<<"x-priority">>, <<"x-credit">>],
      server_named => false}.

rpc_delete_metrics(QName) ->
    ets:delete(queue_coarse_metrics, QName),
    ets:delete(queue_metrics, QName),
    ok.

spawn_deleter(QName) ->
    spawn(fun () ->
                  {ok, Q} = rabbit_amqqueue:lookup(QName),
                  delete(Q, false, false, <<"expired">>)
          end).

spawn_notify_decorators(QName, Fun, Args) ->
    %% run in ra process for now
    catch notify_decorators(QName, Fun, Args).

handle_tick(QName,
            #{config := #{name := Name},
              num_active_consumers := NumConsumers,
              num_checked_out := NumCheckedOut,
              num_ready_messages := NumReadyMsgs,
              num_messages := NumMessages,
              enqueue_message_bytes := EnqueueBytes,
              checkout_message_bytes := CheckoutBytes,
              num_discarded := NumDiscarded,
              num_discard_checked_out  :=  NumDiscardedCheckedOut,
              discard_message_bytes := DiscardBytes,
              discard_checkout_message_bytes := DiscardCheckoutBytes,
              smallest_raft_index := _} = Overview,
            Nodes) ->
    %% this makes calls to remote processes so cannot be run inside the
    %% ra server
    Self = self(),
    _ = spawn(
          fun() ->
                  try
                      Reductions = reductions(Name),
                      rabbit_core_metrics:queue_stats(QName, NumReadyMsgs,
                                                      NumCheckedOut, NumMessages,
                                                      Reductions),
                      Util = case NumConsumers of
                                 0 -> 0;
                                 _ -> rabbit_fifo:usage(Name)
                             end,
                      Keys = ?STATISTICS_KEYS -- [consumers,
                                                  messages_dlx,
                                                  message_bytes_dlx,
                                                  single_active_consumer_pid,
                                                  single_active_consumer_ctag
                                                 ],
                      {SacTag, SacPid} = maps:get(single_active_consumer_id,
                                                  Overview, {'', ''}),
                      MsgBytesDiscarded = DiscardBytes + DiscardCheckoutBytes,
                      MsgBytes = EnqueueBytes + CheckoutBytes + MsgBytesDiscarded,
                      Infos = [{consumers, NumConsumers},
                               {consumer_capacity, Util},
                               {consumer_utilisation, Util},
                               {message_bytes_ready, EnqueueBytes},
                               {message_bytes_unacknowledged, CheckoutBytes},
                               {message_bytes, MsgBytes},
                               {message_bytes_persistent, MsgBytes},
                               {messages_persistent, NumMessages},
                               {messages_dlx, NumDiscarded + NumDiscardedCheckedOut},
                               {message_bytes_dlx, MsgBytesDiscarded},
                               {single_active_consumer_ctag, SacTag},
                               {single_active_consumer_pid, SacPid}
                               | infos(QName, Keys)],
                      rabbit_core_metrics:queue_stats(QName, Infos),
                      ok = repair_leader_record(QName, Self),
                      ExpectedNodes = rabbit_nodes:all(),
                      case Nodes -- ExpectedNodes of
                          [] ->
                              ok;
                          Stale ->
                              rabbit_log:info("~ts: stale nodes detected. Purging ~w",
                                              [rabbit_misc:rs(QName), Stale]),
                              %% pipeline purge command
                              {ok, Q} = rabbit_amqqueue:lookup(QName),
                              ok = ra:pipeline_command(amqqueue:get_pid(Q),
                                                       rabbit_fifo:make_purge_nodes(Stale)),

                              ok
                      end
                  catch
                      _:_ ->
                          ok
                  end
          end),
    ok.

repair_leader_record(Q, Self) ->
    Node = node(),
    case amqqueue:get_pid(Q) of
        {_, Node} ->
            %% it's ok - we don't need to do anything
            ok;
        _ ->
            QName = amqqueue:get_name(Q),
            rabbit_log:debug("~ts: repairing leader record",
                             [rabbit_misc:rs(QName)]),
            {_, Name} = erlang:process_info(Self, registered_name),
            become_leader(QName, Name)
    end,
    ok.

repair_amqqueue_nodes(VHost, QueueName) ->
    QName = #resource{virtual_host = VHost, name = QueueName, kind = queue},
    repair_amqqueue_nodes(QName).

-spec repair_amqqueue_nodes(rabbit_types:r('queue') | amqqueue:amqqueue()) ->
    ok | repaired.
repair_amqqueue_nodes(QName = #resource{}) ->
    {ok, Q0} = rabbit_amqqueue:lookup(QName),
    repair_amqqueue_nodes(Q0);
repair_amqqueue_nodes(Q0) ->
    QName = amqqueue:get_name(Q0),
    Leader = amqqueue:get_pid(Q0),
    {ok, Members, _} = ra:members(Leader),
    RaNodes = [N || {_, N} <- Members],
    #{nodes := Nodes} = amqqueue:get_type_state(Q0),
    case lists:sort(RaNodes) =:= lists:sort(Nodes) of
        true ->
            %% up to date
            ok;
        false ->
            %% update amqqueue record
            Fun = fun (Q) ->
                          TS0 = amqqueue:get_type_state(Q),
                          TS = TS0#{nodes => RaNodes},
                          amqqueue:set_type_state(Q, TS)
                  end,
            rabbit_amqqueue:update(QName, Fun),
            repaired
    end.

reductions(Name) ->
    try
        {reductions, R} = process_info(whereis(Name), reductions),
        R
    catch
        error:badarg ->
            0
    end.

is_recoverable(Q) ->
    Node = node(),
    Nodes = get_nodes(Q),
    lists:member(Node, Nodes).

-spec recover(binary(), [amqqueue:amqqueue()]) ->
    {[amqqueue:amqqueue()], [amqqueue:amqqueue()]}.
recover(_Vhost, Queues) ->
    lists:foldl(
      fun (Q0, {R0, F0}) ->
         {Name, _} = amqqueue:get_pid(Q0),
         QName = amqqueue:get_name(Q0),
         Nodes = get_nodes(Q0),
         Formatter = {?MODULE, format_ra_event, [QName]},
         Res = case ra:restart_server(?RA_SYSTEM, {Name, node()},
                                      #{ra_event_formatter => Formatter}) of
                   ok ->
                       % queue was restarted, good
                       ok;
                   {error, Err1}
                     when Err1 == not_started orelse
                          Err1 == name_not_registered ->
                       % queue was never started on this node
                       % so needs to be started from scratch.
                       Machine = ra_machine(Q0),
                       RaNodes = [{Name, Node} || Node <- Nodes],
                       case ra:start_server(?RA_SYSTEM, Name, {Name, node()},
                                            Machine, RaNodes) of
                           ok -> ok;
                           Err2 ->
                               rabbit_log:warning("recover: quorum queue ~w could not"
                                                  " be started ~w", [Name, Err2]),
                               fail
                       end;
                   {error, {already_started, _}} ->
                       %% this is fine and can happen if a vhost crashes and performs
                       %% recovery whilst the ra application and servers are still
                       %% running
                       ok;
                   Err ->
                       %% catch all clause to avoid causing the vhost not to start
                       rabbit_log:warning("recover: quorum queue ~w could not be "
                                          "restarted ~w", [Name, Err]),
                       fail
               end,
         %% we have to ensure the quorum queue is
         %% present in the rabbit_queue table and not just in
         %% rabbit_durable_queue
         %% So many code paths are dependent on this.
         ok = rabbit_db_queue:insert_dirty(Q0),
         Q = Q0,
         case Res of
             ok ->
                 {[Q | R0], F0};
             fail ->
                 {R0, [Q | F0]}
         end
      end, {[], []}, Queues).

-spec stop(rabbit_types:vhost()) -> ok.
stop(VHost) ->
    _ = [begin
             Pid = amqqueue:get_pid(Q),
             ra:stop_server(?RA_SYSTEM, Pid)
         end || Q <- find_quorum_queues(VHost)],
    ok.

-spec stop_server({atom(), node()}) -> ok | {error, term()}.
stop_server({_, _} = Ref) ->
    ra:stop_server(?RA_SYSTEM, Ref).

-spec start_server(map()) -> ok | {error, term()}.
start_server(Conf) when is_map(Conf) ->
    ra:start_server(?RA_SYSTEM, Conf).

-spec restart_server({atom(), node()}) -> ok | {error, term()}.
restart_server({_, _} = Ref) ->
    ra:restart_server(?RA_SYSTEM, Ref).

-spec delete(amqqueue:amqqueue(),
             boolean(), boolean(),
             rabbit_types:username()) ->
    {ok, QLen :: non_neg_integer()} |
    {protocol_error, Type :: atom(), Reason :: string(), Args :: term()}.
delete(Q, true, _IfEmpty, _ActingUser) when ?amqqueue_is_quorum(Q) ->
    {protocol_error, not_implemented,
     "cannot delete ~ts. queue.delete operations with if-unused flag set are not supported by quorum queues",
     [rabbit_misc:rs(amqqueue:get_name(Q))]};
delete(Q, _IfUnused, true, _ActingUser) when ?amqqueue_is_quorum(Q) ->
    {protocol_error, not_implemented,
     "cannot delete ~ts. queue.delete operations with if-empty flag set are not supported by quorum queues",
     [rabbit_misc:rs(amqqueue:get_name(Q))]};
delete(Q, _IfUnused, _IfEmpty, ActingUser) when ?amqqueue_is_quorum(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    QName = amqqueue:get_name(Q),
    QNodes = get_nodes(Q),
    %% TODO Quorum queue needs to support consumer tracking for IfUnused
    Timeout = ?DELETE_TIMEOUT,
    {ok, ReadyMsgs, _} = stat(Q),
    Servers = [{Name, Node} || Node <- QNodes],
    case ra:delete_cluster(Servers, Timeout) of
        {ok, {_, LeaderNode} = Leader} ->
            MRef = erlang:monitor(process, Leader),
            receive
                {'DOWN', MRef, process, _, _} ->
                    ok
            after Timeout ->
                    ok = force_delete_queue(Servers)
            end,
            notify_decorators(QName, shutdown),
            ok = delete_queue_data(QName, ActingUser),
            _ = erpc:call(LeaderNode, rabbit_core_metrics, queue_deleted, [QName],
                          ?RPC_TIMEOUT),
            {ok, ReadyMsgs};
        {error, {no_more_servers_to_try, Errs}} ->
            case lists:all(fun({{error, noproc}, _}) -> true;
                              (_) -> false
                           end, Errs) of
                true ->
                    %% If all ra nodes were already down, the delete
                    %% has succeed
                    delete_queue_data(QName, ActingUser),
                    {ok, ReadyMsgs};
                false ->
                    %% attempt forced deletion of all servers
                    rabbit_log:warning(
                      "Could not delete quorum '~ts', not enough nodes "
                       " online to reach a quorum: ~255p."
                       " Attempting force delete.",
                      [rabbit_misc:rs(QName), Errs]),
                    ok = force_delete_queue(Servers),
                    notify_decorators(QName, shutdown),
                    delete_queue_data(QName, ActingUser),
                    {ok, ReadyMsgs}
            end
    end.

force_delete_queue(Servers) ->
    [begin
         case catch(ra:force_delete_server(?RA_SYSTEM, S)) of
             ok -> ok;
             Err ->
                 rabbit_log:warning(
                   "Force delete of ~w failed with: ~w"
                   "This may require manual data clean up",
                   [S, Err]),
                 ok
         end
     end || S <- Servers],
    ok.

delete_queue_data(QName, ActingUser) ->
    _ = rabbit_amqqueue:internal_delete(QName, ActingUser),
    ok.


delete_immediately(Resource, {_Name, _} = QPid) ->
    _ = rabbit_amqqueue:internal_delete(Resource, ?INTERNAL_USER),
    {ok, _} = ra:delete_cluster([QPid]),
    rabbit_core_metrics:queue_deleted(Resource),
    ok.

settle(complete, CTag, MsgIds, QState) ->
    rabbit_fifo_client:settle(quorum_ctag(CTag), MsgIds, QState);
settle(requeue, CTag, MsgIds, QState) ->
    rabbit_fifo_client:return(quorum_ctag(CTag), MsgIds, QState);
settle(discard, CTag, MsgIds, QState) ->
    rabbit_fifo_client:discard(quorum_ctag(CTag), MsgIds, QState).

credit(CTag, Credit, Drain, QState) ->
    rabbit_fifo_client:credit(quorum_ctag(CTag), Credit, Drain, QState).

-spec dequeue(NoAck :: boolean(), pid(),
              rabbit_types:ctag(), rabbit_fifo_client:state()) ->
    {empty, rabbit_fifo_client:state()} |
    {ok, QLen :: non_neg_integer(), qmsg(), rabbit_fifo_client:state()} |
    {error, term()}.
dequeue(NoAck, _LimiterPid, CTag0, QState0) ->
    CTag = quorum_ctag(CTag0),
    Settlement = case NoAck of
                     true ->
                         settled;
                     false ->
                         unsettled
                 end,
    rabbit_fifo_client:dequeue(CTag, Settlement, QState0).

-spec consume(amqqueue:amqqueue(),
              rabbit_queue_type:consume_spec(),
              rabbit_fifo_client:state()) ->
    {ok, rabbit_fifo_client:state(), rabbit_queue_type:actions()} |
    {error, global_qos_not_supported_for_queue_type | timeout}.
consume(Q, #{limiter_active := true}, _State)
  when ?amqqueue_is_quorum(Q) ->
    {error, global_qos_not_supported_for_queue_type};
consume(Q, Spec, QState0) when ?amqqueue_is_quorum(Q) ->
    #{no_ack := NoAck,
      channel_pid := ChPid,
      prefetch_count := ConsumerPrefetchCount,
      consumer_tag := ConsumerTag0,
      exclusive_consume := ExclusiveConsume,
      args := Args,
      ok_msg := OkMsg,
      acting_user :=  ActingUser} = Spec,
    %% TODO: validate consumer arguments
    %% currently quorum queues do not support any arguments
    QName = amqqueue:get_name(Q),
    maybe_send_reply(ChPid, OkMsg),
    ConsumerTag = quorum_ctag(ConsumerTag0),
    %% A prefetch count of 0 means no limitation,
    %% let's make it into something large for ra
    Prefetch0 = case ConsumerPrefetchCount of
                    0 -> 2000;
                    Other -> Other
                end,
    %% consumer info is used to describe the consumer properties
    AckRequired = not NoAck,
    ConsumerMeta = #{ack => AckRequired,
                     prefetch => ConsumerPrefetchCount,
                     args => Args,
                     username => ActingUser},

    {CreditMode, Credit, Drain} = parse_credit_args(Prefetch0, Args),
    %% if the mode is credited we should send a separate credit command
    %% after checkout and give 0 credits initally
    Prefetch = case CreditMode of
                   credited -> 0;
                   simple_prefetch -> Prefetch0
               end,
    {ok, QState1} = rabbit_fifo_client:checkout(ConsumerTag, Prefetch,
                                                CreditMode, ConsumerMeta,
                                                QState0),
    QState = case CreditMode of
                   credited when Credit > 0 ->
                     rabbit_fifo_client:credit(ConsumerTag, Credit, Drain,
                                               QState1);
                   _ -> QState1
               end,
    case single_active_consumer_on(Q) of
        true ->
            %% get the leader from state
            case rabbit_fifo_client:query_single_active_consumer(QState) of
                {ok, SacResult} ->
                    ActivityStatus = case SacResult of
                                         {value, {ConsumerTag, ChPid}} ->
                                             single_active;
                                         _ ->
                                             waiting
                                     end,
                    rabbit_core_metrics:consumer_created(
                      ChPid, ConsumerTag, ExclusiveConsume,
                      AckRequired, QName,
                      ConsumerPrefetchCount, ActivityStatus == single_active, %% Active
                      ActivityStatus, Args),
                    emit_consumer_created(ChPid, ConsumerTag, ExclusiveConsume,
                                          AckRequired, QName, Prefetch,
                                          Args, none, ActingUser),
                    {ok, QState, []};
                {error, Error} ->
                    Error;
                {timeout, _} ->
                    {error, timeout}
            end;
        false ->
            rabbit_core_metrics:consumer_created(
              ChPid, ConsumerTag, ExclusiveConsume,
              AckRequired, QName,
              ConsumerPrefetchCount, true, %% Active
              up, Args),
            emit_consumer_created(ChPid, ConsumerTag, ExclusiveConsume,
                                  AckRequired, QName, Prefetch,
                                  Args, none, ActingUser),
            {ok, QState, []}
    end.

cancel(_Q, ConsumerTag, OkMsg, _ActingUser, State) ->
    maybe_send_reply(self(), OkMsg),
    rabbit_fifo_client:cancel_checkout(quorum_ctag(ConsumerTag), State).

emit_consumer_created(ChPid, CTag, Exclusive, AckRequired, QName, PrefetchCount, Args, Ref, ActingUser) ->
    rabbit_event:notify(consumer_created,
                        [{consumer_tag,   CTag},
                         {exclusive,      Exclusive},
                         {ack_required,   AckRequired},
                         {channel,        ChPid},
                         {queue,          QName},
                         {prefetch_count, PrefetchCount},
                         {arguments,      Args},
                         {user_who_performed_action, ActingUser}],
                        Ref).

emit_consumer_deleted(ChPid, ConsumerTag, QName, ActingUser) ->
    rabbit_event:notify(consumer_deleted,
        [{consumer_tag, ConsumerTag},
            {channel, ChPid},
            {queue, QName},
            {user_who_performed_action, ActingUser}]).

-spec stateless_deliver(amqqueue:ra_server_id(), rabbit_types:delivery()) -> 'ok'.

stateless_deliver(ServerId, Delivery) ->
    ok = rabbit_fifo_client:untracked_enqueue([ServerId],
                                              Delivery#delivery.message).

-spec deliver(Confirm :: boolean(), rabbit_types:delivery(),
              rabbit_fifo_client:state()) ->
    {ok | slow, rabbit_fifo_client:state()} |
    {reject_publish, rabbit_fifo_client:state()}.
deliver(false, Delivery, QState0) ->
    case rabbit_fifo_client:enqueue(Delivery#delivery.message, QState0) of
        {ok, _} = Res -> Res;
        {slow, _} = Res -> Res;
        {reject_publish, State} ->
            {ok, State}
    end;
deliver(true, Delivery, QState0) ->
    rabbit_fifo_client:enqueue(Delivery#delivery.msg_seq_no,
                               Delivery#delivery.message, QState0).

deliver(QSs, #delivery{message = #basic_message{content = Content0} = Msg,
                       confirm = Confirm} = Delivery0) ->
    %% TODO: we could also consider clearing out the message id here
    Content = prepare_content(Content0),
    Delivery = Delivery0#delivery{message = Msg#basic_message{content = Content}},
    lists:foldl(
      fun({Q, stateless}, {Qs, Actions}) ->
              QRef = amqqueue:get_pid(Q),
              ok = rabbit_fifo_client:untracked_enqueue(
                     [QRef], Delivery#delivery.message),
              {Qs, Actions};
         ({Q, S0}, {Qs, Actions}) ->
              case deliver(Confirm, Delivery, S0) of
                  {reject_publish, S} ->
                      Seq = Delivery#delivery.msg_seq_no,
                      QName = rabbit_fifo_client:cluster_name(S),
                      {[{Q, S} | Qs], [{rejected, QName, [Seq]} | Actions]};
                  {_, S} ->
                      {[{Q, S} | Qs], Actions}
              end
      end, {[], []}, QSs).


state_info(S) ->
    #{pending_raft_commands => rabbit_fifo_client:pending_size(S)}.

-spec infos(rabbit_types:r('queue')) -> rabbit_types:infos().
infos(QName) ->
    infos(QName, ?STATISTICS_KEYS).

infos(QName, Keys) ->
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} ->
            info(Q, Keys);
        {error, not_found} ->
            []
    end.

info(Q, all_keys) ->
    info(Q, ?INFO_KEYS);
info(Q, Items) ->
    lists:foldr(fun(totals, Acc) ->
                        i_totals(Q) ++ Acc;
                   (type_specific, Acc) ->
                        format(Q) ++ Acc;
                   (Item, Acc) ->
                        [{Item, i(Item, Q)} | Acc]
                end, [], Items).

-spec stat(amqqueue:amqqueue()) ->
    {'ok', non_neg_integer(), non_neg_integer()}.
stat(Q) when ?is_amqqueue(Q) ->
    %% same short default timeout as in rabbit_fifo_client:stat/1
    stat(Q, 250).

-spec stat(amqqueue:amqqueue(), non_neg_integer()) -> {'ok', non_neg_integer(), non_neg_integer()}.

stat(Q, Timeout) when ?is_amqqueue(Q) ->
    Leader = amqqueue:get_pid(Q),
    try
        case rabbit_fifo_client:stat(Leader, Timeout) of
          {ok, _, _} = Success -> Success;
          {error, _}           -> {ok, 0, 0};
          {timeout, _}         -> {ok, 0, 0}
        end
    catch
        _:_ ->
            %% Leader is not available, cluster might be in minority
            {ok, 0, 0}
    end.

-spec purge(amqqueue:amqqueue()) ->
    {ok, non_neg_integer()}.
purge(Q) when ?is_amqqueue(Q) ->
    Server = amqqueue:get_pid(Q),
    rabbit_fifo_client:purge(Server).

requeue(ConsumerTag, MsgIds, QState) ->
    rabbit_fifo_client:return(quorum_ctag(ConsumerTag), MsgIds, QState).

cleanup_data_dir() ->
    Names = [begin
                 {Name, _} = amqqueue:get_pid(Q),
                 Name
             end
             || Q <- rabbit_amqqueue:list_by_type(?MODULE),
                lists:member(node(), get_nodes(Q))],
    Registered = ra_directory:list_registered(?RA_SYSTEM),
    Running = Names,
    _ = [maybe_delete_data_dir(UId) || {Name, UId} <- Registered,
                                       not lists:member(Name, Running)],
    ok.

maybe_delete_data_dir(UId) ->
    Dir = ra_env:server_data_dir(?RA_SYSTEM, UId),
    {ok, Config} = ra_log:read_config(Dir),
    case maps:get(machine, Config) of
        {module, rabbit_fifo, _} ->
            ra_lib:recursive_delete(Dir),
            ra_directory:unregister_name(?RA_SYSTEM, UId);
        _ ->
            ok
    end.

policy_changed(Q) ->
    QPid = amqqueue:get_pid(Q),
    _ = rabbit_fifo_client:update_machine_state(QPid, ra_machine_config(Q)),
    ok.

-spec cluster_state(Name :: atom()) -> 'down' | 'recovering' | 'running'.

cluster_state(Name) ->
    case whereis(Name) of
        undefined -> down;
        _ ->
            case ets_lookup_element(ra_state, Name, 2, undefined) of
                recover ->
                    recovering;
                _ ->
                    running
            end
    end.

-spec status(rabbit_types:vhost(), Name :: rabbit_misc:resource_name()) ->
    [[{binary(), term()}]] | {error, term()}.
status(Vhost, QueueName) ->
    %% Handle not found queues
    QName = #resource{virtual_host = Vhost, name = QueueName, kind = queue},
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            {RName, _} = amqqueue:get_pid(Q),
            Nodes = get_nodes(Q),
            [begin
                 case get_sys_status({RName, N}) of
                     {ok, Sys} ->
                         {_, M} = lists:keyfind(ra_server_state, 1, Sys),
                         {_, RaftState} = lists:keyfind(raft_state, 1, Sys),
                         #{commit_index := Commit,
                           machine_version := MacVer,
                           current_term := Term,
                           log := #{last_index := Last,
                                    snapshot_index := SnapIdx}} = M,
                         [{<<"Node Name">>, N},
                          {<<"Raft State">>, RaftState},
                          {<<"Log Index">>, Last},
                          {<<"Commit Index">>, Commit},
                          {<<"Snapshot Index">>, SnapIdx},
                          {<<"Term">>, Term},
                          {<<"Machine Version">>, MacVer}
                         ];
                     {error, Err} ->
                         [{<<"Node Name">>, N},
                          {<<"Raft State">>, Err},
                          {<<"Log Index">>, <<>>},
                          {<<"Commit Index">>, <<>>},
                          {<<"Snapshot Index">>, <<>>},
                          {<<"Term">>, <<>>},
                          {<<"Machine Version">>, <<>>}
                         ]
                 end
             end || N <- Nodes];
        {ok, _Q} ->
            {error, not_quorum_queue};
        {error, not_found} = E ->
            E
    end.

get_sys_status(Proc) ->
    try lists:nth(5, element(4, sys:get_status(Proc))) of
        Sys -> {ok, Sys}
    catch
        _:Err when is_tuple(Err) ->
            {error, element(1, Err)};
        _:_ ->
            {error, other}

    end.


add_member(VHost, Name, Node, Timeout) ->
    QName = #resource{virtual_host = VHost, name = Name, kind = queue},
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            QNodes = get_nodes(Q),
            case lists:member(Node, rabbit_nodes:all_running()) of
                false ->
                    {error, node_not_running};
                true ->
                    case lists:member(Node, QNodes) of
                        true ->
                          %% idempotent by design
                          ok;
                        false ->
                            add_member(Q, Node, Timeout)
                    end
            end;
        {ok, _Q} ->
            {error, not_quorum_queue};
        {error, not_found} = E ->
                    E
    end.

add_member(Q, Node, Timeout) when ?amqqueue_is_quorum(Q) ->
    {RaName, _} = amqqueue:get_pid(Q),
    QName = amqqueue:get_name(Q),
    %% TODO parallel calls might crash this, or add a duplicate in quorum_nodes
    ServerId = {RaName, Node},
    Members = members(Q),
    TickTimeout = application:get_env(rabbit, quorum_tick_interval,
                                      ?TICK_TIMEOUT),
    SnapshotInterval = application:get_env(rabbit, quorum_snapshot_interval,
                                           ?SNAPSHOT_INTERVAL),
    Conf = make_ra_conf(Q, ServerId, TickTimeout, SnapshotInterval),
    case ra:start_server(?RA_SYSTEM, Conf) of
        ok ->
            case ra:add_member(Members, ServerId, Timeout) of
                {ok, _, Leader} ->
                    Fun = fun(Q1) ->
                                  Q2 = update_type_state(
                                         Q1, fun(#{nodes := Nodes} = Ts) ->
                                                     Ts#{nodes => [Node | Nodes]}
                                             end),
                                  amqqueue:set_pid(Q2, Leader)
                          end,
                    rabbit_amqqueue:update(QName, Fun),
                    ok;
                {timeout, _} ->
                    _ = ra:force_delete_server(?RA_SYSTEM, ServerId),
                    _ = ra:remove_member(Members, ServerId),
                    {error, timeout};
                E ->
                    _ = ra:force_delete_server(?RA_SYSTEM, ServerId),
                    E
            end;
        E ->
            E
    end.

delete_member(VHost, Name, Node) ->
    QName = #resource{virtual_host = VHost, name = Name, kind = queue},
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            QNodes = get_nodes(Q),
            case lists:member(Node, QNodes) of
                false ->
                    %% idempotent by design
                    ok;
                true ->
                    delete_member(Q, Node)
            end;
        {ok, _Q} ->
            {error, not_quorum_queue};
        {error, not_found} = E ->
                    E
    end.


delete_member(Q, Node) when ?amqqueue_is_quorum(Q) ->
    QName = amqqueue:get_name(Q),
    {RaName, _} = amqqueue:get_pid(Q),
    ServerId = {RaName, Node},
    case members(Q) of
        [{_, Node}] ->

            %% deleting the last member is not allowed
            {error, last_node};
        Members ->
            case ra:remove_member(Members, ServerId) of
                {ok, _, _Leader} ->
                    Fun = fun(Q1) ->
                                  update_type_state(
                                    Q1,
                                    fun(#{nodes := Nodes} = Ts) ->
                                            Ts#{nodes => lists:delete(Node, Nodes)}
                                    end)
                          end,
                    %% TODO
                    rabbit_amqqueue:update(QName, Fun),
                    case ra:force_delete_server(?RA_SYSTEM, ServerId) of
                        ok ->
                            ok;
                        {error, {badrpc, nodedown}} ->
                            ok;
                        {error, {badrpc, {'EXIT', {badarg, _}}}} ->
                            %% DETS/ETS tables can't be found, application isn't running
                            ok;
                        {error, _} = Err ->
                            Err;
                        Err ->
                            {error, Err}
                    end;
                {timeout, _} ->
                    {error, timeout};
                E ->
                    E
            end
    end.

-spec shrink_all(node()) ->
    [{rabbit_amqqueue:name(),
      {ok, pos_integer()} | {error, pos_integer(), term()}}].
shrink_all(Node) ->
    [begin
         QName = amqqueue:get_name(Q),
         rabbit_log:info("~ts: removing member (replica) on node ~w",
                         [rabbit_misc:rs(QName), Node]),
         Size = length(get_nodes(Q)),
         case delete_member(Q, Node) of
             ok ->
                 {QName, {ok, Size-1}};
             {error, Err} ->
                 rabbit_log:warning("~ts: failed to remove member (replica) on node ~w, error: ~w",
                                    [rabbit_misc:rs(QName), Node, Err]),
                 {QName, {error, Size, Err}}
         end
     end || Q <- rabbit_amqqueue:list(),
            amqqueue:get_type(Q) == ?MODULE,
            lists:member(Node, get_nodes(Q))].

-spec grow(node(), binary(), binary(), all | even) ->
    [{rabbit_amqqueue:name(),
      {ok, pos_integer()} | {error, pos_integer(), term()}}].
grow(Node, VhostSpec, QueueSpec, Strategy) ->
    Running = rabbit_nodes:all_running(),
    [begin
         Size = length(get_nodes(Q)),
         QName = amqqueue:get_name(Q),
         rabbit_log:info("~ts: adding a new member (replica) on node ~w",
                         [rabbit_misc:rs(QName), Node]),
         case add_member(Q, Node, ?ADD_MEMBER_TIMEOUT) of
             ok ->
                 {QName, {ok, Size + 1}};
             {error, Err} ->
                 rabbit_log:warning(
                   "~ts: failed to add member (replica) on node ~w, error: ~w",
                   [rabbit_misc:rs(QName), Node, Err]),
                 {QName, {error, Size, Err}}
         end
     end
     || Q <- rabbit_amqqueue:list(),
        amqqueue:get_type(Q) == ?MODULE,
        %% don't add a member if there is already one on the node
        not lists:member(Node, get_nodes(Q)),
        %% node needs to be running
        lists:member(Node, Running),
        matches_strategy(Strategy, get_nodes(Q)),
        is_match(amqqueue:get_vhost(Q), VhostSpec) andalso
        is_match(get_resource_name(amqqueue:get_name(Q)), QueueSpec) ].

transfer_leadership(Q, Destination) ->
    {RaName, _} = Pid = amqqueue:get_pid(Q),
    case ra:transfer_leadership(Pid, {RaName, Destination}) of
        ok ->
          case ra:members(Pid) of
            {_, _, {_, NewNode}} ->
              {migrated, NewNode};
            {timeout, _} ->
              {not_migrated, ra_members_timeout}
          end;
        already_leader ->
            {not_migrated, already_leader};
        {error, Reason} ->
            {not_migrated, Reason};
        {timeout, _} ->
            %% TODO should we retry once?
            {not_migrated, timeout}
    end.

queue_length(Q) ->
    Name = amqqueue:get_name(Q),
    case ets:lookup(ra_metrics, Name) of
        [] -> 0;
        [{_, _, SnapIdx, _, _, LastIdx, _}] ->
            LastIdx - SnapIdx
    end.

get_replicas(Q) ->
    get_nodes(Q).

get_resource_name(#resource{name  = Name}) ->
    Name.

matches_strategy(all, _) -> true;
matches_strategy(even, Members) ->
    length(Members) rem 2 == 0.

is_match(Subj, E) ->
   nomatch /= re:run(Subj, E).

file_handle_leader_reservation(QName) ->
    {ok, Q} = rabbit_amqqueue:lookup(QName),
    ClusterSize = length(get_nodes(Q)),
    file_handle_cache:set_reservation(2 + ClusterSize).

file_handle_other_reservation() ->
    file_handle_cache:set_reservation(2).

file_handle_release_reservation() ->
    file_handle_cache:release_reservation().

-spec reclaim_memory(rabbit_types:vhost(), Name :: rabbit_misc:resource_name()) -> ok | {error, term()}.
reclaim_memory(Vhost, QueueName) ->
    QName = #resource{virtual_host = Vhost, name = QueueName, kind = queue},
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} when ?amqqueue_is_classic(Q) ->
            {error, classic_queue_not_supported};
        {ok, Q} when ?amqqueue_is_quorum(Q) ->
            ok = ra:pipeline_command(amqqueue:get_pid(Q),
                                     rabbit_fifo:make_garbage_collection());
        {ok, _Q} ->
            {error, not_quorum_queue};
        {error, not_found} = E ->
            E
    end.

-spec wal_force_roll_over(node()) -> ok.
 wal_force_roll_over(Node) ->
    ra_log_wal:force_roll_over({?RA_WAL_NAME, Node}).

%%----------------------------------------------------------------------------
dead_letter_handler(Q, Overflow) ->
    Exchange = args_policy_lookup(<<"dead-letter-exchange">>, fun queueArgHasPrecedence/2, Q),
    RoutingKey = args_policy_lookup(<<"dead-letter-routing-key">>, fun queueArgHasPrecedence/2, Q),
    Strategy = args_policy_lookup(<<"dead-letter-strategy">>, fun queueArgHasPrecedence/2, Q),
    QName = amqqueue:get_name(Q),
    dlh(Exchange, RoutingKey, Strategy, Overflow, QName).

dlh(undefined, undefined, undefined, _, _) ->
    undefined;
dlh(undefined, RoutingKey, undefined, _, QName) ->
    rabbit_log:warning("Disabling dead-lettering for ~ts despite configured dead-letter-routing-key '~ts' "
                       "because dead-letter-exchange is not configured.",
                       [rabbit_misc:rs(QName), RoutingKey]),
    undefined;
dlh(undefined, _, Strategy, _, QName) ->
    rabbit_log:warning("Disabling dead-lettering for ~ts despite configured dead-letter-strategy '~ts' "
                       "because dead-letter-exchange is not configured.",
                       [rabbit_misc:rs(QName), Strategy]),
    undefined;
dlh(Exchange, RoutingKey, <<"at-least-once">>, reject_publish, QName) ->
    %% Feature flag stream_queue includes the rabbit_queue_type refactor
    %% which is required by rabbit_fifo_dlx_worker.
    case rabbit_queue_type:is_supported() of
        true ->
            at_least_once;
        false ->
            rabbit_log:warning("Falling back to dead-letter-strategy at-most-once for ~ts "
                               "because feature flag stream_queue is disabled.",
                               [rabbit_misc:rs(QName)]),
            dlh_at_most_once(Exchange, RoutingKey, QName)
    end;
dlh(Exchange, RoutingKey, <<"at-least-once">>, drop_head, QName) ->
    rabbit_log:warning("Falling back to dead-letter-strategy at-most-once for ~ts "
                       "because configured dead-letter-strategy at-least-once is incompatible with "
                       "effective overflow strategy drop-head. To enable dead-letter-strategy "
                       "at-least-once, set overflow strategy to reject-publish.",
                       [rabbit_misc:rs(QName)]),
    dlh_at_most_once(Exchange, RoutingKey, QName);
dlh(Exchange, RoutingKey, _, _, QName) ->
    dlh_at_most_once(Exchange, RoutingKey, QName).

dlh_at_most_once(Exchange, RoutingKey, QName) ->
    DLX = rabbit_misc:r(QName, exchange, Exchange),
    MFA = {?MODULE, dead_letter_publish, [DLX, RoutingKey, QName]},
    {at_most_once, MFA}.

dead_letter_publish(X, RK, QName, Reason, Msgs) ->
    case rabbit_exchange:lookup(X) of
        {ok, Exchange} ->
            lists:foreach(fun(Msg) ->
                                  rabbit_dead_letter:publish(Msg, Reason, Exchange, RK, QName)
                          end, Msgs),
            rabbit_global_counters:messages_dead_lettered(Reason, ?MODULE, at_most_once, length(Msgs));
        {error, not_found} ->
            %% Even though dead-letter-strategy is at_most_once,
            %% when configured dead-letter-exchange does not exist,
            %% we increment counter for dead-letter-strategy 'disabled' because
            %% 1. we know for certain that the message won't be delivered, and
            %% 2. that's in line with classic queue behaviour
            rabbit_global_counters:messages_dead_lettered(Reason, ?MODULE, disabled, length(Msgs))
    end.

find_quorum_queues(VHost) ->
    Node = node(),
    mnesia:async_dirty(
      fun () ->
              qlc:e(qlc:q([Q || Q <- mnesia:table(rabbit_durable_queue),
                                ?amqqueue_is_quorum(Q),
                                amqqueue:get_vhost(Q) =:= VHost,
                                amqqueue:qnode(Q) == Node]))
      end).

i_totals(Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    case ets:lookup(queue_coarse_metrics, QName) of
        [{_, MR, MU, M, _}] ->
            [{messages_ready, MR},
             {messages_unacknowledged, MU},
             {messages, M}];
        [] ->
            [{messages_ready, 0},
             {messages_unacknowledged, 0},
             {messages, 0}]
    end.

i(name,        Q) when ?is_amqqueue(Q) -> amqqueue:get_name(Q);
i(durable,     Q) when ?is_amqqueue(Q) -> amqqueue:is_durable(Q);
i(auto_delete, Q) when ?is_amqqueue(Q) -> amqqueue:is_auto_delete(Q);
i(arguments,   Q) when ?is_amqqueue(Q) -> amqqueue:get_arguments(Q);
i(pid, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    whereis(Name);
i(messages, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    quorum_messages(QName);
i(messages_ready, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    ets_lookup_element(queue_coarse_metrics, QName, 2, 0);
i(messages_unacknowledged, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    ets_lookup_element(queue_coarse_metrics, QName, 3, 0);
i(policy, Q) ->
    case rabbit_policy:name(Q) of
        none   -> '';
        Policy -> Policy
    end;
i(operator_policy, Q) ->
    case rabbit_policy:name_op(Q) of
        none   -> '';
        Policy -> Policy
    end;
i(effective_policy_definition, Q) ->
    case rabbit_policy:effective_definition(Q) of
        undefined -> [];
        Def       -> Def
    end;
i(consumers, Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    Consumers = ets_lookup_element(queue_metrics, QName, 2, []),
    proplists:get_value(consumers, Consumers, 0);
i(memory, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    try
        {memory, M} = process_info(whereis(Name), memory),
        M
    catch
        error:badarg ->
            0
    end;
i(state, Q) when ?is_amqqueue(Q) ->
    {Name, Node} = amqqueue:get_pid(Q),
    %% Check against the leader or last known leader
    case erpc_call(Node, ?MODULE, cluster_state, [Name], ?RPC_TIMEOUT) of
        {error, _} ->
            down;
        State ->
            State
    end;
i(local_state, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    ets_lookup_element(ra_state, Name, 2, not_member);
i(garbage_collection, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    try
        rabbit_misc:get_gc_info(whereis(Name))
    catch
        error:badarg ->
            []
    end;
i(members, Q) when ?is_amqqueue(Q) ->
    get_nodes(Q);
i(online, Q) -> online(Q);
i(leader, Q) -> leader(Q);
i(open_files, Q) when ?is_amqqueue(Q) ->
    {Name, _} = amqqueue:get_pid(Q),
    Nodes = get_connected_nodes(Q),
    {Data, _} = rpc:multicall(Nodes, ?MODULE, open_files, [Name]),
    lists:flatten(Data);
i(single_active_consumer_pid, Q) when ?is_amqqueue(Q) ->
    QPid = amqqueue:get_pid(Q),
    case ra:local_query(QPid, fun rabbit_fifo:query_single_active_consumer/1) of
        {ok, {_, {value, {_ConsumerTag, ChPid}}}, _} ->
            ChPid;
        {ok, _, _} ->
            '';
        {error, _} ->
            '';
        {timeout, _} ->
            ''
    end;
i(single_active_consumer_ctag, Q) when ?is_amqqueue(Q) ->
    QPid = amqqueue:get_pid(Q),
    case ra:local_query(QPid,
                        fun rabbit_fifo:query_single_active_consumer/1) of
        {ok, {_, {value, {ConsumerTag, _ChPid}}}, _} ->
            ConsumerTag;
        {ok, _, _} ->
            '';
        {error, _} ->
            '';
        {timeout, _} ->
            ''
    end;
i(type, _) -> quorum;
i(messages_ram, Q) when ?is_amqqueue(Q) ->
    0;
i(message_bytes_ram, Q) when ?is_amqqueue(Q) ->
    0;
i(messages_dlx, Q) when ?is_amqqueue(Q) ->
    QPid = amqqueue:get_pid(Q),
    case ra:local_query(QPid,
                        fun rabbit_fifo:query_stat_dlx/1) of
        {ok, {_, {Num, _}}, _} ->
            Num;
        {error, _} ->
            0;
        {timeout, _} ->
            0
    end;
i(message_bytes_dlx, Q) when ?is_amqqueue(Q) ->
    QPid = amqqueue:get_pid(Q),
    case ra:local_query(QPid,
                        fun rabbit_fifo:query_stat_dlx/1) of
        {ok, {_, {_, Bytes}}, _} ->
            Bytes;
        {error, _} ->
            0;
        {timeout, _} ->
            0
    end;
i(_K, _Q) -> ''.

open_files(Name) ->
    case whereis(Name) of
        undefined ->
            {node(), 0};
        Pid ->
            {node(), ets_lookup_element(ra_open_file_metrics, Pid, 2, 0)}
    end.

leader(Q) when ?is_amqqueue(Q) ->
    {Name, Leader} = amqqueue:get_pid(Q),
    case is_process_alive(Name, Leader) of
        true -> Leader;
        false -> ''
    end.

peek(Vhost, Queue, Pos) ->
    peek(Pos, rabbit_misc:r(Vhost, queue, Queue)).

peek(Pos, #resource{} = QName) ->
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} ->
            peek(Pos, Q);
        Err ->
            Err
    end;
peek(Pos, Q) when ?is_amqqueue(Q) andalso ?amqqueue_is_quorum(Q) ->
    LeaderPid = amqqueue:get_pid(Q),
    case ra:aux_command(LeaderPid, {peek, Pos}) of
        {ok, {MsgHeader, Msg0}} ->
            Count = case MsgHeader of
                        #{delivery_count := C} -> C;
                       _ -> 0
                    end,
            Msg = rabbit_basic:add_header(<<"x-delivery-count">>, long,
                                          Count, Msg0),
            {ok, rabbit_basic:peek_fmt_message(Msg)};
        {error, Err} ->
            {error, Err};
        Err ->
            Err
    end;
peek(_Pos, Q) when ?is_amqqueue(Q) andalso ?amqqueue_is_classic(Q) ->
    {error, classic_queue_not_supported};
peek(_Pos, Q) when ?is_amqqueue(Q) ->
    {error, not_quorum_queue}.

online(Q) when ?is_amqqueue(Q) ->
    Nodes = get_connected_nodes(Q),
    {Name, _} = amqqueue:get_pid(Q),
    [Node || Node <- Nodes, is_process_alive(Name, Node)].

format(Q) when ?is_amqqueue(Q) ->
    Nodes = get_nodes(Q),
    [{members, Nodes}, {online, online(Q)}, {leader, leader(Q)}].

is_process_alive(Name, Node) ->
    %% don't attempt rpc if node is not already connected
    %% as this function is used for metrics and stats and the additional
    %% latency isn't warranted
    erlang:is_pid(erpc_call(Node, erlang, whereis, [Name], ?RPC_TIMEOUT)).

-spec quorum_messages(rabbit_amqqueue:name()) -> non_neg_integer().

quorum_messages(QName) ->
    ets_lookup_element(queue_coarse_metrics, QName, 4, 0).

quorum_ctag(Int) when is_integer(Int) ->
    integer_to_binary(Int);
quorum_ctag(Other) ->
    Other.

maybe_send_reply(_ChPid, undefined) -> ok;
maybe_send_reply(ChPid, Msg) -> ok = rabbit_channel:send_command(ChPid, Msg).

queue_name(RaFifoState) ->
    rabbit_fifo_client:cluster_name(RaFifoState).

get_default_quorum_initial_group_size(Arguments) ->
    case rabbit_misc:table_lookup(Arguments, <<"x-quorum-initial-group-size">>) of
        undefined ->
            application:get_env(rabbit, quorum_cluster_size, 3);
        {_Type, Val} ->
            Val
    end.

%% member with the current leader first
members(Q) when ?amqqueue_is_quorum(Q) ->
    {RaName, LeaderNode} = amqqueue:get_pid(Q),
    Nodes = lists:delete(LeaderNode, get_nodes(Q)),
    [{RaName, N} || N <- [LeaderNode | Nodes]].

format_ra_event(ServerId, Evt, QRef) ->
    {'$gen_cast', {queue_event, QRef, {ServerId, Evt}}}.

make_ra_conf(Q, ServerId, TickTimeout, SnapshotInterval) ->
    QName = amqqueue:get_name(Q),
    RaMachine = ra_machine(Q),
    [{ClusterName, _} | _] = Members = members(Q),
    UId = ra:new_uid(ra_lib:to_binary(ClusterName)),
    FName = rabbit_misc:rs(QName),
    Formatter = {?MODULE, format_ra_event, [QName]},
    #{cluster_name => ClusterName,
      id => ServerId,
      uid => UId,
      friendly_name => FName,
      metrics_key => QName,
      initial_members => Members,
      log_init_args => #{uid => UId,
                         snapshot_interval => SnapshotInterval},
      tick_timeout => TickTimeout,
      machine => RaMachine,
      ra_event_formatter => Formatter}.

get_nodes(Q) when ?is_amqqueue(Q) ->
    #{nodes := Nodes} = amqqueue:get_type_state(Q),
    Nodes.

get_connected_nodes(Q) when ?is_amqqueue(Q) ->
    ErlangNodes = [node() | nodes()],
    [N || N <- get_nodes(Q), lists:member(N, ErlangNodes)].

update_type_state(Q, Fun) when ?is_amqqueue(Q) ->
    Ts = amqqueue:get_type_state(Q),
    amqqueue:set_type_state(Q, Fun(Ts)).

overflow(undefined, Def, _QName) -> Def;
overflow(<<"reject-publish">>, _Def, _QName) -> reject_publish;
overflow(<<"drop-head">>, _Def, _QName) -> drop_head;
overflow(<<"reject-publish-dlx">> = V, Def, QName) ->
    rabbit_log:warning("Invalid overflow strategy ~tp for quorum queue: ~ts",
                       [V, rabbit_misc:rs(QName)]),
    Def.

parse_credit_args(Default, Args) ->
    case rabbit_misc:table_lookup(Args, <<"x-credit">>) of
        {table, T} ->
            case {rabbit_misc:table_lookup(T, <<"credit">>),
                  rabbit_misc:table_lookup(T, <<"drain">>)} of
                {{long, C}, {bool, D}} ->
                    {credited, C, D};
                _ ->
                    {simple_prefetch, Default, false}
            end;
        undefined ->
            {simple_prefetch, Default, false}
    end.

-spec notify_decorators(amqqueue:amqqueue()) -> 'ok'.
notify_decorators(Q) when ?is_amqqueue(Q) ->
    QName = amqqueue:get_name(Q),
    QPid = amqqueue:get_pid(Q),
    case ra:local_query(QPid, fun rabbit_fifo:query_notify_decorators_info/1) of
        {ok, {_, {MaxActivePriority, IsEmpty}}, _} ->
            notify_decorators(QName, consumer_state_changed,
                              [MaxActivePriority, IsEmpty]);
        _ -> ok
    end.

notify_decorators(QName, Event) ->
    notify_decorators(QName, Event, []).

notify_decorators(Q, F, A) when ?is_amqqueue(Q) ->
    Ds = amqqueue:get_decorators(Q),
    [ok = apply(M, F, [Q|A]) || M <- rabbit_queue_decorator:select(Ds)],
    ok;
notify_decorators(QName, F, A) ->
    %% Look up again in case policy and hence decorators have changed
    case rabbit_amqqueue:lookup(QName) of
        {ok, Q} ->
            Ds = amqqueue:get_decorators(Q),
            [ok = apply(M, F, [Q|A]) || M <- rabbit_queue_decorator:select(Ds)],
            ok;
        {error, not_found} ->
            ok
    end.

%% remove any data that a quorum queue doesn't need
prepare_content(#content{properties = none} = Content) ->
    Content;
prepare_content(#content{protocol = none} = Content) ->
    Content;
prepare_content(#content{properties = #'P_basic'{expiration = undefined} = Props,
                         protocol = Proto} = Content) ->
    Content#content{properties = none,
                    properties_bin = Proto:encode_properties(Props)};
prepare_content(Content) ->
    %% expiration is set. Therefore, leave properties decoded so that
    %% rabbit_fifo can directly parse it without having to decode again.
    Content.

ets_lookup_element(Tbl, Key, Pos, Default) ->
    try ets:lookup_element(Tbl, Key, Pos) of
        V -> V
    catch
        _:badarg ->
            Default
    end.

erpc_call(Node, M, F, A, Timeout)
  when is_integer(Timeout) andalso Node == node()  ->
    %% Only timeout 'infinity' optimises the local call in OTP 23-25 avoiding a new process being spawned:
    %% https://github.com/erlang/otp/blob/47f121af8ee55a0dbe2a8c9ab85031ba052bad6b/lib/kernel/src/erpc.erl#L121
    try erpc:call(Node, M, F, A, infinity) of
        Result ->
            Result
    catch
        error:Err ->
            {error, Err}
    end;
erpc_call(Node, M, F, A, Timeout) ->
    case lists:member(Node, nodes()) of
        true ->
            try erpc:call(Node, M, F, A, Timeout) of
                Result ->
                    Result
            catch
                error:Err ->
                    {error, Err}
            end;
        false ->
            {error, noconnection}
    end.


