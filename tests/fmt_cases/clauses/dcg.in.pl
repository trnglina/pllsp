greeting --> [hello], name.
name --> [world].
digits([D|T]) --> digit(D), !, digits(T).
digits([]) --> [].
with_braces --> [a], { X = 1, Y is X+1 }, [b].
