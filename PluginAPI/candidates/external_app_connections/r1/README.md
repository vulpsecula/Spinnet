# External App connections r1

Exact Candidate Contract `external_app_connections` revision 1, based on
Plugin API Level 2. Declare this revision in `candidate_contracts` and add:

```json
"external_app_connections": [
  {"bundle_id":"com.spotify.client", "command_ids":["spotify.play", "spotify.pause"]}
]
```

The optional member is a nonempty array of at most eight uniquely named
External Apps. Each entry has only `bundle_id` and a nonempty list of unique,
declared `command_ids`. A dependent Command must be in the Plugin's declared
`control_external_app` scope for that target, including the family of the
Host's connection check. Required and optional Capabilities keep their existing
meaning; a dependent Command requires a granted connection Capability even
when declared optional. Connections grant no authority.

Only a Reviewed App Interface with a Host-reviewed, parameterless, read-only
connection check can be declared. This revision supports Spotify, using its
existing `playback` operation and `playback_read` family. The Plugin cannot
choose the check, provide a script, label, shell, arguments or another target.

The Host presents connection status and explicit Connect/repair controls in
Plugin Settings. A connection-dependent Preset must finish this setup before
placement. Cancel preserves the Menu Slot and any existing Menu Item. Repeated
Menu Items share current connection state; no persisted initialized flag is
used. Installing, launching, refreshing status and executing Actions never
request Automation consent. Only explicit Connect may request it, using the
reviewed harmless check. Connecting never starts the target, plays media or
replays a pending Action. Already authorized access is connected even when the
App has quit; execution is then unavailable until the user starts it. A quit
App with unknown Automation permission is not considered authorized.

Permission revocation keeps Menu Items and inputs, exposing repair in Plugin
Settings. Capability changes, replacement, removal and disable invalidate
pending work. The Host checks current declaration, scoped grant and registration
before dispatch and consuming asynchronous completion, and again at execution.
Missing installation, permission needed/denied, stopped App, busy and failed
checks have distinct statuses. Connection checks use the reviewed service's
existing deadline. No Plugin script or helper runs during setup.

The [schema](external-app-connections.schema.json) describes this member and
exact opt-in; validate the manifest after removing `candidate_contracts` and
`external_app_connections` against the stable manifest schema too. Cross-field
Command, reviewed-target and scope checks are enforced by the Host. The
[types](external-app-connections.d.ts) describe manifest data only; there is no
new JavaScript runtime API.

Open File and Open URL use the existing stable `preset.readiness:
"setup_required"` input flow. They do not declare an External App connection:
their configured path/URL opens in the system default application.
