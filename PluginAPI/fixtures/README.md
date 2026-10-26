# Contract fixtures

These deterministic fixtures preserve meaningful accepted/refused shapes and
boundary cases; they do not execute native effects or prove device acceptance.

- [Conformance matrix](conformance/index.json): current schemas and Host parsers, real SDK answers and Host-version admission cases. `migration` records how each former check was retained.
- [Pages](pages/index.json), [operations](host-operations/index.json), [App Targets](apps/index.json), [sources](sources/index.json), [keep awake](keep-awake/index.json): feature-specific boundaries.
- [Adaptive cards](adaptive-cards/index.json), [viewport fit](adaptive-layout/index.json), [Spotify controls](spotify-controls/index.json), [unused dependencies](homebrew-autoremove/index.json): domain-specific accepted/refused payloads.
- [Current SDK](sdk/current.ts), [activity sources](sdk/activity-source.ts), [Terminal](sdk/terminal-homebrew.ts), [command output](sdk/command-output.ts), [catalog refresh](sdk/catalog-refresh.ts): compile-time samples, including intentional `@ts-expect-error` assertions.

The Host's Swift tests check semantic admission, budgets, ownership and helper
outputs. `script/check_plugin_schemas.py` checks the same conformance matrix
with a standard Draft 2020-12 validator; neither replaces the other.

In topic indexes, `valid` is Host semantic acceptance. An optional `schema_valid`
records shape-only acceptance for constraints the Host checks, such as unique
IDs, referenced components or aggregate budgets. A schema-valid payload may
still be a required Host refusal; these negative parser assertions remain.
