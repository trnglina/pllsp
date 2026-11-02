/* Parsed items to a flat stream of tokens and gaps.

   items_pieces(+Items, -Pieces)
     tok(Text, Kind)          source text that must be copied verbatim
     gap(Role, Level, Parts)  everything between two tokens: Parts are
                              ws(Chars), cmt(Chars, Kind, Column) and
                              pun(Chars), the structural punctuation
                              ( ) [ ] { } , | . that has no token of its own

   Concatenating the pieces reproduces the source, so formatting is exactly
   rewriting gaps. Role says what a gap is for; Level is the logical depth a
   continuation line in it is indented to.

   Brackets are identified by ref(Id, Hanging, Multiline): Id is the opening
   token's offset, and the two flags are left unbound for the renderer to
   set once it knows where the line breaks fall. Roles also record the
   author's spacing: whether a container was padded inside its brackets, and
   whether an operator had space around it. */

:- module(fmt_cst, [items_pieces/2, control_op/1]).

:- use_module(library(lists)).
:- use_module('./fmt_parse').

:- set_prolog_flag(double_quotes, chars).

items_pieces(Items, Pieces) :-
    items_pieces_(Items, Pieces, []).

items_pieces_([], P, P).
items_pieces_([Item|Items], P0, P) :-
    item_pieces(Item, P0, P1),
    items_pieces_(Items, P1, P).

item_pieces(clause(Node, tk(_, ET, EPre, _)), [gap(leading, 0, Pre)|P0], P) :-
    node_pre(Node, Pre),
    pieces(Node, 0, none, P0, [gap(clause_end, 0, End)|P]),
    append(EPre, [pun(ET)], End).
item_pieces(verbatim([tk(_, Text, Pre, _)|Ts]),
            [gap(leading, 0, Pre), tok(Chars, verbatim)|P], P) :-
    verbatim_text(Ts, Rest),
    append(Text, Rest, Chars).
item_pieces(trailing(tk(_, _, Pre, _)), [gap(trailing, 0, Pre)|P], P).

verbatim_text([], []).
verbatim_text([tk(_, Text, Pre, _)|Ts], Chars) :-
    layout_chars(Pre, Lay),
    verbatim_text(Ts, Rest),
    append(Text, Rest, Chars1),
    append(Lay, Chars1, Chars).

layout_chars([], []).
layout_chars([ws(Cs)|Ls], Out) :- layout_chars(Ls, R), append(Cs, R, Out).
layout_chars([cmt(Cs, _, _)|Ls], Out) :- layout_chars(Ls, R), append(Cs, R, Out).

%% pieces(+Node, +Level, +Anchor, -Pieces, ?Tail)
%  Pieces for Node, without the layout before its first token, which
%  belongs to the gap in front of it.

pieces(leaf(_, Text, Kind), _, _, [tok(Text, Kind)|P], P).
pieces(neg(_, tk(_, ST, _, _), tk(_, NT, NPre, _)), L, _,
       [tok(ST, sign), gap(sign(Pad), L, NPre), tok(NT, number)|P], P) :-
    gap_space(NPre, Pad).
pieces(paren(_, tk(_, OT, _, Id), Inner, tk(_, CT, CPre, _)), L, _, P0, P) :-
    L1 is L + 1,
    Ref = ref(Id, _, _),
    paren_kind(Inner, Kind),
    node_pre(Inner, IPre),
    P0 = [gap(paren_open(Kind, Ref), L, [pun(OT)|IPre])|P1],
    pieces(Inner, L1, Ref, P1, [gap(paren_close(Ref), L, Close)|P]),
    append(CPre, [pun(CT)], Close).
pieces(curly(_, tk(_, OT, _, Id), Inner, tk(_, CT, CPre, _)), L, _, P0, P) :-
    L1 is L + 1,
    Ref = ref(Id, _, _),
    node_pre(Inner, IPre),
    inner_pad(IPre, Pad),
    P0 = [gap(curly_open(Ref, Pad), L, [pun(OT)|IPre])|P1],
    pieces(Inner, L1, Ref, P1, [gap(curly_close(Ref, Pad), L, Close)|P]),
    append(CPre, [pun(CT)], Close).
pieces(list(_, tk(_, OT, _, Id), [E|Es], Seps, Tail, tk(_, CT, CPre, _)), L, _,
       P0, P) :-
    L1 is L + 1,
    Ref = ref(Id, _, _),
    node_pre(E, EPre),
    inner_pad(EPre, Pad),
    P0 = [gap(list_open(Ref, Pad), L1, [pun(OT)|EPre])|P1],
    pieces(E, L1, Ref, P1, P2),
    siblings(Es, Seps, L1, Ref, list_sep(Ref), 2, P2, P3),
    (   Tail = tail(tk(_, BT, BPre, _), TN)
    ->  node_pre(TN, TPre),
        append(BPre, [pun(BT)|TPre], Bar),
        P3 = [gap(list_bar(Ref), L, Bar)|P4],
        pieces(TN, L1, Ref, P4, P5)
    ;   P5 = P3
    ),
    P5 = [gap(list_close(Ref, Pad), L, Close)|P],
    append(CPre, [pun(CT)], Close).
pieces(comp(_, tk(_, FT, _, _), tk(_, OT, _, Id), [A|As], Seps,
            tk(_, CT, CPre, _)), L, _, P0, P) :-
    L1 is L + 1,
    Ref = ref(Id, _, _),
    node_pre(A, APre),
    P0 = [tok(FT, functor), gap(open(Ref), L1, [pun(OT)|APre])|P1],
    pieces(A, L1, Ref, P1, P2),
    siblings(As, Seps, L1, Ref, sep(Ref), 2, P2, P3),
    P3 = [gap(close(Ref), L, Close)|P],
    append(CPre, [pun(CT)], Close).
pieces(prefix(_, tk(_, OT, _, _), Op, Arg), L, A, P0, P) :-
    level_of(Op, right, L, AL),
    node_pre(Arg, APre),
    gap_space(APre, Pad),
    P0 = [tok(OT, op(Op)), gap(after_op(Op, A, Pad), AL, APre)|P1],
    pieces(Arg, AL, A, P1, P).
pieces(postfix(_, Arg, tk(_, OT, OPre, _), Op), L, A, P0, P) :-
    gap_space(OPre, Pad),
    pieces(Arg, L, A, P0, [gap(before_op(Op, A, Pad), L, OPre), tok(OT, op(Op))|P]).
pieces(infix(_, Left, tk(_, OT, OPre, _), Op, Right), L, A, P0, P) :-
    level_of(Op, right, L, RL),
    op_line_level(Op, L, OL),
    node_pre(Right, RPre),
    % The left side decides and the right follows, so `A+ 1` closes up.
    % A break on the left leaves nothing to mirror; the right keeps its own.
    gap_space(OPre, LPad),
    (   breaks(OPre)
    ->  gap_space(RPre, RPad)
    ;   RPad = LPad
    ),
    pieces(Left, L, A, P0,
           [ gap(before_op(Op, A, LPad), OL, OPre), tok(OT, op(Op)),
             gap(after_op(Op, A, RPad), RL, RPre)|P1 ]),
    pieces(Right, RL, A, P1, P).

siblings([], [], _, _, _, _, P, P).
siblings([N|Ns], [tk(_, ST, SPre, _)|Ss], L, Ref, Role0, I, P0, P) :-
    Role0 =.. Parts0,
    append(Parts0, [I], Parts),
    Role =.. Parts,
    node_pre(N, NPre),
    append(SPre, [pun(ST)|NPre], Gap),
    P0 = [gap(Role, L, Gap)|P1],
    pieces(N, L, Ref, P1, P2),
    I1 is I + 1,
    siblings(Ns, Ss, L, Ref, Role0, I1, P2, P).

% Body operators step out a level when they start a line, so `;` and `->`
% line up with the `(` that opens the construct.
op_line_level(op(_, _, Pri), L, OL) :-
    (   Pri >= 1000
    ->  OL is max(0, L - 1)
    ;   OL = L
    ).

% Only priority 1200 operators open a level, so conjunctions stay in one
% column instead of following the right-nested structure of `,`/2.
level_of(op(_, _, Pri), right, L, AL) :-
    (   Pri >= 1200
    ->  AL is L + 1
    ;   AL = L
    ).

paren_kind(infix(_, _, _, op(Name, _, _), _), Kind) :-
    control_op(Name),
    !,
    Kind = control.
paren_kind(_, plain).

control_op(';').
control_op('->').
control_op('*->').
control_op('|').

% Whether the author put space just inside an opening bracket. A newline
% there is not padding: the break and its indent already hold the contents.
inner_pad([ws([C|_])|_], 1) :- ( C == ' ' ; C == '\t' ), !.
inner_pad(_, 0).

gap_space(Layout, Pad) :-
    (   member(ws(Cs), Layout), member(C, Cs), ( C == ' ' ; C == '\t' )
    ->  Pad = 1
    ;   Pad = 0
    ).

breaks(Layout) :-
    member(ws(Cs), Layout),
    ( memberchk('\n', Cs) ; memberchk('\r', Cs) ),
    !.
