/* Language features. Lifecycle methods (initialize, shutdown, exit) are
   handled by server.pl and never reach this module.

   handle_request(+Method, +Params, -Outcome)
     Outcome is result(Json) or error(CodeName, MessageChars).
     Failure means "method not found".
   handle_notification(+Method, +Params)
     Failure is ignored, as LSP requires for unknown notifications.
   server_capabilities(-Json)
     The ServerCapabilities object sent in the initialize result. */

:- module(handlers, [server_capabilities/1, handle_request/3, handle_notification/2]).

:- set_prolog_flag(double_quotes, chars).

server_capabilities(pairs([])).

handle_request(_Method, _Params, _Outcome) :-
    fail.

handle_notification(_Method, _Params).
