/* ISO Prolog tokenizer that keeps every character of the source.

   lex(+Chars, -Tokens)
     Tokens is a list of tk(Kind, Text, Pre, Offset), ending in one
     tk(eof, [], Pre, Offset). Text is the token's chars, verbatim. Pre is
     the layout before the token: ws(Chars) and cmt(Chars, Kind, Column),
     where Kind is line or block. Offset is the token's character offset.

   Kind is name, qname (quoted), var, num, str ("..."), bq (`...`),
   punct(C) for ( ) [ ] { } , |, end, or bad. A lexical error yields one
   bad token covering the rest of the input, followed by eof.

   Concatenating every Pre and Text reproduces the input exactly. */

:- module(fmt_lex, [lex/2, layout_chars/2, symbol_char/1, alnum_char/1]).

:- use_module(library(lists)).

:- set_prolog_flag(double_quotes, chars).

lex(Cs, Toks) :-
    tokens(Cs, 0, 0, Toks).

tokens(Cs0, Off0, Col0, Toks) :-
    layout(Cs0, Off0, Col0, Pre, Cs, Off, Col, Status),
    (   Status == bad
    ->  bad_rest(Cs, Pre, Off, Toks)
    ;   Cs == []
    ->  Toks = [tk(eof, [], Pre, Off)]
    ;   token(Cs, Kind, Text, Rest)
    ->  Toks = [tk(Kind, Text, Pre, Off)|Toks1],
        length(Text, Len),
        Off1 is Off + Len,
        advance(Text, Col, Col1),
        tokens(Rest, Off1, Col1, Toks1)
    ;   bad_rest(Cs, Pre, Off, Toks)
    ).

bad_rest(Cs, Pre, Off, [tk(bad, Cs, Pre, Off), tk(eof, [], [], End)]) :-
    length(Cs, Len),
    End is Off + Len.

advance([], Col, Col).
advance([C|Cs], Col0, Col) :-
    (   ( C == '\n' ; C == '\r' )
    ->  Col1 = 0
    ;   Col1 is Col0 + 1
    ),
    advance(Cs, Col1, Col).

%% Layout ----------------------------------------------------------------

layout(Cs0, Off0, Col0, Pre, Cs, Off, Col, Status) :-
    (   Cs0 = [C|_], layout_char(C)
    ->  span(Cs0, layout_char, Ws, Cs1),
        length(Ws, N),
        Off1 is Off0 + N,
        advance(Ws, Col0, Col1),
        Pre = [ws(Ws)|Pre1],
        layout(Cs1, Off1, Col1, Pre1, Cs, Off, Col, Status)
    ;   Cs0 = ['%'|_]
    ->  span(Cs0, not_newline, Text, Cs1),
        comment(Text, line, Off0, Col0, Pre, Pre1, Off1, Col1),
        layout(Cs1, Off1, Col1, Pre1, Cs, Off, Col, Status)
    ;   Cs0 = ['/', '*'|Cs2]
    ->  (   block_end(Cs2, Body, Cs1)
        ->  append(['/', '*'|Body], ['*', '/'], Text),
            comment(Text, block, Off0, Col0, Pre, Pre1, Off1, Col1),
            layout(Cs1, Off1, Col1, Pre1, Cs, Off, Col, Status)
        ;   Pre = [], Cs = Cs0, Off = Off0, Col = Col0, Status = bad
        )
    ;   Pre = [], Cs = Cs0, Off = Off0, Col = Col0, Status = ok
    ).

comment(Text, Kind, Off0, Col0, [cmt(Text, Kind, Col0)|Pre], Pre, Off, Col) :-
    length(Text, N),
    Off is Off0 + N,
    advance(Text, Col0, Col).

block_end(['*', '/'|Cs], [], Cs) :- !.
block_end([C|Cs0], [C|Body], Cs) :-
    block_end(Cs0, Body, Cs).

layout_chars([], []).
layout_chars([ws(Cs)|Ls], Out) :-
    layout_chars(Ls, Rest),
    append(Cs, Rest, Out).
layout_chars([cmt(Cs, _, _)|Ls], Out) :-
    layout_chars(Ls, Rest),
    append(Cs, Rest, Out).

layout_char(' ').
layout_char('\t').
layout_char('\n').
layout_char('\r').
layout_char('\f').
layout_char('\v').

not_newline(C) :- C \== '\n', C \== '\r'.

%% Tokens ----------------------------------------------------------------

token(['.'|Cs], end, ['.'], Cs) :-
    end_follows(Cs),
    !.
token([C|Cs0], Kind, [C|Text], Cs) :-
    (   lower_char(C)
    ->  Kind = name, span(Cs0, alnum_char, Text, Cs)
    ;   var_start(C)
    ->  Kind = var, span(Cs0, alnum_char, Text, Cs)
    ;   digit(C)
    ->  Kind = num, number_rest(C, Cs0, Text, Cs)
    ;   C == '\''
    ->  Kind = qname, quoted('\'', Cs0, Text, Cs)
    ;   C == '"'
    ->  Kind = str, quoted('"', Cs0, Text, Cs)
    ;   C == '`'
    ->  Kind = bq, quoted('`', Cs0, Text, Cs)
    ;   symbol_char(C)
    ->  Kind = name, span(Cs0, symbol_char, Text, Cs)
    ;   solo_char(C)
    ->  Kind = name, Text = [], Cs = Cs0
    ;   punct_char(C)
    ->  Kind = punct(C), Text = [], Cs = Cs0
    ).

end_follows([]).
end_follows([C|_]) :- layout_char(C), !.
end_follows(['%'|_]).

number_rest('0', ['\''|Cs0], ['\''|Text], Cs) :-
    char_code_literal(Cs0, Text, Cs),
    !.
number_rest('0', [R, D|Cs0], [R, D|Text], Cs) :-
    radix(R, Digit),
    call(Digit, D),
    !,
    span(Cs0, Digit, Text, Cs).
number_rest(_, Cs0, Text, Cs) :-
    span(Cs0, digit, Int, Cs1),
    (   Cs1 = ['.', D|Cs2], digit(D)
    ->  span(Cs2, digit, Frac, Cs3),
        exponent(Cs3, Exp, Cs),
        append(Int, ['.', D|Frac], Text0),
        append(Text0, Exp, Text)
    ;   Text = Int, Cs = Cs1
    ).

exponent([E|Cs0], [E|Exp], Cs) :-
    ( E == e ; E == 'E' ),
    (   Cs0 = [S, D|Cs1], memberchk(S, "+-"), digit(D)
    ->  span(Cs1, digit, Ds, Cs), Exp = [S, D|Ds]
    ;   Cs0 = [D|Cs1], digit(D)
    ->  span(Cs1, digit, Ds, Cs), Exp = [D|Ds]
    ),
    !.
exponent(Cs, [], Cs).

radix(x, hex_digit).
radix(o, octal_digit).
radix(b, binary_digit).

% 0'c: a quote is written doubled; an escape is a backslash sequence.
char_code_literal(['\'', '\''|Cs], ['\'', '\''], Cs) :- !.
char_code_literal(['\\'|Cs0], ['\\'|Text], Cs) :-
    !,
    escape(Cs0, Text, Cs).
char_code_literal([C|Cs], [C], Cs) :-
    C \== '\n'.

escape([C|Cs0], [C|Text], Cs) :-
    (   C == x
    ->  span(Cs0, hex_digit, Ds, ['\\'|Cs]), append(Ds, ['\\'], Text)
    ;   octal_digit(C)
    ->  span(Cs0, octal_digit, Ds, ['\\'|Cs]), append(Ds, ['\\'], Text)
    ;   Text = [], Cs = Cs0
    ).

% Scans to the closing quote, keeping escapes and doubled quotes intact.
quoted(Q, [C|Cs0], [C|Text], Cs) :-
    (   C == Q
    ->  (   Cs0 = [Q|Cs1]
        ->  Text = [Q|Text1], quoted(Q, Cs1, Text1, Cs)
        ;   Text = [], Cs = Cs0
        )
    ;   C == ('\\')
    ->  % \xHH\ and \NNN\ end in a backslash of their own, which must not
        % be read as escaping the character after it.
        (   escape(Cs0, Esc, Cs1)
        ->  true
        ;   Cs0 = [E|Cs1], Esc = [E]
        ),
        append(Esc, Text1, Text),
        quoted(Q, Cs1, Text1, Cs)
    ;   quoted(Q, Cs0, Text, Cs)
    ).

span([C|Cs0], P, [C|Cs1], Cs) :-
    call(P, C),
    !,
    span(Cs0, P, Cs1, Cs).
span(Cs, _, [], Cs).

%% Character classes -----------------------------------------------------

lower_char(C) :- char_code(C, X), ( X >= 0'a, X =< 0'z ; X > 127 ), !.
upper_char(C) :- char_code(C, X), X >= 0'A, X =< 0'Z.
var_start('_') :- !.
var_start(C) :- upper_char(C).
digit(C) :- char_code(C, X), X >= 0'0, X =< 0'9.
hex_digit(C) :- digit(C), !.
hex_digit(C) :- char_code(C, X), ( X >= 0'a, X =< 0'f ; X >= 0'A, X =< 0'F ), !.
octal_digit(C) :- char_code(C, X), X >= 0'0, X =< 0'7.
binary_digit('0').
binary_digit('1').

alnum_char('_') :- !.
alnum_char(C) :- lower_char(C), !.
alnum_char(C) :- upper_char(C), !.
alnum_char(C) :- digit(C).

symbol_char(C) :- memberchk(C, "+-*/\\^<>=~:.?@#&$").

solo_char('!').
solo_char(';').

punct_char('(').
punct_char(')').
punct_char('[').
punct_char(']').
punct_char('{').
punct_char('}').
punct_char(',').
punct_char('|').
