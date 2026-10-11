# Homebrew system authorization

System administrator authorization follows the concrete Host Confirmation.
It grants no new Plugin entry point, shell access or administrator credentials.
The signed Host registers its bundled `SMAppService` launch daemon. macOS may
require the user to enable that helper in Login Items; an unavailable or
unapproved helper refuses the Task before mutation starts. An ad-hoc build
cannot use this route.

After confirmation and revalidation, a Host-only XPC endpoint admits the
concrete privileged plan into root-helper memory. This endpoint enforces the
stable signing team and Host executable identifier. The admission expires
after 60 seconds and is consumed once: a signed runner must be a direct child
of that admitting Host process, with matching kernel start identity and an
exactly equal plan. A same-user process cannot obtain privileged admission by
launching the signed runner with a fabricated journal. The private user-owned
journal supplies recovery state and is never privileged authority.

Once admitted, the independent signed Task runner owns its concrete Task,
selected cask checksum/artifacts or reviewed Doctor directories even after
Host exit. All three XPC endpoints enforce the signing team and designated
executable identifier on messages. The native authorization client must descend from that runner.
Each concrete privileged operation creates a fresh request-bound administrator
right; it expires and is consumed once. Authorization forms remain only in
native memory and XPC, never Plugin responses, argv, environment, journals or
logs. Stop reaches supervised privileged subprocesses and prevents subsequent
operations; earlier changes remain.
If communication with the privileged helper is lost after authorization, the
Task reports `unknown` and never retries. Installer work may already have
changed the system; that refusal is not evidence of rollback or a clean state.

Homebrew itself remains the current user with ordinary sudo refused. A sealed
Host Ruby adapter checks reviewed Homebrew source SHA-256 digests before
dispatch. A different source revision requires review and is unavailable.
For privileged cask installation, upgrade or language reinstallation, the
reviewed adapter supports immutable-checksum flat `.pkg` downloads and flat
`.pkg` artifacts inside `.dmg` downloads. The helper copies and verifies the
approved download in root-owned private staging; DMGs mount read-only and the
selected package is verified again before `/usr/sbin/installer` runs. Missing
checksums, custom installers, non-flat packages, other archive containers,
installer choices and unreviewed privileged uninstall directives are unavailable with
manual Homebrew guidance. The Plugin must present these concrete refusals,
and must not imply universal privileged cask support.

The reviewed privileged uninstall class supports exact system launch-daemon
labels for installed application casks. The Host freezes each root-owned,
non-writable, single-link plist's label, checksum, device and inode before
confirmation and rechecks it before removal. The helper stops the exact
system service, verifies absence, and removes only that same plist; it never
accepts a path or wildcard from a Plugin. LaunchAgents, Apple service labels,
scripts, kexts and Zap remain outside this class.

The receipt removal class resolves recorded receipt expressions through the
bounded native read interface and admits only exact non-Apple identifiers from
data-only recorded installed cask history. The Host binds its exact token,
recorded tap and version to the selected package, checks that recorded tap's
current trust before confirmation and launch, and discloses it as locally
recorded history. It does not claim immutable upstream ownership from editable
local metadata. A mismatched current catalog source is refused. The reader
uses no-follow ancestor descriptors, bounded reads and bounded timestamp
enumeration. The sealed Ruby adapter delegates revalidation to the signed
native client. It never evaluates an installed
Ruby recipe or substitutes the current catalog for missing history. The Host
resolves relative and trailing-slash native install locations against the
declared volume. It intersects the complete native receipt inventory using
package information, selected receipt exports and compact unselected file
lists; missing `file-info` indexing never establishes exclusivity. Physical
ancestor and file identities account for location and case aliases. The
inventory admits at most 2,000 receipts, 50,000 candidate paths, 4 MiB per
selected export and 16 MiB/250,000 names per unselected file list, with 64 MiB
of aggregate read metadata; incomplete or
over-budget ownership is an explicit refusal. The Host builds one index for
the batch, and the native helper reconstructs it before mutation.
It then freezes the canonical native exported receipt and a manifest of existing file identities and content hashes,
with at most 10,000 entries and a 30-second aggregate read deadline. Each file
must belong only to receipts selected in the confirmed batch, be root-owned
and non-writable (including extended ACL authority). Reviewed locations are
Applications, Library Application Support, PrivilegedHelperTools, Frameworks,
Fonts, exact LaunchDaemons, and receipt-derived usr/local bin, lib and share
entries. Frozen symbolic links can be removed without following their targets.
Multiple hard links, special files and unselected or unknown ownership refuse
before confirmation. Ordinary writable containers such as Applications are
supported through descriptor-based private quarantine rather than trusted for
direct deletion. No expression reaches privileged execution.
The manifest establishes current receipt ownership and file identity; pkgutil
file names do not establish original installer payload checksums.

After native authorization, the helper rebuilds and matches the full manifest,
before the first mutation, then rechecks each identity, content and ACL with
its parent descriptor open. It atomically moves each exact entry into private
quarantine and rechecks it before deletion. It
removes receipt-owned files and empty directories before forgetting the exact
receipt. Nonempty directories remain. Any failure or Stop leaves the receipt
intact unless all required removals already succeeded; prior changes remain.
Daemon-only receipts account for verified daemon removals in the same plan.
Directory size and modification times changed by admitted child removals do
not invalidate a later receipt; owner, ACL and inode identity still must match.
A restore collision preserves original bytes at a concrete recovery location
reported to the Host; automatic cleanup never deletes retained files.
Hashing observes cancellation and the shared read deadline. Each native
rename/delete step shares the Task's Stop lock, so an acknowledged Stop
prevents the next step without waiting for hashing. Repeated exact receipts
or daemon labels across selected casks reuse only matching completed authority
in that same running Task. A final no-follow presence check detects recreated
files and dangling links before receipt forgetting.
Receipt forgetting alone is never reported as an uninstall. The Host
Confirmation names each receipt and its reviewed entry count. Concrete removal
details exceeding 8 KiB refuse the Task before confirmation rather than being
silently truncated.

For upgrades and language reinstalls, the Host freezes the installed
predecessor version/history independently of the successor checksum and
artifacts. The same receipt and daemon classes can remove only that frozen
predecessor; installation remains bound to the successor's Caskroom version.
Before Homebrew dispatch, the sealed Ruby adapter rechecks the installed
history fingerprint. A current application-only catalog entry does not hide
an installed predecessor's privileged uninstall requirements.

Vendor scripts, non-flat/other archive containers, installer choices,
LaunchAgents, Zap and mutable-checksum download
staging remain explicit implementation requirements; these reviewed classes
do not establish complete elevated cask compatibility.

Doctor recognizes only the exact reviewed ownership recommendation for fixed
Homebrew prefix subdirectories, alongside other reviewed cleanup/link fixes.
Its opaque target expires, is bound to the report and freezes current directory
identity/ownership before confirmation. The helper changes only root-owned
entries to the requesting user, through descriptor-relative traversal on the
same filesystem. Symbolic links, files with multiple hard links, special files,
more than 100,000 entries, depth above 64 or work exceeding two minutes refuse
the repair. It executes no printed command text, recursive shell expression or
permission-mode change. A refusal or Stop can follow partial changes and never
promises rollback. Unknown Doctor recommendations stay visible and copyable
for manual review.

These boundaries are implementation coverage, not proof of real installer,
administrator-prompt or repair acceptance. Native mutating acceptance requires
a suitable disposable environment and the user's system approval.
