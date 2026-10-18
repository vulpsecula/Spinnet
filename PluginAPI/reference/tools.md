# Reviewed Homebrew reads (Plugin API Level 2)

`spinnet.tools.read(input)` reads existing local Homebrew data. Mutation uses the separate reviewed `tools.startTask` profile. Both calls and once-only visible-page sources are offered; sources follow the [visible-page lifecycle](sources.md).

`spinnet.tools.read.source(id, input, {deliver: true})` builds a page source with the same input and result as a call. `deliver` is optional and may select a result pointer. A source has a **15 second** deadline including admission and all subprocesses. It samples once, refuses `every`, and stops its process group on hide, close, owner invalidation or revocation, discarding late results. A successful source does not repeat on hide/show; a cancelled incomplete source may resume when shown. Source definitions added in non-gesture answers wait at least one second before sampling. This grants no background schedule or additional authority. Its four typed tool failures appear in `source_delivered.failure` when delivery is requested.

Declare `read_reviewed_tools` with a concrete `capability_scopes` entry. Its `reviewed_tools` array names `{"tool":"homebrew","operations":["installed","outdated","search","info"],"kinds":["formula","cask"]}`. Limit either list to the operations and kinds the Command needs. Scope changes invalidate the previous grant. A request without `kind` reads both kinds and needs both authorized. Out-of-scope requests end the invocation before discovery or process launch.

Every input has `tool: "homebrew"` and one `operation`:

| Operation | Other input | Result |
| --- | --- | --- |
| `installed` | `kind?` | Installed formulae and casks, including the user's existing taps |
| `outdated` | `kind?`, `greedy?` | Outdated records; greedy includes self-updating casks, off by default |
| `search` | `query`, `kind?` | Matching names and their kinds from locally available catalogues/taps |
| `info` | `kind`, `names` | Exact details; unknown selected names in `not_found` |

Names are unique bounded package identities: bare lowercase tokens or `owner/tap/name`, at most 160 characters, 1–50 per info read. Search queries are 2–64 characters matching `^[a-z0-9+_.@][a-z0-9+_.@-]*$`. Flags, paths, regex search, executable names and environment input are refused. All output names may be qualified when Homebrew resolves an existing third-party tap. Reads retain persistent Homebrew source trust, disable the qualified-argument temporary trust exception before loading definitions, and never mutate taps or trust. A qualified Plugin selector is not an explicit user trust decision.

The Host discovers `/opt/homebrew/bin/brew` then `/usr/local/bin/brew` on every read, checks the regular executable's ownership and write permissions and permits at most one symlink within that prefix. PATH and custom prefixes are unsupported. A Plugin stays in the Library when Homebrew is missing; the read's guidance names Homebrew and [brew.sh](https://brew.sh).

The Host constructs the environment, enables `HOMEBREW_NO_AUTO_UPDATE`, `NO_ANALYTICS`, `NO_GITHUB_API`, `NO_SUDO`, `NO_ENV_HINTS`, `NO_COLOR`, `NO_EMOJI` and `NO_INSECURE_REDIRECT`, and passes no credentials, agent sockets or proxy variables. Homebrew's own `brew.env` files still apply, except they cannot disable source trust for a reviewed read. A macOS sandbox denies network and persistent filesystem writes to the whole process tree, including bootstrap installation. For Apple Bash here-documents only, it permits regular `/private/tmp/sh-thd-<digits>` temporary files and the directory writability check; arbitrary temporary paths, symlink creation and hard-link escapes remain denied. A missing/corrupt catalogue therefore fails rather than downloading or refreshing it. Existing data is as of the user's last update. Missing derived caches remain unavailable; this service cannot create them or update package catalogues. The loader adapter is bound to reviewed Homebrew source hashes and refuses a changed implementation pending review. Installed JSON history is data-only with API/Ruby fallback disabled; detached or installed Ruby history has no implicit current source authority and returns an explicit unavailable result.

Fixed argv are `info --json=v2 --installed [--formula|--cask]`, `outdated --json=v2 [--formula|--cask] [--greedy]`, `search --formula|--cask -- query`, and `info --json=v2 --formula|--cask -- names...`. A mixed exact-info batch that Homebrew refuses for one missing name retries the remaining names within the same deadline.

A call has a **3 second** deadline including admission and all subprocesses. One read per Plugin and two Host-wide may run; a queued read waits within its deadline. Every process has closed stdin, bounded pipes, and a separate process group; timeout/output overflow kills the group, including children left after the leader exits. The Host rechecks scope and current registration before launch and delivery, and a revocation during a read retires its result even if the user regrants access.

The result is `{tool, operation, packages, not_found?, truncated?}`. Package records contain `kind`, `name`, and optional `tap`, `official`, `title`, `description`, `version`, `installed_version`, `outdated`, `pinned`, `auto_updates`, `deprecated`, `disabled`, `needs_privileges`, `quits_app`. The state flags above appear only when true. Detail records also expose bounded `dependencies`, safe `homepage` and `download_url`, and installed request/dependency flags. The Host may return `installed_path`, `linked`, `linkable`, `keg_only`, `languages` and `selected_language` as described below. Search returns kind and name only. Caveats, arbitrary artifact paths, raw output and stderr never reach the Plugin. Text strips controls, redacts the home path and credential patterns, and is limited to 200 characters (versions 80). Results hold at most 2,000 packages and 512 KiB; overflow truncates with `truncated: true`. Raw stdout is capped at 4 MiB and stderr at 64 KiB.

`tool_missing`, `tool_timed_out`, `tool_failed` and `output_too_large` are catchable JavaScript errors with `error.code` and a bounded Host message. A Plugin may render a guidance page. Permission denial is governed by the ordinary Capability rules. Unknown packages/search misses return bounded empty results; cache failures and unrelated errors never become a false `not_found`.

Shapes: [schema](../schemas/reviewed-tools.schema.json), [types](../spinnet-level-2.d.ts). The test kit accepts recorded `tools.read` values or `PluginHostServiceError.tool(...)` failures through `RecordedHostServices(operations:)`, with real input/scope checks. See [verification evidence](../fixtures/reviewed-tools/verification.md).

## Management additions

The approved expanded Homebrew profile adds the typed management operations in
[management reads](homebrew-management-reads.md). The earlier four reads stay
offline; selected remote metadata has fixed disclosed destinations and bounded
HTTPS transfers. Exact info can now name a controlled tap-qualified identity,
keeping a user-selected package from resolving to another tap's same bare name.

Package directories are derived only from the Host-discovered prefix and validated installed package name/version. They must exist under Cellar or Caskroom, with no symlink escape, and are bounded to 2,048 UTF-8 bytes. Recipe-provided path strings are ignored. `linked` is optional known state; `linkable` reflects non-forced formula linking policy or installed cask binary/manpage/completion artifacts. Application-only casks are not linkable. A cask link state is omitted when declared sources or destinations cannot be resolved within reviewed prefix paths. This does not grant a Plugin arbitrary filesystem access.

Cask languages are bounded to 64 declared locales. For `info` only, the Host reads at most 64 KiB from the fixed Caskroom package configuration and checks explicit, environment, then default preferences against declared languages. `selected_language` is omitted when no saved preference establishes the choice; an unknown default is never guessed. Download URLs come from the selected formula source or cask archive metadata and accept only bounded HTTP(S) URLs without credentials.

Adoption candidates include an opaque `identity` for stable Collection selection of the same concrete App across refreshes. It differs across Plugin owners and App copies and changes when the App fingerprint changes; it reveals no path. The transient `target` remains the only adoption-preview authority. An identity grants no operation.
