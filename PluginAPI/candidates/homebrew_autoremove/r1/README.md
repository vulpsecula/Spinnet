# Homebrew autoremove, revision 1

Declare `api_level: 2` and `candidate_contracts: [{"name":"homebrew_autoremove","revision":1}]`.
This exact Candidate Contract adds two operations through the existing tools
namespace. It does not add them to stable Level 2. Installation, registration,
restoration and each run require the exact declaration; older Hosts refuse it.
Bundled Plugins cannot declare candidates. Pin SDK, test kit and helper to the
same exact public commit.

[Declaration](candidate.json), [schema](homebrew-autoremove.schema.json),
[types](homebrew-autoremove.d.ts), [SDK](homebrew-autoremove.js),
[fixtures](fixtures/index.json).

- `tools.read` operation `previewAutoremove`: no selector, formula scope only.
  Available as a synchronous call or one-shot Host-Run Source.
- `tools.startTask` operation `autoremove`: no selector, formula scope only.
  Available as a Requested Host Operation or standard page action, never a
  synchronous call or manifest Host Command.
- Existing generic SDK builders are extended only for a declaring Plugin.
  Calls, Sources, requests and standard actions require the candidate before
  read authority or task admission. Scope operations also require it.

`previewAutoremove` is a global, read-only formula inventory operation. It never
accepts a package selector, kind, flag or environment. Homebrew retains cask Apps
and packages installed on request while calculating now-unused dependencies.
The reviewed Homebrew 7.0.x command and dependency-analysis sources are checked
before the write- and network-denied subprocess runs. Only a complete successful
preview may lead to `tools.startTask` with operation `autoremove`; a no-op has no
mutating Task. Preview output is at most 98,304 bytes and stderr 32,768 characters;
malformed, overbound or failed output has `complete: false`, never a partial
removal list presented as authoritative.

Autoremove instead has only `{tool:"homebrew", operation:"autoremove"}`
and requires formula scope. It removes formulae installed only as dependencies
that Homebrew now considers unused; it does not clean cached downloads or remove
cask Apps. The Host obtains a fresh complete nonempty `previewAutoremove`, lists
every candidate in its own paged confirmation, and refuses no-op, incomplete or
changed results before creating a Task. The independent runner repeats the
preview before its one fixed `brew autoremove` spawn. Its task record starts with
the reviewed operation and preview output, then captures Homebrew output. No
package name, flag or shell text can be supplied by a Plugin.
