# Reviewed Homebrew management reads (Plugin API Level 2)

The `tools.read` Homebrew profile now supports version, taps, services, doctor,
previewInstall, previewUpgrade, previewUpgradeAll, previewLink, previewUnlink, adoptionCandidates, adoptionPreview,
vulnerabilities, vulnerabilityDetail and packageAnalytics, beside its existing
installed/outdated/search/info reads. The Plugin declares each operation and
package kind in read_reviewed_tools. Reading is separate from mutation.
Inputs are typed; no Plugin argv, URL, shell, path or environment is accepted.
Before launching brew, the Host also checks bounded owned regular bootstrap
configuration files. Developer Ruby warning options are restricted to reviewed
`-W0`, `-W1` or `-W2`; `-r`/`-e` preload options and protected Library/repository
`NAME+=` redirects are refused before Ruby starts. Compiled Bootsnap caches are
disabled. These are checks on live files, not an immutable Homebrew distribution.
See [schema](../schemas/homebrew-management-reads.schema.json) and
[types](../homebrew-management.d.ts).

| Operation | Additional input | Result fields |
| --- | --- | --- |
| version | none | version, features |
| taps | optional exact tap name | taps with actual official/trusted flags and package counts; selected tap adds at most 1,000 formula/cask package identities |
| services | none | current user's named service statuses; no file paths/account names |
| doctor | none | tier, findings with text/links/copyable commands and recognized repair targets |
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

Install and upgrade previews execute the installed Homebrew 7.0.x command's actual `--dry-run
--no-ask` through a Host-owned version-gated Ruby adapter. Their stages retain
Homebrew's version transitions, dependency and dependent changes and download
sizes when known; diagnostics retain warnings and refusals. `estimated:false`
identifies the real dry-run, while `succeeded:false` with the actual exit status
preserves a refusal, including pinned packages. A refusal is never an empty
successful upgrade. Unsupported Homebrew versions return available:false and
requires_reviewed_homebrew_version. A preview is current advice; confirmed Tasks
still recheck current package metadata, source trust and pins.

Link previews use the reviewed Homebrew 7.0.x Keg and cask artifact traversal
without taking locks or writing files. Plain `brew link --dry-run` omits opt,
alias and linked-keg metadata, related formula unlinks, directory changes and
info index updates. The Host adds those concrete effects to at most 2,000
`changes`: `link` includes its new `source`; the other actions are `unlink`,
`mkdir`, `rmdir` and `update_info_index`. `paths` lists the distinct destinations.
The fingerprint binds the planned actions and source identities together with
current destination, parent and symlink states. The Host repeats the complete
preview at Task preparation and launch; changed metadata, sources, paths or
diagnostics require a new confirmation. No Plugin path or fingerprint is
accepted as Task input.

`complete:false` or `succeeded:false` describes a refused plan and must not
offer a Task. `no_op:true` is a successful empty plan and also needs no Task.
Unsupported shared-directory conversions, recursive legacy alias cleanup,
unbounded or contradictory changes and force-required kegs are refused with
diagnostics. Ordinary missing parents and empty-directory cleanup are listed
explicitly. No force or overwrite flag is enabled; Homebrew's normal replacement
of an existing cask link is disclosed when applicable. These previews share the
network-denied, write-denied subprocess and the existing call/Source deadlines.

The subprocess has all network access and persistent file writes denied. Its
adapter prevents Homebrew's implicit qualified-package trust and missing-tap
installation. Homebrew's guarded loader checks persistent source trust before
package Ruby evaluation and after canonical alias/rename resolution; a qualified
selector never grants temporary trust. Existing canonical item trust is enough
without granting the entire tap. Metadata and persistent source trust are checked
before and after the dry-run; changed data is refused. Explicit all previews read current
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


Read and preview subprocesses validate the reviewed entry, selected bootstrap,
and loader source hashes before starting Homebrew, then recheck loader hashes in
the Ruby adapter. Missing, changed or oversized reviewed files return unavailable
and require a Host review of that source revision. These checks detect drift in
live user-owned files; they do not freeze the whole Homebrew installation.

Installed cask history is accepted only as a bounded regular JSON file, parsed
once as an object and passed as an immutable snapshot to Homebrew's data loader.
Null, scalar, array, malformed or changing history is explicitly unavailable;
it never falls through to Ruby evaluation or a current-catalog fallback. Legacy
installed Ruby history requires immutable source provenance and stays unavailable
in this read profile.
