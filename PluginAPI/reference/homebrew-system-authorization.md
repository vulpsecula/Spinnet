# Homebrew authorization

New Homebrew Tasks execute the documented `brew` CLI as the current user.
The Plugin supplies typed operations and package identities, never a shell,
executable, arbitrary argv, environment, password or Root operation.

The Host confirms the selected native command and its package metadata.
Homebrew owns artifact ordering, installed history, downloads, installer scripts,
receipts and sudo operations. Confirmation authorizes that native behavior; it
is not an exact Root file/action manifest or a frozen archive promise.
Homebrew source revisions are not matched against a Host allowlist.

Cask install, upgrade, uninstall and language changes first attempt native
`sudo -S -v` validation when Touch ID is available and enabled in sudo's PAM
configuration. Stdin is EOF: Spinnet does not collect a password in this step.
The signed command worker then uses `exec` to become the native Homebrew
process, retaining the parent PID/birth that sudo uses for no-TTY credential
reuse. Only authentication is prepared; Homebrew's actual command is run once.
Spinnet never enables or edits system PAM configuration. A failed/unavailable
system attempt leaves the ordinary password path available; cached credentials
and expiration follow sudo policy. System Touch ID support is conditional.

When sudo needs a password, its documented `SUDO_ASKPASS` mechanism invokes
Spinnet's signed askpass executable. A private per-Task Unix socket authenticates
both endpoints by kernel audit token, signing team, executable identifier and
bundle location; only descendants of the active runner may request a password
window. The socket carries command context and prompt lifetime, never passwords.
Before showing the window, askpass verifies its parent's kernel image is the
Root-owned, non-writable, setuid system `/usr/bin/sudo` and stdout is a pipe.
Launching askpass directly cannot open a window or capture a password.
The Host-owned askpass window collects the login password and writes it directly
to sudo's anonymous stdout pipe. The Plugin and Task journal never receive it.
Spinnet does not save passwords. Native sudo credential caching still follows
system policy. The askpass password window itself is not an Authorization
Services prompt and cannot translate a biometric result into a password.

The output-only PTY remains inside the Plugin View. It cannot accept password
input. Cancel closes the askpass window without returning a password; Task Stop
closes its authorization channel and stops the supervised process tree. Errors
remain native output and failure results, with no automatic retry or rollback.

New Tasks do not register or require Spinnet's privileged background daemon.
Existing background approval is not reset or unregistered. Recovery retains
legacy journals' status and Stop handling until independently proven reaping;
legacy journals are never launched again by the new runner.
The legacy daemon refuses new admission, inspection and mutation requests,
including requests from older signed clients. Its retained interfaces query or
stop existing work and recover or clean up existing records; they cannot start
another legacy operation.

Doctor's native brew repairs remain typed. Suggestions requiring commands
outside this profile remain manual guidance rather than arbitrary elevated
execution. Package/API metadata is display and command-selection data, never
independent authority for a Root operation.
