/* Language features. Lifecycle methods (initialize, shutdown, exit) are
   handled by server.pl and never reach this module.

   The workspace is ws(Encoding, Documents): Encoding is the negotiated
   position encoding, utf16 or utf32, and Documents is a list of
   doc(UriChars, TextChars), synchronised in full on every change.

   handlers_init(+InitializeParams, -Workspace, -Capabilities)
     Capabilities is the ServerCapabilities object for the initialize result.
   handle_request(+Method, +Params, +Workspace, -Outcome)
     Outcome is result(Json) or error(CodeName, MessageChars).
     Failure means "method not found".
   handle_notification(+Method, +Params, +Workspace0, -Workspace)
     Failure is ignored, as LSP requires for unknown notifications. */

:- module(handlers, [handlers_init/3, handle_request/4, handle_notification/4]).

:- use_module(library(lists)).
:- use_module('./fmt').
:- use_module('./positions').

:- set_prolog_flag(double_quotes, chars).

handlers_init(Params, ws(Enc, []), pairs(Caps)) :-
    position_encoding(Params, Enc),
    encoding_name(Enc, Name),
    Caps = [ string("positionEncoding")-string(Name),
             string("textDocumentSync")-pairs([ string("openClose")-boolean(true),
                                                string("change")-number(1)
                                              ]),
             string("documentFormattingProvider")-boolean(true),
             string("documentRangeFormattingProvider")-boolean(true)
           ].

% UTF-32 positions match the decoded text; UTF-16 is the fallback every
% client supports.
position_encoding(Params, Enc) :-
    (   path(Params, ["capabilities", "general", "positionEncodings"], list(Encs)),
        memberchk(string("utf-32"), Encs)
    ->  Enc = utf32
    ;   Enc = utf16
    ).

encoding_name(utf16, "utf-16").
encoding_name(utf32, "utf-32").

%% Requests --------------------------------------------------------------

handle_request('textDocument/formatting', Params, ws(Enc, Docs), Outcome) :-
    with_document(Params, Docs, Text, Opts, Outcome0),
    (   nonvar(Outcome0)
    ->  Outcome = Outcome0
    ;   format_edits(Text, Opts, Edits, _),
        text_edits(Text, Enc, Edits, Json),
        Outcome = result(Json)
    ).
handle_request('textDocument/rangeFormatting', Params, ws(Enc, Docs), Outcome) :-
    with_document(Params, Docs, Text, Opts, Outcome0),
    (   nonvar(Outcome0)
    ->  Outcome = Outcome0
    ;   path(Params, ["range", "start"], StartJson),
        path(Params, ["range", "end"], EndJson),
        json_position(StartJson, Start),
        json_position(EndJson, End),
        ordered_positions(Start, End)
    ->  position_offset(Text, Start, Enc, From),
        position_offset(Text, End, Enc, To),
        format_range(Text, From, To, Opts, Edits, _),
        text_edits(Text, Enc, Edits, Json),
        Outcome = result(Json)
    ;   Outcome = error(invalid_params, "Invalid range")
    ).

with_document(Params, Docs, Text, Opts, Outcome) :-
    (   path(Params, ["textDocument", "uri"], string(Uri))
    ->  (   memberchk(doc(Uri, Text), Docs)
        ->  (   path(Params, ["options"], pairs(Members))
            ->  format_options(Members, Opts)
            ;   Opts = []
            )
        ;   Outcome = error(invalid_params, "Unknown document")
        )
    ;   Outcome = error(invalid_params, "Missing textDocument")
    ).

% FormattingOptions: tabSize is the indent; the other keys are this
% server's own, which LSP allows alongside the standard ones.
format_options([], []).
format_options([string(Key)-Value|Ms], Opts) :-
    (   format_option(Key, Value, Opt)
    ->  Opts = [Opt|Opts1]
    ;   Opts = Opts1
    ),
    format_options(Ms, Opts1).

format_option("tabSize", number(N), indent(N)) :- integer(N), N >= 0.
format_option("blankLinesMax", number(N), blank_lines_max(N)) :- integer(N), N >= 0.
format_option("alignWidth", number(N), align_width(N)) :- integer(N), N >= 0.
format_option("listSpacing", V, list_spacing(S)) :- spacing(V, S).
format_option("curlySpacing", V, curly_spacing(S)) :- spacing(V, S).

spacing(string("preserve"), preserve).
spacing(number(0), 0).
spacing(number(1), 1).

text_edits(Text, Enc, Edits, list(Json)) :-
    edit_offsets(Edits, Offsets),
    offsets_positions(Text, Offsets, Enc, Positions),
    edits_json(Edits, Positions, Json).

edit_offsets([], []).
edit_offsets([edit(F, T, _)|Es], [F, T|Os]) :-
    edit_offsets(Es, Os).

edits_json([], [], []).
edits_json([edit(_, _, New)|Es], [S, E|Ps], [Edit|Json]) :-
    position_json(S, SJ),
    position_json(E, EJ),
    Edit = pairs([ string("range")-pairs([string("start")-SJ, string("end")-EJ]),
                   string("newText")-string(New)
                 ]),
    edits_json(Es, Ps, Json).

position_json(position(L, C),
              pairs([string("line")-number(L), string("character")-number(C)])).

json_position(Json, position(L, C)) :-
    path(Json, ["line"], number(L)), integer(L), L >= 0,
    path(Json, ["character"], number(C)), integer(C), C >= 0.

ordered_positions(position(L0, C0), position(L1, C1)) :-
    ( L0 < L1 ; L0 =:= L1, C0 =< C1 ).

%% Notifications ---------------------------------------------------------

handle_notification('textDocument/didOpen', Params, ws(Enc, Docs0), ws(Enc, Docs)) :-
    path(Params, ["textDocument", "uri"], string(Uri)),
    path(Params, ["textDocument", "text"], string(Text)),
    put_document(Docs0, Uri, Text, Docs).
handle_notification('textDocument/didChange', Params, ws(Enc, Docs0), ws(Enc, Docs)) :-
    path(Params, ["textDocument", "uri"], string(Uri)),
    path(Params, ["contentChanges"], list(Changes)),
    last_change(Changes, Change),
    path(Change, ["text"], string(Text)),
    put_document(Docs0, Uri, Text, Docs).
handle_notification('textDocument/didClose', Params, ws(Enc, Docs0), ws(Enc, Docs)) :-
    path(Params, ["textDocument", "uri"], string(Uri)),
    remove_document(Docs0, Uri, Docs).

% With full synchronisation each change is the whole document.
last_change([C], C) :- !.
last_change([_|Cs], C) :- last_change(Cs, C).

put_document(Docs0, Uri, Text, [doc(Uri, Text)|Docs]) :-
    remove_document(Docs0, Uri, Docs).

remove_document([], _, []).
remove_document([doc(U, T)|Ds], Uri, Out) :-
    (   U == Uri
    ->  Out = Ds
    ;   Out = [doc(U, T)|Out1],
        remove_document(Ds, Uri, Out1)
    ).

%% JSON access -----------------------------------------------------------

path(Json, [], Json).
path(pairs(Members), [Key|Keys], Value) :-
    memberchk(string(Key)-Json, Members),
    path(Json, Keys, Value).
