# Proposal: reviewed Homebrew operations and task policy

> **Status: design proposal (#72), not offered by any Host.** It proposes
> later additions to Plugin API Level 2, which is still open to additions
> (see [`../../README.md`](../../README.md)), under catalogue IDs that
> [`catalogue.json`](../../catalogue.json) already reserves: `tools.read`,
> `tools.startTask`, `activities.list` and `activities.stop`. It is not a
> Candidate Contract. #87 implements the reads and #88 the tasks; the
> product choices in [`design.md`](design.md) section 14 return to the user
> first.

The Level 2 catalogue, schemas and SDK one directory up are unchanged by
this proposal.

## What it proposes

A **reviewed tool profile** for Homebrew: the Host finds `brew` at
`/opt/homebrew/bin/brew` or `/usr/local/bin/brew` only, runs it with a fixed
argv and an environment it builds from nothing (`HOMEBREW_NO_AUTO_UPDATE`,
`_NO_SUDO`, `_NO_ANALYTICS`, `_NO_ENV_HINTS` and others), validates every
package name and query, and returns typed, projected, bounded data. A
Plugin may:

- **read** installed and outdated packages, search the official catalogue
  for packages that are not installed, and get exact details of up to 50
  named formulae or casks, as a 3 s call (later also as a #71 source);
- **start a task** that installs or upgrades one named package from
  `homebrew/core` or `homebrew/cask`, after a pre-flight check and a Host
  Confirmation, as a Requested Host Operation; the Host owns the task,
  which survives its view, runs one at a time Host-wide, reports
  indeterminate stages and a redacted log tail, and can be stopped, by a
  SIGINT, SIGTERM and SIGKILL escalation to its process group, from the
  Plugin's view or the Status Item. Stopping never rolls back. Quitting
  Spinnet asks whether to wait or stop; a crash or logout is reported on
  the next launch and never resumed.

No shell, arbitrary argv, `sudo`, repairs, services, `update`, `tap` or
`uninstall`.

## Files

| File | Contents |
| --- | --- |
| [`design.md`](design.md) | The design: Host baseline with code references, local reads against HTTPS metadata, the profile (discovery, argv, environment, validation, formulae and casks, taps), reads, tasks (admission, ownership, stages, output), cancellation, crash/logout/recovery, owner changes, where tasks meet #71's sources and #84's effects, the contract summary and budgets, test seams, and the product choices returned to the user |
| [`reference.md`](reference.md) | A draft of the reference page #87/#88 would publish |
| [`reviewed-tools.schema.json`](reviewed-tools.schema.json) | Draft JSON Schema (draft 2020-12) for the inputs, results, requests, outcomes, activities, the `activity_changed` event and the Capability scope |
| [`reviewed-tools.d.ts`](reviewed-tools.d.ts) | Draft types and SDK members |
| [`additions.json`](additions.json) | The additions in catalogue terms, and the proposed bounds |
| [`measurements.md`](measurements.md), [`measurements.json`](measurements.json) | What was measured on this Mac with read-only commands: sizes, durations, processes, memory, stop timings, broken-pipe behaviour, formulae.brew.sh sizes |
| [`measure-brew.py`](measure-brew.py) | The read-only measurement, to rerun on another Mac |
| [`fixtures/`](fixtures/index.json) | 67 valid and invalid values and 14 behaviour scenarios |
| [`check.py`](check.py) | Checks the schema, fixtures and scenarios, holds `additions.json` to `catalogue.json` and the bounds to the Host's budget constants and to `measurements.json` |

Run `python3 PluginAPI/proposals/reviewed-tool-tasks/check.py`. Like the
other proposals' checks, it implements only the JSON Schema keywords of the
Spinnet test suite's `JSONSchemaSubsetValidator` and refuses any other.
Rerun the measurement with
`python3 PluginAPI/proposals/reviewed-tool-tasks/measure-brew.py --json PluginAPI/proposals/reviewed-tool-tasks/measurements.json`;
it runs only read commands.

## Relation to other work

- **#70/ADR 0018**: `tools.startTask` and `activities.stop` are Requested
  Host Operations; `tools.startTask` is the first that always asks a Host
  Confirmation.
- **#71** (Host-run sources, designed in parallel): slow reads and task
  status reach a visible view as sources; design section 11 lists what this
  needs from #71.
- **#84** (effects and Host activity controls): shares the owner record,
  Status Item entries, invalidation observers and `activities.*`, not the
  lifetime.
- **#81** (Progress): shows the stage, without a percentage.
- **#87**, **#88**: implement and publish this, after the product choices.

## Licence

Like the rest of `PluginAPI/`, these drafts are published under the MIT
licence in [`../../LICENSE`](../../LICENSE).
