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
repository is not counted as checked. Results are advisory matches for installed
source tags, with no inference that the installed build contains a recipe's
security patch. The initial scan includes up to forty advisory IDs per package,
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
