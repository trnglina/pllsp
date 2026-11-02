/* LSP base protocol: Content-Length framed messages over binary streams.

   Streams are binary because Scryer's user_input cannot carry LSP traffic
   (see docs/DESIGN-NOTES.md), and because Content-Length counts bytes. */

:- module(transport, [read_message/2, write_message/2]).

:- use_module(library(lists)).
:- use_module('./utf8').

:- set_prolog_flag(double_quotes, chars).

%% read_message(+In, -Result)
%  Framing errors are fatal: the next frame boundary is no longer known.
read_message(In, Result) :-
    read_headers(In, Headers),
    (   Headers == eof
    ->  Result = eof
    ;   Headers = error(Reason)
    ->  Result = error(Reason)
    ;   content_length(Headers, N)
    ->  read_bytes(In, N, Bytes, Status),
        (   Status == eof
        ->  Result = error(truncated_body)
        ;   \+ supported_charset(Headers)
        ->  Result = error(unsupported_charset)
        ;   utf8_decode(Bytes, Chars)
        ->  Result = message(Chars)
        ;   Result = error(invalid_utf8)
        )
    ;   Result = error(invalid_content_length)
    ).

%% write_message(+Out, +Chars)
write_message(Out, Chars) :-
    utf8_encode(Chars, Body),
    length(Body, N),
    number_codes(N, NCodes),
    atom_codes('Content-Length: ', Prefix),
    append(Prefix, NCodes, Header0),
    append(Header0, [13, 10, 13, 10], Header),
    put_bytes(Header, Out),
    put_bytes(Body, Out),
    flush_output(Out).

put_bytes([], _).
put_bytes([B|Bs], Out) :-
    put_byte(Out, B),
    put_bytes(Bs, Out).

%% Headers ----------------------------------------------------------------

% Headers is eof or a list of LowercaseNameCodes-ValueCodes.
read_headers(In, Headers) :-
    read_line(In, Line),
    (   Line == eof
    ->  Headers = eof
    ;   Line = error(Reason)
    ->  Headers = error(Reason)
    ;   Line == []
    ->  Headers = []
    ;   read_headers(In, Rest),
        (   Rest == eof
        ->  Headers = error(truncated_headers)
        ;   Rest = error(Reason)
        ->  Headers = error(Reason)
        ;   parse_header(Line, Header)
        ->  Headers = [Header|Rest]
        ;   Headers = error(invalid_header)
        )
    ).

parse_header(Line, Name-Value) :-
    append(Name0, [0':|Value0], Line),
    !,
    ascii_lower(Name0, Name1),
    trim(Name1, Name),
    trim(Value0, Value).

content_length(Headers, N) :-
    atom_codes('content-length', Key),
    findall(Value, member(Key-Value, Headers), [Value]),
    Value = [_|_],
    all_digits(Value),
    number_codes(N, Value).

supported_charset(Headers) :-
    atom_codes('content-type', Key),
    findall(Value, member(Key-Value, Headers), Values),
    (   Values = []
    ->  true
    ;   Values = [Value],
        ascii_lower(Value, Lower),
        content_type_parts(Lower)
    ).

content_type_parts(Codes) :-
    (   append(_, [0';|Rest], Codes)
    ->  content_type_parameters(Rest)
    ;   true
    ).

content_type_parameters(Codes) :-
    (   append(Part, [0';|Rest], Codes)
    ->  charset_parameter(Part), content_type_parameters(Rest)
    ;   charset_parameter(Codes)
    ).

charset_parameter(Codes) :-
    (   append(Name0, [0'=|Value0], Codes),
        trim(Name0, Name), atom_codes(charset, Name)
    ->  trim(Value0, Value1),
        ( append([0'"|Value], [0'"], Value1) -> true ; Value = Value1 ),
        atom_codes(Charset, Value),
        ( Charset == 'utf-8' ; Charset == utf8 )
    ;   true
    ).

% Reads one line of bytes, terminated by LF; a trailing CR is dropped.
read_line(In, Line) :-
    get_byte(In, B),
    read_line_(B, In, Bytes, Status),
    (   Status == eof
    ->  ( Bytes == [] -> Line = eof ; Line = error(truncated_headers) )
    ;   strip_cr(Bytes, Line)
    ).

read_line_(-1, _, [], eof) :- !.
read_line_(10, _, [], ok) :- !.
read_line_(B, In, [B|Bs], Status) :-
    get_byte(In, B1),
    read_line_(B1, In, Bs, Status).

strip_cr(Bs0, Bs) :-
    (   append(Bs, [13], Bs0)
    ->  true
    ;   Bs = Bs0
    ).

%% read_bytes(+In, +N, -Bytes, -Status)
read_bytes(In, N, Bytes, Status) :-
    (   N =:= 0
    ->  Bytes = [],
        Status = ok
    ;   get_byte(In, B),
        (   B =:= -1
        ->  Bytes = [],
            Status = eof
        ;   Bytes = [B|Bytes1],
            N1 is N - 1,
            read_bytes(In, N1, Bytes1, Status)
        )
    ).

%% Code-list helpers ------------------------------------------------------

ascii_lower([], []).
ascii_lower([C|Cs], [L|Ls]) :-
    (   C >= 0'A, C =< 0'Z
    ->  L is C + 32
    ;   L = C
    ),
    ascii_lower(Cs, Ls).

trim(Cs0, Cs) :-
    drop_blanks(Cs0, Cs1),
    reverse(Cs1, Rs0),
    drop_blanks(Rs0, Rs),
    reverse(Rs, Cs).

drop_blanks([C|Cs0], Cs) :-
    blank(C),
    !,
    drop_blanks(Cs0, Cs).
drop_blanks(Cs, Cs).

blank(0' ).
blank(0'\t).

all_digits([]).
all_digits([C|Cs]) :-
    C >= 0'0, C =< 0'9,
    all_digits(Cs).
