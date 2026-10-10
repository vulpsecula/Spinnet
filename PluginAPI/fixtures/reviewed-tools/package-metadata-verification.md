# Package detail metadata verification — 10 October 2026

The public read boundary verifies Host-derived installed directories, formula
linking state, cask symlink artifact applicability/owned link state, saved cask
language preference, and cask download URLs. A cask application artifact alone
does not enable link/unlink. An installed-version symlink escaping Caskroom does
not publish an installed directory. Tap-qualified exact info is not mistakenly
returned in `not_found`.

The formula metadata test first failed with three missing fields; the cask
workflow then failed with five missing-state assertions. Both passed after their
respective implementation slices. A separate regression asserted the qualified
name was not missing, reproduced the old false `not_found`, then passed after
canonical identity matching was corrected. The fixture index includes positive
formula/cask metadata results and rejects relative installed directories and
more than 64 declared languages.

Focused SwiftPM verification passed 25 tests: original reads, management reads,
three metadata behaviors and an actual local metadata check. The two process
group tests require execution outside the agent's nested sandbox; their fixture
children and marker files are temporary. The real Homebrew profile still denies
network and package-prefix writes. Updated contract fixtures then passed with the
three metadata tests (four tests total). Native checks read installed libtommath
and Spotify only:

| Package kind | Profile elapsed | Projected bytes |
| --- | ---: | ---: |
| formula | 0.575 s | 562 B |
| cask | 0.397 s | 455 B |

These are individual readings on this Mac, not performance guarantees. No
install, upgrade, pin, linking operation, language reinstall, source trust change
or network transfer occurred. Local evidence logs are
`/private/tmp/brew-package-metadata-final.log` and
`/private/tmp/brew-package-metadata-contract.log`.

`selected_language` remains absent when the flattened recipe languages and saved
preferences cannot establish Homebrew's chosen default. Cask `linked` remains
absent for source paths outside the reviewed Caskroom paths; cask `linkable`
still identifies supported binary/manpage/completion artifacts. A normal package
read grants no arbitrary filesystem access. Full app rendering and confirmed
mutation acceptance belong to the integration route.
