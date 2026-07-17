-module(quest_schema_ffi).
-export([validate/2]).

%% Validates a decoded JSON value against a decoded JSON Schema using jesse.
%% Returns {ok, nil} | {error, Binary} to match Gleam's Result(Nil, String).
validate(Schema, Value) ->
    try jesse:validate_with_schema(Schema, Value) of
        {ok, _} -> {ok, nil};
        {error, Errors} ->
            {error, unicode:characters_to_binary(io_lib:format("~p", [Errors]))}
    catch
        Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~p:~p", [Class, Reason]))}
    end.
