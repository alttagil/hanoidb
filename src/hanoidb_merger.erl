%% ----------------------------------------------------------------------------
%%
%% hanoidb: LSM-trees (Log-Structured Merge Trees) Indexed Storage
%%
%% Copyright 2011-2012 (c) Trifork A/S.  All Rights Reserved.
%% http://trifork.com/ info@trifork.com
%%
%% Copyright 2012 (c) Basho Technologies, Inc.  All Rights Reserved.
%% http://basho.com/ info@basho.com
%%
%% This file is provided to you under the Apache License, Version 2.0 (the
%% "License"); you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
%% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
%% License for the specific language governing permissions and limitations
%% under the License.
%%
%% ----------------------------------------------------------------------------

-module(hanoidb_merger).
-author('Kresten Krab Thorup <krab@trifork.com>').
-author('Gregory Burd <greg@burd.me>').

%% @doc Merging two Indexes

-export([start/6, merge/6]).

-include("hanoidb.hrl").
-include("include/plain_rpc.hrl").

%% A merger which is inactive for this long will sleep which means that it will
%% close open files, and compress the current bloom filter.
-define(HIBERNATE_TIMEOUT, 5000).

%% Most likely, there will be plenty of I/O being generated by concurrent
%% merges, so we default to running the entire merge in one process.
-define(LOCAL_WRITER, true).


-spec start(string(), string(), string(), integer(), boolean(), list()) -> pid().
start(A,B,X, Size, IsLastLevel, Options) ->
    Owner = self(),
    plain_fsm:spawn_link(?MODULE, fun() ->
        try
            {ok, OutCount} = hanoidb_merger:merge(A, B, X,
                Size,
                IsLastLevel,
                Options),

            Owner ! ?CAST(self(),{merge_done, OutCount, X})
        catch
            C:E ->
                %% this semi-bogus code makes sure we always get a stack trace if merging fails
                error_logger:error_msg("~p: merge failed ~p:~p ~p -> ~s~n",
                    [self(), C,E,erlang:get_stacktrace(), X]),
                erlang:raise(C,E,erlang:get_stacktrace())
        end
    end).

-spec merge(string(), string(), string(), integer(), boolean(), list()) -> {ok, integer()}.
merge(A,B,C, Size, IsLastLevel, Options) ->
    {ok, IXA} = hanoidb_reader:open(A, [sequential|Options]),
    {ok, IXB} = hanoidb_reader:open(B, [sequential|Options]),
    {ok, Out} = hanoidb_writer:init([C, [{size, Size} | Options]]),
    AKVs =
        case hanoidb_reader:first_node(IXA) of
            {node, AKV} -> AKV;
            none -> []
        end,
    BKVs =
        case hanoidb_reader:first_node(IXB) of
            {node, BKV} ->BKV;
            none -> []
        end,
    scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {0, none}).

terminate(Out) ->
    {ok, Count, Out1} = hanoidb_writer:handle_call(count, self(), Out),
    {stop, normal, ok, _Out2} = hanoidb_writer:handle_call(close, self(), Out1),
    {ok, Count}.

step(S) ->
    step(S, 1).

step({N, From}, Steps) ->
    {N-Steps, From}.

hibernate_scan(Keep) ->
    erlang:garbage_collect(),
    receive
        {step, From, HowMany} ->
            {IXA, IXB, Out, IsLastLevel, AKVs, BKVs, N} = erlang:binary_to_term(Keep),
            scan(hanoidb_reader:deserialize(IXA),
                 hanoidb_reader:deserialize(IXB),
                 hanoidb_writer:deserialize(Out),
                 IsLastLevel, AKVs, BKVs, {N+HowMany, From});

        %% gen_fsm handling
        {system, From, Req} ->
            plain_fsm:handle_system_msg(
                Req, From, Keep, fun hibernate_scan/1);

        {'EXIT', Parent, Reason} ->
            case plain_fsm:info(parent) of
                Parent ->
                    plain_fsm:parent_EXIT(Reason, Keep)
            end

    end.


hibernate_scan_only(Keep) ->
    erlang:garbage_collect(),
    receive
        {step, From, HowMany} ->
            {IX, OutBin, IsLastLevel, KVs, N} = erlang:binary_to_term(Keep),
            scan_only(hanoidb_reader:deserialize(IX),
                hanoidb_writer:deserialize(OutBin),
                IsLastLevel, KVs, {N+HowMany, From});

        %% gen_fsm handling
        {system, From, Req} ->
            plain_fsm:handle_system_msg(
                Req, From, Keep, fun hibernate_scan_only/1);

        {'EXIT', Parent, Reason} ->
            case plain_fsm:info(parent) of
                Parent ->
                    plain_fsm:parent_EXIT(Reason, Keep)
            end
    end.


receive_scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {N, FromPID}) ->

    receive
        {step, From, HowMany} ->
            scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {N+HowMany, From});

        %% gen_fsm handling
        {system, From, Req} ->
            plain_fsm:handle_system_msg(
                Req, From, {IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {N, FromPID}},
                            fun({IXA2, IXB2, Out2, IsLastLevel2, AKVs2, BKVs2, {N2, FromPID2}}) ->
                                receive_scan(IXA2, IXB2, Out2, IsLastLevel2, AKVs2, BKVs2, {N2, FromPID2})
                            end);

        {'EXIT', Parent, Reason} ->
            case plain_fsm:info(parent) of
                Parent ->
                    plain_fsm:parent_EXIT(Reason, {IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {N, FromPID}})
            end

    after ?HIBERNATE_TIMEOUT ->
        Args = {hanoidb_reader:serialize(IXA),
            hanoidb_reader:serialize(IXB),
            hanoidb_writer:serialize(Out), IsLastLevel, AKVs, BKVs, N},
        Keep = erlang:term_to_binary(Args, [compressed]),
        hibernate_scan(Keep)
    end.


scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {N, FromPID}) when N < 1, AKVs =/= [], BKVs =/= [] ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

    receive_scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, {N, FromPID});

scan(IXA, IXB, Out, IsLastLevel, [], BKVs, Step) ->
    case hanoidb_reader:next_node(IXA) of
        {node, AKVs} ->
            scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, Step);
        end_of_data ->
            hanoidb_reader:close(IXA),
            scan_only(IXB, Out, IsLastLevel, BKVs, Step)
    end;

scan(IXA, IXB, Out, IsLastLevel, AKVs, [], Step) ->
    case hanoidb_reader:next_node(IXB) of
        {node, BKVs} ->
            scan(IXA, IXB, Out, IsLastLevel, AKVs, BKVs, Step);
        end_of_data ->
            hanoidb_reader:close(IXB),
            scan_only(IXA, Out, IsLastLevel, AKVs, Step)
    end;

scan(IXA, IXB, Out, IsLastLevel, [{Key1,Value1}|AT]=_AKVs, [{Key2,_Value2}|_IX]=BKVs, Step)
  when Key1 < Key2 ->
    {noreply, Out3} = hanoidb_writer:handle_cast({add, Key1, Value1}, Out),
    scan(IXA, IXB, Out3, IsLastLevel, AT, BKVs, step(Step));
scan(IXA, IXB, Out, IsLastLevel, [{Key1,_Value1}|_AT]=AKVs, [{Key2,Value2}|IX]=_BKVs, Step)
  when Key1 > Key2 ->
    {noreply, Out3} = hanoidb_writer:handle_cast({add, Key2, Value2}, Out),
    scan(IXA, IXB, Out3, IsLastLevel, AKVs, IX, step(Step));
scan(IXA, IXB, Out, IsLastLevel, [{_Key1,_Value1}|AT]=_AKVs, [{Key2,Value2}|IX]=_BKVs, Step) ->
    {noreply, Out3} = hanoidb_writer:handle_cast({add, Key2, Value2}, Out),
    scan(IXA, IXB, Out3, IsLastLevel, AT, IX, step(Step, 2)).


receive_scan_only(IX, Out, IsLastLevel, KVs, {N, FromPID}) ->


    receive
        {step, From, HowMany} ->
            scan_only(IX, Out, IsLastLevel, KVs, {N+HowMany, From});

        %% gen_fsm handling
        {system, From, Req} ->
            plain_fsm:handle_system_msg(
                Req, From, {IX, Out, IsLastLevel, KVs, {N, FromPID}},
                fun({IX2, Out2, IsLastLevel2, KVs2, {N2, FromPID2}}) ->
                    receive_scan_only(IX2, Out2, IsLastLevel2, KVs2, {N2, FromPID2})
                end);

        {'EXIT', Parent, Reason} ->
            case plain_fsm:info(parent) of
                Parent ->
                    plain_fsm:parent_EXIT(Reason, {IX, Out, IsLastLevel, KVs, {N, FromPID}})
            end

    after ?HIBERNATE_TIMEOUT ->
        Args = {hanoidb_reader:serialize(IX),
            hanoidb_writer:serialize(Out), IsLastLevel, KVs, N},
        Keep = erlang:term_to_binary(Args, [compressed]),
        hibernate_scan_only(Keep)
    end.



scan_only(IX, Out, IsLastLevel, KVs, {N, FromPID}) when N < 1, KVs =/= [] ->
    case FromPID of
        none ->
            ok;
        {PID, Ref} ->
            PID ! {Ref, step_done}
    end,

    receive_scan_only(IX, Out, IsLastLevel, KVs, {N, FromPID});

scan_only(IX, Out, IsLastLevel, [], {_, FromPID}=Step) ->
    case hanoidb_reader:next_node(IX) of
        {node, KVs} ->
            scan_only(IX, Out, IsLastLevel, KVs, Step);
        end_of_data ->
            case FromPID of
                none ->
                    ok;
                {PID, Ref} ->
                    PID ! {Ref, step_done}
            end,
            hanoidb_reader:close(IX),
            terminate(Out)
    end;

scan_only(IX, Out, true, [{_,?TOMBSTONE}|Rest], Step) ->
    scan_only(IX, Out, true, Rest, step(Step));

scan_only(IX, Out, IsLastLevel, [{Key,Value}|Rest], Step) ->
    {noreply, Out3} = hanoidb_writer:handle_cast({add, Key, Value}, Out),
    scan_only(IX, Out3, IsLastLevel, Rest, step(Step)).
