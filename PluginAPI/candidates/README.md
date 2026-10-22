# Candidate Contracts

Stable Levels 1–7 are the current [Plugin interface](../README.md). No candidate revision is currently provided. A candidate declaration uses an exact name and revision; it is not a stable Level and grants no authority. Bundled Plugins use stable Levels only.

## Declaration and refusal

The [declaration schema](schemas/candidate-contracts.schema.json) describes `candidate_contracts`; the [metadata schema](schemas/candidate-metadata.schema.json) describes each retained `candidate.json`. The stable manifest schemas refuse `candidate_contracts`.

Installation, registration and each scripted run check unsupported Levels, Bundled Plugin candidate declarations, retirement, exact revision, base Level, required candidates and conflicts. Refused Plugins retain their data and unavailable Menu Items until replacement or removal; refusal does not silently remove them. Host Service access is still restricted to declared stable Levels and any admitted candidates.

A retired revision is refused with the stable Level to declare instead. Migration means setting that `api_level` and omitting `candidate_contracts`; retirement never changes earlier stable vocabulary. The metadata retains member sets and historical tag identifiers for refusal, promotion and compatibility tests. Old SDK/schema/proposal copies have been replaced by current stable contracts and equivalent fixtures; Git history preserves their original commits.

## Candidate Contracts this Host provides

| Candidate | Revision | Base Level | Reference |
| --- | --- | --- | --- |
| None | — | — | — |

## Retired candidate declarations

| Candidate | Revision | Became | Tag |
| --- | --- | --- | --- |
| [`adaptive_layout`](adaptive_layout/r1/candidate.json) | 1 | [Plugin API Level 3](../reference/level-3.md) | `plugin-api-candidate/adaptive_layout/r1` |
| [`adaptive_layout`](adaptive_layout/r2/candidate.json) | 2 | [Plugin API Level 3](../reference/level-3.md) | `plugin-api-candidate/adaptive_layout/r2` |
| [`collections`](collections/r1/candidate.json) | 1 | [Plugin API Level 2](../reference/pages.md) | `plugin-api-candidate/collections/r1` |
| [`collections`](collections/r2/candidate.json) | 2 | [Plugin API Level 2](../reference/pages.md) | `plugin-api-candidate/collections/r2` |
| [`collections`](collections/r3/candidate.json) | 3 | [Plugin API Level 2](../reference/pages.md) | `plugin-api-candidate/collections/r3` |
| [`external_app_connections`](external_app_connections/r1/candidate.json) | 1 | [Plugin API Level 3](../reference/level-3.md) | `plugin-api-candidate/external_app_connections/r1` |
| [`homebrew_autoremove`](homebrew_autoremove/r1/candidate.json) | 1 | [Plugin API Level 3](../reference/level-3.md) | `plugin-api-candidate/homebrew_autoremove/r1` |
| [`homebrew_catalog_refresh`](homebrew_catalog_refresh/r1/candidate.json) | 1 | [Plugin API Level 7](../reference/level-7.md) | `plugin-api-candidate/homebrew_catalog_refresh/r1` |
| [`homebrew_command_output`](homebrew_command_output/r1/candidate.json) | 1 | [Plugin API Level 6](../reference/level-6.md) | `plugin-api-candidate/homebrew_command_output/r1` |
| [`host_operations`](host_operations/r1/candidate.json) | 1 | [Plugin API Level 2](../reference/pages.md) | `plugin-api-candidate/host_operations/r1` |
| [`host_operations`](host_operations/r2/candidate.json) | 2 | [Plugin API Level 2](../reference/pages.md) | `plugin-api-candidate/host_operations/r2` |
| [`live_activity_delivery`](live_activity_delivery/r1/candidate.json) | 1 | [Plugin API Level 4](../reference/level-4.md) | `plugin-api-candidate/live_activity_delivery/r1` |
| [`namespaces`](namespaces/r1/candidate.json) | 1 | [Plugin API Level 2](../reference/pages.md) | `plugin-api-candidate/namespaces/r1` |
| [`spotify_controls`](spotify_controls/r1/candidate.json) | 1 | [Plugin API Level 3](../reference/level-3.md) | `plugin-api-candidate/spotify_controls/r1` |
| [`terminal_homebrew`](terminal_homebrew/r1/candidate.json) | 1 | [Plugin API Level 5](../reference/level-5.md) | `plugin-api-candidate/terminal_homebrew/r1` |
