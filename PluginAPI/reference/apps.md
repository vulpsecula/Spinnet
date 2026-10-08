# The App in front (Plugin API Level 2)

A Level 2 Plugin may identify the App the user is working in, the App in
front behind Spinnet's panel, and ask the Host to quit or force quit it.
The two are separate Host Services under separate Capabilities, so a Plugin
allowed to read which App is in front cannot end it, and a Plugin allowed to
quit it learns nothing about it. Neither offers a list of the user's Apps,
and neither ends a process by its process ID. Both were appended to Level 2
while it is open (#83).
[`namespaces.schema.json`](../schemas/namespaces.schema.json) publishes the
shapes (`apps.frontmost.*`, `apps.quit.*`, `app_target`, `app_exit`),
[`fixtures/apps/`](../fixtures/apps/index.json) results and inputs, and
[`fixtures/host-operations/`](../fixtures/host-operations/index.json) the
requests and outcomes.

| ID | Offered as | Input | Result | Capability |
| --- | --- | --- | --- | --- |
| `apps.frontmost` | call | none | `{target, name, bundle_id, exits}` or null | `read_frontmost_app` |
| `apps.quit` | request, page action | `{target?, force?}` or none | null; the outcome is `operation_finished`'s | `quit_frontmost_app` |

Neither needs a System Permission. A manifest declaring `api_level` 1 may not
declare either Capability, and neither needs a `capability_scopes` entry.

## `apps.frontmost`

```js
const app = spinnet.apps.frontmost();
// {target: "app_3f…", name: "TextEdit", bundle_id: "com.apple.TextEdit",
//  exits: ["quit", "force_quit"]}, or null
```

- It reads the App in front when the script calls it. While a Plugin View is
  open that is the App behind Spinnet's panel, since the panel never makes
  Spinnet the active App. It is null while Spinnet itself is in front, as
  when its Settings are open, or no App is, and for an App macOS gives no
  launch date (one started without Launch Services), which the Host cannot
  tell from a later App that reuses its process ID.
- `name` is the App's name and `bundle_id` its bundle identifier or null,
  each at most 256 characters. Nothing else about the App, such as its
  process ID, path, windows or documents, reaches the Plugin.
- `exits` lists what `apps.quit` would do to that App: `quit`,
  `force_quit`, both, or none when the Host protects it (below). It does not
  say whether the Plugin may quit it; that is the Capability's.

### App Targets

`target` is an App Target: the Host's opaque name for that one running App,
given to this Plugin only. The Plugin may keep it, in its state or Plugin
Storage, and name it back as `apps.quit`'s `target`; a later Level may take
it elsewhere, such as an App-bound effect (#84).

- It names exactly the App it was read for, identified by its process ID,
  bundle identifier and launch date together, so another App that later
  gets the same process ID is never that App, and an App that quits and
  starts again is a new App with a new target.
- Reading the same App again gives the same target.
- It stops naming the App once the App quits, the Plugin is updated,
  disabled or removed or loses any Capability, or Spinnet quits. A Plugin
  holds at most 16; reading a seventeenth App forgets the target read least
  recently.
- It is `app_` and 32 lowercase hexadecimal digits and means nothing
  outside the Host. A target another Plugin was given names nothing for this
  one.

## `apps.quit`

```js
const ui = spinnet.ui;
const quit = ui.components.actions({ id: "exit" }, [
  spinnet.apps.quit.action(null, { id: "quit", notify: true }),
  spinnet.apps.quit.action({ force: true }, { id: "force", notify: true })
]);
// or, answering a gesture:
return ui.request(spinnet.apps.quit.operation({ target: state.target }, { notify: true }));
```

`apps.quit` is a [Requested Host Operation](host-operations.md) or a page
action: it runs after the answer that asked for it commits, never inside the
script's invocation, and a script cannot call it.

- Without `target`, it acts on the App in front when the Host accepts the
  request, as the answer commits or the user chooses the page action, which
  is the App behind Spinnet's panel; if it waits behind an earlier
  operation, it still acts on that App. With `target`, it acts on the App
  that App Target names, whichever App is in front.
- `force: true` asks for Force Quit; otherwise the Host asks the App to quit,
  as its Quit menu item does.
- A page action without a `title` is called Quit, or Force Quit when it
  forces.
- Input other than an App Target and a boolean `force`, such as a process
  ID, is a protocol violation.

### What the Host does

1. It checks the Capability, the Plugin and its Command when the answer
   commits and again when the operation starts.
2. It resolves the App: the one that was in front when it accepted the
   request, or the one the target names, if that App still runs as itself.
   It refuses Spinnet, an App the Host protects from that exit, or no App at
   all, without asking.
3. It shows the Host Confirmation, which names that App.
4. Once the user confirms, it checks the Capability, the Plugin and its
   Command again, and that the same App still runs as itself, and only then
   quits or force quits exactly that App. If the App quit, or another App
   now has its process ID, it is refused and nothing else is quit: the Host
   never moves a confirmed operation to another App.

### Host Confirmation

Every `apps.quit` asks the user, for Quit as for Force Quit, in a
confirmation the Host draws with its own words: "Quit TextEdit?" or "Force
Quit TextEdit?", the Plugin that asks, and for Force Quit that unsaved
changes will be lost. No Plugin text appears in it. It is drawn near the
pointer without activating Spinnet; Cancel is its default button, so Return
and Escape decline. Closing the view, updating, disabling or removing the
Plugin, revoking a Capability or quitting Spinnet cancels it; unanswered for
60 seconds, it expires. One is on screen at a time: a confirmation another
Plugin asks for meanwhile waits its turn, and its 60 seconds start when it
is shown. See [Host Confirmation](host-operations.md#host-confirmation).

### Protected Apps

The Host performs no exit on Spinnet itself, on an App that is not a regular
App (an agent or background process, without a Dock icon), or on the parts of
macOS that run as Apps (`com.apple.loginwindow`, `com.apple.dock`,
`com.apple.SystemUIServer`, `com.apple.WindowManager`,
`com.apple.controlcenter`, `com.apple.notificationcenterui`,
`com.apple.Spotlight`, `com.apple.coreservices.uiagent`,
`com.apple.UserNotificationCenter`, `com.apple.SecurityAgent`). It asks
Finder to quit but never force quits it. These rules are the same for every
Plugin; no grant lifts them.

### Outcomes

| Outcome | Reason | When |
| --- | --- | --- |
| `succeeded` | | The Host delivered the exit to the App. A quit may still be met by the App's own save prompt, or refused by it; a force quit ends it |
| `refused` | `no_target` | Spinnet or no App the Host can name was in front when it accepted the request, the target names nothing for this Plugin, or the App quit or was replaced before the Host could act |
| `refused` | `target_protected` | The Host never performs that exit on that App |
| `refused` | `capability_denied`, `command_unavailable` | The Capability was revoked, or the Plugin or Command changed, by the time the Host acted |
| `failed` | `host_service_failed` | macOS did not accept the exit |
| `declined` | | The user declined the Host Confirmation |
| `expired` | | The Host Confirmation went unanswered for 60 seconds |
| `cancelled` | | The view closed, the Plugin changed or lost a Capability, or Spinnet quit, before the operation ran, its Host Confirmation still unanswered or waiting its turn |

No outcome, reason or message given to the Plugin names the App; the Host
shows its own message, which may. An outcome after the view closed reaches
the Plugin only for an operation that ran (`succeeded`, `refused`,
`failed`), as for every request.

## In the test kit

`RecordedApps` stands for the desktop: the App in front, the Apps running
and the exits the Host performed. `RecordedHostServices(apps:)` answers
`apps.frontmost` the Host's way from it, App Targets included, and
`RecordedHostOperations(apps:confirmation:)` performs `apps.quit` with the
Host's own rules, recording the Host Confirmation it showed and answering it
as the test says. A test can bring another App to the front, quit or
relaunch an App, or revoke a Capability while the confirmation is shown
(`whileConfirming`).

## Limits

| Limit | Value |
| --- | --- |
| App Targets per Plugin | 16 |
| `name`, `bundle_id` | 256 characters |
| Host Confirmation unanswered before `expired` | 60 s |
