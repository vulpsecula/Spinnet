# #87 verification — 2026-10-09

Host source baseline `7976490`; Homebrew 7.0.9-6-g96d7c8b, macOS 27, Apple silicon. Only read operations were run. Each real subprocess used the fixed profile environment, network denial and package-prefix write denial. No mutation, Homebrew installation, tap/trust operation or catalogue refresh was requested.

| Read | Raw stdout | Projected result | Records | Profile elapsed |
| --- | ---: | ---: | ---: | ---: |
| installed (both kinds) | 840,568 B | 38,925 B | 203 | 1.913 s |
| outdated casks, greedy | 4,301 B | 2,527 B | 21 | 0.519 s |
| search wget, both kinds | 21 B formula stdout | 158 B | 3 | 0.840 s |
| exact formula info, wget + an unknown name | first batch empty, then known-name retry | 257 B | 1, plus one not_found | 0.941 s |

These are single runs on this Mac, not performance guarantees. Profiles include process startup and projection. Empty metadata cache was isolated in a temporary home/cache directory: the real profile timed out after **3.008 s**, stopped its process group and **downloaded no catalogue**. A separate sandbox-only read with the longer diagnostic deadline exited 1 after 4.576 s; network resolution was denied and the catalogue remained absent. Neither check altered the user's real metadata cache.

Native subprocess regression launches a fixture with a child holding inherited stdout after its leader exits. Deadline failure kills the group; the child's delayed marker is absent. Public profile tests cover installed/third-party-tap projection, outdated casks, mixed missing-name info, invalid shell/path/tap inputs, scoped kinds/operations, bounded raw output and process deadlines. The real-helper public package covers List rendering, typed missing-tool recovery and revocation followed by regrant retiring old data. Catalogue consistency and schema fixtures cover the published shapes.

An independent project at `/private/tmp/brew87-public-package` uses only `SpinnetCore` and `SpinnetPluginTestKit` public imports plus copied Plugin SDK fixture scripts. Its Measure executable runs actual Host profile reads; its external tests record lists and all four typed read failures through the real helper. The project must pin the final integration revision before archival or reuse.

Limits: no second Mac without Homebrew was available; missing-tool behavior is injected at the public fixture boundary and executable discovery is fixed-path only. Homebrew mutation and long-task cancellation remain #88; the final Homebrew Plugin UX remains #93. The full native app build and integrated suite belong to the integration branch.

Review fixes (10 October 2026) add the once-only `tools.read` source after #82.
The real-helper package builds its published source, then recorded Host sampling
renders its projected name and delivers a typed missing-tool failure without
another helper invocation. The real broker source adapter passes a 15-second
deadline, forwards cancellation on hide, drops the late result and resumes an
incomplete read after the one-second floor. A native subprocess fixture verifies
cancellation kills a child still holding stdout after its leader has exited;
its delayed marker is absent. Optional out-of-scope reads remain terminal with
both granted and denied grants and never discover or launch Homebrew. A valid
denied optional grant remains catchable. Literal budget guards quote the committed
source and tool reference pages in `DocumentedBudgetsTests`.
