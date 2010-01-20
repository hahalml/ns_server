%% @author Northscale <info@northscale.com>
%% @copyright 2009 NorthScale, Inc.
%% All rights reserved.

%% @doc Web server for menelaus.

-module(menelaus_stats).
-author('NorthScale <info@northscale.com>').

-include_lib("eunit/include/eunit.hrl").

-ifdef(EUNIT).
-export([test/0]).
-import(menelaus_util,
        [test_under_debugger/0, debugger_apply/2,
         wrap_tests_with_cache_setup/1]).
-endif.

-export([handle_bucket_stats/3, basic_stats/2]).

-import(menelaus_util,
        [reply_json/2,
         expect_prop_value/2,
         java_date/0,
         string_hash/1,
         my_seed/1,
         stateful_map/3,
         stateful_takewhile/3,
         low_pass_filter/2,
         caching_result/2]).

%% External API

basic_stats(PoolId, BucketId) ->
    Pool = menelaus_web:find_pool_by_id(PoolId),
    Bucket = menelaus_web:find_bucket_by_id(Pool, BucketId),
    MbPerNode = expect_prop_value(size_per_node, Bucket),
    NumNodes = length(ns_node_disco:nodes_wanted()),
    % TODO.
    [{cacheSize, NumNodes * MbPerNode},
     {opsPerSec, 100},
     {evictionsPerSec, 5},
     {cachePercentUsed, 50}].

% GET /pools/default/stats?stat=opsbysecond
% GET /pools/default/stats?stat=hot_keys

handle_bucket_stats(PoolId, all, Req) ->
    % TODO: get aggregate stats for all buckets.
    handle_bucket_stats(PoolId, "default", Req);

handle_bucket_stats(PoolId, Id, Req) ->
    Params = Req:parse_qs(),
    case proplists:get_value("stat", Params) of
        "opsbysecond" ->
            handle_bucket_stats_ops(Req, PoolId, Id, Params);
        "hot_keys" ->
            handle_bucket_stats_hks(Req, PoolId, Id, Params);
        _ ->
            Req:respond({400, [], []})
    end.

handle_bucket_stats_ops(Req, PoolId, BucketId, Params) ->
    Res = build_bucket_stats_ops_response(PoolId, BucketId, Params),
    reply_json(Req, Res).

handle_bucket_stats_hks(Req, PoolId, BucketId, Params) ->
    Res = build_bucket_stats_hks_response(PoolId, BucketId, Params),
    reply_json(Req, Res).

%% ops SUM(cmd_get, cmd_set,
%%         incr_misses, incr_hits,
%%         decr_misses, decr_hits,
%%         cas_misses, cas_hits, cas_badval,
%%         delete_misses, delete_hits,
%%         cmd_flush)
%% cmd_get (cmd_get)
%% get_misses (get_misses)
%% get_hits (get_hits)
%% cmd_set (cmd_set)
%% evictions (evictions)
%% replacements (if available in time)
%% misses SUM(get_misses, delete_misses, incr_misses, decr_misses,
%%            cas_misses)
%% updates SUM(cmd_set, incr_hits, decr_hits, cas_hits)
%% bytes_read (bytes_read)
%% bytes_written (bytes_written)
%% hit_ratio (get_hits / cmd_get)
%% curr_items (curr_items)

%% Implementation

% get_stats() returns something like, where lists are sorted
% with most-recent last.
%
% [{"total_items",[0,0,0,0,0]},
%  {"curr_items",[0,0,0,0,0]},
%  {"bytes_read",[2208,2232,2256,2280,2304]},
%  {"cas_misses",[0,0,0,0,0]},
%  {t, [{1263,946873,864055},
%       {1263,946874,864059},
%       {1263,946875,864050},
%       {1263,946876,864053},
%       {1263,946877,864065}]},
%  ...]

get_stats_raw(_PoolId, BucketId, SamplesNum) ->
    dict:to_list(stats_aggregator:get_stats(BucketId, SamplesNum)).

get_stats(PoolId, BucketId, _Params) ->
    SamplesInterval = 1, % A sample every second.
    SamplesNum = 60, % Sixty seconds worth of data.
    Samples = get_stats_raw(PoolId, BucketId, SamplesNum),
    Samples2 = case lists:keytake(t, 1, Samples) of
                   false -> [{t, []} | Samples];
                   {value, {t, TStamps}, SamplesNoTStamps} ->
                       [{t, lists:map(fun misc:time_to_epoch_int/1,
                                      TStamps)} |
                        SamplesNoTStamps]
               end,
    LastSampleTStamp = case Samples2 of
                           [{t, []} | _]       -> 0;
                           [{t, TStamps2} | _] -> lists:last(TStamps2);
                           _                   -> 0
                       end,
    {ok, SamplesInterval, LastSampleTStamp, Samples2}.

build_bucket_stats_ops_response(PoolId, BucketId, Params) ->
    {ok, SamplesInterval, LastSampleTStamp, Samples2} =
        get_stats(PoolId, BucketId, Params),
    {struct, [{op, {struct, [{tstamp, LastSampleTStamp},
                             {samplesInterval, SamplesInterval}
                             | Samples2]}}]}.

build_bucket_stats_hks_response(_PoolId, _BucketId, _Params) ->
    {struct, [{hot_keys, [{struct, [{name, <<"product:324:inventory">>},
                                    {gets, 10000},
                                    {bucket, <<"shopping application">>},
                                    {misses, 100}]},
                          {struct, [{name, <<"user:image:value2">>},
                                    {gets, 10000},
                                    {bucket, <<"chat application">>},
                                    {misses, 100}]},
                          {struct, [{name, <<"blog:117">>},
                                    {gets, 10000},
                                    {bucket, <<"blog application">>},
                                    {misses, 100}]},
                          {struct, [{name, <<"user:image:value4">>},
                                    {gets, 10000},
                                    {bucket, <<"chat application">>},
                                    {misses, 100}]}]}]}.

-ifdef(EUNIT).

test() ->
    eunit:test(wrap_tests_with_cache_setup({module, ?MODULE}),
               [verbose]).

-endif.

