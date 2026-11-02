# Notes

## Portability

Scryer's `user_input` uses rustyline: it blocks until a newline arrives and
does not report EOF as required for LSP. Its text-mode file streams also
stopped after the first character on a pipe in testing. Binary `/dev/stdin`
streams worked incrementally in both runtimes.

Trealla resolves relative `use_module` paths against the process cwd;
Scryer resolves them against the loading file. In Trealla, bare `json`
resolves to `library(json)` rather than the local module.

Trealla 3.13 and Scryer 0.10 both reject a quoted prefix-operator atom
followed by `)` or `->`, e.g. `( S == '-' )`, so the source writes `('-')`.
Scryer has no `last/2` in `library(lists)` and no `forall/2` by default.

## Formatter

Both runtimes read `- 1` as the integer -1 despite the intervening layout.
Trealla defines `|` as an infix operator at 1100; Scryer rejects it outside
lists.
