/* LSP lifecycle state machine and dispatch to handlers.

   State is state(Phase, Workspace): Phase is uninitialized, running or
   shutdown, and Workspace is owned by handlers.pl once initialized.
   Actions: reply(Reply), exit(Code), log(Term). */

:- module(server, [server_init/1, server_handle/4, server_eof/2]).

:- use_module('./handlers').
:- use_module(library(lists)).

:- set_prolog_flag(double_quotes, chars).

server_version("0.1.0").

%% server_init(-State)
server_init(state(uninitialized, none)).

%% server_eof(+State, -ExitCode)
%  Losing stdin counts as an exit notification.
server_eof(State, Code) :-
    exit_code(State, Code).

exit_code(state(shutdown, _), 0) :- !.
exit_code(_, 1).

%% server_handle(+Message, +State0, -State, -Actions)
server_handle(parse_error, S, S,
              [reply(error(null, parse_error, "Parse error"))]).
server_handle(invalid(Id), S, S,
              [reply(error(Id, invalid_request, "Invalid request"))]).
server_handle(response(_), S, S, []).
server_handle(request(Id, Method, Params), S0, S, Actions) :-
    request(S0, Id, Method, Params, S, Actions).
server_handle(notification(Method, Params), S0, S, Actions) :-
    notification(S0, Method, Params, S, Actions).

%% Requests ---------------------------------------------------------------

request(state(uninitialized, W), Id, Method, Params, S, [reply(Reply)]) :-
    !,
    (   Method == initialize
    ->  (   initialize_params(Params)
        ->  handlers_init(Params, W1, Capabilities),
            initialize_result(Capabilities, Result),
            S = state(running, W1),
            Reply = result(Id, Result)
        ;   S = state(uninitialized, W),
            Reply = error(Id, invalid_params, "Invalid initialize params")
        )
    ;   S = state(uninitialized, W),
        Reply = error(Id, server_not_initialized, "Server not initialized")
    ).
request(state(running, W), Id, Method, Params, S, Actions) :-
    !,
    (   Method == initialize
    ->  S = state(running, W),
        Actions = [reply(error(Id, invalid_request, "Server already initialized"))]
    ;   Method == shutdown
    ->  (   Params == null
        ->  S = state(shutdown, W),
            Actions = [reply(result(Id, null))]
        ;   S = state(running, W),
            Actions = [reply(error(Id, invalid_params, "shutdown takes no params"))]
        )
    ;   S = state(running, W),
        dispatch_request(Id, Method, Params, W, Actions)
    ).
request(S, Id, _, _, S,
        [reply(error(Id, invalid_request, "Server is shutting down"))]).

% Feature-specific capability contents remain opaque to this scaffold.
initialize_params(pairs(Members)) :-
    memberchk(string("capabilities")-pairs(_), Members).

dispatch_request(Id, Method, Params, W, Actions) :-
    catch(outcome(Method, Params, W, Outcome), E, Outcome = exception(E)),
    outcome_actions(Outcome, Id, Method, Actions).

outcome(Method, Params, W, Outcome) :-
    (   handle_request(Method, Params, W, Outcome0)
    ->  Outcome = Outcome0
    ;   Outcome = unhandled
    ).

outcome_actions(result(Json), Id, _, [reply(result(Id, Json))]).
outcome_actions(error(Name, Message), Id, _, [reply(error(Id, Name, Message))]).
outcome_actions(unhandled, Id, _, [reply(error(Id, method_not_found, "Method not found"))]).
outcome_actions(exception(E), Id, Method,
                [ log(request_exception(Method, E)),
                  reply(error(Id, internal_error, "Internal error"))
                ]).

initialize_result(Capabilities,
                  pairs([ string("capabilities")-Capabilities,
                          string("serverInfo")-pairs([ string("name")-string("pllsp"),
                                                       string("version")-string(Version)
                                                     ])
                        ])) :-
    server_version(Version).

%% Notifications ----------------------------------------------------------

notification(S, exit, _, S, [exit(Code)]) :-
    !,
    exit_code(S, Code).
notification(state(running, W0), Method, Params, state(running, W), Actions) :-
    !,
    catch(( handle_notification(Method, Params, W0, W1) -> true ; W1 = W0 ), E, true),
    (   var(E)
    ->  W = W1, Actions = []
    ;   W = W0, Actions = [log(notification_exception(Method, E))]
    ).
notification(S, _, _, S, []).
