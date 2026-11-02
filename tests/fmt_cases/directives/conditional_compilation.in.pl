:- if(current_prolog_flag(bounded, false)).
big(X) :- X is 2**200.
:- else.
big(0).
:- endif.
