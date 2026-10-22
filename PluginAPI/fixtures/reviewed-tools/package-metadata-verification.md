# Historical package metadata verification

Recorded 2026-10-10; the original report did not pin an exact Host commit.
Twenty-five focused tests passed then. Read-only local observations of
libtommath (formula) and Spotify (cask) took 0.575 s/562 B and 0.397 s/455 B.
These single runs are regression history, not current release acceptance or
performance guarantees. No install, upgrade, linking, reinstall, trust change
or network transfer was performed.

Retained regression reasons, exercised by the current metadata tests/fixtures:

- Formula details must include Host-derived installed directories and linking
  state; cask details retain applicable owned links, language preference and
  download URLs. An application artifact alone does not permit link/unlink.
- An installed-version symlink escaping Caskroom must not publish an installed
  directory. A normal read grants no arbitrary filesystem access.
- Tap-qualified exact info must match canonical identity before `not_found`
  is calculated; this previously produced a false missing result.
- Relative installed directories and more than 64 declared languages are refused.
  `selected_language` stays absent when recipe/saved preferences cannot establish
  the selected default; cask `linked` stays absent outside reviewed paths.

Current shape/bounds live in [management reads](../../reference/homebrew-management-reads.md)
and adjacent fixtures. Temporary logs from the original run were removed from
this summary because they are not a durable reproduction path. Process-group
checks require an environment that can launch their fixture children; current
native behavior and confirmed mutations require separate current validation.
