%% This file is a copy of exometer_slide.erl from https://github.com/Feuerlabs/exometer_core,
%% with the following modifications:
%%
%% 1) The elements are tuples of numbers
%%
%% 2) Only one element for each expected interval point is added, intermediate values
%%    are discarded. Thus, if we have a window of 60s and interval of 5s, at max 12 elements
%%    are stored.
%%
%% 3) Additions can be provided as increments to the last value stored
%%
%% 4) sum/1 implements the sum of several slides, generating a new timestamp sequence based
%%    on the given intervals. Elements on each window are added to the closest interval point.
%%
%% Original commit: https://github.com/Feuerlabs/exometer_core/commit/2759edc804211b5245867b32c9a20c8fe1d93441
%%
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 Basho Technologies, Inc.  All Rights Reserved.
%%
%%   This Source Code Form is subject to the terms of the Mozilla Public
%%   License, v. 2.0. If a copy of the MPL was not distributed with this
%%   file, You can obtain one at http://mozilla.org/MPL/2.0/.
%%
%% -------------------------------------------------------------------
%%
%% @author Tony Rogvall <tony@rogvall.se>
%% @author Ulf Wiger <ulf@feuerlabs.com>
%% @author Magnus Feuer <magnus@feuerlabs.com>
%%
%% @doc Efficient sliding-window buffer
%%
%% Initial implementation: 29 Sep 2009 by Tony Rogvall
%%
%% This module implements an efficient sliding window, maintaining
%% two lists - a primary and a secondary. Values are paired with a
%% timestamp (millisecond resolution, see `timestamp/0')
%% and prepended to the primary list. When the time span between the oldest
%% and the newest entry in the primary list exceeds the given window size,
%% the primary list is shifted into the secondary list position, and the
%% new entry is added to a new (empty) primary list.
%%
%% The window can be converted to a list using `to_list/1'.
%% @end
%%
%%
%% All modifications are (C) 2007-2016 Pivotal Software, Inc. All rights reserved.
%% The Initial Developer of the Original Code is Basho Technologies, Inc.
%%
-module(exometer_slide).

-export([new/2, new/3,
         reset/1,
         add_element/3,
         to_list/2,
         foldl/5,
         to_normalized_list/5]).

-export([timestamp/0,
         last_two/1,
         last/1]).

-export([sum/1, optimize/1]).

-compile(inline).
-compile(inline_list_funcs).


-type value() :: tuple().
-type internal_value() :: tuple() | drop.
-type timestamp() :: non_neg_integer().

-type fold_acc() :: any().
-type fold_fun() :: fun(({timestamp(), internal_value()}, fold_acc()) -> fold_acc()).

%% Fixed size event buffer
-record(slide, {size = 0 :: integer(),  % ms window
                n = 0 :: integer(),  % number of elements in buf1
                max_n :: undefined | integer(),  % max no of elements
                incremental = false :: boolean(),
                interval :: integer(),
                last = 0 :: integer(), % millisecond timestamp
                first = undefined :: undefined | integer(), % millisecond timestamp
                buf1 = [] :: [internal_value()],
                buf2 = [] :: [internal_value()],
                total :: undefined | value()}).

-opaque slide() :: #slide{}.

-export_type([slide/0, timestamp/0]).

-spec timestamp() -> timestamp().
%% @doc Generate a millisecond-resolution timestamp.
%%
%% This timestamp format is used e.g. by the `exometer_slide' and
%% `exometer_histogram' implementations.
%% @end
timestamp() ->
    time_compat:os_system_time(milli_seconds).

-spec new(_Size::integer(), _Options::list()) -> slide().
%% @doc Create a new sliding-window buffer.
%%
%% `Size' determines the size in milliseconds of the sliding window.
%% The implementation prepends values into a primary list until the oldest
%% element in the list is `Size' ms older than the current value. It then
%% swaps the primary list into a secondary list, and starts prepending to
%% a new primary list. This means that more data than fits inside the window
%% will be kept - upwards of twice as much. On the other hand, updating the
%% buffer is very cheap.
%% @end
new(Size, Opts) -> new(timestamp(), Size, Opts).

-spec new(Timestamp :: timestamp(), Size::integer(), Options::list()) -> slide().
new(TS, Size, Opts) ->
    #slide{size = Size,
           max_n = proplists:get_value(max_n, Opts, infinity),
           interval = proplists:get_value(interval, Opts, infinity),
           last = TS,
           first = undefined,
           incremental = proplists:get_value(incremental, Opts, false),
           buf1 = [],
           buf2 = []}.

-spec reset(slide()) -> slide().
%% @doc Empty the buffer
%%
reset(Slide) ->
    Slide#slide{n = 0, buf1 = [], buf2 = [], last = 0}.

-spec add_element(timestamp(), value(), slide()) -> slide().
%% @doc Add an element to the buffer, tagged with the given timestamp.
%%
%% Apart from the specified timestamp, this function works just like
%% {@link add_element/2}.
%% @end
%%
add_element(TS, Evt, Slide) ->
    add_element(TS, Evt, Slide, false).

-spec add_element(timestamp(), value(), slide(), true) ->
                         {boolean(), slide()};
                 (timestamp(), value(), slide(), false) ->
                         slide().
%% @doc Add an element to the buffer, optionally indicating if a swap occurred.
%%
%% This function works like {@link add_element/3}, but will also indicate
%% whether the sliding window buffer swapped lists (this means that the
%% 'primary' buffer list became full and was swapped to 'secondary', starting
%% over with an empty primary list. If `Wrap == true', the return value will be
%% `{Bool,Slide}', where `Bool==true' means that a swap occurred, and
%% `Bool==false' means that it didn't.
%%
%% If `Wrap == false', this function works exactly like {@link add_element/3}.
%%
%% One possible use of the `Wrap == true' option could be to keep a sliding
%% window buffer of values that are pushed e.g. to an external stats service.
%% The swap indication could be a trigger point where values are pushed in order
%% to not lose entries.
%% @end
%%

add_element(_TS, _Evt, Slide, Wrap) when Slide#slide.size == 0 ->
    add_ret(Wrap, false, Slide);
add_element(TS, Evt, #slide{last = Last, interval = Interval, total = Total0,
                            incremental = true} = Slide, _Wrap)
  when (TS - Last) < Interval ->
    Total = add_to_total(Evt, Total0),
    Slide#slide{total = Total};
add_element(TS, Evt, #slide{last = Last, interval = Interval} = Slide, _Wrap)
  when (TS - Last) < Interval ->
    Slide#slide{total = Evt};
add_element(TS, Evt, #slide{last = Last, size = Sz, incremental = true,
                            n = N, max_n = MaxN, total = Total0,
                            buf1 = Buf1} = Slide, Wrap) ->
    N1 = N+1,
    Total = add_to_total(Evt, Total0),
    %% Total could be the same as the last sample, by adding and substracting
    %% the same amout to the totals. That is not strictly a drop, but should
    %% generate new samples.
    %% I.e. 0, 0, -14, 14 (total = 0, samples = 14, -14, 0, drop)
    case {is_zeros(Evt), Buf1} of
        {_, []} ->
            add_ret(Wrap, false, Slide#slide{n = N1, first = TS,
                                             buf1 = [{TS, Total} | Buf1],
                                             last = TS, total = Total});
        {true, [{_, Total}, drop | Tail]} ->
            %% Memory optimisation
            Slide#slide{buf1 = [{TS, Total}, drop | Tail],
                        last = TS};
        {true, [{_, Total} | Tail]} ->
            %% Memory optimisation
            Slide#slide{buf1 = [{TS, Total}, drop | Tail],
                        last = TS};
        _ when TS - Last > Sz; N1 > MaxN ->
            %% swap
            add_ret(Wrap, true, Slide#slide{last = TS,
                                            n = 1,
                                            buf1 = [{TS, Total}],
                                            buf2 = Buf1,
                                            total = Total});
        _ ->
            add_ret(Wrap, false, Slide#slide{n = N1,
                                             buf1 = [{TS, Total} | Buf1],
                                             last = TS, total = Total})
    end;
add_element(TS, Evt, #slide{buf1 = [{_, Evt}, drop | Tail]} = Slide, _Wrap) ->
    %% Memory optimisation
    Slide#slide{buf1 = [{TS, Evt}, drop | Tail],
                last = TS};
add_element(TS, Evt, #slide{buf1 = [{_, Evt} | Tail]} = Slide, _Wrap) ->
    %% Memory optimisation
    Slide#slide{buf1 = [{TS, Evt}, drop | Tail],
                last = TS};
add_element(TS, Evt, #slide{last = Last, size = Sz,
                            n = N, max_n = MaxN,
                            buf1 = Buf1} = Slide, Wrap) ->
    N1 = N+1,
    case Buf1 of
        [] ->
            add_ret(Wrap, false, Slide#slide{n = N1, buf1 = [{TS, Evt} | Buf1],
                                             last = TS, first = TS, total = Evt});
        _ when TS - Last > Sz; N1 > MaxN ->
            %% swap
            add_ret(Wrap, true, Slide#slide{last = TS,
                                            n = 1,
                                            buf1 = [{TS, Evt}],
                                            buf2 = Buf1,
                                            total = Evt});
       _ ->
            add_ret(Wrap, false, Slide#slide{n = N1, buf1 = [{TS, Evt} | Buf1],
                                             last = TS, total = Evt})
    end.

add_to_total(Evt, undefined) ->
    Evt;
add_to_total({A0}, {B0}) ->
    {B0 + A0};
add_to_total({A0, A1}, {B0, B1}) ->
    {B0 + A0, B1 + A1};
add_to_total({A0, A1, A2}, {B0, B1, B2}) ->
    {B0 + A0, B1 + A1, B2 + A2};
add_to_total({A0, A1, A2, A3, A4, A5, A6}, {B0, B1, B2, B3, B4, B5, B6}) ->
    {B0 + A0, B1 + A1, B2 + A2, B3 + A3, B4 + A4, B5 + A5, B6 + A6};
add_to_total({A0, A1, A2, A3, A4, A5, A6, A7}, {B0, B1, B2, B3, B4, B5, B6, B7}) ->
    {B0 + A0, B1 + A1, B2 + A2, B3 + A3, B4 + A4, B5 + A5, B6 + A6, B7 + A7};
add_to_total({A0, A1, A2, A3, A4, A5, A6, A7, A8, A9, A10, A11, A12, A13, A14,
          A15, A16, A17, A18, A19},
         {B0, B1, B2, B3, B4, B5, B6, B7, B8, B9, B10, B11, B12, B13, B14,
          B15, B16, B17, B18, B19}) ->
    {B0 + A0, B1 + A1, B2 + A2, B3 + A3, B4 + A4, B5 + A5, B6 + A6, B7 + A7, B8 + A8,
     B9 + A9, B10 + A10, B11 + A11, B12 + A12, B13 + A13, B14 + A14, B15 + A15, B16 + A16,
     B17 + A17, B18 + A18, B19 + A19}.

is_zeros({0}) ->
    true;
is_zeros({0, 0}) ->
    true;
is_zeros({0, 0, 0}) ->
    true;
is_zeros({0, 0, 0, 0, 0, 0, 0}) ->
    true;
is_zeros({0, 0, 0, 0, 0, 0, 0, 0}) ->
    true;
is_zeros({0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}) ->
    true;
is_zeros(_) ->
    false.

add_ret(false, _, Slide) ->
    Slide;
add_ret(true, Flag, Slide) ->
    {Flag, Slide}.

-spec optimize(#slide{}) -> #slide{}.
optimize(#slide{buf2 = []} = Slide) ->
    Slide;
optimize(#slide{buf1 = Buf1, buf2 = Buf2, max_n = MaxN, n = N} = Slide)
  when is_integer(MaxN) andalso length(Buf1) < MaxN ->
    Slide#slide{buf1 = Buf1,
                buf2 = lists:sublist(Buf2, n_diff(MaxN, N))};
optimize(Slide) -> Slide.


-spec to_list(timestamp(), #slide{}) -> [{timestamp(), value()}].
%% @doc Convert the sliding window into a list of timestamped values.
%% @end
to_list(_Now, #slide{size = Sz}) when Sz == 0 ->
    [];
to_list(Now, #slide{size = Sz} = Slide) ->
    to_list_from(Now, Now - Sz, Slide).

to_list_from(Now, From, #slide{max_n = MaxN, buf2 = Buf2, first = FirstTS,
                               interval = Interval} = Slide) ->
    {NewN, Buf1} = maybe_add_last_sample(Now, Slide),
    Start = first_max(FirstTS, From),
    Buf1_1 = take_since(Buf1, Start, NewN, [], Interval),
    take_since(Buf2, Start, n_diff(MaxN, NewN), Buf1_1, Interval).

first_max(undefined, X) -> X;
first_max(F, X) -> max(F, X).

-spec last_two(slide()) -> [{timestamp(), value()}].
%% @doc Returns the newest 2 elements on the sample
last_two(#slide{buf1 = [{TS, Evt} = H1, drop | _], interval = Interval}) ->
    [H1, {TS - Interval, Evt}];
last_two(#slide{buf1 = [H1, H2 | _]}) ->
    [H1, H2];
last_two(#slide{buf1 = [H1], buf2 = [H2 | _]}) ->
    [H1, H2];
last_two(#slide{buf1 = [H1], buf2 = []}) ->
    [H1];
last_two(#slide{buf1 = [], buf2 = [{TS, Evt} = H1, drop | _], interval = Interval}) ->
    [H1, {TS - Interval, Evt}];
last_two(#slide{buf1 = [], buf2 = [H1, H2 | _]}) ->
    [H1, H2];
last_two(#slide{buf1 = [], buf2 = [H1]}) ->
    [H1];
last_two(_) ->
    [].

-spec last(slide()) -> value() | undefined.
last(#slide{total = T}) when T =/= undefined ->
    T;
last(#slide{buf1 = [{_TS, T} | _]}) ->
    T;
last(#slide{buf2 = [{_TS, T} | _]}) ->
    T;
last(_) ->
    undefined.

-spec foldl(timestamp(), fold_fun(), fold_acc(), slide()) -> fold_acc().
%% @doc Fold over the sliding window, starting from `Timestamp'.
%%
%% The fun should as `fun({Timestamp, Value}, Acc) -> NewAcc'.
%% The values are processed in order from oldest to newest.
%% @end
foldl(Timestamp, Fun, Acc, #slide{} = Slide) ->
    foldl(timestamp(), Timestamp, Fun, Acc, Slide).

-spec foldl(timestamp(), timestamp(), fold_fun(), fold_acc(), slide()) -> fold_acc().
%% @doc Fold over the sliding window, starting from `Timestamp'.
%% Now provides a reference point to evaluate whether to include
%% partial, unrealised sample values in the sequence. Unrealised values will be
%% appended to the sequence when Now >= LastTS + Interval
%%
%% The fun should as `fun({Timestamp, Value}, Acc) -> NewAcc'.
%% The values are processed in order from oldest to newest.
%% @end
foldl(_Now, _Timestamp, _Fun, _Acc, #slide{size = Sz}) when Sz == 0 ->
    [];
foldl(Now, Timestamp, Fun, Acc, #slide{max_n = MaxN, buf2 = Buf2, first = FirstTS,
                                       interval = Interval} = Slide) ->
    Start = first_max(FirstTS, Timestamp),
    %% Ensure real actuals are reflected, if no more data is coming we might never
    %% shown the last value (i.e. total messages after queue delete)
    {NewN, Buf1} = maybe_add_last_sample(Now, Slide),
    lists:foldl(Fun, lists:foldl(Fun, Acc,
                                 take_since(Buf2, Start, n_diff(MaxN, NewN), [],
                                            Interval)),
                take_since(Buf1, Start, NewN, [], Interval) ++ [last]).

maybe_add_last_sample(_Now, #slide{total = T, n = N,
                                   buf1 = [{_, T} | _] = Buf1}) ->
    {N, Buf1};
maybe_add_last_sample(Now, #slide{total = T,
                                  n = N,
                                  interval = I,
                                  buf1 = [{TS, _} | _] = Buf1})
  when T =/= undefined andalso Now > TS ->
    {N + 1, [{min(Now, TS + I), T} | Buf1]};
maybe_add_last_sample(Now, #slide{total = T, buf1 = [], buf2 = []})
  when T =/= undefined ->
    {1, [{Now, T}]};
maybe_add_last_sample(_Now, #slide{buf1 = Buf1, n = N}) ->
    {N, Buf1}.

-spec to_normalized_list(timestamp(), timestamp(), integer(), slide(), no_pad | tuple()) ->
    [tuple()].
to_normalized_list(Now, Start, Interval, Slide, Empty) ->
    to_normalized_list(Now, Start, Interval, Slide, Empty, fun round/1).

to_normalized_list(Now, Start, Interval, #slide{first = FirstTS0,
                                                total = Total,
                                                last = _LastTS0} = Slide, Empty,
                  Round) ->
    Samples = to_list_from(Now, Start, Slide),
    Lookup = lists:foldl(fun({TS, Value}, Dict) when TS - Start >= 0 ->
                              NewTS = map_timestamp(TS, Start, Interval, Round),
                              orddict:update(NewTS, fun({T, V}) when T > TS ->
                                                            {T, V};
                                                       (_) -> {TS, Value}
                                                    end, {TS, Value}, Dict);
                            (_, Dict) -> Dict end, orddict:new(),
                         Samples),

    Pad = case Samples of
              _ when Empty =:= no_pad ->
                  [];
              [{TS, _} | _] when TS =:= FirstTS0, Start < FirstTS0 ->
                % only if we know there is nothing in the past can we
                % generate a 0 pad
                  [{T, Empty}
                   || T <- lists:seq(map_timestamp(TS, Start, Interval, Round) - Interval,
                                     Start, -Interval)];
              _ when FirstTS0 =:= undefined andalso Total =:= undefined ->
                  [{T, Empty} || T <- lists:seq(Now, Start, -Interval)];
              [] ->
                  [{T, Total} || T <- lists:seq(Now, Start, -Interval)];
              _ -> []
           end,

    {_, Res1} = lists:foldl(
                  fun(T, {Last, Acc}) ->
                          case orddict:find(T, Lookup) of
                              {ok, {_, V}} ->
                                  {V, [{T, V} | Acc]};
                              error when Last =:= undefined ->
                                  {Last, Acc};
                              error ->
                                  {Last, [{T, Last} | Acc]}
                          end
                  end, {undefined, []}, lists:seq(Start, Now, Interval)),
    Res1 ++ Pad.

-spec normalize(timestamp(), timestamp(), non_neg_integer(), slide(), function())
               -> slide().
normalize(Now, Start, Interval, Slide, Fun) ->
    Res = to_normalized_list(Now, Start, Interval, Slide, no_pad, Fun),
    Slide#slide{buf1 = Res, buf2 = [], n = length(Res)}.

%% @doc Normalize an incremental set of slides for summing
%%
%% Puts samples into buckets based on Now
%% Discards anything older than Now - Size
%% Fills in blanks in the ideal sequence with the last known value or undefined
%% @end
-spec normalize_incremental_slide(timestamp(), non_neg_integer(), slide(), function())
                                 -> slide().
normalize_incremental_slide(Now, Interval, #slide{size = Size} = Slide, Fun) ->
    Start = Now - Size,
    normalize(Now, Start, Interval, Slide, Fun).

-spec sum([slide()]) -> slide().
%% @doc Sums a list of slides
%%
%% Takes the last known timestamp and creates an template version of the
%% sliding window. Timestamps are then truncated and summed with the value
%% in the template slide.
%% @end
sum(Slides) ->
    % take the freshest timestamp as reference point for summing operation
    Now = lists:max([Last || #slide{last = Last} <- Slides]),
    sum(Now, Slides).

-spec sum(Now::timestamp(), All::[slide()]) -> slide().
sum(Now, [Slide = #slide{interval = Interval, size = Size, incremental = true} | _] = All) ->
    Start = Now - Size,
    Fun = fun(last, Dict) -> Dict;
             ({TS, Value}, Dict) ->
                  orddict:update(TS, fun(V) -> add_to_total(V, Value) end,
                                 Value, Dict)
          end,
    {Total, Dict} = lists:foldl(fun(#slide{total = T} = S, {Tot, Acc}) ->
                               N = normalize_incremental_slide(Now, Interval, S,
                                                               fun ceil/1),
                               Total = add_to_total(T, Tot),
                               {Total, foldl(Start, Fun, Acc, N#slide{total = undefined})}
                       end, {undefined, orddict:new()}, All),

    {FirstTS, Buffer} = case orddict:to_list(Dict) of
                            [] -> {undefined, []};
                            [{TS, _} | _] = Buf ->
                                {TS, lists:reverse(Buf)}
                        end,

    Slide#slide{buf1 = Buffer, buf2 = [], total = Total, n = length(Buffer),
                first = FirstTS};
sum(Now, [Slide = #slide{size = Size, interval = Interval} | _] = All) ->
    Start = Now - Size,
    Fun = fun(last, Dict) -> Dict;
             ({TS, Value}, Dict) ->
                  NewTS = map_timestamp(TS, Start, Interval, fun ceil/1),
                  orddict:update(NewTS, fun(V) -> add_to_total(V, Value) end,
                                 Value, Dict)
          end,
    Dict = lists:foldl(fun(S, Acc) ->
                               %% Unwanted last sample here
                               foldl(Start, Fun, Acc, S#slide{total = undefined})
                       end, orddict:new(), All),
    Buffer = lists:reverse(orddict:to_list(Dict)),
    Total = lists:foldl(fun(#slide{total = T}, Acc) ->
                                add_to_total(T, Acc)
                        end, undefined, All),
    First = lists:min([TS || #slide{first = TS} <- All, is_integer(TS)]),
    Slide#slide{buf1 = Buffer, buf2 = [], total = Total, n = length(Buffer),
                first = First}.

take_since([drop | T], Start, N, [{TS, Evt} | _] = Acc, Interval) ->
    case T of
        [] ->
            Fill = [{TS0, Evt}
                    || TS0 <- lists:reverse(lists:seq(TS - Interval, Start, -Interval))],
            Fill ++ Acc;
        [{TS0, _} = E | Rest] when TS0 >= Start, N > 0 ->
            Fill = [{TS1, Evt}
                    || TS1 <- lists:seq(TS0 + Interval, TS - Interval, Interval)],
            take_since(Rest, Start, decr(N), [E | Fill ++ Acc], Interval);
        _ ->
            Fill = [{TS1, Evt}
                    || TS1 <- lists:seq(Start, TS - Interval, Interval)],
            Fill ++ Acc
    end;
take_since([{TS,_} = H|T], Start, N, Acc, Interval) when TS >= Start, N > 0 ->
    take_since(T, Start, decr(N), [H|Acc], Interval);
take_since(_, _, _, Acc, _) ->
    %% Don't reverse; already the wanted order.
    Acc.

decr(N) when is_integer(N) ->
    N-1.

n_diff(A, B) when is_integer(A) ->
    A - B;
n_diff(_, B) ->
    B.

ceil(X) when X < 0 ->
    trunc(X);
ceil(X) ->
    T = trunc(X),
    case X - T == 0 of
        true -> T;
        false -> T + 1
    end.

map_timestamp(TS, Start, Interval, Round) ->
    Factor = Round((TS - Start) / Interval),
    Start + Interval * Factor.

