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

Homebrew itself remains the current user with ordinary sudo refused. A sealed
Host Ruby adapter checks reviewed Homebrew source SHA-256 digests before
dispatch. A different source revision requires review and is unavailable.
For privileged cask installation, upgrade or language reinstallation, the
reviewed adapter supports immutable-checksum flat `.pkg` downloads and flat
`.pkg` artifacts inside `.dmg` downloads. The helper copies and verifies the
approved download in root-owned private staging; DMGs mount read-only and the
selected package is verified again before `/usr/sbin/installer` runs. Missing
checksums, custom installers, non-flat packages, other archive containers,
installer choices and privileged uninstall directives are unavailable with
manual Homebrew guidance. The Plugin must present these concrete refusals,
and must not imply universal privileged cask support.

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
