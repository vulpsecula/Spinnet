# Historical reviewed-tool read verification (#87)

Recorded 2026-10-09/10 at Host `7976490`, Homebrew 7.0.9-6-g96d7c8b,
macOS 27, Apple silicon. These single-machine readings are historical evidence,
not current release acceptance, performance guarantees or proof of mutations.

| Read | Raw stdout | Projected result | Records | Elapsed |
| --- | ---: | ---: | ---: | ---: |
| installed, both kinds | 840,568 B | 38,925 B | 203 | 1.913 s |
| outdated casks, greedy | 4,301 B | 2,527 B | 21 | 0.519 s |
| search wget, both kinds | 21 B formula stdout | 158 B | 3 | 0.840 s |
| exact formula info, known + missing | known-name retry | 257 B | 1 + one not_found | 0.941 s |

The profile denied network and package-prefix writes. With an isolated empty
metadata cache, the read timed out after 3.008 s, killed its process group and
downloaded no catalogue. No real user cache or package was changed.

Retained regression reasons:

- A child can hold inherited stdout after its leader exits; deadline and
  cancellation must kill the group and prevent the child's delayed marker.
- Reads project bounded records, canonical missing-name results, kinds and
  scoped operations; shell/path/tap-shaped input is refused before execution.
- Once-only `tools.read` sources cancel on hide, drop late results and resume
  incomplete reads without a second helper invocation for the binding.
- Out-of-scope optional reads remain terminal and never discover Homebrew;
  a valid denied optional grant remains catchable.
- Revocation/regrant retires old data. Current bounds and wire shapes belong to
  [Reviewed tools](../../reference/tools.md), [Sources](../../reference/sources.md)
  and the adjacent fixtures, checked by the current contract/budget tests.

No second Mac without Homebrew was available; missing-tool behavior was injected
at the public fixture seam. An external temporary package exercised public imports
but was not pinned to final integration, so it is not a reproducible current
artifact. Mutation, cancellation of real mutations and installed-app UX were
outside this report. Old temporary logs are not current validation requirements.
