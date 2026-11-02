:- use_module('./transport').
:- use_module('./stdio_posix').
:- use_module('./jsonrpc').
:- use_module('./server').

:- set_prolog_flag(double_quotes, chars).

main :-
    catch(( run -> true ; log(fatal(failed)), halt(2) ),
          E, ( log(fatal(E)), halt(2) )).

run :-
    open_transport(In, Out),
    server_init(State),
    loop(In, Out, State).

loop(In, Out, State0) :-
    read_message(In, Input),
    step(Input, Out, State0, State, Next),
    (   Next = halt(Code)
    ->  halt(Code)
    ;   loop(In, Out, State)
    ).

step(eof, _, State, State, halt(Code)) :-
    server_eof(State, Code).
step(error(Reason), Out, State, State, continue) :-
    ( Reason == invalid_utf8 ; Reason == unsupported_charset ),
    !,
    perform([reply(error(null, parse_error, "Parse error"))], Out, continue, _).
step(error(Reason), _, State, State, halt(1)) :-
    log(transport_error(Reason)).
step(message(Chars), Out, State0, State, Next) :-
    jsonrpc_parse(Chars, Message),
    server_handle(Message, State0, State, Actions),
    perform(Actions, Out, continue, Next).

perform([], _, Next, Next).
perform([Action|Actions], Out, Next0, Next) :-
    perform_one(Action, Out, Next0, Next1),
    perform(Actions, Out, Next1, Next).

perform_one(reply(Reply), Out, Next, Next) :-
    jsonrpc_serialize(Reply, Chars),
    write_message(Out, Chars).
perform_one(log(Term), _, Next, Next) :-
    log(Term).
perform_one(exit(Code), _, _, halt(Code)).

log(Term) :-
    write(user_error, 'pllsp: '),
    writeq(user_error, Term),
    nl(user_error),
    flush_output(user_error).
