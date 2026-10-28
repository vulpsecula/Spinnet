# Plugin API reference

Start with [Host compatibility](compatibility.md) and the [interface overview](overview.md).
All compatible Plugins use the same current schemas and [TypeScript surface](../sdk/spinnet.d.ts).

| Topic | Reference | Machine-readable contract |
| --- | --- | --- |
| Identity, Commands, Preset, configuration and migrations | [Manifest](manifest.md) | [Manifest schema](../schemas/manifest.schema.json) |
| Publishing Plugin Updates from GitHub Releases | [Update Source](update-source.md) | [Manifest schema](../schemas/manifest.schema.json), [types](../sdk/update-source.d.ts), [version selection](../fixtures/update-source/index.json) |
| Host Service IDs, entry points and authority | [Namespaces](namespaces.md), [Host Services](host-services.md) | [Catalogue](../catalogue.json), [catalogue shape](../schemas/catalogue.schema.json), [inputs/results](../schemas/namespaces.schema.json) |
| Script globals, answers, failures and helper protocol | [Scripts](scripts.md) | [Current SDK](../sdk/spinnet.d.ts), [SDK runtime](../sdk/spinnet.js) |
| Form/detail Plugin Views | [Views](views.md), [SDK builders](sdk.md) | [Views](../schemas/plugin-view.schema.json), [sessions](../schemas/view-session.schema.json), [fetched sections](../schemas/host-fetched-section.schema.json) |
| Pages, Collections, identity and styling | [Pages](pages.md) | [Pages schema](../schemas/pages.schema.json) |
| Adaptive cards and viewport fit | [Adaptive layout](adaptive-layout.md) | [Adaptive schema](../schemas/adaptive-layout.schema.json) |
| Requested Host Operations and outcomes | [Host operations](host-operations.md) | [Operations schema](../schemas/host-operations.schema.json) |
| Visible-page observations and delivery | [Sources](sources.md), [activity cadence](activities.md) | [Sources schema](../schemas/host-run-sources.schema.json) |
| App Targets, Quit and Close | [Apps](apps.md) | [Namespace inputs/results](../schemas/namespaces.schema.json) |
| Local Spotify and connection setup | [Spotify](spotify.md) | [Playback](../schemas/spotify.schema.json), [controls](../schemas/spotify-controls.schema.json), [connections](../schemas/external-app-connections.schema.json) |
| Keep-awake Effects | [Keep awake](keep-awake.md) | [Namespace inputs/results](../schemas/namespaces.schema.json) |
| Reviewed Homebrew data and Tasks | [Tools](tools.md), [management reads](homebrew-management-reads.md), [Tasks](reviewed-tasks.md), [Services surface](services-surface.md) | [Reviewed tools](../schemas/reviewed-tools.schema.json), [management reads](../schemas/homebrew-management-reads.schema.json) |
| Unused dependencies | [Autoremove](homebrew-autoremove.md) | [Autoremove schema](../schemas/homebrew-autoremove.schema.json) |
| Terminal handoff | [Terminal Homebrew](terminal-homebrew.md) | [Terminal arguments](../schemas/terminal-homebrew.schema.json) |
| Native command output and Task transcripts | [Command output](command-output.md) | [Output schema](../schemas/command-output.schema.json) |
| Separately scoped catalog refresh | [Catalog refresh](catalog-refresh.md) | [Refresh schema](../schemas/catalog-refresh.schema.json) |
| System authentication and recovery | [Homebrew authorization](homebrew-system-authorization.md) | Reviewed tool admission and ownership still apply |
| Constraints and reasons | [Scope](scope.md) | Authority remains independent of compatibility |

[Contract fixtures](../fixtures/README.md) include deterministic accepted/refused
payloads and type-check examples with intentional errors. Shared budgets are
also asserted by Host tests. Native permissions and real system effects need
separate acceptance.
