/* JSON-RPC 2.0: conversion between JSON text and message/reply terms.

   Incoming messages:
     request(Id, Method, Params)   Id is the raw JSON id term
     notification(Method, Params)  Method is an atom; Params is JSON or null
     response(Id)                  reply to a server->client request
     invalid(Id)                   Id is null when unknown
     parse_error

   Replies:
     result(Id, Json)
     error(Id, CodeName, MessageChars)   CodeName is a key of error_code/2 */

:- module(jsonrpc, [jsonrpc_parse/2, jsonrpc_serialize/2, error_code/2]).

:- use_module(library(dcgs)).
:- use_module(library(lists)).
:- use_module('./json').

:- set_prolog_flag(double_quotes, chars).

%% jsonrpc_parse(+Chars, -Message)
jsonrpc_parse(Chars, Message) :-
    (   catch(once(phrase(json_chars(Json), Chars)), _, fail)
    ->  classify(Json, Message)
    ;   Message = parse_error
    ).

classify(pairs(Members), Message) :-
    !,
    (   memberchk(string("jsonrpc")-string("2.0"), Members)
    ->  classify_object(Members, Message)
    ;   message_id(Members, Id),
        Message = invalid(Id)
    ).
classify(_, invalid(null)).

message_id(Members, Id) :-
    (   memberchk(string("id")-Id0, Members), valid_id(Id0)
    ->  Id = Id0
    ;   Id = null
    ).

classify_object(Members, Message) :-
    (   memberchk(string("method")-MethodJson, Members)
    ->  classify_call(MethodJson, Members, Message)
    ;   memberchk(string("id")-Id, Members),
        ( valid_id(Id) ; Id == null ),
        (   memberchk(string("result")-_, Members),
            \+ memberchk(string("error")-_, Members)
        ;   memberchk(string("error")-pairs(Error), Members),
            memberchk(string("code")-number(Code), Error), integer(Code),
            memberchk(string("message")-string(_), Error),
            \+ memberchk(string("result")-_, Members)
        )
    ->  Message = response(Id)
    ;   Message = invalid(null)
    ).

classify_call(string(MethodChars), Members, Message) :-
    !,
    atom_chars(Method, MethodChars),
    (   memberchk(string("params")-Params, Members)
    ->  true
    ;   Params = null
    ),
    (   \+ valid_params(Params)
    ->  message_id(Members, Id), Message = invalid(Id)
    ;   memberchk(string("id")-Id, Members)
    ->  (   valid_id(Id)
        ->  Message = request(Id, Method, Params)
        ;   Message = invalid(null)
        )
    ;   Message = notification(Method, Params)
    ).
classify_call(_, Members, invalid(Id)) :-
    (   memberchk(string("id")-Id, Members),
        valid_id(Id)
    ->  true
    ;   Id = null
    ).

% LSP request IDs are integers or strings (unlike general JSON-RPC).
valid_id(number(N)) :- integer(N), N >= -2147483648, N =< 2147483647.
valid_id(string(_)).

valid_params(pairs(_)).
valid_params(list(_)).
valid_params(null).

%% jsonrpc_serialize(+Reply, -Chars)
jsonrpc_serialize(Reply, Chars) :-
    reply_json(Reply, Json),
    once(phrase(json_chars(Json), Chars)).

reply_json(result(Id, Result),
           pairs([ string("jsonrpc")-string("2.0"),
                   string("id")-Id,
                   string("result")-Result
                 ])).
reply_json(error(Id, Name, Message),
           pairs([ string("jsonrpc")-string("2.0"),
                   string("id")-Id,
                   string("error")-pairs([ string("code")-number(Code),
                                           string("message")-string(Message)
                                         ])
                 ])) :-
    error_code(Name, Code).

%% error_code(?Name, ?Code)
error_code(parse_error,            -32700).
error_code(invalid_request,        -32600).
error_code(method_not_found,       -32601).
error_code(invalid_params,         -32602).
error_code(internal_error,         -32603).
error_code(server_not_initialized, -32002).
error_code(unknown_error_code,     -32001).
error_code(request_failed,         -32803).
error_code(server_cancelled,       -32802).
error_code(content_modified,       -32801).
error_code(request_cancelled,      -32800).
