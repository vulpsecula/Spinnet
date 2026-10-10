# Reviewed Homebrew Tasks (Plugin API Level 2)

`tools.startTask` is offered as a Requested Host Operation and a page
action. A Plugin Page gesture chooses concrete reviewed work; an Action's
start, a call and a source delivery cannot start a mutation. Declare the
separate `run_reviewed_tool_tasks` Capability with `reviewed_tools` scopes
listing the tool (`homebrew`), allowed operations and package kinds.

The Host validates typed input and current authority, reserves one
Host-wide slot, reads the concrete package plan and current Homebrew trust,
then draws a Host Confirmation. Cancel is the default. No task queues,
automatic update/cleanup, mutation retries or replay exist. After
confirmation the Host checks identity, scope, source trust and the exact
plan again; a changed plan is refused for review.

Inputs are defined in [reviewed-tools.schema.json](../schemas/reviewed-tools.schema.json).
Package operations name one `kind` and bounded package `name`. Tap
operations name a bounded `owner/repository`; service operations name one
user-owned formula. Cleanup has a reviewed day threshold or explicit
`pruneAll`. Zap is an explicit cask-uninstall option and its deletion
scope is disclosed. Adoption and reviewed Doctor repairs name opaque
Host-produced targets; a Plugin never supplies a command, executable,
path, shell source, environment or elevated instruction. Selected upgrades
hold 1–50 names of one kind; the Host resolves all-upgrade targets and
respects package pins before confirmation.

The start outcome reports only whether the Task started. Reopening calls
`activities.list` or declares `spinnet.activities.list.source(id,
{every: 1, deliver: true})`. This visible-page source reads own activity
state at least one second apart, without a resident Plugin helper.
The latest result may show stages, elapsed seconds and at most 20 redacted
lines of 200 characters. Task stages are hints, progress is indeterminate.
Closing or hiding a view never stops a Task. A Task's eventual end does
not invoke a viewless Plugin script.

Tasks are `running`, `stopping`, then `ended` with `completed`, `failed`,
`stopped`, `interrupted` or `unknown`. Stop means an attempt, never a
rollback. The independent signed Host runner owns the process group and
journal; SIGINT has a 10-second grace, SIGTERM a further 5 seconds, then
SIGKILL. Escaped descendants found by kernel identity are signalled too;
processes handed to an App or launchd lie outside this Task. These grace
values remain provisional until real disposable-environment cancellation
measurements. The runner holds only idle-system sleep prevention; explicit
Sleep, lid closure and low-battery sleep still apply.

The runner continues confirmed work if the Host crashes and writes its
result. Recovery reads the journal and validates process start identities.
It never runs a saved mutation again. A missing runner/result is shown as
interrupted or unknown, with no fabricated success. The Host preserves a
Stop control for detached work after revocation, disable or removal; the
Plugin receives nothing more. Same-scope updates may retain ownership;
scope changes detach it. Normal exit offers Wait and Quit (default), Stop
and Quit, or Don't Quit, with no logout timeout. Waiting keeps Stop
available. Ended Tasks are retained for an hour, within the existing
8-activity-per-Plugin limit.

Output removes ANSI/control sequences, home paths, URL userinfo/query
strings and credential-key/Authorization forms before journal publication.
Complete line handling prevents a secret split over OS reads leaking.
The runner keeps no Plugin helper alive. `HOMEBREW_NO_SUDO=1` remains on
for nonprivileged work; administrator operations require the separately
reviewed system-authorization route after Host Confirmation.

Typed refusals include `tool_busy`, `package_not_found`,
`source_not_allowed`, `already_installed`, `not_outdated`,
`task_not_found`, `task_finished` and `plan_changed`. Existing effect Stop
semantics remain an idempotent no-op for absent effect handles.
