/* Pieces back to text, in two passes.

   1. Layout: pieces become events -- t(Text, Kind), sp, spn(N),
      br(N, Spec), c(Text, Kind, Column), pad(N), bpad(Ref, N). This pass
      decides style: operator spacing, which breaks the author keeps, how
      deep a continuation line sits.
   2. Emission: events become characters. This pass decides nothing about
      style; it enforces what must hold whatever the style, chiefly that two
      tokens which would lex as one are kept apart (`X * -1` must not become
      `X*-1`).

   Intra-line whitespace is regenerated; line breaks are the author's. The
   exceptions are layout that carries meaning structure cannot recover:
   space before a trailing comment, the column of a comment alone on its
   line, and anything inside a region that failed to parse. */

:- module(fmt_render, [render_pieces/3, option_value/3]).

:- use_module(library(lists)).
:- use_module('./fmt_cst').
:- use_module('./fmt_lex').

:- set_prolog_flag(double_quotes, chars).

%% option_value(+Options, +Name, -Value)
option_value(Opts, Name, Value) :-
    Probe =.. [Name, V],
    (   memberchk(Probe, Opts)
    ->  Value = V
    ;   default_option(Name, Value)
    ).

default_option(indent, 4).
default_option(blank_lines_max, 2).
default_option(align_width, 4).
default_option(list_spacing, preserve).
default_option(curly_spacing, preserve).
default_option(final_newline, true).
default_option(strip_leading_blanks, true).

render_pieces(Pieces, Opts, Text) :-
    option_value(Opts, indent, Indent),
    option_value(Opts, blank_lines_max, MaxBlank),
    option_value(Opts, final_newline, FinalNL),
    option_value(Opts, strip_leading_blanks, StripLead),
    option_value(Opts, align_width, AlignWidth),
    pieces_events(Pieces, Opts, Events0, []),
    normalise(Events0, MaxBlank, StripLead, AlignWidth, Events),
    emit(Events, Indent, FinalNL, Text).

%% Pass 1: layout --------------------------------------------------------

pieces_events([], _, E, E).
pieces_events([P|Ps], Opts, E0, E) :-
    piece_events(P, Opts, E0, E1),
    pieces_events(Ps, Opts, E1, E).

piece_events(tok(Text, Kind), _, [t(Text, Kind)|E], E).
piece_events(gap(Role, Level, Parts), Opts, E0, E) :-
    role_spacing(Role, Opts, Before, After),
    space_if(Before, E0, E1),
    parts_events(Parts, Level, Role, E1, E2),
    trailing_space(Role, After, E2, E).

% Padding after an opening bracket moves the bracket's content column with
% it, so later lines line up under the first element (see emission).
trailing_space(Role, After, E0, E) :-
    (   After > 0,
        padded_role(Role, Ref)
    ->  E0 = [bpad(Ref, After)|E]
    ;   space_if(After, E0, E)
    ).

padded_role(list_open(Ref, _), Ref).
padded_role(curly_open(Ref, _), Ref).

space_if(0, E, E) :- !.
space_if(N, [spn(N)|E], E).

% Whitespace directly before a comment on the same line is the author
% aligning trailing comments in a column, so its width is kept.
parts_events([], _, _, E, E).
parts_events([ws(Ws), cmt(Text, Kind, Col)|Ps], Level, Role, E0, E) :-
    \+ memberchk('\n', Ws), \+ memberchk('\r', Ws),
    !,
    length(Ws, W0),
    W is max(1, W0),
    E0 = [spn(W), c(Text, Kind, Col), sp|E1],
    parts_events(Ps, Level, Role, E1, E).
parts_events([P|Ps], Level, Role, E0, E) :-
    part_events(P, Level, Role, E0, E1),
    parts_events(Ps, Level, Role, E1, E).

part_events(ws(Ws), Level, Role, E0, E) :-
    newline_count(Ws, 0, N),
    (   N > 0
    ->  indent_spec(Role, Level, Spec),
        E0 = [br(N, Spec)|E]
    ;   E0 = E
    ).
part_events(pun(Text), _, Role, [t(Text, punct(Role))|E], E).
part_events(cmt(Text, Kind, Col), _, _, [sp, c(Text, Kind, Col), sp|E], E).

newline_count([], N, N).
newline_count(['\r', '\n'|Cs], N0, N) :-
    !,
    N1 is N0 + 1,
    newline_count(Cs, N1, N).
newline_count([C|Cs], N0, N) :-
    ( ( C == '\n' ; C == '\r' ) -> N1 is N0 + 1 ; N1 = N0 ),
    newline_count(Cs, N1, N).

%% indent_spec(+Role, +Level, -Spec)
%  level(L) is structural indent; align(Ref, Which) lines up with an
%  enclosing bracket: Which is open (the bracket's column) or content (the
%  column just inside it).
indent_spec(open(Ref), _, align(Ref, content)) :- !.
indent_spec(sep(Ref, _), _, align(Ref, content)) :- !.
indent_spec(close(Ref), _, align(Ref, open)) :- !.
indent_spec(list_open(Ref, _), _, align(Ref, content)) :- !.
indent_spec(list_sep(Ref, _), _, align(Ref, content)) :- !.
indent_spec(list_bar(Ref), _, align(Ref, open)) :- !.
indent_spec(list_close(Ref, _), _, align(Ref, open)) :- !.
indent_spec(curly_open(Ref, _), _, align(Ref, content)) :- !.
indent_spec(curly_close(Ref, _), _, align(Ref, open)) :- !.
indent_spec(paren_open(_, Ref), _, align(Ref, content)) :- !.
indent_spec(paren_close(Ref), _, align(Ref, open)) :- !.
% A broken operator chain inside brackets lines up with them: control
% operators under the bracket, anything else just inside it.
indent_spec(before_op(op(Name, _, _), Anchor, _), Level, Spec) :-
    !,
    op_anchor_spec(Name, Anchor, Level, open, Spec).
indent_spec(after_op(op(Name, _, _), Anchor, _), Level, Spec) :-
    !,
    op_anchor_spec(Name, Anchor, Level, content, Spec).
indent_spec(_, Level, level(Level)).

op_anchor_spec(_, none, Level, _, level(Level)) :- !.
op_anchor_spec(Name, Anchor, _, _, align(Anchor, open)) :-
    control_op(Name),
    !.
op_anchor_spec(_, Anchor, _, Which, align(Anchor, Which)).

%% role_spacing(+Role, +Options, -Before, -After)
%  Spaces around the punctuation a gap carries, when it has no line break.
role_spacing(before_op(op(N, T, P), _, Pad), Opts, Before, 0) :-
    !,
    op_spacing(Opts, N, T, P, Setting, _),
    pad_setting(Setting, Pad, Before).
role_spacing(after_op(op(N, T, P), _, Pad), Opts, 0, After) :-
    !,
    op_spacing(Opts, N, T, P, _, Setting),
    pad_setting(Setting, Pad, After).
role_spacing(list_open(_, Pad), Opts, 0, After) :-
    !,
    option_value(Opts, list_spacing, Setting),
    pad_setting(Setting, Pad, After).
role_spacing(list_close(_, Pad), Opts, Before, 0) :-
    !,
    option_value(Opts, list_spacing, Setting),
    pad_setting(Setting, Pad, Before).
role_spacing(curly_open(_, Pad), Opts, 0, After) :-
    !,
    option_value(Opts, curly_spacing, Setting),
    pad_setting(Setting, Pad, After).
role_spacing(curly_close(_, Pad), Opts, Before, 0) :-
    !,
    option_value(Opts, curly_spacing, Setting),
    pad_setting(Setting, Pad, Before).
role_spacing(sign(Pad), _, 0, Pad) :- !.
role_spacing(sep(_, _), _, 0, 1) :- !.
role_spacing(list_sep(_, _), _, 0, 1) :- !.
% A full stop must be followed by layout or it is not a full stop.
role_spacing(clause_end, _, 0, 1) :- !.
role_spacing(_, _, 0, 0).

pad_setting(preserve, Pad, Pad) :- !.
pad_setting(N, _, N).

%% op_spacing(+Options, +Name, +Type, +Pri, -Before, -After)
%  Before and After are space counts or `preserve`.
%  Control and comparison operators are always spaced; below 700 the
% author's spacing is kept, since `A+1`, `foo/2` and `K-V` are idiomatic.
op_spacing(_, ',', _, _, 0, 1) :- !.
op_spacing(_, '|', _, _, 1, 1) :- !.
op_spacing(_, Name, _, _, 1, 1) :-
    alpha_operator(Name),
    !.
op_spacing(_, _, _, Pri, 1, 1) :-
    Pri >= 700,
    !.
op_spacing(_, _, _, _, preserve, preserve).

alpha_operator(Name) :-
    atom_chars(Name, [C|_]),
    char_code(C, X),
    X >= 0'a, X =< 0'z.

%% Normalisation ---------------------------------------------------------

normalise(Events0, MaxBlank, StripLead, AlignWidth, Events) :-
    close_line_comments(Events0, Events1),
    drop_sp_before_br(Events1, Events2a),
    drop_sp_after_br(Events2a, Events2),
    collapse_spaces(Events2, Events3),
    cap_blanks(Events3, MaxBlank, Events4),
    tighten_comment_spaces(Events4, Events5),
    keep_comment_columns(Events5, Events6),
    scan_brackets(Events6, []),
    align_control(Events6, AlignWidth, Events7),
    pad_control_parens(Events7, AlignWidth, Events8),
    (   StripLead == true
    ->  strip_leading_breaks(Events8, Events)
    ;   Events = Events8
    ).

% A break followed by a comment puts the comment back in its own column.
keep_comment_columns([], []).
keep_comment_columns([br(N, _), c(T, K, Col)|Es], [br(N, fixed(Col)), c(T, K, Col)|Out]) :-
    !,
    keep_comment_columns(Es, Out).
keep_comment_columns([E|Es], [E|Out]) :-
    keep_comment_columns(Es, Out).

%% scan_brackets(+Events, +Stack)
%  Sets each bracket's flags: Hanging when a break follows it directly, so
%  its contents take a hanging indent; Multiline when its contents span
%  lines at all.
scan_brackets([], _).
scan_brackets([E|Es], Stack) :-
    (   E = t(_, punct(Role)),
        opening_role(Role, Ref)
    ->  (   starts_with_break(Es)
        ->  Ref = ref(_, true, _)
        ;   true
        ),
        scan_brackets(Es, [Ref|Stack])
    ;   E = t(_, punct(Role)),
        closing_role(Role, Ref)
    ->  pop_to(Stack, Ref, Stack1),
        scan_brackets(Es, Stack1)
    ;   E = br(_, _)
    ->  mark_multiline(Stack),
        scan_brackets(Es, Stack)
    ;   scan_brackets(Es, Stack)
    ).

mark_multiline([]).
mark_multiline([ref(_, _, M)|Rs]) :-
    (   M == true
    ->  true                    % everything below is marked already
    ;   M = true,
        mark_multiline(Rs)
    ).

starts_with_break(Es) :-
    skip_padding(Es, [br(_, _)|_]).

skip_padding([E|Es], Out) :-
    padding(E),
    !,
    skip_padding(Es, Out).
skip_padding(Es, Es).

padding(sp).
padding(spn(_)).
padding(pad(_)).
padding(bpad(_, _)).

pop_to([], _, []).
pop_to([ref(Id, _, _)|T], ref(Id1, _, _), Out) :-
    (   Id == Id1
    ->  Out = T
    ;   pop_to(T, ref(Id1, _, _), Out)
    ).

% A comment is padded away from its neighbours, but not from a bracket.
tighten_comment_spaces([], []).
tighten_comment_spaces([t(T, punct(Role)), S, C|Es], [t(T, punct(Role))|Out]) :-
    is_space(S),
    C = c(_, _, _),
    opening_role(Role, _),
    !,
    tighten_comment_spaces([C|Es], Out).
tighten_comment_spaces([C, S, t(T, Kind)|Es], [C|Out]) :-
    C = c(_, _, _),
    is_space(S),
    closing_kind(Kind),
    !,
    tighten_comment_spaces([t(T, Kind)|Es], Out).
tighten_comment_spaces([E|Es], [E|Out]) :-
    tighten_comment_spaces(Es, Out).

is_space(sp).
is_space(spn(_)).

closing_kind(punct(Role)) :-
    closing_role(Role, _).
closing_kind(punct(clause_end)).

%% align_control(+Events, +Width, -Out)
%  A control operator opening a line is padded to Width, so the goals it
%  governs start in one column:  (   Cond  /  ->  Then  /  ;   Else.
align_control(Events, 0, Events) :- !.
align_control([], _, []).
align_control([br(N, Spec), t(Text, Kind)|Es], Width, Out) :-
    Kind = op(op(Name, _, _)),
    control_op(Name),
    !,
    length(Text, Len),
    Pad is max(1, Width - Len),
    skip_spaces(Es, Es1),
    Out = [br(N, Spec), t(Text, Kind), pad(Pad)|Rest],
    align_control(Es1, Width, Rest).
align_control([E|Es], Width, [E|Out]) :-
    align_control(Es, Width, Out).

% A control paren that spans lines, with something on its opening line,
% opens `(   ` so its first goal lines up with those under `->` and `;`.
pad_control_parens([], _, []).
pad_control_parens([E|Es], AW, Out) :-
    E = t(_, punct(paren_open(control, Ref))),
    Ref = ref(_, Hanging, Multi),
    Multi == true,
    Hanging \== true,
    Pad is max(0, AW - 1),
    Pad > 0,
    !,
    Out = [E, bpad(Ref, Pad)|Rest],
    skip_spaces(Es, Es1),
    pad_control_parens(Es1, AW, Rest).
pad_control_parens([E|Es], AW, [E|Out]) :-
    pad_control_parens(Es, AW, Out).

% A line comment must end its line, or it swallows what follows.
close_line_comments([], []).
close_line_comments([c(T, line, L)|Es], [c(T, line, L)|Out]) :-
    !,
    skip_spaces(Es, Es1),
    (   Es1 = [br(_, _)|_]
    ->  close_line_comments(Es1, Out)
    ;   Es1 == []
    ->  Out = [br(1, level(0))]
    ;   Out = [br(1, level(0))|Rest],
        close_line_comments(Es1, Rest)
    ).
close_line_comments([E|Es], [E|Out]) :-
    close_line_comments(Es, Out).

skip_spaces([S|Es], Out) :-
    is_space(S),
    !,
    skip_spaces(Es, Out).
skip_spaces(Es, Es).

drop_sp_before_br([], []).
drop_sp_before_br([S|Es], Out) :-
    is_space(S),
    skip_spaces(Es, Es1),
    Es1 = [br(_, _)|_],
    !,
    drop_sp_before_br(Es1, Out).
drop_sp_before_br([E|Es], [E|Out]) :-
    drop_sp_before_br(Es, Out).

drop_sp_after_br([], []).
drop_sp_after_br([br(N, S)|Es], [br(N, S)|Out]) :-
    !,
    skip_spaces(Es, Es1),
    drop_sp_after_br(Es1, Out).
drop_sp_after_br([E|Es], [E|Out]) :-
    drop_sp_after_br(Es, Out).

% Runs of spacing collapse to the widest request.
collapse_spaces([], []).
collapse_spaces([S|Es], [spn(W)|Out]) :-
    is_space(S),
    !,
    space_width(S, W0),
    widest(Es, W0, W, Rest),
    collapse_spaces(Rest, Out).
collapse_spaces([E|Es], [E|Out]) :-
    collapse_spaces(Es, Out).

space_width(sp, 1).
space_width(spn(N), N).

widest([S|Es], W0, W, Rest) :-
    is_space(S),
    !,
    space_width(S, W1),
    W2 is max(W0, W1),
    widest(Es, W2, W, Rest).
widest(Es, W, W, Es).

% Adjacent breaks add up; the last spec wins, since it belongs to what
% comes next.
cap_blanks([], _, []).
cap_blanks([br(N, Spec)|Es], Max, [br(Capped, Spec2)|Out]) :-
    !,
    merge_breaks(Es, N, Spec, Total, Spec2, Rest),
    Capped is min(Total, Max + 1),
    cap_blanks(Rest, Max, Out).
cap_blanks([E|Es], Max, [E|Out]) :-
    cap_blanks(Es, Max, Out).

merge_breaks([br(N, S)|Es], Acc, _, Total, S2, Rest) :-
    !,
    Acc1 is Acc + N,
    merge_breaks(Es, Acc1, S, Total, S2, Rest).
merge_breaks(Es, Acc, S, Acc, S, Es).

strip_leading_breaks([br(_, _)|Es], Out) :- !, strip_leading_breaks(Es, Out).
strip_leading_breaks(Es, Es).

opening_role(open(Ref), Ref).
opening_role(list_open(Ref, _), Ref).
opening_role(curly_open(Ref, _), Ref).
opening_role(paren_open(_, Ref), Ref).

closing_role(close(Ref), Ref).
closing_role(list_close(Ref, _), Ref).
closing_role(curly_close(Ref, _), Ref).
closing_role(paren_close(Ref), Ref).

%% Pass 2: emission ------------------------------------------------------

emit(Events, Indent, FinalNL, Text) :-
    reverse(Events, Rev),
    drop_trailing_layout(Rev, Rev1),
    reverse(Rev1, Trimmed),
    emit_(Trimmed, Indent, st(none, 0, [], 0), Raw, []),
    (   FinalNL == true, \+ ends_in_newline(Raw)
    ->  append(Raw, ['\n'], Text)
    ;   Text = Raw
    ).

% Trim layout events before emission: trimming the rendered characters
% would also alter multiline literals and clauses copied verbatim.
drop_trailing_layout([E|Es], Out) :-
    ( padding(E) ; E = br(_, _) ),
    !,
    drop_trailing_layout(Es, Out).
drop_trailing_layout(Es, Es).

ends_in_newline(Text) :-
    last_elem(Text, C),
    ( C == '\n' ; C == '\r' ).

% st(Last, Column, Brackets, LineIndent): Last is last(Text, Kind), space or
% none at a line start; Brackets holds Id-Open-Content-LineIndent for each
% open bracket, so a later break can line up under it.
emit_([], _, _, T, T).
emit_([E|Es], Indent, St0, T0, T) :-
    emit_one(E, Indent, St0, St, T0, T1),
    emit_(Es, Indent, St, T1, T).

emit_one(t(Text, Kind), _, St0, St, T0, T) :-
    (   Text == []
    ->  St = St0, T = T0
    ;   St0 = st(Last, Col, Cols, LI),
        separator(Last, Text, Sep),
        OpenCol is Col + Sep,
        advance(Text, OpenCol, Col1),
        record_bracket(Kind, OpenCol, Col1, LI, Cols, Cols1),
        spaces(Sep, T0, T1),
        append(Text, T, T1),
        St = st(last(Text, Kind), Col1, Cols1, LI)
    ).
emit_one(c(Text0, _, _), _, st(Last, Col, Cols, LI), st(last(Text, comment), Col1, Cols, LI),
         T0, T) :-
    strip_codes(Text0, [], Text),
    separator(Last, Text, Sep),
    Start is Col + Sep,
    advance(Text, Start, Col1),
    spaces(Sep, T0, T1),
    append(Text, T, T1).
emit_one(bpad(Ref, N), _, st(Last, Col, Cols, LI), st(Last, Col1, Cols1, LI), T0, T) :-
    Col1 is Col + N,
    shift_content(Cols, Ref, N, Cols1),
    spaces(N, T0, T).
% Control padding only ever opens a line, so what follows is where the
% line's content really begins.
emit_one(pad(N), _, st(Last, Col, Cols, _), st(Last, Col1, Cols, Col1), T0, T) :-
    Col1 is Col + N,
    spaces(N, T0, T).
emit_one(S, _, st(Last, Col, Cols, LI), St, T0, T) :-
    is_space(S),
    !,
    (   Last == none
    ->  St = st(Last, Col, Cols, LI), T = T0
    ;   space_width(S, N),
        Col1 is Col + N,
        spaces(N, T0, T),
        St = st(space, Col1, Cols, LI)
    ).
emit_one(br(N, Spec), Indent, st(_, _, Cols, _), st(none, W, Cols, W), T0, T) :-
    newlines(N, T0, T1),
    indent_width(Spec, Indent, Cols, W),
    spaces(W, T1, T).

record_bracket(punct(Role), OpenCol, ContentCol, LI, Cols, [Id-OpenCol-ContentCol-LI|Cols]) :-
    opening_role(Role, ref(Id, _, _)),
    !.
% A closed bracket's anchors are never wanted again, so the list only ever
% holds the brackets currently open.
record_bracket(punct(Role), _, _, _, Cols, Cols1) :-
    closing_role(Role, ref(Id, _, _)),
    !,
    forget_bracket(Cols, Id, Cols1).
record_bracket(_, _, _, _, Cols, Cols).

forget_bracket([], _, []).
forget_bracket([I-O-C-L|T], Id, Out) :-
    (   I == Id
    ->  Out = T
    ;   Out = [I-O-C-L|T1],
        forget_bracket(T, Id, T1)
    ).

shift_content([], _, _, []).
shift_content([I-O-C-L|T], Ref, N, Out) :-
    Ref = ref(Id, _, _),
    (   I == Id
    ->  C1 is C + N,
        Out = [I-O-C1-L|T]
    ;   Out = [I-O-C-L|T1],
        shift_content(T, Ref, N, T1)
    ).

lookup_bracket([I-O-C-L|T], Id, Open, Content, LI) :-
    (   I == Id
    ->  Open = O, Content = C, LI = L
    ;   lookup_bracket(T, Id, Open, Content, LI)
    ).

indent_width(level(L), Indent, _, W) :-
    W is max(0, L * Indent).
indent_width(fixed(Col), _, _, Col).
indent_width(align(ref(Id, Hanging, _), Which), Indent, Cols, W) :-
    (   lookup_bracket(Cols, Id, Open, Content, LI)
    ->  (   Hanging == true
        ->  ( Which == open -> W = LI ; W is LI + Indent )
        ;   ( Which == open -> W = Open ; W = Content )
        )
    ;   W = Indent
    ).

advance([], Col, Col).
advance([C|Cs], Col0, Col) :-
    ( C == '\n' -> Col1 = 0 ; Col1 is Col0 + 1 ),
    advance(Cs, Col1, Col).

newlines(0, T, T) :- !.
newlines(N, ['\n'|T0], T) :- N1 is N - 1, newlines(N1, T0, T).

spaces(N, T, T) :- N =< 0, !.
spaces(N, [' '|T0], T) :- N1 is N - 1, spaces(N1, T0, T).

%% separator(+Last, +Next, -Width)
%  Two tokens that would lex as one get a space, whatever the style said:
%  `X * -1` is not `X*-1`, `X mod Y` is not `XmodY`, and a prefix operator
%  before `(` would otherwise become a call.
separator(none, _, 0) :- !.
separator(space, _, 0) :- !.
separator(last(Prev, Kind), Next, Sep) :-
    (   must_separate(Prev, Kind, Next)
    ->  Sep = 1
    ;   Sep = 0
    ).

must_separate(Prev, Kind, [B|_]) :-
    last_elem(Prev, A),
    (   symbol_char(A), symbol_char(B)
    ->  true
    ;   alnum_char(A), alnum_char(B)
    ->  true
    ;   Kind = op(op(_, Type, _)), prefix_type(Type), B == '('
    ->  true
    ;   A == (/), B == (*)
    ->  true
    ;   quote_char(A), A == B
    ).

quote_char('\'').
quote_char('"').
quote_char('`').

prefix_type(fx).
prefix_type(fy).

%% Strip trailing whitespace inside comments only.
strip_codes([], _, []).
strip_codes([C|Cs], Pending, Out) :-
    (   line_space(C)
    ->  strip_codes(Cs, [C|Pending], Out)
    ;   C == '\n'
    ->  Out = [C|Rest],
        strip_codes(Cs, [], Rest)
    ;   reverse(Pending, Flush),
        append(Flush, [C|Rest], Out),
        strip_codes(Cs, [], Rest)
    ).

line_space(' ').
line_space('\t').
line_space('\r').

last_elem([X], X) :- !.
last_elem([_|Xs], X) :- last_elem(Xs, X).
