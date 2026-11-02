/* LSP lifecycle state machine and dispatch to handlers.

   State is the lifecycle phase: uninitialized, running or shutdown.
   Actions: reply(Reply), exit(Code), log(Term). */

:- module(server, [server_init/1, server_handle/4, server_eof/2]).

:- use_module('./handlers').
:- use_module(library(lists)).

:- set_prolog_flag(double_quotes, chars).

server_version("0.1.0").

%% server_init(-State)
server_init(uninitialized).

%% server_eof(+State, -ExitCode)
%  Losing stdin counts as an exit notification.
server_eof(State, Code) :-
    exit_code(State, Code).

exit_code(shutdown, 0) :- !.
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

request(uninitialized, Id, Method, Params, S, [reply(Reply)]) :-
    !,
    (   Method == initialize
    ->  (   initialize_params(Params)
        ->  initialize_result(Result),
            S = running,
            Reply = result(Id, Result)
        ;   S = uninitialized,
            Reply = error(Id, invalid_params, "Invalid initialize params")
        )
    ;   S = uninitialized,
        Reply = error(Id, server_not_initialized, "Server not initialized")
    ).
request(running, Id, Method, Params, S, Actions) :-
    !,
    (   Method == initialize
    ->  S = running,
        Actions = [reply(error(Id, invalid_request, "Server already initialized"))]
    ;   Method == shutdown
    ->  (   Params == null
        ->  S = shutdown,
            Actions = [reply(result(Id, null))]
        ;   S = running,
            Actions = [reply(error(Id, invalid_params, "shutdown takes no params"))]
        )
    ;   S = running,
        dispatch_request(Id, Method, Params, Actions)
    ).
request(shutdown, Id, _, _, shutdown,
        [reply(error(Id, invalid_request, "Server is shutting down"))]).

% Feature-specific capability contents remain opaque to this scaffold.
initialize_params(pairs(Members)) :-
    memberchk(string("capabilities")-pairs(_), Members).

dispatch_request(Id, Method, Params, Actions) :-
    catch(outcome(Method, Params, Outcome), E, Outcome = exception(E)),
    outcome_actions(Outcome, Id, Method, Actions).

outcome(Method, Params, Outcome) :-
    (   handle_request(Method, Params, Outcome0)
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

initialize_result(pairs([ string("capabilities")-Capabilities,
                          string("serverInfo")-pairs([ string("name")-string("pllsp"),
                                                       string("version")-string(Version)
                                                     ])
                        ])) :-
    server_capabilities(Capabilities),
    server_version(Version).

%% Notifications ----------------------------------------------------------

notification(S, exit, _, S, [exit(Code)]) :-
    !,
    exit_code(S, Code).
notification(running, Method, Params, running, Actions) :-
    !,
    catch(( handle_notification(Method, Params) -> true ; true ), E, true),
    (   var(E)
    ->  Actions = []
    ;   Actions = [log(notification_exception(Method, E))]
    ).
notification(S, _, _, S, []).
