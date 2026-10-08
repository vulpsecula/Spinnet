# Design: reviewed Homebrew operations and task policy

Issue #72, part of #47, governed by spec #68; unblocks #87 (reads) and #88
(tasks). Proposal only; see the [README](README.md) for status. Host
baseline inspected: `c440132` (Plugin API Level 2, still open to additions).
Measured on Homebrew 7.0.8 on an M1 Pro: [`measurements.md`](measurements.md).

The draft public contract is [`reference.md`](reference.md),
[`reviewed-tools.schema.json`](reviewed-tools.schema.json),
[`reviewed-tools.d.ts`](reviewed-tools.d.ts) and
[`additions.json`](additions.json); [`fixtures/`](fixtures/index.json) holds
valid and invalid values and fourteen behaviour scenarios, and
[`check.py`](check.py) checks all of them. Section 14 lists the product
choices this design returns to the user instead of deciding them.

## 1. Problem and scope

#68 asks for a Homebrew Plugin that browses installed and outdated packages,
finds packages that are not installed, and lets the user explicitly install
or upgrade one chosen package, with the work owned by the Host so it
survives the view (ADR 0017). It also excludes, permanently for this
profile: arbitrary shell or process execution, `sudo`, repairs (`doctor`,
`fix`), services, and tap policy the user has not approved.

This design gives the Host one **reviewed tool profile**, Homebrew's, the way
the Host ships one Reviewed App Interface for Bob (ADR 0012): the Host owns
the executable, the argv, the environment, input validation and the output
it returns; the Plugin chooses only among typed operations. Adding a second
tool (npm, mas, pipx) would be a Host release. It is a starting point with
one adapter, as ADR 0012's was.

It fills four IDs `catalogue.json` reserves today, under the `tools` and
`activities` namespaces (`HostServiceCatalogue.swift:299-302`):

| ID | What | Owner |
| --- | --- | --- |
| `tools.read` | One read of the profile: installed, outdated, search, info | #87 |
| `tools.startTask` | One install or upgrade of one package, as a Host-owned task after a Host Confirmation | #88 |
| `activities.list` | The Plugin's own running and recently ended tasks (and #84's effects) | #88, #84 |
| `activities.stop` | An attempt to stop one of them; never a rollback | #88, #84 |

## 2. Baseline: what the Host does today

| Behaviour | Where | Consequence |
| --- | --- | --- |
| A script invocation has 4 s; a Host-Fetched Section 15 s; a script's `http.request` 3 s and 128 KiB | `ScriptedActionBudgets.actionDeadline` (l. 23), `.hostFetchedSectionDeadline` (l. 91); `HTTPSRequestBudgets.timeout`, `.maximumResponseBodyBytes` (`PluginHTTPSRequest.swift` l. 21, 29) | A read called from a script gets 3 s like `http.request`; a slower read belongs to a Host-run source (section 6.1) |
| One helper message is at most 1 MiB, a view 256 KiB | `ScriptedActionBudgets.maximumMessageBytes`, `.viewDescriptionBytes` | Homebrew's own JSON (838 KB for 203 installed packages) must be projected by the Host (section 6.3) |
| The Host already runs fixed executables: `/usr/bin/shortcuts` with a fixed argv, a 4 s timeout and `SIGKILL` to the one pid | `HostServices.swift` l. 135-155 (`shortcutExecutionTimeout`, l. 46) | Prior art for a fixed path and argv; but it signals the leader only, which would orphan Homebrew's `curl`, `git` and `ruby` children (section 8) |
| Helpers are supervised with `SIGKILL` and polled to exit without a nested run loop | `PluginHelperProcess.terminate` / `.waitForExit` (`PluginHelperPool.swift` l. 466-505) | The polling approach carries over; the signal must go to the group, and the leader must be reaped before probing it |
| A Requested Host Operation commits with its answer, is re-authorized at execution, has one outstanding slot per Plugin, and reports one outcome, including after its view closed (r2) | `HostOperationRequests` (`isBusy`, `commit`, `ownerEnded`, l. 113-170, 222) and `HostOperationOutcome`/`HostOperationReason` (`HostOperations.swift` l. 271-340) | `tools.startTask` is just another request kind: its outcome is "the task started", and the task's own end is reported separately (section 7.6) |
| No Host Confirmation exists yet (`host.confirm` reserved; no Level 2 operation asks one) | ADR 0018; `catalogue.json` | `tools.startTask` is the first operation that always asks one (P6) |
| Sessions end on close, update, disable, removal and revocation | `PluginViewSessions.observe` (`PluginViewSession.swift` l. 779-783) | Tasks do not end with the session (ADR 0017); section 10 says what does happen |
| The Status Item has only Settings and Quit; nothing owns effects or tasks yet | `StatusItemController.swift`; `main.swift` l. 427 | #84 builds the activity entries and owner machinery; this design states what a task needs from them |
| Quitting answers `.terminateNow` unconditionally | `ApplicationDelegate.applicationShouldTerminate`, `main.swift` l. 354 | The wait-or-stop dialog goes here (section 8.4) |
| `system.keepAwake` (#84) and `system.metrics` (#86) are reserved; sources are #71's | `HostServiceCatalogue.swift` l. 267-268 | Shared machinery, different lifetimes (section 11) |

## 3. Vocabulary used here

- **Reviewed tool profile** (proposed glossary term, section 15): the Host's
  reviewed description of the operations one command-line tool may run for
  Plugins, with the executable's location, the argv and environment of each
  operation, input rules and output bounds. Adding one is a Host release.
- **Read**: an operation of a profile that changes nothing Homebrew keeps;
  bounded by a timeout and returned as typed data.
- **Task**: a Host-owned run of one mutating operation of a profile on one
  package, which outlives the view that started it. It has a handle, a
  state, a stage, a bounded log and, once ended, a result.
- **Stop attempt**: signalling a task's process group. It ends the run; it
  does not undo what Homebrew already changed.

## 4. Local reads compared with HTTPS metadata

| Need | `brew` read | formulae.brew.sh HTTPS | Choice |
| --- | --- | --- | --- |
| What is installed, at which version, outdated, pinned | Only `brew` knows (`info --installed`, `outdated`): 1.41 s, 838 KB raw | Not available: the API knows the catalogue, not this Mac | Local |
| Search names | `search`, 0.4-1.0 s, names only | Only whole catalogues: `formula.json` 32 MB, `cask.json` 19 MB, 145-244 times the 128 KiB ceiling (5.2 MB and 2.1 MB gzipped, which are still over it) | Local |
| Exact details of one package | `info --json=v2 --formula -- name`, 0.43 s; 50 names in one process 0.58 s | `api/formula/<name>.json` 4.8-7.1 KB, `api/cask/<name>.json` 4.3-27.6 KB, 0.3-0.4 s each, all under the ceiling | Local by default; HTTPS is possible and useful only where Homebrew is missing |
| Consistency with what a task will install | `brew` reads the same API data the task will use | The live API may be newer than the user's local data | Local |
| Authority | `read_reviewed_tools` | `contact_https` scoped to `formulae.brew.sh`, which a Plugin may declare today without any of this design | |

Recommendation: the profile reads locally. A Plugin that wants to show
details of packages without Homebrew installed (an onboarding page, say)
can already use `http.request` against `formulae.brew.sh` for single
packages within the existing ceiling; nothing in this proposal raises that
ceiling, and full catalogues stay out of reach by design. The Host does not
read Homebrew's own cache files (`~/Library/Caches/Homebrew/api/`): their
format is Homebrew's private business, and `brew` already reads them.

Freshness: with `HOMEBREW_NO_AUTO_UPDATE=1` (required, section 5.3) a read
reflects the catalogue as of the user's last `brew update`, or Homebrew's
last own auto-update in the user's terminal. Whether Spinnet should ever
refresh it is P9.

## 5. The profile

### 5.1 Executable discovery and availability

- The Host looks at exactly two paths, in order: `/opt/homebrew/bin/brew`
  (Apple silicon default) and `/usr/local/bin/brew` (Intel default). `PATH`,
  shell aliases, `HOMEBREW_PREFIX`, `which`, login shells and every other
  location are never consulted. A custom prefix is unsupported (an open
  question only if a user asks; it would add a source).
- The path must resolve to a regular executable file owned by the user or
  root and not writable by others (`stat`, after resolving at most one
  symlink level inside the same prefix). On the measured Mac
  `/opt/homebrew/bin/brew` is a regular file owned by the user, in a
  user-owned prefix: Homebrew runs as the user, never as root.
- Discovery runs at each read and each task start, not cached across them,
  so installing or removing Homebrew needs no Host restart. A missing
  Homebrew fails the operation with `tool_missing` (scenario 11). The Host
  never offers to install Homebrew (its installer is a remote shell script)
  and never runs anything from `PATH` instead.
- Availability for the Library: a Plugin whose Commands need the profile
  stays available; a Command that reads reports Homebrew missing the way a
  missing External App is reported, with guidance naming Homebrew and
  `brew.sh`, which #87 words (P19).

### 5.2 Argv

Every argv is fixed by the Host; a Plugin supplies only the typed members of
`tools.read.input` and `tools.startTask.input`. Names and queries always
follow `--`, after which Homebrew reads arguments as names only (checked:
`info --json=v2 --formula -- --HEAD` looks up a formula named `--head`).

| Operation | Argv after the executable |
| --- | --- |
| `installed` | `info --json=v2 --installed [--formula \| --cask]` |
| `outdated` | `outdated --json=v2 [--formula \| --cask] [--greedy]` |
| `search` | `search --formula -- <query>` and `search --cask -- <query>`, one or both by `kind`; piped output has no headings, so each run fixes its kind |
| `info` | `info --json=v2 --formula -- <names…>` or `--cask`, 1 to 50 names |
| task pre-flight | `info --json=v2 --formula -- <name>` or `--cask`, the same read |
| `install` | `install --formula -- <name>` or `install --cask -- <name>` |
| `upgrade` | `upgrade --formula -- <name>` or `upgrade --cask -- <name>` |

Never offered, as an operation, a flag or an input: `update`, `tap`,
`untap`, `trust`, `uninstall`, `reinstall`, `cleanup`, `autoremove`,
`link`/`unlink`, `pin`, `services`, `doctor`, `bundle`, `sh`, `exec`,
`--build-from-source`, `--HEAD`, `--force`, `--overwrite`, `--debug`,
`--interactive`, `--cask-opts`, `--appdir` and every other option, and
`search`'s `/regex/` form.

### 5.3 Environment

The Host builds the environment from nothing:

| Variable | Value | Why |
| --- | --- | --- |
| `PATH` | `/usr/bin:/bin:/usr/sbin:/sbin` | What `bin/brew` sets anyway; no user directories |
| `HOME`, `USER`, `LOGNAME` | the user's | Homebrew's cache, logs and trust store live under them |
| `TMPDIR` | the Host's | |
| `LANG` | `en_US.UTF-8` | Stable output for stage detection and redaction |
| `NONINTERACTIVE` | `1` | Homebrew never waits for input |
| `HOMEBREW_NO_AUTO_UPDATE` | `1` | **Required.** `outdated`, `install` and `upgrade` otherwise run `brew update` first (`utils/auto-update.sh`), which changes taps and API data the user did not ask for; it also stops reads refreshing API data |
| `HOMEBREW_NO_ANALYTICS` | `1` | Spinnet sends nothing on the user's behalf |
| `HOMEBREW_NO_ENV_HINTS` | `1` | Hints in the log would advise environment changes the user cannot make through Spinnet |
| `HOMEBREW_NO_COLOR`, `HOMEBREW_NO_EMOJI` | `1` | Plain output |
| `HOMEBREW_NO_GITHUB_API` | `1` | Search never queries GitHub for other taps |
| `HOMEBREW_NO_SUDO` | `1` | Homebrew 7 never runs `sudo` (`system_command.rb`, `sudo_available?`) |
| `HOMEBREW_NO_INSECURE_REDIRECT` | `1` | No HTTPS-to-HTTP downgrade during downloads |
| `HOMEBREW_NO_INSTALL_UPGRADE` | `1` (tasks) | `install` of an installed outdated package does not silently become an upgrade; the operation is what the user confirmed |
| `HOMEBREW_NO_INSTALL_CLEANUP` | `1` (tasks, P12) | No old versions of other packages are deleted as a side effect |

Never set or passed through: `SUDO_ASKPASS` (Homebrew forwards it and would
use `sudo -A`), `HOMEBREW_GITHUB_API_TOKEN` and every other credential,
`HOMEBREW_DEVELOPER`, `HOMEBREW_NO_INSTALL_FROM_API`, `HOMEBREW_CASK_OPTS`,
`HOMEBREW_*_DOMAIN`, proxies, `SSH_AUTH_SOCK`. stdin is `/dev/null`; there
is no terminal, so Homebrew 7's ask mode only prints its plan ("The
confirmation prompt is skipped without a TTY", `env_config.rb`).

`bin/brew` loads `/etc/homebrew/brew.env`, `$HOMEBREW_PREFIX/etc/homebrew/brew.env`
and `~/.homebrew/brew.env` after this environment, and they may override it.
These are the user's (or administrator's) own Homebrew configuration; the
Host honours them and the reference says so (P18). None exists on the
measured Mac.

### 5.4 Input validation

| Input | Rule | Refuses |
| --- | --- | --- |
| package name | `^[a-z0-9][a-z0-9+_.@-]*$`, at most 64; every one of the 16,421 official names matches, the longest 54 | options (`--HEAD`), paths (`./x.rb`), URLs, tap-qualified names, spaces (two names), upper case |
| search query | `^[a-z0-9+_.@][a-z0-9+_.@-]*$`, 2 to 64 | `/regex/`, anything starting with `-`, single characters |
| kind | `formula` or `cask`; required for info and tasks | ambiguity: without a kind Homebrew picks one (`info docker` returned only the formula) |
| names per info | 1 to 50, unique | larger batches; 50 cost 0.58 s |

Validation happens in the SDK (so a script fails fast), at commit for
requests, and again in the Host before anything runs.

### 5.5 Formulae and casks

Both kinds are read and listed (P2). Casks bring two trade-offs that tasks
must handle: 5 of the 47 installed casks run `pkg` or `installer` artifacts,
which need an administrator, and 19 quit their running App before an
upgrade. The pre-flight `info` exposes both, projected as `needs_privileges`
and `quits_app`; a task refuses the first (`needs_privileges`, P3) and
states the second in its Host Confirmation (P4). `--greedy` is a read
option only, off by default (P20): with it, `outdated` lists 21 casks
instead of 1, mostly Apps that update themselves.

### 5.6 Tap policy

- **Input never names a tap.** Names are bare, so a Plugin cannot make
  Homebrew tap a repository: `brew install user/repo/name` would tap
  `user/repo` and evaluate its Ruby, which is arbitrary code.
- **Tasks act only on official taps** (`homebrew/core`, `homebrew/cask`)
  while P1 stands. The pre-flight `info` resolves the bare name and the Host
  refuses `source_not_allowed` when the package's `tap` is another. This
  matters for installed packages: on the measured Mac `terraform` resolves
  to `hashicorp/tap/terraform` (scenario 05).
- **Reads report every tap** the user already has, with `tap` and
  `official` on each record, because the listings are of the user's own
  Mac. Homebrew 7 evaluates non-official tap code only for taps, formulae or
  casks the user trusted with `brew trust` (`trust.rb`; both third-party
  taps here are trusted), so reading does not make Spinnet the first to run
  a tap's code.
- Spinnet never runs `tap`, `untap` or `trust`.

`HOMEBREW_ALLOWED_TAPS` is deprecated in Homebrew 7 and
`HOMEBREW_FORBIDDEN_TAPS` cannot express "every non-official tap", so the
pre-flight check is the Host's own enforcement, not Homebrew's.

## 6. Reads

### 6.1 Entry points and timeouts

- **Call** (`spinnet.tools.read(input)`), inside the script's invocation,
  with a 3 s timeout, the same as `http.request`'s inside the same 4 s
  deadline. Measured medians are 0.03-1.41 s, the slowest single run
  1.49 s (installed listing), so about 2× headroom on this Mac.
- **Source**, once #71 publishes sources: the Host runs a read for a visible
  page and delivers the result, with up to 15 s, the Host-Fetched Section's
  deadline. A Mac with a thousand packages, a cold start after login or a
  slow disk can exceed 3 s; the source path is what #87 should recommend
  for the installed listing. Which result delivery and provenance rules
  apply is #71's (section 11).

A read past its timeout has its process group stopped (section 8.2) and
fails `tool_timed_out`.

### 6.2 Concurrency

Reads cost 46-125 MiB of RSS each in Homebrew's Ruby (measured). They do
not count against the helper's footprint (they are the Host's children, not
the helper's), but the Host bounds them: at most one read per Plugin and two
Host-wide at a time; a further call waits for a slot within its own
timeout. Reads run while a task runs; Homebrew's per-package `flock` locks
(`lock_file.rb`) are taken by mutations only.

### 6.3 Output

- The Host reads at most 4 MiB of stdout and 64 KiB of stderr per read; more
  fails `output_too_large`. The largest measured output is 838 KB.
- It projects Homebrew's JSON into the `package` record of the schema:
  kind, name, tap, official, title, description, versions, and the flags
  that hold. That is 174 bytes per package instead of 4,130, so the 203
  installed packages are 35,308 bytes: under 256 KiB for a view and far
  under the 1 MiB message. Homebrew's other members (caveats, artifacts,
  dependencies, URLs, checksums, paths) are not passed through; a later
  addition can project more when a Plugin needs it.
- Strings are cut to 200 characters with control characters removed.
- A result holds at most 2,000 packages and 512 KiB; more sets `truncated`.
  `search lib`, the broadest measured, found 737.
- Exit status: `search` and `info` exit 1 for no match. The Host turns
  that into an empty result or `not_found`, never a failure.

## 7. Tasks

### 7.1 Starting one

A task starts only from a gesture, as a Requested Host Operation or a page
action (ADR 0018), never from a call or a Command alone (the catalogue
already says a task "acts on a package the user chose in a view"):

```js
// The answer to item_action "install" on the selected package.
return ui.showPage(page, {
  state,
  operation: spinnet.tools.startTask.operation(
    { tool: "homebrew", operation: "install", kind: "formula", name: "wget" },
    { id: "install-wget", notify: true })
});
```

At commit the Host checks shape, the gesture rule and
`run_reviewed_tool_tasks` with its scope. At execution it:

1. re-checks authority and discovers the executable (`tool_missing`);
2. checks admission: no other Homebrew task is running anywhere
   (`tool_busy`, section 7.3);
3. runs the pre-flight `info` read and refuses, before any confirmation:
   `package_not_found`, `source_not_allowed` (not an official tap),
   `needs_privileges` (a `pkg`/`installer` cask), `already_installed`
   (install), `not_outdated` (upgrade);
4. shows its Host Confirmation (P6): the operation, the package and kind,
   from-version and to-version, the source tap, that dependencies may also
   be installed or upgraded, that the App quits first where `quits_app`
   holds, and that stopping later does not undo anything. Plugin text never
   appears in it. Decline gives `declined`, no answer within the expiry
   `expired`;
5. on confirmation, spawns the task and reports `succeeded` with the task's
   handle in `operation_finished`.

Each answer requests at most one operation, so one gesture starts at most
one task on one package.

### 7.2 Ownership

A task is owned by the Host on behalf of the Plugin and the requesting
Action (its Command and configuration), not by the View Session. Closing
the view, the page changing, the helper retiring or idling out, and the
Plugin's session ending do not touch it. The Plugin addresses it only by its
opaque handle; it never learns a process ID, a path or another Plugin's
tasks.

### 7.3 Admission and concurrency

**One Homebrew task at a time, Host-wide**, across Plugins: Homebrew's
mutations take per-package locks and share dependencies, so two concurrent
installs can fail each other part-way. A second request is refused
`tool_busy` before its confirmation rather than queued (P7): a queued
mutation would start minutes later, unseen. When the user's own `brew` in
Terminal holds a lock, Homebrew fails the task, which ends `failed` with
`tool_failed`; the Host never retries.

### 7.4 States, stages and progress

`running` → `stopping` (after a stop attempt) → `ended` with a result:
`completed`, `failed`, `stopped` (with the signal that ended it),
`interrupted` or `unknown` (section 9). There is no `rolled_back`.

The stage is read from Homebrew's `==>` headings, a hint only: Homebrew's
output is not a stable interface and an unrecognised heading keeps the
current stage.

| Stage | Headings that set it (Homebrew's `ohai`/`oh1` texts in its installer sources; #88 confirms them against real task output) |
| --- | --- |
| `starting` | before the first heading |
| `fetching` | `Fetching`, `Downloading` |
| `installing` | `Installing`, `Installing Cask`, `Installing dependencies`, `Upgrading`, `Pouring`, `Moving App` |
| `linking` | `Linking`, `Caveats` |
| `finishing` | `Finishing up`, `Summary`, `Checking for dependents` |
| `stopping` | the Host's own, once a stop attempt began |

Progress is indeterminate with `elapsed_seconds`; the design never derives a
percentage (#68, #81's Progress component shows the stage).

### 7.5 Output: bounded and redacted

- The Host keeps the last 256 KiB of combined stdout and stderr per task in
  memory, while it runs and until it is no longer listed.
- Redaction, before anything is kept or shown: ANSI and other control
  sequences removed; the user's home directory replaced by `~`; URL
  userinfo (`https://user:secret@`) and query strings removed;
  `key=value` and `Authorization:` forms whose key names a token, password,
  secret or key replaced by `…`. The Host passes no credential (5.3), so
  these catch only what the user's own configuration or a server put in.
- The Plugin sees at most the last 20 lines of at most 200 characters
  (P17), in `activity.log`.

### 7.6 Telling the Plugin and the user

- `operation_finished` for `tools.startTask` reports the start only:
  `succeeded` with `task`, or a refusal, decline or expiry. It follows the
  published request rules, including delivery to a viewless invocation
  after the view closed (host_operations r2's `view_closed`).
- `activities.list` (call) returns the Plugin's running tasks first, then
  those that ended in the last hour or since the Host launched, at most 8.
  A reopened view calls it to show the running task (#68 user story 26).
- `activity_changed` (a #71 source) pushes the latest state to a visible
  view (section 11).
- The task's end is **not** delivered to a viewless invocation: a script
  would then run minutes later when the user asked for nothing. The Host's
  Status Item entry shows the end; P14 asks whether more is wanted.

## 8. Cancellation

### 8.1 Spawning so that a stop can reach every process

The Host starts Homebrew with `posix_spawn` and `POSIX_SPAWN_SETPGROUP`
(its own process group, no controlling terminal), `POSIX_SPAWN_CLOEXEC_DEFAULT`
(no Host descriptor leaks into Homebrew), default signal dispositions and an
empty mask, stdin `/dev/null`, and stdout and stderr to the task's output
(section 9). Foundation's `Process`, which `HostServices` and the helper
pool use, has no process-group option.

### 8.2 The stop attempt

1. `SIGINT` to the group: what Control-C in a terminal sends. Homebrew is
   built for it: it defers it while cleaning up and restores a previous
   keg if an install fails part-way. Reads ended within 6-12 ms.
2. If any process of the group remains after 10 s, `SIGTERM` to the group.
   Homebrew does not treat TERM as an interrupt (measured: a Ruby backtrace
   and exit 1).
3. After 5 s more, `SIGKILL` to the group.

The 10 s and 5 s are placeholders until #88 measures real installs being
stopped mid-download and mid-pour (`budgets.unmeasured` in
`additions.json`). Before each signal the Host also sweeps descendants it
can find by parent process ID that left the group, and signals them too.
Processes Homebrew hands to `launchd` or to another App (an App opened by a
cask's postflight, an Apple Event asking an App to quit) are outside the
task and are not signalled.

The group is gone once a `kill(-pgid, 0)` after reaping the leader fails;
measured: an unreaped leader keeps the group present as a zombie, and a
group of zombies answers `EPERM`.

The result is `stopped` with `interrupted`, `terminated` or `killed`, and
the Host's text says the package may be partly installed or still at its
old version. **Nothing is rolled back**; the user may run Homebrew
themselves to repair it, which Spinnet does not offer.

### 8.3 Who may stop

The user from the Host's Status Item entry (always, for any task); the
Plugin's own view through `activities.stop` as a page action or request, on
a gesture, for its own handle. A call cannot stop, and nothing stops a task
automatically except Host exit by the user's choice (8.4).

### 8.4 Normal Host exit: wait or stop

`applicationShouldTerminate` answers `.terminateLater` while a task runs and
shows the Host's dialog (scenario 07): **Wait and Quit** (proposed default,
P8), **Stop and Quit** (the stop attempt of 8.2, then quit), **Don't
Quit**. While waiting, the dialog stays to offer Stop and Quit. Reads are
simply stopped on exit; they change nothing.

## 9. Crash, logout and child processes

- **Sudden termination.** While a task runs the Host disables sudden and
  automatic termination (`ProcessInfo.disableSuddenTermination()`), so macOS
  asks it to quit at logout instead of killing it.
- **Logout, restart, shutdown.** macOS asks Spinnet to quit; the same dialog
  as 8.4 appears (P8 covers whether it should time out). If macOS ends the
  session anyway, it signals every process of the user, Homebrew included;
  the next launch reports the task `interrupted`.
- **Host crash.** Homebrew does not get a signal: it is in its own group
  with no terminal. What then happens depends on where its output goes, a
  user-visible trade-off returned as P10:
  - into a **pipe** to the Host: Homebrew fails at its next write (measured:
    `Broken pipe @ rb_sys_fail_on_write`, exit 1), at an arbitrary point,
    through the same clean-up as an interrupt;
  - into a **file**, Homebrew finishes on its own as an orphan of `launchd`,
    and its exit status is lost;
  - under a small **Host-owned runner** (a fixed executable in the app
    bundle, like the helper), which spawns Homebrew, writes its output and
    exit status to a Host-owned file, and outlives a Host crash: Homebrew
    finishes and its result is known. Recommended.
- **Recovery.** At task start the Host writes a journal entry (Plugin,
  Action, operation, package, handle, start time, process group and the
  leader's start time); it removes it when the result is recorded. At
  launch, an entry left behind is resolved without resuming anything: with
  the runner, by its status file (`completed`/`failed`), or as still
  running if the recorded process is alive with the same start time (shown
  in the Status Item with Stop, not otherwise followed); otherwise
  `interrupted` or `unknown`. The Host tells the user once, and the
  Plugin's next `activities.list` returns it. **No task is ever restarted,
  retried or replayed**, and no request is re-executed from the journal.
- **Homebrew's own state** after any of these is Homebrew's: its `flock`
  locks are released when the process dies, and an interrupted install
  leaves whatever Homebrew's clean-up left. Spinnet does not inspect or
  repair the prefix.

## 10. Owner changes and late completion

| Event while a task runs | Proposed (P11) | Alternative |
| --- | --- | --- |
| Capability revoked, Plugin disabled or removed | The task runs to its end under the Host, keeps its Status Item entry with Stop, and nothing more is delivered to the Plugin | Attempt to stop it, as 8.2 |
| Plugin updated, same scope | Ownership carries to the new version; `activities.list` still finds it | |
| Plugin updated, scope changed | As revocation | |
| Session ends, view closes, helper retires | Nothing happens to the task (ADR 0017) | |
| The task ends after its owner ended | Only the Host's entry is updated; no delivery, no invocation | |

Stopping a mutation part-way is riskier than letting a confirmed one finish,
which is why the recommendation differs from Coffee's effects, which #84
releases on revocation. Either way the user can stop it from the Status
Item.

## 11. Where tasks meet sources (#71) and effects (#84)

- **Slow reads as a source.** `tools.read` offered at #71's source entry
  point: a page declares the read, the Host runs it while the page is
  visible and delivers the projected result. The read's input (operation,
  kind, query, names, greedy) and the Plugin's `read_reviewed_tools` grant
  are all of its authority and result inputs, as #71 requires of a source
  definition; a change of any of them is a new source. Not sampled
  periodically: a Homebrew read costs about 100 MiB and a second, so it
  runs when the page is shown or its definition changes.
- **Task status as a source.** `activities.list` at the same entry point
  delivers `activity_changed`, latest-wins, at most every 500 ms and on
  every state or stage change, while the page is visible. Hiding or closing
  the view stops the source, never the task (scenario 14). This is the line
  ADR 0017 draws: visibility-bound sampling and a mutating task share
  delivery machinery but not lifetime.
- **What #71 must provide for this**: a source whose result is an ordinary
  call result (no helper running), delivery checked against page and
  requesting Action like `operation_finished`, coalescing to latest, and a
  current-state delivery when a view becomes visible again. If #71 chooses
  otherwise, `activities.list` as a call already serves reopening, and
  `activity_changed` waits.
- **Shared with #84**: the owner record (Plugin, Action, handle), the
  Status Item entry with Host-generated name, state and Stop, owner
  invalidation observers, `activities.list` and `activities.stop` over both
  effects and tasks. Not shared: lifetimes (an effect is released on
  revocation, expiry and Host exit; a task is not), and everything about
  processes.

## 12. Public contract summary

Proposed Level 2 additions (Level 2 is open while no outside Plugin
depends on it), listed in [`additions.json`](additions.json), which
`check.py` holds to `catalogue.json`:

- `tools.read` (call; source once #71 lands), input and result in the schema;
- `tools.startTask` (request, page action), always with a Host Confirmation;
  its `operation_finished` carries `task`;
- `activities.list` (call; source once #71 lands) and `activities.stop`
  (page action, request);
- the `activity_changed` View Event (with #71);
- Capabilities `read_reviewed_tools` (Reads) and `run_reviewed_tool_tasks`
  (Changes), each scoped by a `reviewed_tools` member of
  `capability_scopes` naming the tool, its operations and kinds (P5);
- failure reasons `tool_missing`, `tool_busy`, `tool_timed_out`,
  `tool_failed`, `output_too_large`, `package_not_found`,
  `source_not_allowed`, `needs_privileges`, `already_installed`,
  `not_outdated`, `task_not_found`, `task_finished`;
- SDK `spinnet.tools.read`, `spinnet.tools.startTask.operation/.action`,
  `spinnet.activities.list`, `spinnet.activities.stop.operation/.action`.

Budgets this design proposes, all new (no existing budget is changed):

| Bound | Value | From |
| --- | --- | --- |
| Read, as a call | 3 s | `http.request`'s; slowest measured read 1.49 s |
| Read, as a source | 15 s | Host-Fetched Section's deadline |
| Raw output read from Homebrew | 4 MiB stdout, 64 KiB stderr | largest measured 838 KB |
| Result | 2,000 packages, 512 KiB | Collections' 2,000 items; 174 B/package measured |
| Names per info | 50 | 0.58 s for 50 |
| Concurrent reads | 1 per Plugin, 2 Host-wide | 46-125 MiB each |
| Running tasks | 1 Host-wide | Homebrew's locks |
| Task log | 256 KiB kept by the Host; 20 lines × 200 chars to the Plugin | unmeasured for real tasks |
| Ended tasks listed | 8, for an hour or until relaunch | |
| `activity_changed` | at most every 500 ms | ADR 0007's 500 ms progress delay |
| Stop grace | SIGINT 10 s, SIGTERM 5 s, then SIGKILL | placeholders; reads 6-12 ms |

## 13. Test seams and verification for #87 and #88

- **Test kit**: recorded `tools.read` results (the shape of
  `RecordedHostServices`) and recorded task timelines (start outcome,
  `activity_changed` steps, end), so an external Plugin tests its list,
  detail and progress pages without Homebrew. The fixtures here are the
  first recordings.
- **Host tests** against a fake `brew`: the Host's discovery roots are an
  internal parameter, so tests point them at a temporary prefix holding a
  script that prints recorded output, sleeps, spawns a child, ignores
  SIGINT, or writes after its reader closes. That covers argv and
  environment exactly, timeouts, output bounds, redaction, the stop
  escalation and group sweep, the zombie-leader probe, admission, the
  journal and recovery, without touching a real prefix. These are not
  public.
- **Real Homebrew, reads (#87)**: rerun `measure-brew.py` on the frozen Host
  build's Mac and a Mac without Homebrew.
- **Real Homebrew, tasks (#88)**, in a disposable environment (a separate
  macOS user or VM with its own prefix, never the user's): install and
  upgrade a small formula and a small cask; stop each in `fetching` and in
  `installing` and record the time each signal needs; quit with a task
  running (both dialog choices); log out with a task running; kill the Host
  (and, under P10, the runner) during a task and relaunch; revoke and remove
  the Plugin during a task; hold a lock from a terminal `brew`; measure
  `install --dry-run` as the confirmation's plan.

## 14. Product choices returned to the user

User decisions (2026-10-08):

- **P1: (b).** Tasks may act on `homebrew/core`, `homebrew/cask` and taps
  the user has already trusted in Homebrew (`brew trust`); the tap is
  named in the Host Confirmation. This departs from the recommendation, so
  #88 must treat the trusted-tap list as a user-controlled source: read it
  at admission, show it, and refuse a tap that is not trusted then.
- **P8: Wait and Quit** is the default; at logout the same dialog without a
  timeout.

The other choices stay open until #87/#88; P3, P5, P10, P11 and P15 must be
answered before #88 publishes.

None of these is decided here. Each has a recommendation so #87 and #88 can
start; the user may overrule any.

| # | Question | Options | Recommendation |
| --- | --- | --- | --- |
| P1 | Which taps may tasks act on? | (a) `homebrew/core` and `homebrew/cask` only; (b) also taps the user already trusted in Homebrew (`brew trust`), with the tap named in the confirmation; (c) taps a Plugin declares in its scope, consented at install | (a). (b) and (c) are new sources whose Ruby runs with the user's rights; reads list every tap regardless |
| P2 | Are casks in scope? | (a) reads and tasks; (b) reads only, tasks formulae only; (c) formulae only | (a), with P3 and P4 |
| P3 | Casks that need an administrator (`pkg`, `installer`; 5 of 47 here) | (a) refuse with `needs_privileges`; (b) allow and let macOS ask for an administrator password through an askpass helper, a new privilege | (a). `sudo` is out of scope in #68 |
| P4 | A cask upgrade quits its running App (19 of 47 here) | (a) Homebrew's behaviour, stated in the confirmation; (b) `HOMEBREW_NO_UPGRADE_QUIT_CASKS=1`, replacing the App under its feet; (c) refuse while the App runs | (a) |
| P5 | New Capabilities | (a) `read_reviewed_tools` and `run_reviewed_tool_tasks`, scoped by tool, operations and kinds; (b) one Capability for both; (c) a Capability per tool | (a): reading the user's package list and changing their Mac are different consents |
| P6 | Host Confirmation for tasks | (a) every task, no "don't ask again", Cancel as default button, Return does not confirm; (b) allow "don't ask again for upgrades" | (a). Content as in 7.1 |
| P7 | A task requested while another runs | (a) refuse `tool_busy`; (b) queue it | (a) |
| P8 | Host exit with a running task | Default button Wait and Quit or Stop and Quit; at logout/shutdown the same dialog without a timeout, or stop automatically after N seconds | Wait and Quit; at logout the same dialog without a timeout, so nothing is stopped without the user choosing it |
| P9 | Catalogue freshness | (a) never refresh; reads say the data is as of the user's last update; (b) a reviewed `update` task with its own confirmation; (c) let Homebrew refresh API data for reads (network and cache writes per read) | (a) for the first profile |
| P10 | A Host crash during a task | (a) pipe: Homebrew fails at its next write; (b) file: it finishes, result unknown; (c) Host-owned runner: it finishes, result recorded | (c); (a) if a new executable in the bundle is unwanted |
| P11 | Revocation, disable or removal during a task | (a) let it finish detached; (b) attempt to stop it | (a) |
| P12 | Homebrew's automatic cleanup after install/upgrade | (a) off (`HOMEBREW_NO_INSTALL_CLEANUP=1`): nothing but the chosen work is changed; (b) Homebrew's default, which deletes old versions | (a) |
| P13 | Dependents upgraded by an upgrade | (a) Homebrew's default, stated generically in the confirmation; (b) `HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1`, fewer changes but possible breakage | (a); #88 measures `--dry-run` to show the actual plan |
| P14 | Telling the user a task ended with no view open | (a) the Status Item entry (and its icon state); (b) a macOS notification, a new permission; (c) a viewless invocation of the Plugin | (a) |
| P15 | Sleep during a task | (a) nothing; (b) prevent idle system sleep while a task runs, shown in its entry | (b): an install interrupted by sleep is worse than a later sleep; this is an effect the user did not ask for, hence the question |
| P16 | Longest task | (a) no limit, elapsed time shown; (b) a stop attempt after a limit | (a) |
| P17 | What the Plugin sees of the log | (a) last 20 redacted lines; (b) stage only; (c) nothing | (a) |
| P18 | The user's `brew.env` files override the profile's environment | (a) honour them, documented; (b) refuse to run while one sets a variable the profile sets | (a): it is the user's own configuration |
| P19 | Homebrew missing | (a) Commands stay available and report `tool_missing` with guidance naming Homebrew; (b) the Library marks the Plugin unavailable | (a); the Host never installs Homebrew |
| P20 | `outdated` and self-updating casks | (a) not greedy unless asked; (b) greedy by default | (a) |

Escalation summary: P1 (new code sources), P3 (privilege), P5 (new
authority) and P4, P8, P10, P11, P15 (user-visible trade-offs) need the
user's answer before #88 publishes; #87's reads need only P2, P5, P18 and
P19.

## 15. Proposed Host-internal records

The glossary gains proposed entries for Reviewed Tool Profile and Task in
`GLOSSARY.md`. Proposed ADR text and Host implementation touchpoints are in
#72's report for the Host's design notes in `docs/`, which are not part of
this repository's history.
