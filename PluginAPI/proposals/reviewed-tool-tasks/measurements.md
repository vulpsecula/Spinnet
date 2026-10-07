# Measurements: Homebrew reads on this machine

Recorded 2026-10-07 by [`measure-brew.py`](measure-brew.py); the raw record
is [`measurements.json`](measurements.json), and `check.py` holds the
proposed bounds to it. **Only read operations were run.** The script
refuses any subcommand outside `--version`, `--prefix`, `tap` (listing
only), `tap-info`, `list`, `info`, `outdated` and `search`, and always sets
`HOMEBREW_NO_AUTO_UPDATE=1`. Signals went only to reads the script had
started itself. Homebrew's API cache files kept the modification time they
had before the runs (15:49, from the user's own earlier `brew` use), so the
runs fetched no new catalogue data.

| | |
| --- | --- |
| Machine | Apple M1 Pro, macOS 27.0.1, arm64 |
| Homebrew | 7.0.8-38-g1b0b73c at `/opt/homebrew/bin/brew` (a regular file owned by the user; `/usr/local/bin/brew` absent) |
| Taps | `homebrew/cask` (git checkout), `hashicorp/tap`, `jlcodes99/cockpit-tools` (both trusted in `~/.homebrew/trust.json`); `homebrew/core` from the API |
| Installed | 156 formulae (155 core, 1 `hashicorp/tap`), 47 casks (46 `homebrew/cask`, 1 third-party) |
| Environment | `PATH=/usr/bin:/bin:/usr/sbin:/sbin`, `HOME`, `USER`, `LOGNAME`, `TMPDIR`, `LANG=en_US.UTF-8`, `NONINTERACTIVE=1`, `HOMEBREW_NO_AUTO_UPDATE`, `_NO_ANALYTICS`, `_NO_ENV_HINTS`, `_NO_COLOR`, `_NO_EMOJI`, `_NO_GITHUB_API`, `_NO_SUDO`, `_NO_INSECURE_REDIRECT`, all `1`; stdin `/dev/null`; own process group; cwd `/` |
| Runs | 5 per read, warm (Homebrew had been used minutes before); peak process count and RSS sampled every 50 ms on the first run |

## Reads

| Read | Exit | stdout | Median (max) | Peak processes, RSS | Items |
| --- | --- | --- | --- | --- | --- |
| `--version` | 0 | 101 B | 0.12 s (0.12) | 6, 12 MiB | |
| `--prefix` | 0 | 14 B | 0.03 s | 1 | |
| `tap` | 0 | 52 B | 0.05 s | 1 | 3 taps |
| `list --formula -1 --full-name` | 0 | 1,246 B | 0.40 s (0.62) | 3, 46 MiB | 156 |
| `list --cask -1 --full-name` | 0 | 579 B | 0.53 s (0.62) | 3, 90 MiB | 47 |
| **`info --json=v2 --installed`** | 0 | **838,359 B** | **1.41 s (1.49)** | 3, 125 MiB | 203, 4,130 B each; **35,308 B projected (174 B each)** |
| `outdated --json=v2` | 0 | 334 B | 0.91 s | 3, 111 MiB | 1 cask |
| `outdated --json=v2 --greedy` | 0 | 4,310 B | 0.72 s | 3, 97 MiB | 21 casks |
| `search lib` | 0 | 8,056 B | 0.96 s | 3, 110 MiB | 737 names |
| `search py` | 0 | 1,801 B | 0.60 s | 5, 95 MiB | 165 |
| `search --formula py` | 0 | 1,389 B | 0.94 s | 5 | 129 |
| `search --cask firefox` | 0 | 99 B | 0.51 s | 3 | 7 |
| `search wget` | 0 | 21 B | 0.47 s | 3 | 3 |
| `search zzqxnotapackage` | **1** | 0 B (57 B stderr) | 0.52 s | 3 | `Error: No formulae or casks found` |
| `search /^lib.*ssl/` | 0 | 9 B | 0.41 s | 3 | regex form accepted by Homebrew |
| `search --desc ssl` | 0 | 6,519 B | 0.46 s | 5 | 100 |
| `info --json=v2 --formula wget` | 0 | 5,761 B | 0.43 s | 3, 66 MiB | 159 B projected |
| `info --json=v2 --formula python@3.13` | 0 | 5,550 B | 0.41 s | 3 | 175 B projected |
| `info --json=v2 --formula ffmpeg` | 0 | 7,157 B | 0.43 s | 3 | 197 B projected |
| `info --json=v2 --cask firefox` | 0 | 5,081 B | 0.45 s | 3, 89 MiB | 163 B projected |
| `info --json=v2 docker` (no kind) | 0 | 2,916 B | 0.43 s | 3 | the formula only: without `--formula` or `--cask`, Homebrew picks the kind |
| `info --json=v2 --formula zzqxnotapackage` | **1** | 0 B (61 B stderr) | 0.55 s | 3 | `Error: No available formula` |
| `info --json=v2 hashicorp/tap/terraform` | 0 | 2,606 B | 0.51 s | 3 | third-party tap, evaluated because trusted |

Processes seen in the groups: `bash`, `ruby`, `curl`, `git`,
`xcode-select`, `tr`. Even reads start children, so the process group, not
the leader, is what the Host supervises.

Output is stable across runs (identical byte counts in all five). Piped
`search` output has no `==> Formulae` / `==> Casks` headings: 737 names in
one list with a blank line between kinds, so the Host must run `--formula`
and `--cask` separately to know each name's kind.

### Exact info in batches

`info --json=v2 --formula` with the first N names `search --formula lib`
returned, median of 3:

| Names | stdout | Median | Projected |
| --- | --- | --- | --- |
| 10 | 30,436 B | 0.41 s | 1,422 B |
| 50 | 157,434 B | 0.58 s | 6,829 B |
| 150 | 452,035 B | 0.64 s | 20,730 B |

Process start-up dominates: 50 names cost little more than one.

## Stopping a read

`info --json=v2 --installed`, signalled at 0.05 s (still in `brew.sh`, with
`git` running) and at 0.6 s (in Ruby), by `killpg`:

| Plan | At 0.05 s | At 0.6 s |
| --- | --- | --- |
| SIGINT | group gone in 6–8 ms, killed by the signal | gone in 9–12 ms, exit 130 (Homebrew's own `trap("INT") { exit! 130 }`) |
| SIGTERM | 1–6 ms, killed by the signal | 8 ms, exit 1 with a Ruby backtrace: Homebrew does not handle TERM as an interrupt |
| SIGKILL | ≤ 1 ms | 2–3 ms |
| SIGINT, then SIGTERM after 2 s, then SIGKILL after 2 s | SIGINT sufficed | SIGINT sufficed |

No process of the group outlived its leader in any run. Waiting for the
group needs care: an unreaped leader keeps the group present as a zombie,
and a group of only zombies answers `kill(-pgid, 0)` with `EPERM`, not
`ESRCH`, so the Host must reap the leader before probing the group.

Homebrew's source explains why SIGINT is the right first signal for a
mutation (not measured on one): `Utils::Interrupts.ignore` defers SIGINT
during clean-up ("One sec, cleaning up..."), `FormulaInstaller` restores a
previous keg when installation raises, and `SystemCommand` raises Interrupt
when a child died of SIGINT, which is what a terminal's Control-C to the
whole foreground group produces.

## The reader going away

With stdout a pipe whose reader closed after 0.2 s, `info --json=v2
--installed` exited 1 after 1.5 s with `Error: Broken pipe @
rb_sys_fail_on_write - <STDOUT>`. A task writing to a Host pipe would
therefore fail at its next write if the Host crashed (design section 9).

## HTTPS metadata from formulae.brew.sh

`curl` to `/dev/null`, against the existing 128 KiB response ceiling
(`HTTPSRequestBudgets.maximumResponseBodyBytes`):

| URL | Bytes (identity) | Bytes (gzip) | Time | Fits 128 KiB |
| --- | --- | --- | --- | --- |
| `api/formula/wget.json` | 4,781 | 1,546 | 0.41 s | yes |
| `api/formula/python@3.13.json` | 7,141 | 2,132 | 0.31 s | yes |
| `api/formula/ffmpeg.json` | 5,226 | 1,945 | 0.29 s | yes |
| `api/cask/firefox.json` | 27,585 | 7,070 | 0.33 s | yes |
| `api/cask/visual-studio-code.json` | 4,255 | 1,361 | 0.28 s | yes |
| `api/formula/zzqxnotapackage.json` | 9,379 (404 page) | 5,254 | 0.29 s | yes |
| **`api/formula.json`** | **32,037,601** | 5,219,669 | 3.1 s | **no, 244×** |
| **`api/cask.json`** | **19,064,631** | 2,069,644 | 2.0 s | **no, 145×** |
| `api/internal/packages.arm64_golden_gate.jws.json` (what Homebrew 7 itself fetches) | | 3,789,760 | 0.17–0.73 s | no |

Homebrew's local API cache holds the same catalogue: a 15.6 MB
`internal/packages.*.jws.json`, and name lists of 76,980 B (formulae) and
107,234 B (casks), 16,421 names in all, the longest 54 characters, every
one matching `^[a-z0-9][a-z0-9+_.@-]*$`.

## Installed casks that bear on tasks

From the installed listing (no task was run):

- 5 of 47 casks have a `pkg` or `installer` artifact (`logitech-g-hub`,
  `microsoft-auto-update`, `microsoft-teams`, `onedrive`,
  `tailscale-app`): installing or upgrading them needs an administrator.
- 19 have an `uninstall` `quit` stanza: upgrading them quits the running
  App first.
- 37 set `auto_updates`; `outdated` lists 1 cask, `outdated --greedy` 21.
- 15 formulae and 3 casks have caveats; 2 packages are deprecated, 1
  disabled; none is pinned.

## Not measured

Nothing that changes Homebrew was run, so these stay open for #88, in a
disposable environment (a separate macOS user or VM with its own prefix):
the duration and output volume of real installs and upgrades, how long
Homebrew's SIGINT clean-up takes mid-download and mid-pour (the 10 s and 5 s
grace periods are placeholders), `brew install --dry-run` and `brew upgrade
--dry-run` as a source for the confirmation's plan, behaviour under a
held package lock, a cold first read after login, and reads while Homebrew
refreshes its API data. A Mac without Homebrew was not available; scenario
11 describes the expected behaviour.
