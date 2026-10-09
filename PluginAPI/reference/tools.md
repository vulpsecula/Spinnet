# Reviewed Homebrew reads (Plugin API Level 2)

`spinnet.tools.read(input)` reads existing local Homebrew data. `tools.startTask` remains reserved (#88). Both calls and once-only visible-page sources are offered; sources follow the [visible-page lifecycle](sources.md).

`spinnet.tools.read.source(id, input, {deliver: true})` builds a page source with the same input and result as a call. `deliver` is optional and may select a result pointer. A source has a **15 second** deadline including admission and all subprocesses. It samples once, refuses `every`, and stops its process group on hide, close, owner invalidation or revocation, discarding late results. A successful source does not repeat on hide/show; a cancelled incomplete source may resume when shown. Source definitions added in non-gesture answers wait at least one second before sampling. This grants no background schedule or additional authority. Its four typed tool failures appear in `source_delivered.failure` when delivery is requested.

Declare `read_reviewed_tools` with a concrete `capability_scopes` entry. Its `reviewed_tools` array names `{"tool":"homebrew","operations":["installed","outdated","search","info"],"kinds":["formula","cask"]}`. Limit either list to the operations and kinds the Command needs. Scope changes invalidate the previous grant. A request without `kind` reads both kinds and needs both authorized. Out-of-scope requests end the invocation before discovery or process launch.

Every input has `tool: "homebrew"` and one `operation`:

| Operation | Other input | Result |
| --- | --- | --- |
| `installed` | `kind?` | Installed formulae and casks, including the user's existing taps |
| `outdated` | `kind?`, `greedy?` | Outdated records; greedy includes self-updating casks, off by default |
| `search` | `query`, `kind?` | Matching names and their kinds from locally available catalogues/taps |
| `info` | `kind`, `names` | Exact details; unknown bare names in `not_found` |

Names are unique bare lowercase tokens, `^[a-z0-9][a-z0-9+_.@-]*$`, at most 64 characters, 1–50 per info read. Search queries are 2–64 characters matching `^[a-z0-9+_.@][a-z0-9+_.@-]*$`. Flags, paths, tap-qualified input, regex search, executable names and environment input are refused. All output names may be qualified when Homebrew resolves an existing third-party tap. Reads use Homebrew's trust checks and never run `tap` or `trust`.

The Host discovers `/opt/homebrew/bin/brew` then `/usr/local/bin/brew` on every read, checks the regular executable's ownership and write permissions and permits at most one symlink within that prefix. PATH and custom prefixes are unsupported. A Plugin stays in the Library when Homebrew is missing; the read's guidance names Homebrew and [brew.sh](https://brew.sh).

The Host constructs the environment, enables `HOMEBREW_NO_AUTO_UPDATE`, `NO_ANALYTICS`, `NO_GITHUB_API`, `NO_SUDO`, `NO_ENV_HINTS`, `NO_COLOR`, `NO_EMOJI` and `NO_INSECURE_REDIRECT`, and passes no credentials, agent sockets or proxy variables. Homebrew's own `brew.env` files still apply. A macOS sandbox denies network to the whole process tree and writes to package prefixes, including bootstrap installation. A missing/corrupt catalogue therefore fails rather than downloading or refreshing it. Existing data is as of the user's last update. Homebrew may produce its ordinary derived caches under the user's cache directory; this service never asks it to update package catalogues.

Fixed argv are `info --json=v2 --installed [--formula|--cask]`, `outdated --json=v2 [--formula|--cask] [--greedy]`, `search --formula|--cask -- query`, and `info --json=v2 --formula|--cask -- names...`. A mixed exact-info batch that Homebrew refuses for one missing name retries the remaining names within the same deadline.

A call has a **3 second** deadline including admission and all subprocesses. One read per Plugin and two Host-wide may run; a queued read waits within its deadline. Every process has closed stdin, bounded pipes, and a separate process group; timeout/output overflow kills the group, including children left after the leader exits. The Host rechecks scope and current registration before launch and delivery, and a revocation during a read retires its result even if the user regrants access.

The result is `{tool, operation, packages, not_found?, truncated?}`. Package records contain `kind`, `name`, and optional `tap`, `official`, `title`, `description`, `version`, `installed_version`, `outdated`, `pinned`, `auto_updates`, `deprecated`, `disabled`, `needs_privileges`, `quits_app`. Only true flags are present. Search returns kind and name only. Caveats, dependencies, artifact paths, URLs, raw output and stderr never reach the Plugin. Text strips controls, redacts the home path and credential patterns, and is limited to 200 characters (versions 80). Results hold at most 2,000 packages and 512 KiB; overflow truncates with `truncated: true`. Raw stdout is capped at 4 MiB and stderr at 64 KiB.

`tool_missing`, `tool_timed_out`, `tool_failed` and `output_too_large` are catchable JavaScript errors with `error.code` and a bounded Host message. A Plugin may render a guidance page. Permission denial is governed by the ordinary Capability rules. Unknown packages/search misses return bounded empty results; cache failures and unrelated errors never become a false `not_found`.

Shapes: [schema](../schemas/reviewed-tools.schema.json), [types](../spinnet-level-2.d.ts). The test kit accepts recorded `tools.read` values or `PluginHostServiceError.tool(...)` failures through `RecordedHostServices(operations:)`, with real input/scope checks. See [verification evidence](../fixtures/reviewed-tools/verification.md).
