# Catalog refresh before browsing

Use `tools.startTask({tool:"homebrew",operation:"refreshCatalog"})`
through the existing requested-operation builder. This separately scoped Task
runs exactly `brew update`, with no package, path, flags, executable or environment
input. It updates Homebrew itself and all configured tap/package catalogs; it
does not install or upgrade installed packages or change source trust.

Declare `run_reviewed_tool_tasks`, operation `refreshCatalog`, and both `formula`
and `cask` kinds. The changed scope requires fresh user consent. That consent
allows automatic catalog updates without a per-Task Host Confirmation. An old
`update` grant does not authorize this operation. The legacy explicit `update`
Task and every package mutation retain their confirmation rules for every Plugin.

For this operation only, the page commits before Capability authorization.
The performer checks authorization before any work; a refusal is delivered as
the operation outcome so the Plugin can offer local browsing. This does not
authorize a Task or change pre-commit refusal for other operations.

An Action's start, an explicit `called` event, or a foreground Plugin Page gesture
(including a navigation field change) may request this operation. Background
sources, timers, settings changes, range loads and operation results cannot start
it. Updates are never automatically retried or replayed. A Plugin must not chain
an installation or upgrade after it: completion may only lead to fresh reads.

The ordinary Host-wide single-Task lane, current identity/scope checks at prepare
and launch, Stop, bounded output, ownership, process supervision and no-replay
recovery apply. Its `operation_finished` reports admission; follow the recorded
Task through `activities.list` to its actual end. On success invalidate earlier
catalog/detail caches before reading. On failure show the native output and let
the user explicitly retry or continue with the last locally available catalog.
Sources remain read-only and never update implicitly. Refreshing grants no new
source trust or package-mutation authority. Native Homebrew owns source loading;
the Host does not pin its private implementation files. See the
[current execution profile](homebrew-system-authorization.md).

Use the [input schema](../schemas/catalog-refresh.schema.json),
[types](../sdk/spinnet.d.ts) and [type-check contract sample](../fixtures/sdk/catalog-refresh.ts).
Compose answers with the [Current page schema](../schemas/pages.schema.json)
and [Requested Host Operation schema](../schemas/host-operations.schema.json);
visible-page sources retain the [Current source schema](../schemas/host-run-sources.schema.json).
