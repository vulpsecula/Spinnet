# Homebrew system authorization

Privileged work follows Host-generated confirmations and macOS system
administrator authorization. It grants no new Plugin entry point, arbitrary
shell access, path, installer choice or administrator credential. An ad-hoc
Host build cannot use the signed native route. Homebrew itself remains the
current user; ordinary sudo and automatic mutation retry remain refused.

## Receipt inspection and concrete confirmation

Removing receipt-owned files needs two Host Confirmations. The first names
the selected packages and discloses a read-only inspection of **all installed
receipt ownership metadata**, including unselected owners needed to prove
exclusivity. It also discloses registration of Spinnet's bundled signed
reviewed-tool helper when needed. Helper setup runs only after this trusted
confirmation; macOS may require the user to enable it in Login Items. The
Host opens the relevant System Settings page and reports unavailability
until approval is complete. Ordinary metadata reads never register a helper.
An unavailable or unapproved helper changes no installed package.

After setup, the authenticated helper reserves the exact draft. A separate
inspection-only administrator right allows its fixed read-only inventory
worker to inspect receipt metadata. That right cannot authorize a mutation.
The Host receives a bounded summary and **every page** of the selected
concrete disclosure, verifies the complete byte count, digest, receipt counts
and target counts, and refuses changed, missing, repeated or oversized pages.
The complete unselected ownership index stays private to the helper and is
never returned to the Plugin or included in a Plugin response.

The second Host Confirmation presents the complete selected file targets,
retained directories, exact receipts to forget, and every other frozen native
installer, executable, path, service and continuation declaration. Its
Host-owned presentation retains at most 60,000 rows and 96 MiB of aggregate
UTF-8 text across all categories, with 100 rows per page. Paging never drops
rows or grants authority to a preview. Cancel is the default; presenting the
panel does not activate Spinnet. Declared installer or vendor-code actions
can have further effects; their immutable source and exact options are
shown, rather than claiming to predict every action of that code.

Only an affirmative final confirmation can request a **fresh, separate
mutation right**. The helper reconstructs the installed history, source
provenance, declarations, complete ownership and filesystem evidence again
before admission. A changed plan requires a new review. Receipt inspection
has a 30-second aggregate inventory deadline; the helper's inspection/review
reservation lasts at most 120 seconds. Selected disclosure has at most
50,000 targets, 8 GiB of existing file bytes and 96 MiB of wire data; each page
has at most 720 KiB of payload and a 1 MiB encoded message. A summary alone
never authorizes removal.

Closing the initiating view, owner invalidation, Cancel, expiry or Host exit
cancels pre-admission work. The Host retains a private Stop/status entry and
the shared lane while an owned worker remains unreaped. A request to stop is
not proof of reaping. On restart the Host restores only authenticated
liveness, never an old credential, seal, final confirmation or mutation.
Unknown recovery evidence keeps the lane busy. Another account's native
operation exposes liveness only, with no recovered right to stop or mutate it.

## Native admission and execution

The Host-only XPC admission endpoint enforces the stable signing team and
Host executable identifier. Admission expires after 60 seconds and is
consumed once: the signed runner must be a direct child of the admitting
Host, with matching kernel start identity and an exactly equal plan. A
same-user process cannot obtain admission by launching the runner with a
fabricated journal. A user-owned journal supplies status recovery and is
never privileged authority.

After admission, the independent signed Task runner continues confirmed work
if the Host crashes. Each concrete elevated operation receives a fresh,
request-bound administrator right. Native endpoints independently enforce
their designated executable identifiers. Authorization external forms remain
only in the signed native client and XPC; no credential enters Plugin data,
argv, environment, journal or logs. Stop reaches supervised native children
and prevents later steps; earlier changes remain. Lost authenticated results
are `unknown`, with no retry, replay or claim of rollback.

The Host durably records a pending runner launch before starting it. The
runner durably reserves each ordinary Homebrew, batch or Doctor client step
before process creation, records bounded kernel birth identities, and clears
that reservation only after its supervisor actually reaps the owned execution.
If the runner dies, the Host retains the Task, Stop control and shared lane.
It requests Stop only for verified same-account process identities, and uses
an authenticated signed Host endpoint bound to the same account and exact
Root-stored admitted plan for native Stop and liveness. This endpoint cannot
admit work or recover credentials. Missing process ownership or reap evidence
remains `unknown` even if previously recorded PIDs have disappeared. Stop may
be unavailable for an unrecorded process; the Host never guesses a PID or
process group, reports completion, or replays a command to resolve uncertainty.

The surviving runner prevents idle system sleep. For orphaned work the Host
acquires its own idle-system-sleep assertion until independently proven
terminal execution; failure to acquire it is shown explicitly. Recovery
inventory is complete within its bounds or explicitly unavailable and busy,
never an idle result inferred from a truncated list. An incomplete inventory
also retains Host sleep prevention and reports unavailable Stop ownership.
Privileged helper restart with durable unreaped work likewise retains its
private lane; recovery is status evidence rather than execution authority.

The fixed Ruby adapter and native source readers check reviewed Homebrew
bootstrap/loader/artifact source digests. Drift checks do not claim to seal an
entire mutable Homebrew installation. A changed or unsupported source
revision requires review and produces explicit unavailability.

## Reviewed native artifact classes

The native implementation supports flat and directory `.pkg`/`.mpkg`
artifacts, read-only DMG payloads, and reviewed archive decoding, including
ZIP, tar and native XAR/PBZX package members. Root does not load archive
parsers: a signed bootstrap irreversibly drops identity/groups, applies fixed
resource limits and a deny-by-default sandbox, and runs a fixed unprivileged
decoder. Root independently validates bounded frames and builds private
staging with exclusive, no-follow creation. Unsafe traversal, links,
collisions, unsupported formats, expansion beyond bounds, incomplete output
or cancellation refuse staging. Native tools and payloads use separate
immutable/private staging authorities.

Installer options are derived only from reviewed source metadata. Native
choices, choice toggles, permitted custom locations and `allowUntrusted` are
bound to the concrete plan and disclosed; a Plugin supplies none of them.
Verified native continuation evidence may report `restart_required`,
`logout_required` or `shutdown_required`. These are incomplete outcomes;
Spinnet never performs those system actions automatically.

Vendor installers, uninstall/Zap scripts and generated scripts/resources
require immutable source and executable-origin evidence. Editable installed
history is data for target selection, not executable provenance. Published
source, effective language/configuration, exact archive member, executable
bytes, arguments and generated content remain bound together. Missing or
unreviewed provenance refuses the operation. A generated script cannot be
substituted by a same-named file in a user-owned extraction directory.

For `no_check` downloads, the Host freezes an exact bounded snapshot before
confirmation, including its URL, byte count, SHA-256, source and effective
configuration. Confirmation clearly identifies the absence of a publisher
checksum. Launch revalidates and uses that snapshot; it never silently
fetches a newer download. Snapshot/download and payload limits remain 8 GiB;
archive and native payload staging admit at most 50,000 entries. The exact
selected language is frozen for language reinstallation and metadata reads.

Manual GUI installers are opened through a reviewed continuation. Opening
one is not verified installation: the Task reports
`manual_installation_required` and remains failed/incomplete. Manual-only
plans do not borrow administrator authorization for work they cannot perform.

## Installed removal and ownership

Receipt expressions are resolved into exact non-Apple receipt identifiers
from bounded, data-only installed history. The Host binds the installed
version, tap, fingerprint and selected declarations independently of a
successor's current metadata. It checks the recorded source's current trust
and refuses source mismatches. It never evaluates installed Ruby history or
uses the current catalog as a substitute for missing history.

The complete owner index includes selected exports and compact unselected
file lists. Missing native `file-info` indexes never establish exclusivity.
Physical ancestor/leaf identities account for location, case aliases,
firmlinks and known mount topology. Unknown filesystem/driver identity,
protected unreadable metadata, incomplete enumeration, multiple hard links,
special files or unselected ownership refuse proof. The bounded index admits
at most 2,000 receipts, 50,000 candidates, 4 MiB per selected export,
16 MiB/250,000 names per unselected file list, and 64 MiB aggregate read
metadata. Separate supervised workers retain the lane until actual reaping;
blocking native calls do not become permission to skip an owner.

Reviewed receipt locations include Applications, selected Library locations
and receipt-derived usr/local bin, lib and share entries. Exact frozen links
can be removed without following targets. Descriptor-relative private
quarantine supports ordinary writable containers without trusting them for
direct deletion. Root rebuilds and compares full evidence before mutation,
then rechecks each file's identity, content and ACL with its parent open.
Only successfully removed exclusive files and empty directories permit
forgetting an exact receipt. Nonempty directories remain. A restore collision
retains bytes at a concrete recovery location; automatic cleanup never deletes
retained files. Receipt metadata alone is never reported as an uninstall.

Reviewed `delete`/`rmdir` and explicit Zap paths use separate bounded frozen
manifests and display concrete matches, retained directories and unmatched
expressions. Their related-data scope does not imply receipt exclusivity;
shared settings may be deleted. `zap_needs_privileges` is advice only and
applies solely to an actual `uninstall` request with `zap:true`.

Launch services bind exact domains, labels, jobs, plist identities and
selected file removals, including reviewed LaunchAgents and LaunchDaemons.
Kernel-extension removal binds exact identifiers and concrete paths. Required
restart, SIP/TCC/FDA, system approval or missing provenance remains an
explicit incomplete/manual boundary; no permission is bypassed and generic
exit codes never fabricate verified continuation evidence.

Doctor executes only reviewed typed repairs, including fixed Homebrew
ownership subdirectories. It never executes printed commands or arbitrary
shell repair text. Ownership repair remains bounded to 100,000 entries,
depth 64 and two minutes; symlinks, multiple hard links, special files or
changed evidence refuse. Stop can follow partial changes and never promises
rollback. Unsupported recommendations remain manual guidance.

These descriptions identify implemented code paths and refusal boundaries.
They do not establish real administrator-prompt, Root identity-drop, installer,
repair or native UX acceptance. Final acceptance requires the signed Host,
the user's system approval and a suitable disposable mutation environment.
