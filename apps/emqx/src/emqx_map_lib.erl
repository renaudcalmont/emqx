%%--------------------------------------------------------------------
%% Copyright (c) 2020-2022 EMQ Technologies Co., Ltd. All Rights Reserved.
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%--------------------------------------------------------------------
-module(emqx_map_lib).

-export([ deep_get/2
        , deep_get/3
        , deep_find/2
        , deep_put/3
        , deep_remove/2
        , deep_merge/2
        , safe_atom_key_map/1
        , unsafe_atom_key_map/1
        , jsonable_map/1
        , jsonable_map/2
        , binary_string/1
        , deep_convert/3
        , diff_maps/2
        ]).

-export_type([config_key/0, config_key_path/0]).
-type config_key() :: atom() | binary() | [byte()].
-type config_key_path() :: [config_key()].
-type convert_fun() :: fun((...) -> {K1::any(), V1::any()} | drop).

%%-----------------------------------------------------------------
-spec deep_get(config_key_path(), map()) -> term().
deep_get(ConfKeyPath, Map) ->
    Ref = make_ref(),
    Res = deep_get(ConfKeyPath, Map, Ref),
    case Res =:= Ref of
        true -> error({config_not_found, ConfKeyPath});
        false -> Res
    end.

-spec deep_get(config_key_path(), map(), term()) -> term().
deep_get(ConfKeyPath, Map, Default) ->
    case deep_find(ConfKeyPath, Map) of
        {not_found, _KeyPath, _Data} -> Default;
        {ok, Data} -> Data
    end.

-spec deep_find(config_key_path(), map()) ->
    {ok, term()} | {not_found, config_key_path(), term()}.
deep_find([], Map) ->
    {ok, Map};
deep_find([Key | KeyPath] = Path, Map) when is_map(Map) ->
    case maps:find(Key, Map) of
        {ok, SubMap} -> deep_find(KeyPath, SubMap);
        error -> {not_found, Path, Map}
    end;
deep_find(_KeyPath, Data) ->
    {not_found, _KeyPath, Data}.

-spec deep_put(config_key_path(), map(), term()) -> map().
deep_put([], _Map, Data) ->
    Data;
deep_put([Key | KeyPath], Map, Data) ->
    SubMap = maps:get(Key, Map, #{}),
    Map#{Key => deep_put(KeyPath, SubMap, Data)}.

-spec deep_remove(config_key_path(), map()) -> map().
deep_remove([], Map) ->
    Map;
deep_remove([Key], Map) ->
    maps:remove(Key, Map);
deep_remove([Key | KeyPath], Map) ->
    case maps:find(Key, Map) of
        {ok, SubMap} when is_map(SubMap) ->
            Map#{Key => deep_remove(KeyPath, SubMap)};
        {ok, _Val} -> Map;
        error -> Map
    end.

%% #{a => #{b => 3, c => 2}, d => 4}
%%  = deep_merge(#{a => #{b => 1, c => 2}, d => 4}, #{a => #{b => 3}}).
-spec deep_merge(map(), map()) -> map().
deep_merge(BaseMap, NewMap) ->
    NewKeys = maps:keys(NewMap) -- maps:keys(BaseMap),
    MergedBase = maps:fold(fun(K, V, Acc) ->
            case maps:find(K, NewMap) of
                error ->
                    Acc#{K => V};
                {ok, NewV} when is_map(V), is_map(NewV) ->
                    Acc#{K => deep_merge(V, NewV)};
                {ok, NewV} ->
                    Acc#{K => NewV}
            end
        end, #{}, BaseMap),
    maps:merge(MergedBase, maps:with(NewKeys, NewMap)).

-spec deep_convert(map(), convert_fun(), Args::list()) -> map().
deep_convert(Map, ConvFun, Args) when is_map(Map) ->
    maps:fold(fun(K, V, Acc) ->
            case apply(ConvFun, [K, deep_convert(V, ConvFun, Args) | Args]) of
                drop -> Acc;
                {K1, V1} -> Acc#{K1 => V1}
            end
        end, #{}, Map);
deep_convert(ListV, ConvFun, Args) when is_list(ListV) ->
    [deep_convert(V, ConvFun, Args) || V <- ListV];
deep_convert(Val, _, _Args) -> Val.

-spec unsafe_atom_key_map(#{binary() | atom() => any()}) -> #{atom() => any()}.
unsafe_atom_key_map(Map) ->
    covert_keys_to_atom(Map, fun(K) -> binary_to_atom(K, utf8) end).

-spec safe_atom_key_map(#{binary() | atom() => any()}) -> #{atom() => any()}.
safe_atom_key_map(Map) ->
    covert_keys_to_atom(Map, fun(K) -> binary_to_existing_atom(K, utf8) end).

-spec jsonable_map(map() | list()) -> map() | list().
jsonable_map(Map) ->
    jsonable_map(Map, fun(K, V) -> {K, V} end).

jsonable_map(Map, JsonableFun) ->
    deep_convert(Map, fun binary_string_kv/3, [JsonableFun]).

-spec diff_maps(map(), map()) ->
    #{added := map(), identical := map(), removed := map(),
      changed := #{any() => {OldValue::any(), NewValue::any()}}}.
diff_maps(NewMap, OldMap) ->
    InitR = #{identical => #{}, changed => #{}, removed => #{}},
    {Result, RemInNew} =
        lists:foldl(fun({OldK, OldV}, {Result0 = #{identical := I, changed := U, removed := D},
                        RemNewMap}) ->
            Result1 = case maps:find(OldK, NewMap) of
                error ->
                    Result0#{removed => D#{OldK => OldV}};
                {ok, NewV} when NewV == OldV ->
                    Result0#{identical => I#{OldK => OldV}};
                {ok, NewV} ->
                    Result0#{changed => U#{OldK => {OldV, NewV}}}
            end,
            {Result1, maps:remove(OldK, RemNewMap)}
        end, {InitR, NewMap}, maps:to_list(OldMap)),
    Result#{added => RemInNew}.


binary_string_kv(K, V, JsonableFun) ->
    case JsonableFun(K, V) of
        drop -> drop;
        {K1, V1} -> {binary_string(K1), V1}
    end.

binary_string([]) -> [];
binary_string(Val) when is_list(Val) ->
    case io_lib:printable_unicode_list(Val) of
        true -> unicode:characters_to_binary(Val);
        false -> [binary_string(V) || V <- Val]
    end;
binary_string(Val) ->
    Val.

%%---------------------------------------------------------------------------
covert_keys_to_atom(BinKeyMap, Conv) ->
    deep_convert(BinKeyMap, fun
            (K, V) when is_atom(K) -> {K, V};
            (K, V) when is_binary(K) -> {Conv(K), V}
        end, []).
