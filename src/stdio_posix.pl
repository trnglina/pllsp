/* POSIX standard streams. Keep platform paths out of protocol code. */
:- module(stdio_posix, [open_transport/2]).

open_transport(In, Out) :-
    open('/dev/stdin', read, In, [type(binary)]),
    open('/dev/stdout', write, Out, [type(binary)]).
