/* UTF-8 encoding and decoding between byte lists and char lists. */

:- module(utf8, [utf8_decode/2, utf8_encode/2]).

:- set_prolog_flag(double_quotes, chars).

%% utf8_decode(+Bytes, -Chars)
%  Fails on malformed UTF-8 rather than changing JSON strings silently.
utf8_decode([], []).
utf8_decode([B|Bs0], [C|Cs]) :-
    decode_scalar(B, Bs0, Code, Bs),
    char_code(C, Code),
    utf8_decode(Bs, Cs).

decode_scalar(B, Bs, B, Bs) :-
    B >= 0, B < 0x80,
    !.
decode_scalar(B, Bs0, Code, Bs) :-
    lead_byte(B, N, Min, Init),
    continuation(N, Bs0, Init, Code, Bs),
    Code >= Min,
    Code =< 0x10FFFF,
    \+ surrogate(Code),
    !.

lead_byte(B, 1, 0x80, Init) :-
    B >= 0xC2, B =< 0xDF, !,
    Init is B /\ 0x1F.
lead_byte(B, 2, 0x800, Init) :-
    B >= 0xE0, B =< 0xEF, !,
    Init is B /\ 0x0F.
lead_byte(B, 3, 0x10000, Init) :-
    B >= 0xF0, B =< 0xF4,
    Init is B /\ 0x07.

continuation(0, Bs, Code, Code, Bs) :-
    !.
continuation(N, [B|Bs0], Code0, Code, Bs) :-
    B >= 0x80, B =< 0xBF,
    Code1 is (Code0 << 6) \/ (B /\ 0x3F),
    N1 is N - 1,
    continuation(N1, Bs0, Code1, Code, Bs).

surrogate(Code) :-
    Code >= 0xD800,
    Code =< 0xDFFF.

%% utf8_encode(+Chars, -Bytes)
utf8_encode(Cs, Bs) :-
    encode_chars(Cs, Bs, []).

encode_chars([], Bs, Bs).
encode_chars([C|Cs], Bs0, Bs) :-
    char_code(C, Code),
    Code >= 0, Code =< 0x10FFFF,
    \+ surrogate(Code),
    encode_scalar(Code, Bs0, Bs1),
    encode_chars(Cs, Bs1, Bs).

encode_scalar(X, [X|Bs], Bs) :-
    X < 0x80,
    !.
encode_scalar(X, [B1, B2|Bs], Bs) :-
    X < 0x800,
    !,
    B1 is 0xC0 \/ (X >> 6),
    B2 is 0x80 \/ (X /\ 0x3F).
encode_scalar(X, [B1, B2, B3|Bs], Bs) :-
    X < 0x10000,
    !,
    B1 is 0xE0 \/ (X >> 12),
    B2 is 0x80 \/ ((X >> 6) /\ 0x3F),
    B3 is 0x80 \/ (X /\ 0x3F).
encode_scalar(X, [B1, B2, B3, B4|Bs], Bs) :-
    B1 is 0xF0 \/ (X >> 18),
    B2 is 0x80 \/ ((X >> 12) /\ 0x3F),
    B3 is 0x80 \/ ((X >> 6) /\ 0x3F),
    B4 is 0x80 \/ (X /\ 0x3F).
