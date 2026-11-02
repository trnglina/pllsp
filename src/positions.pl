/* Conversion between character offsets and LSP positions.

   A position is position(Line, Character), both zero-based. Character
   counts code units of the negotiated encoding: utf16 (the LSP default) or
   utf32, where one unit is one Unicode scalar value. They differ for
   characters outside the Basic Multilingual Plane. */

:- module(positions, [offsets_positions/4, position_offset/4]).

:- set_prolog_flag(double_quotes, chars).

%% offsets_positions(+Chars, +Offsets, +Encoding, -Positions)
%  Offsets must be in non-decreasing order; one pass over the text.
offsets_positions(Chars, Offsets, Enc, Positions) :-
    walk(Offsets, Chars, 0, 0, 0, Enc, Positions).

walk([], _, _, _, _, _, []).
walk([O|Os], Cs, I, Line, Col, Enc, Ps) :-
    (   I >= O
    ->  Ps = [position(Line, Col)|Ps1],
        walk(Os, Cs, I, Line, Col, Enc, Ps1)
    ;   line_break(Cs, Cs1, Width)
    ->  I1 is I + Width,
        (   O < I1
        ->  % No LSP position exists between CR and LF.
            Ps = [position(Line, Col)|Ps1],
            walk(Os, Cs, I, Line, Col, Enc, Ps1)
        ;   Line1 is Line + 1,
            walk([O|Os], Cs1, I1, Line1, 0, Enc, Ps)
        )
    ;   Cs = [C|Cs1]
    ->  I1 is I + 1,
        units(C, Enc, U),
        Col1 is Col + U,
        walk([O|Os], Cs1, I1, Line, Col1, Enc, Ps)
    ;   % Past the end of the text: clamp.
        Ps = [position(Line, Col)|Ps1],
        walk(Os, Cs, I, Line, Col, Enc, Ps1)
    ).

%% position_offset(+Chars, +Position, +Encoding, -Offset)
%  A character past the end of its line clamps to the line end; a line past
%  the end of the text clamps to the end.
position_offset(Chars, position(Line, Char), Enc, Offset) :-
    skip_lines(Line, Chars, 0, Cs, I),
    skip_units(Char, Cs, I, Enc, Offset).

skip_lines(0, Cs, I, Cs, I) :- !.
skip_lines(N, Cs0, I0, Cs, I) :-
    (   line_break(Cs0, Cs1, Width)
    ->  I1 is I0 + Width,
        N1 is N - 1,
        skip_lines(N1, Cs1, I1, Cs, I)
    ;   Cs0 = [_|Cs1]
    ->  I1 is I0 + 1,
        skip_lines(N, Cs1, I1, Cs, I)
    ;   Cs = [], I = I0
    ).

skip_units(N, Cs, I0, Enc, I) :-
    (   N =< 0
    ->  I = I0
    ;   Cs = [C|Cs1], C \== '\n', C \== '\r'
    ->  units(C, Enc, U),
        N1 is N - U,
        I1 is I0 + 1,
        skip_units(N1, Cs1, I1, Enc, I)
    ;   I = I0
    ).

% LSP recognises CRLF, LF and CR as line endings.
line_break(['\r', '\n'|Cs], Cs, 2) :- !.
line_break(['\r'|Cs], Cs, 1).
line_break(['\n'|Cs], Cs, 1).

units(C, utf16, U) :-
    char_code(C, X),
    ( X > 0xFFFF -> U = 2 ; U = 1 ).
units(_, utf32, 1).
