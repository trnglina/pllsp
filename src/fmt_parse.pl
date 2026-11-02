/* Operator-precedence parser over fmt_lex tokens.

   parse_items(+Tokens, -Items)
     Items cover the token list in order:
       clause(Node, EndTok)   a term and its full stop
       verbatim(Toks)         tokens up to and including the next full stop,
                              for a clause that failed to parse
       trailing(EofTok)       layout after the last clause

   Nodes keep their tokens, so the source can be rebuilt from them. The first
   argument of every node is the layout before its first token:
     leaf(Pre, Text, Kind)
     neg(Pre, SignTok, NumTok)
     comp(Pre, FunctorTok, OpenTok, Args, SepToks, CloseTok)
     prefix(Pre, OpTok, Op, Arg)
     infix(Pre, Left, OpTok, Op, Right)
     postfix(Pre, Arg, OpTok, Op)
     paren(Pre, OpenTok, Inner, CloseTok)
     curly(Pre, OpenTok, Inner, CloseTok)
     list(Pre, OpenTok, Elems, SepToks, Tail, CloseTok)
   Op is op(Name, Type, Priority); Tail is none or tail(BarTok, Node).

   The operator table starts from the operators Trealla and Scryer share,
   and op/3 directives in the file (including module export lists) update
   it for the clauses that follow. */

:- module(fmt_parse, [parse_items/2, node_pre/2, token_atom/2]).

:- use_module(library(lists)).

:- set_prolog_flag(double_quotes, chars).

parse_items(Toks, Items) :-
    initial_ops(Ops),
    items(Toks, Ops, Items).

items([T|Ts], _, [trailing(T)]) :-
    T = tk(eof, _, _, _),
    !,
    Ts = [].
items(Toks, Ops0, [Item|Items]) :-
    (   term(1200, Ops0, Node, _, Toks, [E|Rest]),
        E = tk(end, _, _, _)
    ->  Item = clause(Node, E),
        directive_ops(Node, Ops0, Ops)
    ;   skip_clause(Toks, Bad, Rest),
        Item = verbatim(Bad),
        Ops = Ops0
    ),
    items(Rest, Ops, Items).

skip_clause([T|Ts], Bad, Rest) :-
    (   T = tk(eof, _, _, _)
    ->  Bad = [], Rest = [T|Ts]
    ;   T = tk(end, _, _, _)
    ->  Bad = [T], Rest = Ts
    ;   Bad = [T|Bad1],
        skip_clause(Ts, Bad1, Rest)
    ).

node_pre(Node, Pre) :-
    arg(1, Node, Pre).

%% Terms -----------------------------------------------------------------

term(Max, Ops, Node, Pri, S0, S) :-
    primary(Max, Ops, Left, LPri, S0, S1),
    infixes(Max, Ops, Left, LPri, Node, Pri, S1, S).

primary(Max, Ops, Node, Pri, [T|S0], S) :-
    T = tk(Kind, Text, Pre, _),
    primary_(Kind, T, Text, Pre, Max, Ops, Node, Pri, S0, S).

primary_(num, _, Text, Pre, _, _, leaf(Pre, Text, number), 0, S, S).
primary_(var, _, Text, Pre, _, _, leaf(Pre, Text, var), 0, S, S).
primary_(str, _, Text, Pre, _, _, leaf(Pre, Text, string), 0, S, S).
primary_(bq, _, Text, Pre, _, _, leaf(Pre, Text, backquote), 0, S, S).
primary_(punct('('), O, _, Pre, _, Ops, paren(Pre, O, Inner, C), 0, S0, S) :-
    term(1200, Ops, Inner, _, S0, [C|S]),
    C = tk(punct(')'), _, _, _).
primary_(punct('{'), O, Text, Pre, _, Ops, Node, 0, S0, S) :-
    (   S0 = [C|S], C = tk(punct('}'), CText, CPre, _)
    ->  empty_pair(Text, CPre, CText, Atom),
        Node = leaf(Pre, Atom, atom)
    ;   term(1200, Ops, Inner, _, S0, [C|S]),
        C = tk(punct('}'), _, _, _),
        Node = curly(Pre, O, Inner, C)
    ).
primary_(punct('['), O, Text, Pre, _, Ops, Node, 0, S0, S) :-
    (   S0 = [C|S], C = tk(punct(']'), CText, CPre, _)
    ->  empty_pair(Text, CPre, CText, Atom),
        Node = leaf(Pre, Atom, atom)
    ;   arglist(Ops, Elems, Seps, S0, S1),
        (   S1 = [B|S2], B = tk(punct('|'), _, _, _)
        ->  term(999, Ops, TailNode, _, S2, S3),
            Tail = tail(B, TailNode)
        ;   Tail = none, S3 = S1
        ),
        S3 = [C|S],
        C = tk(punct(']'), _, _, _),
        Node = list(Pre, O, Elems, Seps, Tail, C)
    ).
primary_(name, T, _, Pre, Max, Ops, Node, Pri, S0, S) :-
    name_primary(T, Pre, Max, Ops, Node, Pri, S0, S).
primary_(qname, T, _, Pre, Max, Ops, Node, Pri, S0, S) :-
    name_primary(T, Pre, Max, Ops, Node, Pri, S0, S).

% `[]` and `{}` are atoms; whatever layout is inside them stays inside.
empty_pair(Open, CPre, Close, Text) :-
    layout_text(CPre, Inner),
    append(Inner, Close, Text1),
    append(Open, Text1, Text).

name_primary(T, Pre, Max, Ops, Node, Pri, S0, S) :-
    T = tk(Kind, Text, _, _),
    token_atom(T, A),
    (   S0 = [O|S1], O = tk(punct('('), _, [], _)
    ->  arglist(Ops, Args, Seps, S1, [C|S]),
        C = tk(punct(')'), _, _, _),
        Node = comp(Pre, T, O, Args, Seps, C),
        Pri = 0
    ;   Kind == name, Text == ['-'],
        S0 = [N|S], N = tk(num, _, _, _)
    ->  Node = neg(Pre, T, N),
        Pri = 0
    ;   prefix_op(Ops, A, P, Type),
        \+ operand_absent(Ops, S0),
        arg_max(Type, P, P, ArgMax0),
        ( P > Max -> ArgMax is min(ArgMax0, Max) ; ArgMax = ArgMax0 ),
        term(ArgMax, Ops, Arg, _, S0, S1)
    ->  Node = prefix(Pre, T, op(A, Type, P), Arg),
        ( P > Max -> Pri = Max ; Pri = P ),
        S = S1
    ;   Node = leaf(Pre, Text, atom),
        Pri = 0,
        S = S0
    ).

% A prefix operator stands alone when nothing it could apply to follows.
operand_absent(_, [T|_]) :-
    T = tk(Kind, _, _, _),
    terminator(Kind),
    !.
operand_absent(Ops, [T|S]) :-
    T = tk(Kind, _, _, _),
    ( Kind == name ; Kind == qname ),
    token_atom(T, A),
    ( infix_op(Ops, A, _, _) ; postfix_op(Ops, A, _, _) ),
    \+ prefix_op(Ops, A, _, _),
    \+ ( S = [tk(punct('('), _, [], _)|_] ).

terminator(punct(')')).
terminator(punct(']')).
terminator(punct('}')).
terminator(punct(',')).
terminator(punct('|')).
terminator(end).
terminator(eof).

arglist(Ops, [A|As], Seps, S0, S) :-
    term(999, Ops, A, _, S0, S1),
    (   S1 = [Sep|S2], Sep = tk(punct(','), _, _, _)
    ->  Seps = [Sep|Seps1],
        arglist(Ops, As, Seps1, S2, S)
    ;   As = [], Seps = [], S = S1
    ).

infixes(Max, Ops, Left, LPri, Node, Pri, S0, S) :-
    (   S0 = [T|S1],
        infix_token(T, Ops, Op),
        Op = op(_, Type, P),
        P =< Max,
        left_max(Type, P, LMax),
        LPri =< LMax,
        arg_max(Type, P, right, RMax),
        term(RMax, Ops, Right, _, S1, S2)
    ->  node_pre(Left, Pre),
        infixes(Max, Ops, infix(Pre, Left, T, Op, Right), P, Node, Pri, S2, S)
    ;   S0 = [T|S1],
        T = tk(Kind, _, _, _),
        ( Kind == name ; Kind == qname ),
        token_atom(T, A),
        postfix_op(Ops, A, P, Type),
        P =< Max,
        left_max(Type, P, LMax),
        LPri =< LMax
    ->  node_pre(Left, Pre),
        infixes(Max, Ops, postfix(Pre, Left, T, op(A, Type, P)), P, Node, Pri, S1, S)
    ;   Node = Left, Pri = LPri, S = S0
    ).

infix_token(tk(punct(','), _, _, _), _, op(',', xfy, 1000)) :- !.
infix_token(tk(punct('|'), _, _, _), _, op('|', xfy, 1100)) :- !.
infix_token(T, Ops, op(A, Type, P)) :-
    T = tk(Kind, _, _, _),
    ( Kind == name ; Kind == qname ),
    token_atom(T, A),
    infix_op(Ops, A, P, Type).

left_max(xfx, P, M) :- M is P - 1.
left_max(xfy, P, M) :- M is P - 1.
left_max(yfx, P, P).
left_max(xf, P, M) :- M is P - 1.
left_max(yf, P, P).

% arg_max(+Type, +Priority, +Side, -Max); prefix types take Side = Priority.
arg_max(fy, P, _, P).
arg_max(fx, P, _, M) :- M is P - 1.
arg_max(xfx, P, right, M) :- M is P - 1.
arg_max(yfx, P, right, M) :- M is P - 1.
arg_max(xfy, P, right, P).

%% Names -----------------------------------------------------------------

token_atom(tk(name, Text, _, _), A) :-
    atom_chars(A, Text).
token_atom(tk(qname, Text, _, _), A) :-
    append(['\''|Body], ['\''], Text),
    unquote(Body, Chars),
    atom_chars(A, Chars).

% Approximate: only the doubled quote is decoded. Escapes are left as they
% are, which is enough to recognise quoted operator names.
unquote([], []).
unquote(['\'', '\''|Cs], ['\''|Out]) :- !, unquote(Cs, Out).
unquote([C|Cs], [C|Out]) :- unquote(Cs, Out).

layout_text([], []).
layout_text([ws(Cs)|Ls], Out) :- layout_text(Ls, R), append(Cs, R, Out).
layout_text([cmt(Cs, _, _)|Ls], Out) :- layout_text(Ls, R), append(Cs, R, Out).

%% Operator table --------------------------------------------------------

prefix_op(Ops, A, P, T) :- member(op(P, T, A), Ops), prefix_type(T), !.
infix_op(Ops, A, P, T) :- member(op(P, T, A), Ops), infix_type(T), !.
postfix_op(Ops, A, P, T) :- member(op(P, T, A), Ops), postfix_type(T), !.

prefix_type(fy).
prefix_type(fx).
infix_type(xfx).
infix_type(xfy).
infix_type(yfx).
postfix_type(xf).
postfix_type(yf).

initial_ops([ op(1200, xfx, ':-'), op(1200, xfx, '-->'),
              op(1200, fx, ':-'), op(1200, fx, '?-'),
              op(1150, fx, dynamic), op(1150, fx, discontiguous),
              op(1150, fx, multifile), op(1150, fx, meta_predicate),
              op(1100, xfy, ';'), op(1050, xfy, '->'),
              op(900, fy, '\\+'),
              op(700, xfx, '='), op(700, xfx, '\\='), op(700, xfx, '=='),
              op(700, xfx, '\\=='), op(700, xfx, '@<'), op(700, xfx, '@>'),
              op(700, xfx, '@=<'), op(700, xfx, '@>='), op(700, xfx, '=..'),
              op(700, xfx, is), op(700, xfx, '=:='), op(700, xfx, '=\\='),
              op(700, xfx, '<'), op(700, xfx, '>'), op(700, xfx, '=<'),
              op(700, xfx, '>='),
              op(600, xfy, ':'),
              op(500, yfx, '+'), op(500, yfx, '-'), op(500, yfx, '/\\'),
              op(500, yfx, '\\/'),
              op(400, yfx, '*'), op(400, yfx, '/'), op(400, yfx, '//'),
              op(400, yfx, rem), op(400, yfx, mod), op(400, yfx, div),
              op(400, yfx, rdiv), op(400, yfx, '<<'), op(400, yfx, '>>'),
              op(200, xfx, '**'), op(200, xfy, '^'),
              op(200, fy, '-'), op(200, fy, '+'), op(200, fy, '\\')
            ]).

%% Directives that change the syntax of the rest of the file -------------

directive_ops(prefix(_, T, _, Arg), Ops0, Ops) :-
    token_atom(T, ':-'),
    !,
    goal_ops(Arg, Ops0, Ops).
directive_ops(_, Ops, Ops).

goal_ops(infix(_, L, _, op(',', _, _), R), Ops0, Ops) :-
    !,
    goal_ops(L, Ops0, Ops1),
    goal_ops(R, Ops1, Ops).
goal_ops(paren(_, _, Inner, _), Ops0, Ops) :-
    !,
    goal_ops(Inner, Ops0, Ops).
goal_ops(Node, Ops0, Ops) :-
    (   node_term(Node, Goal)
    ->  term_ops(Goal, Ops0, Ops)
    ;   Ops = Ops0
    ).

term_ops(op(P, T, Names), Ops0, Ops) :-
    !,
    add_ops(Names, P, T, Ops0, Ops).
term_ops(module(_, Exports), Ops0, Ops) :-
    !,
    export_ops(Exports, Ops0, Ops).
term_ops(_, Ops, Ops).

export_ops([], Ops, Ops).
export_ops([E|Es], Ops0, Ops) :-
    term_ops_export(E, Ops0, Ops1),
    export_ops(Es, Ops1, Ops).

term_ops_export(op(P, T, N), Ops0, Ops) :- !, add_ops(N, P, T, Ops0, Ops).
term_ops_export(_, Ops, Ops).

add_ops([], _, _, Ops, Ops) :- !.
add_ops([N|Ns], P, T, Ops0, Ops) :-
    !,
    add_ops(N, P, T, Ops0, Ops1),
    add_ops(Ns, P, T, Ops1, Ops).
add_ops(N, P, T, Ops0, Ops) :-
    (   atom(N), integer(P), P >= 0, P =< 1200, op_class(T, Class)
    ->  remove_class(Ops0, N, Class, Ops1),
        (   P > 0
        ->  Ops = [op(P, T, N)|Ops1]
        ;   Ops = Ops1
        )
    ;   Ops = Ops0
    ).

remove_class([], _, _, []).
remove_class([op(P, T, A)|Os], N, Class, Out) :-
    (   A == N, op_class(T, Class)
    ->  Out = Out1
    ;   Out = [op(P, T, A)|Out1]
    ),
    remove_class(Os, N, Class, Out1).

op_class(T, prefix) :- prefix_type(T), !.
op_class(T, infix) :- infix_type(T), !.
op_class(T, postfix) :- postfix_type(T).

% The ground term a node denotes, for the handful of shapes directives use.
node_term(leaf(_, Text, number), N) :-
    catch(number_chars(N, Text), _, fail).
node_term(leaf(_, Text, atom), A) :-
    ( Text = ['\''|_] -> token_atom(tk(qname, Text, [], 0), A) ; atom_chars(A, Text) ).
node_term(neg(_, _, tk(_, Text, _, _)), N) :-
    catch(number_chars(N0, Text), _, fail),
    N is -N0.
node_term(paren(_, _, Inner, _), T) :-
    node_term(Inner, T).
node_term(comp(_, F, _, Args, _, _), T) :-
    token_atom(F, Name),
    nodes_terms(Args, Ts),
    T =.. [Name|Ts].
node_term(prefix(_, _, op(Name, _, _), Arg), T) :-
    node_term(Arg, A),
    T =.. [Name, A].
node_term(infix(_, L, _, op(Name, _, _), R), T) :-
    node_term(L, A),
    node_term(R, B),
    T =.. [Name, A, B].
node_term(list(_, _, Elems, _, Tail, _), T) :-
    nodes_terms(Elems, Ts),
    (   Tail == none
    ->  T = Ts
    ;   Tail = tail(_, TN),
        node_term(TN, TT),
        append(Ts, TT, T)
    ).

nodes_terms([], []).
nodes_terms([N|Ns], [T|Ts]) :-
    node_term(N, T),
    nodes_terms(Ns, Ts).
