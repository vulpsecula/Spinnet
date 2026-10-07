# Reviewed tools and tasks (draft for a later Level 2 addition)

> **PROPOSAL ONLY (#72).** No Host offers anything on this page. It is the
> draft of the reference page #87 and #88 would publish as
> `PluginAPI/reference/tools.md` when they add these operations to Level 2.
> Product choices P1-P20 of [`design.md`](design.md) are written here as
> recommended and may change.

A Plugin may read the user's Homebrew packages and, after the user confirms
in a Host-drawn dialog, install or upgrade one of them as a **task** the Host
runs and owns. The Host runs Homebrew itself, from a fixed location, with a
fixed argv and environment; a Plugin never names a command, a flag, a path,
a tap or an environment variable. Shapes are in
[`reviewed-tools.schema.json`](reviewed-tools.schema.json), types in
[`reviewed-tools.d.ts`](reviewed-tools.d.ts).

## Capabilities

| Capability | Lets a Plugin | Group |
| --- | --- | --- |
| `read_reviewed_tools` | `tools.read` | Reads |
| `run_reviewed_tool_tasks` | `tools.startTask` | Changes |

Each needs a `capability_scopes` entry with `reviewed_tools`, naming the
tool, the operations its Commands use and the kinds:

```json
{
  "capability": "run_reviewed_tool_tasks",
  "command_ids": ["packages"],
  "data_types": [], "includes_existing_host_data": false, "https_hosts": [], "external_apps": [],
  "reviewed_tools": [{"tool": "homebrew", "operations": ["install", "upgrade"], "kinds": ["formula", "cask"]}]
}
```

`activities.list` and `activities.stop` need no Capability: they reach only
the Plugin's own tasks.

## Homebrew

The Host uses `/opt/homebrew/bin/brew`, else `/usr/local/bin/brew`, and
nothing else; `PATH` is never searched. Without either, every operation
fails with `tool_missing`. The Host never installs Homebrew, never runs
`brew update`, `tap`, `trust`, `uninstall`, `cleanup`, `services`, `doctor`
or any other command, never uses `sudo`, and closes Homebrew's input.
Homebrew's own configuration files (`brew.env`) still apply.

Data comes from what Homebrew last fetched: Spinnet does not refresh it.

## `tools.read`

A call: `spinnet.tools.read(input)` returns a result within 3 s or fails
with `tool_timed_out`.

| `operation` | Input | Returns |
| --- | --- | --- |
| `installed` | `kind?` | every installed package, any tap |
| `outdated` | `kind?`, `greedy?` | installed packages with a newer version; `greedy` adds casks that update themselves |
| `search` | `query` (2-64 of `a-z 0-9 + _ . @ -`, not starting with `-`), `kind?` | names in the official catalogue: `kind` and `name` only, at most 2,000, `truncated` beyond |
| `info` | `kind`, `names` (1 to 50) | details of each, `not_found` for names Homebrew does not know |

Every input also has `tool: "homebrew"`. A package name is lowercase
letters, digits and `+ _ . @ -`, starting with a letter or digit, at most 64
characters, and never tap-qualified.

Each package is `{kind, name, tap?, official?, title?, description?,
version?, installed_version?, outdated?, pinned?, auto_updates?,
deprecated?, disabled?, needs_privileges?, quits_app?}`; flags that do not
hold are absent. A package from a tap other than `homebrew/core` or
`homebrew/cask` has a qualified `name` (`user/repo/name`) and no
`official`.

At most one read per Plugin runs at a time; a second waits within its own
timeout.

## `tools.startTask`

Only as a Requested Host Operation or a page action, on a gesture:

```js
operation: spinnet.tools.startTask.operation(
  { tool: "homebrew", operation: "install", kind: "formula", name: "wget" },
  { id: "install-wget", notify: true })
```

Before anything runs, the Host checks the package and refuses with
`package_not_found`, `source_not_allowed` (not from `homebrew/core` or
`homebrew/cask`), `needs_privileges` (a cask whose installer needs an
administrator), `already_installed`, `not_outdated`, or `tool_busy` when any
Homebrew task is running. Then it shows a Host Confirmation it words
itself: operation, package, versions, source, that dependencies may change
too, that the App quits first when it does, and that stopping does not undo
anything. The Plugin cannot skip or word it.

`operation_finished` reports the start: `succeeded` with `task`, the
handle, or `refused`, `declined`, `expired`, `cancelled`, `failed`.
`closes_view` closes the view once the task started.

## The task

A task belongs to the Host on behalf of the Plugin. Closing the view does
not stop it. It is listed in the Spinnet menu in the menu bar with a Stop
entry, whatever the Plugin does.

`spinnet.activities.list()` returns the Plugin's tasks, running first, then
those that ended in the last hour or since Spinnet launched, at most 8:
`{task, tool, operation, kind, name, state, stage?, elapsed_seconds?, log?,
result?}`. `state` is `running`, `stopping` or `ended`. `stage` is
`starting`, `fetching`, `installing`, `linking`, `finishing` or
`stopping`, read from Homebrew's output and only a hint. There is no
percentage. `log` is the last 20 lines, at most 200 characters each, with
the home folder shown as `~` and credentials removed.

`result.outcome` is `completed`, `failed`, `stopped` (with `stop`:
`interrupted`, `terminated` or `killed`), `interrupted` (Spinnet quit
unexpectedly or the user logged out; it is never resumed) or `unknown`.

While a page is visible, the Host delivers `activity_changed` with the
latest state, at most every 500 ms and on every change of state or stage
(once Host-run sources exist).

## Stopping

`spinnet.activities.stop.action({task})` or `.operation({task})`, on a
gesture. Its outcome `succeeded` means the attempt began; it is `refused`
with `task_not_found` or `task_finished` otherwise. The Host sends
Homebrew's process group SIGINT, as Control-C would, then SIGTERM and
SIGKILL if it has not ended. **Stopping never rolls anything back**: a
stopped package may be partly installed or still at its old version.

Quitting Spinnet while a task runs asks the user whether to wait for it or
attempt to stop it.

## Failures

| Category | When |
| --- | --- |
| `capability_denied` | the Capability or its scope does not cover the operation |
| `tool_missing` | Homebrew is not at either location |
| `tool_busy` | a Homebrew task is running |
| `tool_timed_out` | a read did not finish in time |
| `tool_failed` | Homebrew exited with an error |
| `output_too_large` | Homebrew printed more than the Host reads |
| `package_not_found`, `source_not_allowed`, `needs_privileges`, `already_installed`, `not_outdated` | the pre-flight check refused a task |
| `task_not_found`, `task_finished` | `activities.stop` named no running task of this Plugin |
