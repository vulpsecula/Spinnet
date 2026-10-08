# The App in front (Plugin API Level 2)

A Level 2 Plugin may identify the App the user is working in, the App in
front behind Spinnet's panel, and ask the Host to close its front window,
quit it or force quit it. Identifying and ending are separate Host Services
under separate Capabilities, so a Plugin allowed to read which App is in
front cannot end it, and a Plugin allowed to end it learns nothing about it.
None offers a list of the user's Apps, and none ends a process by its
process ID. All were appended to Level 2 while it is open (#83).
[`namespaces.schema.json`](../schemas/namespaces.schema.json) publishes the
shapes (`apps.frontmost.*`, `apps.quit.*`, `apps.close.*`, `app_target`,
`app_exit`), [`fixtures/apps/`](../fixtures/apps/index.json) results and
inputs, and [`fixtures/host-operations/`](../fixtures/host-operations/index.json)
the requests and outcomes.

| ID | Offered as | Input | Result | Capability |
| --- | --- | --- | --- | --- |
| `apps.frontmost` | call | none | `{target, name, bundle_id, exits}` or null | `read_frontmost_app` |
| `apps.quit` | request, page action | `{target?, force?}` or none | null; the outcome is `operation_finished`'s | `quit_frontmost_app` |
| `apps.close` | request, page action | `{target?}` or none | null; the outcome is `operation_finished`'s | `quit_frontmost_app` |

Close and Quit are exactly what the user's ⌘W and ⌘Q do: the Host presses
the App's own menu item, through Accessibility, so they need that System
Permission; Force Quit does not. A manifest declaring `api_level` 1 may not
declare either Capability, and neither needs a `capability_scopes` entry.

## `apps.frontmost`

```js
const app = spinnet.apps.frontmost();
// {target: "app_3f…", name: "TextEdit", bundle_id: "com.apple.TextEdit",
//  exits: ["close", "quit", "force_quit"]}, or null
```

- It reads the App in front when the script calls it. While a Plugin View is
  open that is the App behind Spinnet's panel, since the panel never makes
  Spinnet the active App. It is null while Spinnet itself is in front, as
  when its Settings are open, or no App is, and in the rare case that the
  Host can read neither the App's launch date nor its process's start time,
  so cannot tell it from a later App that reuses its process ID. An App that
  Launch Services did not launch, such as Finder, is identified by its
  process's start time.
- `name` is the App's name and `bundle_id` its bundle identifier or null,
  each at most 256 characters. Nothing else about the App, such as its
  process ID, path, windows, documents or menus, reaches the Plugin.
- `exits` lists, in this order, what the Host would do to that App now (see
  [Which exits an App has](#which-exits-an-app-has)): `close` and `quit`
  when the App's own menu offers them, `force_quit` for any regular App,
  none for Spinnet or an App that is not regular. It does not say whether
  the Plugin may do it; that is the Capability's. It can change as the
  user works: an App with no window left usually has no enabled ⌘W.

### App Targets

`target` is an App Target: the Host's opaque name for that one running App,
given to this Plugin only. The Plugin may keep it, in its state or Plugin
Storage, and name it back as `apps.quit`'s or `apps.close`'s `target`; a
later Level may take it elsewhere, such as an App-bound effect (#84).

- It names exactly the App it was read for, identified by its process ID,
  bundle identifier and launch date (or its process's start time) together,
  so another App that later
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

## `apps.quit` and `apps.close`

```js
const ui = spinnet.ui;
const exits = ui.components.actions({ id: "exit" }, [
  spinnet.apps.close.action(null, { id: "close", notify: true }),
  spinnet.apps.quit.action(null, { id: "quit", notify: true }),
  spinnet.apps.quit.action({ force: true }, { id: "force", notify: true })
]);
// or, answering a gesture:
return ui.request(spinnet.apps.quit.operation({ target: state.target }, { notify: true }));
```

Both are [Requested Host Operations](host-operations.md) or page actions:
they run after the answer that asked for them commits, never inside the
script's invocation, and a script cannot call them.

- Without `target`, they act on the App in front when the Host accepts the
  request, as the answer commits or the user chooses the page action, which
  is the App behind Spinnet's panel; if it waits behind an earlier
  operation, it still acts on that App. With `target`, they act on the App
  that App Target names, whichever App is in front; the Host still notes
  which App was in front when it accepted the request, to decide whether
  to ask (see [Host Confirmation](#host-confirmation)).
- `apps.quit` quits the App exactly as ⌘Q or the Dock's Quit does: the Host
  presses the App's own Quit menu item, the enabled one whose shortcut is
  ⌘Q. The App may ask to save first, or refuse, as it would for the user.
  `force: true` asks for Force Quit instead, which ends the App's process at
  once, losing unsaved changes.
- `apps.close` closes the App's front window exactly as ⌘W does: the Host
  presses the App's own enabled menu item whose shortcut is ⌘W, usually
  Close or Close Window. The App may ask to save first, and keeps running.
- A page action without a `title` is called Quit, Force Quit when it
  forces, or Close Window.
- Input other than an App Target and, for `apps.quit`, a boolean `force`,
  such as a process ID, is a protocol violation.

### Which exits an App has

The Host decides by generic rules alone; no rule names an App, and they
are the same for every Plugin; no grant lifts them.

- Close is offered only while one of the menus of the App's menu bar has an
  enabled item whose shortcut is ⌘W, Command alone; Quit only while one has
  such an item for ⌘Q. Shortcuts with Shift, Option or Control, such as
  ⇧⌘W, do not count, nor do the items of submenus. An App without a ⌘Q item,
  as Finder has none, has no Quit; one without an enabled ⌘W, such as an App
  with no window open, has no Close.
- Reading and pressing another App's menu needs Accessibility. Without it,
  `exits` lists no `close` or `quit`, and a Close or Quit is refused with
  `system_permission_denied`. Force Quit does not need it.
- Force Quit is offered for every regular App: one with a Dock icon and a
  menu bar.
- The Host performs no exit at all on Spinnet itself or on an App that is
  not a regular App, an agent or background process. The parts of macOS that
  run as Apps, such as the Dock, loginwindow and Control Center, are such
  agents.
- The Host waits a bounded time for the App to answer while it reads its
  menu. A menu that does not answer in time offers no Close or Quit.

### What the Host does

1. It checks the Capability, the Plugin and its Command (and for `apps.close`
   Accessibility) when the answer commits and again when the operation
   starts.
2. It resolves the App: the one that was in front when it accepted the
   request, or the one the target names, if that App still runs as itself.
   It refuses Spinnet, an App that is not regular, no App at all, and a
   Close or Quit the App's menu does not offer now, without asking.
3. For Force Quit, or to close or quit an App that was not in front when it
   accepted the request, it shows the Host Confirmation, which names that
   App. A Close or graceful Quit of the App that was in front then goes on
   at once.
4. Before it acts, at once or once the user confirms, it checks the
   Capability, the Plugin and its Command again, that the same App still
   runs as itself, and for Close and Quit finds the App's menu item again,
   and only then presses exactly that App's item or ends exactly that App.
   If the App quit, another App now has its process ID, or its item went
   away or was disabled, it is refused and nothing else is done: the Host
   never moves an operation to another App or another item.

### Host Confirmation

The Host asks the user before every Force Quit, and before closing or
quitting, even gracefully, an App that was not in front when it accepted the
request: one a `target` names while another App, Spinnet included, is in
front. A Close or graceful Quit of the App that was in front then, with no
`target` or a `target` naming that App, asks nothing: it is the App the
user is looking at, and its own save prompts still apply. Which App was in
front is decided when the Host accepts the request, not when it runs, and
nothing a Plugin sends changes it.

The confirmation is drawn with the Host's own words: "Close TextEdit's Front
Window?", "Quit TextEdit?" or "Force Quit TextEdit?", the Plugin that asks,
and for Force Quit that unsaved changes will be lost. No Plugin text appears
in it. It is drawn near the
pointer without activating Spinnet; Cancel is its default button, so Return
and Escape decline. Closing the view, updating, disabling or removing the
Plugin, revoking a Capability or quitting Spinnet cancels it; unanswered for
60 seconds, it expires. One is on screen at a time: a confirmation another
Plugin asks for meanwhile waits its turn, and its 60 seconds start when it
is shown. See [Host Confirmation](host-operations.md#host-confirmation).

### Outcomes

| Outcome | Reason | When |
| --- | --- | --- |
| `succeeded` | | The Host pressed the App's menu item, or ended its process. A close or quit may still be met by the App's own save prompt, or refused by it; a force quit ends it |
| `refused` | `no_target` | Spinnet or no App the Host can name was in front when it accepted the request, the target names nothing for this Plugin, or the App quit or was replaced before the Host could act |
| `refused` | `target_protected` | The App does not offer that exit, its menu having no enabled ⌘Q or ⌘W item then, or the Host performs none on it: Spinnet, or an App that is not regular |
| `refused` | `system_permission_denied` | A Close or Quit while Spinnet does not have Accessibility |
| `refused` | `capability_denied`, `command_unavailable` | The Capability was revoked, or the Plugin or Command changed, by the time the Host acted |
| `failed` | `host_service_failed` | The App or macOS did not take the press or the exit |
| `declined` | | The user declined the Host Confirmation; never for a Close or graceful Quit of the App in front, which asks nothing |
| `expired` | | The Host Confirmation went unanswered for 60 seconds |
| `cancelled` | | The view closed, the Plugin changed or lost a Capability, or Spinnet quit, before the operation ran: while it waited behind another operation, while the Host read the App's menu, or while its Host Confirmation was unanswered or waiting its turn |

No outcome, reason or message given to the Plugin names the App; the Host
shows its own message, which may. An outcome after the view closed reaches
the Plugin only for an operation that ran (`succeeded`, `refused`,
`failed`), as for every request.

## In the test kit

`RecordedApps` stands for the desktop: the App in front, the Apps running,
what each App's menu offers (`App(menu:)`, and `offer(_:in:)` to change it,
as when its last window closes), whether Spinnet has Accessibility
(`isAccessibilityTrusted`), and the exits the Host performed.
`RecordedApps.App.finder` has Close but no Quit, as Finder's menu does.
`RecordedHostServices(apps:)` answers `apps.frontmost` the Host's way from
it, App Targets and `exits` included, and
`RecordedHostOperations(apps:confirmation:)` performs `apps.quit` and
`apps.close` with the Host's own rules, the App in front when `perform` is
called being the one in front when the Host accepted the request; it records
the Host Confirmation it showed, if any, and answers it as the test says. A
test can bring another App to the front, quit or relaunch an App, change
its menu, or revoke a Capability while the confirmation is shown
(`whileConfirming`).

## Limits

| Limit | Value |
| --- | --- |
| App Targets per Plugin | 16 |
| `name`, `bundle_id` | 256 characters |
| Host Confirmation unanswered before `expired` | 60 s |
