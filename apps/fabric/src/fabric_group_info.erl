% Copyright 2010 Cloudant
% 
% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.

-module(fabric_group_info).

-export([go/2]).

-include("fabric.hrl").
-include_lib("mem3/include/mem3.hrl").
-include_lib("couch/include/couch_db.hrl").

go(DbName, GroupId) when is_binary(GroupId) ->
    {ok, DDoc} = fabric:open_doc(DbName, GroupId, []),
    go(DbName, DDoc);

go(DbName, #doc{} = DDoc) ->
    Group = couch_view_group:design_doc_to_view_group(DDoc),
    Shards = mem3:shards(DbName),
    Workers = fabric_util:submit_jobs(Shards, group_info, [Group]),
    Acc0 = {fabric_dict:init(Workers, nil), []},
    fabric_util:recv(Workers, #shard.ref, fun handle_message/3, Acc0).

handle_message({ok, Info}, Shard, {Counters, Acc}) ->
    case fabric_dict:lookup_element(Shard, Counters) of
    undefined ->
        % already heard from someone else in this range
        {ok, {Counters, Acc}};
    nil ->
        C1 = fabric_dict:store(Shard, ok, Counters),
        C2 = fabric_view:remove_overlapping_shards(Shard, C1),
        case fabric_dict:any(nil, C2) of
        true ->
            {ok, {C2, [Info|Acc]}};
        false ->
            {stop, merge_results(lists:flatten([Info|Acc]))}
        end
    end;
handle_message(_, _, Acc) ->
    {ok, Acc}.

merge_results(Info) ->
    Dict = lists:foldl(fun({K,V},D0) -> orddict:append(K,V,D0) end,
        orddict:new(), Info),
    orddict:fold(fun
        (signature, [X|_], Acc) ->
            [{signature, X} | Acc];
        (language, [X|_], Acc) ->
            [{language, X} | Acc];
        (disk_size, X, Acc) ->
            [{disk_size, lists:sum(X)} | Acc];
        (compact_running, X, Acc) ->
            [{compact_running, lists:member(true, X)} | Acc];
        (_, _, Acc) ->
            Acc
    end, [], Dict).
