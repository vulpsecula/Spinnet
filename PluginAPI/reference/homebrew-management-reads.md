# Reviewed Homebrew management reads (Plugin API Level 2)

The `tools.read` Homebrew profile now supports version, taps, services, doctor,
previewInstall, previewUpgrade, previewUpgradeAll, previewLink, previewUnlink, adoptionCandidates, adoptionPreview,
vulnerabilities, vulnerabilityDetail and packageAnalytics, beside its existing
installed/outdated/search/info reads. The Plugin declares each operation and
package kind in read_reviewed_tools. Reading is separate from mutation.
Inputs are typed; no Plugin argv, URL, shell, path or environment is accepted.
Reads and previews execute documented Homebrew CLI commands inside the bounded
read-only sandbox. Homebrew owns its configuration and package-loading rules;
the Host injects no Ruby adapters and requires no internal source hashes.
See [schema](../schemas/homebrew-management-reads.schema.json) and
[types](../homebrew-management.d.ts).

| Operation | Additional input | Result fields |
| --- | --- | --- |
| version | none | version, features |
| taps | optional exact tap name | taps with actual official/trusted flags and package counts; selected tap adds at most 1,000 formula/cask package identities |
| services | none | current user's named service statuses; no file paths/account names |
| doctor | none | tier, context, findings with check identity, affected items, text/guidance/links, complete copyable commands and recognized repair targets |
| previewInstall / previewUpgrade | kind, names (1–50); upgrade also accepts greedy | packages, estimated:false, dry_run:true, succeeded, exit_status, stages, warnings, bounded stdout/stderr, summary |
| previewUpgradeAll | optional kind and greedy | same actual output for current eligible unpinned formulae and casks, grouped into explicit bounded selections |
| previewLink / previewUnlink | kind, names (exactly one) | package, complete, changes, paths, paths_fingerprint, no_op, dry_run, succeeded, diagnostics |
| adoptionCandidates | none | applications with opaque app_ selection target, name, bundle_id, version |
| adoptionPreview | target from candidates, selected cask name | opaque adoption_ review target, kind, name, summary |
| vulnerabilities | names (1–20) OR offset (0–1999), optional | checked, findings/advisories, skipped, total, offset and next_offset |
| vulnerabilityDetail | OSV advisory id | advisory detail, references and fixed versions |
| packageAnalytics | kind, names (exactly one official bare name) | analytics.install counts for 30/90/365 days |

Every result has tool, operation and version. Version-gated Doctor JSON and
vulnerability reads require Homebrew 7; older versions return available:false
and reason:requires_homebrew_7, rather than pretend the scan/report is empty.
Doctor reads the public `brew doctor --json` output. The Host does not inject
result annotations or pin private Doctor source files. Each finding retains
`check` (empty when unavailable or unrecognized), `tier`,
and at most 100 `affects` strings of at most 200 characters. Text and guidance
retain paragraphs within their existing 2,048-character bounds. `truncated`
on a finding identifies omitted text, items, links or commands. Copyable
commands retain only complete, unmodified strings: at most eight commands of
512 characters. An oversized or scrubbed command is omitted, never offered
as a shortened executable command.

Doctor's `context` identifies `scope:host`, `shell_path:not_checked` and
`directory_access:reported_paths_rechecked`. The Host's fixed subprocess PATH
does not describe the user's terminal, so Doctor's PATH advice is excluded.
The read-only sandbox remains intact. Public JSON need not include a private
Ruby check name. The Host recognizes bounded directory-access and Host PATH
message formats for context correction; unknown messages remain visible.
Recognition alone never grants a repair. For the two recognized directory-access
message formats the Host rechecks only bounded, canonical paths under the reviewed
Homebrew prefix or its user cache/log directories, without writing files.
At most 128 distinct directory checks are attempted per read. Writable paths
are removed from those findings; unknown access suppresses that finding and
its repair and increments `unverified_directory_checks`. A nonzero count
requires an incomplete-check notice, never a clean bill of health. Ownership
repair targets require confirmed access failures and the existing reviewed
ownership vocabulary; English diagnostics alone do not grant authority.

`fix_all` is an opaque Host-reviewed selection of at most eight distinct
repairs, not a Homebrew command or a promise to resolve every finding. Its
`repairs` lists the concrete titles in selection order and matches `count`.
Plugins can preview this selection before requesting Host confirmation;
neither these titles nor printed commands are executable Task inputs.
The four earlier reads remain offline. The new remote reads have fixed reviewed
routes: api.osv.dev/v1/querybatch and /v1/vulns/{id}, and
formulae.brew.sh/api/{formula|cask}/{name}.json. OSV receives installed upstream
repository identities and installed source versions/release tags; per-package
analytics sends the selected public package name. These destinations/data flows
are part of the reviewed scope the user grants. No implicit tap trust occurs.

Remote replies stop at 128 KiB each, at most 1 MiB raw network data per read;
no redirect is followed. Final results retain the existing 512 KiB bound.
Reads share the existing one-per-Plugin/two-Host concurrency limits, three-second
call and fifteen-second source deadlines. For remote/report work, use a once
visible source with the fifteen-second deadline; synchronous calls can time out.
Cancellation/revocation stop transfers and refuse late data before publication.

Vulnerability scans use actual installed source information from bounded SPDX
SBOM files below the discovered Homebrew Cellar. They never substitute today's
recipe version for the installed version. Each read checks at most twenty
installed formulae; next_offset pages the inventory. Missing/unsupported installed
source records appear in skipped. A record without a supported upstream Git
repository is not counted as checked. Results classify source-tag matches as `open`, `patched` or `unknown`. The fixed local formula metadata is bound to the installed keg by exact stable version plus Homebrew revision, following Homebrew's current-recipe applicability rule. Only that matching recipe's security patch resolutions can suppress an advisory; an older keg never inherits today's patches. Advisory aliases participate in matching. Missing recipe metadata, or an unfetched alias set needed to decide a patch match, remains `unknown`. `upgrade_available` requires an outdated unpinned package in current local metadata. The initial scan includes up to forty advisory IDs per package,
six immediate details; vulnerabilityDetail fetches further selected details.
truncated identifies an API/record bound, never a clean bill of health. This is
not a claim of exhaustive vulnerability coverage.

Install and upgrade previews use native `install --dry-run` and
`upgrade --dry-run`, without a Homebrew 7.0.x source restriction. Their stages,
warnings and bounded stdout/stderr come from Homebrew. A nonzero exit remains a
failed preview; it never becomes a successful empty result. Missing sizes remain
unknown. The Host rechecks metadata and source trust around the preview.

Link/unlink previews use native `link --dry-run` and `unlink --dry-run` output.
The output is advice and may omit effects; `changes` is empty rather than a
fabricated complete filesystem ledger. `paths` contains displayed absolute-path
lines only, and `paths_fingerprint` identifies displayed output, not a Root grant.
No force or overwrite flag is added. New link Tasks confirm the native operation,
not an exact path manifest. Preview text is not execution authority.

Autoremove uses `autoremove --dry-run`. A recognized complete candidate list is
projected for display and no-op handling; an unknown output format is shown with
`complete:false` and cannot invent removal targets. Public CLI format changes can
still require adapting presentation parsers, but unrelated Ruby source changes
never require a Host compatibility release.

The subprocess has network and persistent writes denied, including implicit
trust-store updates and missing-tap installation. A dry-run needing those writes
fails with native diagnostics. Explicit all previews read current
outdated inventory and exclude pins, resolving at most 2,000 records and running
fixed selections of at most 50 packages each. The existing fifteen-second source
deadline covers the whole preview, so a large inventory can time out explicitly.

Homebrew's install-write permission diagnostics are deferred during the preview,
because the read-only sandbox makes persistent paths appear unwritable. The
adapter emits this warning; other Homebrew diagnostics remain intact. Actual
Task admission and execution perform the normal installation permission checks.
This dry-run describes package changes without certifying that installation will
succeed.

Only the Host may broker missing official bottle manifests. Fixed HTTPS routes
are `ghcr.io/token` with `repository:homebrew/core/<image>:pull`, then the exact
`ghcr.io/v2/homebrew/core/<image>/manifests/<version>` reported by Homebrew.
Chosen/dependency package names and recipe versions reach ghcr.io. This data flow
is disclosed in the read Capability review. No redirect, arbitrary host or
package-content download is permitted. Replies are capped at 128 KiB, 1 MiB
aggregate and twenty manifests for the entire read. Registry tokens stay in the
Host request headers. Temporary metadata files are deleted when the read ends;
Homebrew validates the bottle checksum and platform version reference before
using a size. Cached or brokered manifest sizes are real metadata; unavailable
sizes and unsupported third-party endpoints stay unknown with warnings. Sizes
are not an assertion of the final installed footprint. The original four reads
retain their network-denied executor unchanged.

Adoption preview additionally runs the genuine typed cask `install --dry-run
--adopt` after matching the native App snapshot. A refusal returns diagnostics
and no adopt target. A successful preview issues the separate owner-bound opaque
target; native App changes before/after the dry-run invalidate it.

Doctor text and printed commands are untrusted data. Only exact reviewed cleanup
and non-overwriting link operations produce fix_ IDs. Others stay visible for
copying; the Host never executes a printed command. Repair IDs are bound to the
owner's latest Doctor report and expire in two minutes. A refresh invalidates old
fix IDs; revocation/removal must invalidate the owner's retained targets.

App adoption discovery runs in the Host over fixed /Applications and
~/Applications roots, at most 128 non-Apple App bundles. Paths remain Host-only.
The user selects a candidate and a cask; preview checks its application artifact,
version, unmanaged state and absence of installer/pkg artifacts. It issues a
separate adoption_ target bound to the exact native App snapshot. A changed App,
wrong owner or expired target is refused. The confirmed Homebrew --adopt operation
still performs Homebrew's own compatibility validation; a candidate is no
permission to install or trust a source.

Native API sources: [Homebrew manual](https://docs.brew.sh/Manpage), the deployed
Homebrew 7 command implementations, and the [OSV API](https://google.github.io/osv.dev/api/).


Adoption Candidates automatically search a Host-generated, bounded expression of native App names, then inspect at most 50 casks with the fixed offline read profile. Each App has at most four candidate casks and a `ready`, `likely`, `unlikely` or `cannot` confidence with its reason. Names, artifact filenames, compatible versions and declared uninstall bundle identifiers inform confidence; a match never grants mutation authority. No native path reaches the Plugin. An application-only self-updating cask can be previewed when its published version differs because Homebrew's adoption comparison explicitly exempts `auto_updates`; the confirmed runner still performs Homebrew's actual checks. Search/catalogue truncation is explicit.

Doctor may return `fix_all: {target,title,count}` for the first at most eight unique reviewed repairs in the latest report. The opaque set freezes its constituent targets and expires when any constituent expires or the report refreshes. `doctorFix` consumes it under the original Doctor repair scope, confirms concrete steps once, and executes fixed reviewed inputs. Unsupported printed guidance stays manual. Plugins never provide the set's inputs, arguments or metadata.


`packageAnalytics` accepts one to twenty user-selected bare official package names of one kind. `rankings` returns each selected package's bounded install counts; `name` and `analytics` retain the first package for compatibility with the one-package detail workflow. Every selected endpoint shares a total one-MiB read budget, 128-KiB response limit and the existing 15-second Source deadline (three seconds for a synchronous call). Missing counts remain unknown. No global catalogue or automatic sweep is fetched. A Plugin must disclose the known portion when sorting partially ranked results and request another window only after an explicit user gesture.

A Doctor report issues at most 128 unique individual repair targets, reuses repeated targets, and marks `truncated` when more supported repairs are withheld. This protects the first repair set from eviction by its own report. Refresh after a repair to review the next remaining set.


Read and preview subprocesses use the documented CLI without private-source
hashes or injected loaders. Homebrew owns package and installed-history loading
under the read-only sandbox. Additional local JSON observations are display
hints only; missing history cannot become independent Root authority. Old
native inspection/source-proof machinery is retained only for legacy recovery
and isolated tests and is not a fallback for new Tasks.
