# Homebrew authorization

New Homebrew Tasks execute the documented `brew` CLI as the current user.
The Plugin supplies typed operations and package identities, never a shell,
executable, arbitrary argv, environment, password or Root operation.

The Host confirms the selected native command and its package metadata.
Homebrew owns artifact ordering, installed history, downloads, installer scripts,
receipts and sudo operations. Confirmation authorizes that native behavior; it
is not an exact Root file/action manifest or a frozen archive promise.
Homebrew source revisions are not matched against a Host allowlist.

When a native Homebrew operation needs administrator access, system sudo
performs authentication through the user's macOS PAM configuration. Where
configured, macOS presents its own Touch ID and login password choices. The
Host does not supply `SUDO_ASKPASS` or force `sudo -A`, because macOS disables
its system authentication UI in askpass mode. No Host password window, password
collector, authentication socket or credential-cache preflight is used.

The Host and Plugin never receive the password or a biometric result. They
observe command output and exit status. The native command runs once and sudo
requests authentication when needed, including after cached credentials expire.
The Host does not enable or edit PAM configuration. Availability and fallback
choices belong to macOS system policy; without a working system authentication
route, a privileged command fails rather than collecting a password in Spinnet.

The output-only PTY remains inside the Plugin View and accepts no input. A user
may cancel system authentication, after which Homebrew determines the command's
failure behavior. Task Stop signals the supervised process tree. Errors remain
native output and failure results, with no automatic retry or rollback.

New Tasks do not register or require Spinnet's privileged background daemon.
Existing background approval is not reset or unregistered. Recovery retains
legacy journals' status and Stop handling until independently proven reaping;
legacy journals are never launched again by the new runner.

Doctor's native brew repairs remain typed. Suggestions requiring commands
outside this profile remain manual guidance rather than arbitrary elevated
execution. Package/API metadata is display and command-selection data, never
independent authority for a Root operation.
