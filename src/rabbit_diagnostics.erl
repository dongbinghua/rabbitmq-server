%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2020 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(rabbit_diagnostics).

-define(PROCESS_INFO,
        [registered_name, current_stacktrace, initial_call, message_queue_len,
         links, monitors, monitored_by, heap_size]).

-export([maybe_stuck/0, maybe_stuck/1, top_memory_use/0, top_memory_use/1,
         top_binary_refs/0, top_binary_refs/1]).

maybe_stuck() -> maybe_stuck(5000).

maybe_stuck(Timeout) ->
    Pids = processes(),
    io:format("~s There are ~p processes.~n", [get_time(), length(Pids)]),
    maybe_stuck(Pids, Timeout).

maybe_stuck(Pids, Timeout) when Timeout =< 0 ->
    io:format("~s Found ~p suspicious processes.~n", [get_time(), length(Pids)]),
    [io:format("~s ~p~n", [get_time(), info(Pid)]) || Pid <- Pids],
    ok;
maybe_stuck(Pids, Timeout) ->
    Pids2 = [P || P  <- Pids, looks_stuck(P)],
    io:format("~s Investigated ~p processes this round, ~pms to go.~n",
              [get_time(), length(Pids2), Timeout]),
    timer:sleep(500),
    maybe_stuck(Pids2, Timeout - 500).

looks_stuck(Pid) ->
    case info(Pid, status, gone) of
        {status, waiting} ->
            %% It's tempting to just check for message_queue_len > 0
            %% here rather than mess around with stack traces and
            %% heuristics. But really, sometimes freshly stuck
            %% processes can have 0 messages...
            case info(Pid, current_stacktrace, gone) of
                {current_stacktrace, [H|_]} ->
                    maybe_stuck_stacktrace(H);
                _ ->
                    false
            end;
        _ ->
            false
    end.

maybe_stuck_stacktrace({gen_server2,      process_next_msg, _}) -> false;
maybe_stuck_stacktrace({gen_event,        fetch_msg,        _}) -> false;
maybe_stuck_stacktrace({prim_inet,        accept0,          _}) -> false;
maybe_stuck_stacktrace({prim_inet,        recv0,            _}) -> false;
maybe_stuck_stacktrace({rabbit_heartbeat, heartbeater,      _}) -> false;
maybe_stuck_stacktrace({rabbit_net,       recv,             _}) -> false;
maybe_stuck_stacktrace({group,            _,                _}) -> false;
maybe_stuck_stacktrace({shell,            _,                _}) -> false;
maybe_stuck_stacktrace({io,               _,                _}) -> false;
maybe_stuck_stacktrace({M, F, A, _}) ->
    maybe_stuck_stacktrace({M, F, A});
maybe_stuck_stacktrace({_M, F, _A}) ->
    case string:str(atom_to_list(F), "loop") of
        0 -> true;
        _ -> false
    end.

top_memory_use() -> top_memory_use(30).

top_memory_use(Count) ->
    Pids = processes(),
    io:format("~s Memory use: top ~p of ~p processes.~n", [get_time(), Count, length(Pids)]),
    Procs = [{info(Pid, memory, 0), info(Pid)} || Pid <- Pids],
    Sorted = lists:sublist(lists:reverse(lists:sort(Procs)), Count),
    io:format("~s ~p~n", [get_time(), Sorted]).

top_binary_refs() -> top_binary_refs(30).

top_binary_refs(Count) ->
    Pids = processes(),
    io:format("~s Binary refs: top ~p of ~p processes.~n", [get_time(), Count, length(Pids)]),
    Procs = [{{binary_refs, binary_refs(Pid)}, info(Pid)} || Pid <- Pids],
    Sorted = lists:sublist(lists:reverse(lists:sort(Procs)), Count),
    io:format("~s ~p~n", [get_time(), Sorted]).

binary_refs(Pid) ->
    case info(Pid, binary, []) of
        {binary, Refs} ->
            lists:sum([Sz || {_Ptr, Sz} <- lists:usort([{Ptr, Sz} ||
                                                           {Ptr, Sz, _Cnt} <- Refs])]);
        _ -> 0
    end.

info(Pid) ->
    [{pid, Pid} | info(Pid, ?PROCESS_INFO, [])].

info(Pid, Infos, Default) ->
    try
        process_info(Pid, Infos)
    catch
        _:_ -> case is_atom(Infos) of
                   true  -> {Infos, Default};
                   false -> Default
               end
    end.

get_time() ->
    {{Y,M,D}, {H,Min,Sec}} = calendar:local_time(),
    [ integer_to_list(Y), "-",
      prefix_zero(integer_to_list(M)), "-",
      prefix_zero(integer_to_list(D)), " ",
      prefix_zero(integer_to_list(H)), ":",
      prefix_zero(integer_to_list(Min)), ":",
      prefix_zero(integer_to_list(Sec))
      ].

prefix_zero([C]) -> [$0, C];
prefix_zero([_,_] = Full) -> Full.
