# Reviewed Homebrew Tasks (Plugin API Level 2)

`tools.startTask` is offered as a Requested Host Operation and a page
action. A Plugin Page gesture chooses concrete reviewed work; an Action's
start, a call and a source delivery cannot start a mutation. Level 7 adds the narrowly scoped [automatic catalog refresh](level-7.md) exception for entry and foreground navigation; package mutations keep this rule. Declare the
separate `run_reviewed_tool_tasks` Capability with `reviewed_tools` scopes
listing the tool (`homebrew`), allowed operations and package kinds.

The Host validates typed input and current authority, reserves one
Host-wide slot, reads the selected package metadata and current source trust,
then confirms the native command and selected targets. Cancel is the default. No task queues,
automatic update/cleanup, mutation retries or replay exist in Levels 2–6; Level 7 offers only the separately granted catalog refresh described above. After
confirmation the Host checks identity, scope, source trust and the selected
metadata again; a changed selection is refused for review. Canonical package names resolved
from aliases or renames are frozen in the confirmed Task, and existing canonical
item trust can authorize a package without granting its entire tap. A qualified
selector does not itself grant source trust.

New Tasks run the native Homebrew CLI as the current user. Homebrew owns
installer and uninstall behavior. Cask changes prefer system Touch ID when the
device and the user's sudo PAM configuration support it, without changing that
configuration. If sudo still needs the login password, a signed
Host-owned askpass window requests it and passes it directly to sudo. No password
enters the Plugin, Task journal or output. This replaces the earlier per-artifact
Root authorization route; no new Task requires its background daemon or private
Homebrew source hashes. See [authorization](homebrew-system-authorization.md).

Link/unlink previews show native `--dry-run` output as advice. They are not
complete filesystem manifests. No force or overwrite flag is enabled. The Host
rechecks selected package metadata and current source trust before starting,
while Homebrew determines the concrete effects when the command runs.

New Tasks report the native command's exit outcome. Recovery also retains bounded
results from the earlier native authorization route, including these fixed reasons:
`tool_failed`, `runner_refused`, `system_authorization_unavailable`,
`privileged_result_lost`, `manual_installation_required`, `restart_required`,
`logout_required` or `shutdown_required`.
`manual_installation_required` with stage `awaiting manual installation` means
a manual installer needs the user's continuation; it is a failed/incomplete
Task, never a claim that the App was installed. `restart_required` with stage
`awaiting restart` means a Host-confirmed kernel-extension removal requires
the user to restart macOS. This is also a failed/incomplete outcome; a generic
tool exit status does not create this reason. Confirmed native package installers
may likewise require restart, logout (`logout_required`, `awaiting logout`) or
shutdown (`shutdown_required`, `awaiting shutdown`). These failed/incomplete
outcomes come from authenticated Host continuation evidence; the Task never
logs out, restarts or shuts down the Mac automatically. The result does not request or
authorize automatic retry. Stopped/interrupted/unknown outcomes likewise never
replay a Task.

Inputs are defined in [reviewed-tools.schema.json](../schemas/reviewed-tools.schema.json).
Package operations name one `kind` and bounded package `name`. Tap
operations name a bounded `owner/repository`; service operations name one
user-owned formula. Cleanup has a reviewed day threshold or explicit
`pruneAll`. Zap is an explicit cask-uninstall option and its deletion
scope is disclosed. Adoption and reviewed Doctor repairs name opaque
Host-produced targets; a Plugin never supplies a command, executable,
path, shell source, environment or elevated instruction. Selected upgrades
hold 1–50 names of one kind; the Host resolves up to 2,000 all-upgrade
targets, of both kinds when no kind is given, and respects package pins
before confirmation. It freezes typed batches of at most 50 names and
executes them sequentially under the same Task. Stop prevents later
batches from starting; earlier changes remain. Neither recovery nor an
intermediate result restarts a batch.

The start outcome reports only whether the Task started. Reopening calls
`activities.list` or declares `spinnet.activities.list.source(id,
{every: 1, deliver: true})`. This visible-page source reads own activity
state at least one second apart, without a resident Plugin helper.
The latest result may show stages, elapsed seconds and at most 20 redacted
lines of 200 characters. Task stages are hints, progress is indeterminate.
When Homebrew emits a download progress bar, its latest completed
carriage-return frame replaces the current log line. Printable characters
are retained and terminal control sequences are removed before publication.
Any displayed download percentage describes that transfer, not the overall
Task; tools and operations may emit no numeric progress.
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
The runner keeps no Plugin helper alive. Its output-only PTY handles native
progress while sudo uses the separate askpass pipe. Password cancellation is a
native command failure, not a mutation retry. Existing legacy native continuation
reasons remain readable in saved results but new Tasks report the native exit
outcome. No Homebrew Ruby implementation is injected or loaded by the Host.

An opaque adoption target requires the `cask` kind in the original `adopt`
scope. Doctor targets require each resolved repair's package kind under the
original `doctorFix` scope; they do not borrow an unrelated `install`, `link`
or `cleanup` grant. A Fix All target freezes at most eight reviewed repairs
under one Host Confirmation. Unsupported guidance is never part of that set.

Typed refusals include `tool_busy`, `package_not_found`,
`source_not_allowed`, `already_installed`, `not_outdated`,
`task_not_found`, `task_finished` and `plan_changed`. Existing effect Stop
semantics remain an idempotent no-op for absent effect handles.

`changeLanguage` takes `kind: "cask"`, an installed package name and one language from the Host-projected `languages` list. The Host revalidates that choice before confirmation and execution, discloses App reinstallation, and constructs fixed `reinstall --cask --language=<choice>` arguments. It accepts no extra flags.

## Explicit global catalog update

`{tool: "homebrew", operation: "update"}` starts the fixed `brew update` Task.
It accepts no package name, kind, path or flags. Its Task grant requires both
formula and cask kinds because it updates Homebrew itself and all configured
tap/package catalogs. The Host confirmation discloses that global scope even
when the gesture came from one package. Reads never trigger this mutation;
follow the recorded Task through `activities.list`, then invalidate local
catalog/detail caches and perform fresh reads. Package operations independently
revalidate current metadata and source trust after the update.

Installed package metadata may include privilege hints. They are display
advice, not Root grants. Zap remains an explicit uninstall option disclosed
by the Host; native Homebrew determines its actual uninstall behavior.
