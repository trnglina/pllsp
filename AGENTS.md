- Use the Nix flake for all development and deployment.
- Refer to and maintain `docs/NOTES.md`; keep notes concise and technically
  specific. Include only non-obvious information useful for future reference,
  such as runtime quirks and external constraints. Omit anything evident from
  the project code, standard protocol explanations, speculative risks, and
  unsupported performance claims.
- This is an ISO Prolog (+ modules) project. Test against Trealla and Scryer
  Prolog, but avoid encoding implementation details. Common code may also use
  `library(lists)`, `library(dcgs)` and `library(dif)`.
- Features that require implementation details must be kept in separate modules
  from common code. For runtime-specific features, use `<feature>_trealla.pl`
  and `<feature>_scryer.pl` with the same interface, selected by the Nix
  launchers before loading `main.pl`; keep runtime detection out of common code.
- Keep `src/` flat and load local modules as `use_module('./name')`; launchers
  run from `src/`.
