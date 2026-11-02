:- op(700, xfx, ===>).
:- op(200, xfy, '::').
rule(a) ===> b.
x :- a::b::c.
