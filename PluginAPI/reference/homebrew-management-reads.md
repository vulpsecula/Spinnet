# Reviewed Homebrew management reads (Plugin API Level 2)

The `tools.read` Homebrew profile now supports version, taps, services, doctor,
previewInstall, previewUpgrade, adoptionCandidates, adoptionPreview,
vulnerabilities, vulnerabilityDetail and packageAnalytics, beside its existing
installed/outdated/search/info reads. The Plugin declares each operation and
package kind in read_reviewed_tools. Reading is separate from mutation.
Inputs are typed; no Plugin argv, URL, shell, path or environment is accepted.
See [schema](../schemas/homebrew-management-reads.schema.json) and
[types](../homebrew-management.d.ts).

| Operation | Additional input | Result fields |
| --- | --- | --- |
| version | none | version, features |
| taps | optional exact tap name | taps with actual official/trusted flags and package counts; selected tap adds at most 1,000 formula/cask package identities |
| services | none | current user's named service statuses; no file paths/account names |
| doctor | none | tier, findings with text/links/copyable commands and recognized repair targets |
| previewInstall / previewUpgrade | kind, names (1–20) | packages, estimated:true, summary |
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

Previews are explicitly estimated local metadata plans, not brew dry-run output.
They neither download manifests nor mutate/install/trust anything. Preview package records use the same bounded metadata projection as [package detail reads](tools.md), including discovered installed directories and declared languages when known. Dependencies,
source trust and package pins are rechecked by the actual confirmed task.

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
