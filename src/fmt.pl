/* Whitespace-respecting formatter, ported from swiplfmt to ISO Prolog.

   Tokens are copied verbatim and only the layout between them is
   rewritten, so 0'c, 0x1F, 'quoted' and [a|[b]] survive as written. Each
   run re-reads its own output and returns the input unchanged unless the
   tokens, the parse, and the comments all survived, and formatting the
   output again changes nothing.

   format_text(+Chars, +Options, -Formatted, -Report)
     Report is ok, unchanged or unsafe(Reason); when unsafe, Formatted is
     the input.
   format_edits(+Chars, +Options, -Edits, -Report)
     Edits are edit(From, To, NewChars) over character offsets, in order
     and non-overlapping; each replaces the layout between two tokens.
   format_range(+Chars, +From, +To, +Options, -Edits, -Report)
     Only the edits inside clauses touched by the half-open range From..To.
     An empty range selects the clause at the cursor, including leading layout.

   Options: indent(N), blank_lines_max(N), align_width(N),
   list_spacing(S), curly_spacing(S) where S is preserve, 0 or 1,
   final_newline(Bool) and strip_leading_blanks(Bool). */

:- module(fmt, [format_text/4, format_edits/4, format_range/6]).

:- use_module(library(lists)).
:- use_module('./fmt_lex').
:- use_module('./fmt_parse').
:- use_module('./fmt_cst').
:- use_module('./fmt_render').

:- set_prolog_flag(double_quotes, chars).

format_text(Chars, Opts, Out, Report) :-
    format_checked(Chars, Opts, Out, Report, _, _).

format_edits(Chars, Opts, Edits, Report) :-
    format_checked(Chars, Opts, _, Report, InToks, OutToks),
    (   Report == ok
    ->  token_edits(InToks, OutToks, Edits)
    ;   Edits = []
    ).

format_range(Chars, From, To, Opts, Edits, Report) :-
    format_checked(Chars, Opts, _, Report, InToks, OutToks),
    (   Report == ok,
        clause_bounds(InToks, From, To, Lo, Hi)
    ->  token_edits(InToks, OutToks, All),
        owned_edits(All, Lo, Hi, Edits)
    ;   Edits = []
    ).

format_checked(Chars, Opts, Out, Report, InToks, OutToks) :-
    catch(checked(Chars, Opts, Out0, Report0, InToks, OutToks), E,
          ( Out0 = Chars, Report0 = unsafe(format_error(E)) )),
    !,
    Out = Out0,
    Report = Report0.
format_checked(Chars, _, Chars, unsafe(format_failed), [], []).

checked(Chars, Opts, Out, Report, InToks, OutToks) :-
    one_pass(Chars, Opts, InToks, InItems, Pass1),
    (   Pass1 == Chars
    ->  Out = Chars, Report = unchanged, OutToks = InToks
    ;   one_pass(Pass1, Opts, OutToks, OutItems, Pass2),
        signature(InToks, InItems, SigA),
        signature(OutToks, OutItems, SigB),
        (   difference(SigA, SigB, Reason)
        ->  Out = Chars, Report = unsafe(Reason)
        ;   Pass2 \== Pass1
        ->  Out = Chars, Report = unsafe(not_idempotent)
        ;   Out = Pass1, Report = ok
        )
    ).

one_pass(Chars, Opts, Toks, Items, Out) :-
    lex(Chars, Toks),
    parse_items(Toks, Items),
    items_pieces(Items, Pieces),
    render_pieces(Pieces, Opts, Out).

%% Verification ----------------------------------------------------------

% Everything formatting must preserve: the token texts (which catches
% 0'c -> 99 and [a|[b]] -> [a,b] as well as merged tokens), the parse
% (which catches - (1) -> -(1)), and the comments.
signature(Toks, Items, sig(Texts, Shapes, Comments)) :-
    token_texts(Toks, Texts),
    shapes(Items, Shapes),
    comments(Toks, Comments).

difference(sig(T1, _, _), sig(T2, _, _), tokens_differ) :- T1 \== T2, !.
difference(sig(_, S1, _), sig(_, S2, _), parse_differs) :- S1 \== S2, !.
difference(sig(_, _, C1), sig(_, _, C2), comments_differ) :- C1 \== C2.

token_texts([], []).
token_texts([tk(_, Text, _, _)|Ts], [Text|Xs]) :-
    token_texts(Ts, Xs).

shapes([], []).
shapes([I|Is], [S|Ss]) :-
    shape(I, S),
    shapes(Is, Ss).

% A node with its layout stripped out.
shape(X, X) :-
    atomic(X),
    !.
shape(tk(K, T, _, _), tk(K, T)) :-
    !.
shape([X|Xs], [S|Ss]) :-
    !,
    shape(X, S),
    shape(Xs, Ss).
shape(X, S) :-
    X =.. [F|Args0],
    (   node_functor(F)
    ->  Args0 = [_|Args]
    ;   Args = Args0
    ),
    shape(Args, Shapes),
    S =.. [F|Shapes].

node_functor(leaf).
node_functor(neg).
node_functor(comp).
node_functor(prefix).
node_functor(infix).
node_functor(postfix).
node_functor(paren).
node_functor(curly).
node_functor(list).

% Trailing whitespace inside a comment is layout, and the renderer strips it.
comments([], []).
comments([tk(_, _, Pre, _)|Ts], Cs) :-
    pre_comments(Pre, Cs, Cs1),
    comments(Ts, Cs1).

pre_comments([], Cs, Cs).
pre_comments([ws(_)|Ls], Cs0, Cs) :-
    pre_comments(Ls, Cs0, Cs).
pre_comments([cmt(Text, _, _)|Ls], [Norm|Cs0], Cs) :-
    strip_line_ends(Text, Norm),
    pre_comments(Ls, Cs0, Cs).

strip_line_ends(Cs, Out) :-
    strip_(Cs, [], Out).

strip_([], _, []).
strip_([C|Cs], Pending, Out) :-
    (   ( C == ' ' ; C == '\t' ; C == '\r' )
    ->  strip_(Cs, [C|Pending], Out)
    ;   C == '\n'
    ->  Out = [C|Rest],
        strip_(Cs, [], Rest)
    ;   reverse(Pending, Flush),
        append(Flush, [C|Rest], Out),
        strip_(Cs, [], Rest)
    ).

%% Edits -----------------------------------------------------------------

% Tokens are identical on both sides, so the edits are the gaps whose
% layout differs: no diff is needed.
token_edits([], [], []).
token_edits([tk(_, _, InPre, Off)|Is], [tk(_, _, OutPre, _)|Os], Edits) :-
    layout_chars(InPre, In),
    layout_chars(OutPre, Out),
    (   In == Out
    ->  Edits = Edits1
    ;   length(In, N),
        From is Off - N,
        Edits = [edit(From, Off, Out)|Edits1]
    ),
    token_edits(Is, Os, Edits1).

% Whole clauses are reformatted, never part of one. The gap in front of a
% clause belongs to what precedes it, so only gaps starting inside the
% selected clauses' tokens are taken.
owned_edits([], _, _, []).
owned_edits([E|Es], Lo, Hi, Out) :-
    E = edit(F, _, _),
    (   F >= Lo, F =< Hi
    ->  Out = [E|Out1]
    ;   Out = Out1
    ),
    owned_edits(Es, Lo, Hi, Out1).

%% clause_bounds(+Tokens, +From, +To, -Lo, -Hi)
%  Lo..Hi runs from the first token of the first clause the range overlaps
%  to the end of the last one's last token. A clause's range includes the
%  layout before it for cursor selection. A nonempty range must overlap
%  the clause's tokens, so ending at the next clause does not select it.
clause_bounds(Toks, From, To, Lo, Hi) :-
    clause_spans(Toks, 0, Spans),
    selected(Spans, From, To, Sel),
    Sel = [_-span(Lo, _)|_],
    last_elem(Sel, _-span(_, Hi)).

clause_spans([tk(eof, _, _, _)|_], _, []) :- !.
clause_spans([T|Ts], Start, [Start-span(First, End)|Spans]) :-
    T = tk(_, _, _, First),
    clause_end([T|Ts], End, Rest),
    clause_spans(Rest, End, Spans).

clause_end([T|Ts], End, Rest) :-
    T = tk(Kind, Text, _, Off),
    length(Text, N),
    End0 is Off + N,
    (   Kind == end
    ->  End = End0, Rest = Ts
    ;   Ts = [tk(eof, _, _, _)|_]
    ->  End = End0, Rest = Ts
    ;   clause_end(Ts, End, Rest)
    ).

selected([], _, _, []).
selected([S-span(F, E)|Ss], From, To, Out) :-
    (   E > From,
        ( From =:= To -> S =< From ; F < To )
    ->  Out = [S-span(F, E)|Out1]
    ;   Out = Out1
    ),
    selected(Ss, From, To, Out1).

last_elem([X], X) :- !.
last_elem([_|Xs], X) :- last_elem(Xs, X).
