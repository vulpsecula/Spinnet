# Spinnet Plugin test kit

`SpinnetPluginTestKit` runs a Plugin's Command scripts in the real
`SpinnetPluginHelper`, the JavaScriptCore helper the Host uses, and answers the
script's Host Service requests from answers the test records. A test checks
what the script evaluated to and which Host Services it asked for. The kit
does not depend on the Host's AppKit code, so a Plugin can be tested from its
own repository.

## Setting up

Add Spinnet as a package dependency and give the test target both the kit and
the helper. The helper dependency makes SwiftPM build `SpinnetPluginHelper`
next to the test bundle, where the kit looks for it.

```swift
.testTarget(
    name: "MyPluginTests",
    dependencies: [
        .product(name: "SpinnetPluginTestKit", package: "Spinnet"),
        .product(name: "SpinnetPluginHelper", package: "Spinnet")
    ]
)
```

If the helper is somewhere else, set `SPINNET_PLUGIN_HELPER_URL` to its path.

## Writing a test

```swift
import XCTest
import SpinnetCore
import SpinnetPluginTestKit

final class UppercaseTests: XCTestCase {
    func testCopiesTheSelectionInUpperCase() throws {
        // Finds Uppercase.spinnetplugin beside this file, in a parent
        // directory, or in a Plugins directory of one.
        let plugin = try PluginUnderTest(named: "Uppercase.spinnetplugin")
        let helper = try PluginTestHelper()
        defer { helper.shutdown() }

        let run = helper.run(PluginTestInvocation("uppercase.copy"), of: plugin, answering: RecordedHostServices([
            .readSelectedText: .value(.string("hello")),
            .writeClipboard: .value(.null)
        ]))

        XCTAssertEqual(try run.result.get(), .null)
        XCTAssertEqual(run.inputs(to: .writeClipboard), [.string("HELLO")])
    }
}
```

`PluginTestInvocation` takes the Command ID and the Action's `input`, already
merged from Plugin Settings, Menu Item overrides and the Command's own fields.
To run a View Event of a View Session, give it the event and the state the
script returned with its view; they become the script's `event` and `state`
globals, both `null` when the Action starts. `run.answer()` reads what the
script evaluated to as the Host does, so its state can feed the next run:

```swift
let opened = try helper.run(PluginTestInvocation("example.form"), of: plugin, answering: services).answer()
let submit = PluginTestInvocation("example.form", event: .submitted(values: .object(["query": .string("hi")])),
                                  state: opened.state)
let submitted = try helper.run(submit, of: plugin, answering: services).answer()
XCTAssertEqual(submitted.toast, "Sent")
```

To check a view the way the Host reads it before drawing it, parse it with the
Plugin's settings fields; a view the Host would not draw throws the protocol
violation that would end the View Session:

```swift
let view = try PluginViewDescription(parsing: XCTUnwrap(opened.view),
                                     settingsFields: plugin.manifest.settingsFields)
XCTAssertEqual(view.form?.submitTitle, "Send")
```

`helper.retireHelper(of: plugin)` retires the Plugin's helper, as the Host
does when it idles, and `helper.launchCount` counts the helpers started, so a
test can check that a script keeps nothing between runs.

Scripts run with the same `spinnet` SDK object as in the Host. Its
`spinnet.environment` reports `PluginTestHelper.defaultEnvironment`, English
and an unbundled Host version `0.0.0`, whatever the machine running the tests
prefers. To test another language, start the helper with one:

```swift
let helper = try PluginTestHelper(environment: PluginRuntimeEnvironment(
    hostVersion: "0.0.0", preferredLanguage: "zh-Hans-CN"
))
```

## Recorded answers

Each Host Service answers every request the same way:

- `.value(json)` returns a value.
- `.failure(error)` fails with a `PluginHostServiceError`, which ends the run
  as the Host's failure would; `storageLimitExceeded` reaches the script as
  an error it may catch, as the Host's does.
- `.answer { input in ... }` computes the answer from the request's input.
- `try .encoding(value)` returns an `Encodable` value, such as a
  `FocusedWindow`, encoded as the Host encodes it.

The recordings stand in for the user's grants and the Host, not for the
manifest. A request for a service whose Capability the Command does not
declare is refused with `capabilityDenied`, as the Host refuses it, and a
service with no recorded answer fails the run naming the service.

`run.result` holds what the script evaluated to, or the `PluginRuntimeError`
the Host would have seen. `run.requests` lists every Host Service request in
order, answered or not.

## Plugin Storage

`spinnet.storage` is easiest to test against a real store. Pass one over a
temporary directory, and the five Plugin Storage services are answered the
way the Host answers them, limits and all, unless you record an answer for
one. A store over the same directory in a later run stands for a relaunch:

```swift
let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
defer { try? FileManager.default.removeItem(at: directory) }
for expected in 1...2 {
    let run = helper.run(PluginTestInvocation("counter.count"), of: plugin,
                         answering: RecordedHostServices(storage: PluginStorage(directory: directory)))
    XCTAssertEqual(try run.result.get(), .number(Double(expected)))
}
```

## Host-Fetched Sections

A view's Host-Fetched Sections are sent by the Host, not the script, so a run
only shows the `fetch` the script described. `RecordedHostFetchedSections`
sends them the way the Host does, through its own broker, with recorded
responses by host in place of the network, and reads what each section shows:

```swift
let fetches = RecordedHostFetchedSections(
    ["api.example.com": RecordedHostFetchedSections.json(#"{"text":"Hallo"}"#)],
    credentials: ["key": "s3cret"]
)
let sections = try fetches.fetch(XCTUnwrap(opened.view), of: plugin, for: PluginTestInvocation("example.form"))
XCTAssertEqual(sections.map(\.state), [.text("Hallo")])
XCTAssertEqual(fetches.requests.first?.headers["Authorization"], "Key s3cret")
```

Each request is held to the Host's rules: Credential Uses are applied from
`credentials`, a host outside the manifest's scope is refused unless it is in
`consentedHosts`, a section with `cache` is answered again from its last 2xx
answer across `fetch` calls, and `deniedCapabilities` refuses a declared
Capability. A `show` section's `state` is the answer the Host extracts or why
there is none. A `deliver` section is `.loading` with a `delivery`, the
`section_delivered` event to run the script with next. `fetches.requests`
lists what reached the network, as it left.

## Plugin API Levels and Candidate Contracts

A run is held to what the Host offers: Plugin API Levels 1 and 2, and no
Candidate Contract, since Level 2 retired every revision this kit's Host
provided (see `PluginAPI/candidates/README.md`). A Plugin that Host would
refuse, such as one needing a higher Level or declaring a retired
candidate, fails with the refusal as an `invalidAction`, and a Host Service
request outside the Levels and candidates the Plugin declares fails with
`hostServiceFailed`. A `PluginTestPage` over a helper follows the helper's
contracts.

To run against a Host that offers a Candidate Contract, pass its contracts,
built from the candidate's published `candidate.json`:

```swift
let candidate = try JSONDecoder().decode(CandidateContract.self, from: Data(contentsOf: metadataURL))
let helper = try PluginTestHelper(contracts: PluginInterfaceContracts(
    levels: PluginInterfaceContracts.host.levels, candidates: [candidate]
))
```

`spinnet.environment.apiLevel` then reports the highest stable Level of those
contracts. `RecordedHostFetchedSections(contracts:)` takes the same value.

## Catalogue IDs

A Plugin API Level 2 Plugin (see `PluginAPI/reference/namespaces.md`) calls
Host Services by catalogue ID, such as `clipboard.write`, and its scripts run
with Level 2's `spinnet` object. Answer its operations by ID, and read what a
run performed the same way; each input is the one the Host performs, a bare
string where the script gave the primary member alone:

```swift
let run = helper.run(PluginTestInvocation("example.shout"), of: plugin, answering: RecordedHostServices(operations: [
    "selection.readText": .value(.string("hello")),
    "clipboard.write": .value(.null)
]))
XCTAssertEqual(run.inputs(to: "clipboard.write"), [.string("HELLO")])
```

A Level 1 name, a reserved ID or one not offered to a script fails the run
with `hostServiceFailed` naming the ID to use, as the Host fails it. A
Command that names an ID in `host_command` runs without a script, as the
Host runs it: `run.performed` lists its operation, no helper starts, and its
result is its value or the `ActionFailure` it ended with. A Command the Host
would refuse, such as one naming a Level 1 Host Command, fails with the
refusal as an `invalidAction`.

## Requested Host Operations

A Level 2 Plugin (see `PluginAPI/reference/host-operations.md`) may answer a
gesture with an operation the Host performs after the answer commits.
`run.answer()` reads it as the Host does: `answer.operation` is the request,
and an operation in an answer to an event that is no gesture, or from a
Level 1 Plugin, is the protocol violation the Host would end the View
Session with.

Give an event the view the user made it in, as the script last answered it.
A gesture in a view that sets `shows_insertion_target` is one the Host
showed a target for, so an insertion the invocation makes or requests may go
ahead; any other, and the Action's start, is refused with
`target_not_shown`, as in the Host. `RecordedHostOperations` performs what an
answer requested with recorded outcomes, by default success, and gives the
`operation_finished` event to run next when the request asked to `notify`:

```swift
let submit = PluginTestInvocation("emoji.search", event: .submitted(values: .object(["query": .string("smile")])),
                                  state: opened.state, view: opened.view)
let run = helper.run(submit, of: plugin, answering: RecordedHostServices())
XCTAssertEqual(try run.answer().operation?.perform, "selection.replace")

let operations = RecordedHostOperations(["selection.replace": .refused(.targetChanged)])
let delivery = try XCTUnwrap(operations.perform(run, of: plugin, for: submit)?.delivery)
let finished = helper.run(PluginTestInvocation("emoji.search", event: delivery, state: try run.answer().state),
                          of: plugin, answering: RecordedHostServices())
```

`perform` throws `capabilityDenied`, as the Host refuses the whole answer,
for a Capability the Command does not declare or the test lists in
`deniedCapabilities`. A synchronous `selection.replace` answered with
`.failure(.insertion(.changedWithoutNames))` fails the run with
`insertion_target_changed`, as a changed target fails it in the Host.

## Using the Host's own services

`run(_:of:answering:)` accepts any `PluginHostServiceBroker`, and
`PluginTestHelper` is also a `ScriptedActionExecutor`. Tests inside the Spinnet
repository use this to run a Bundled Plugin through the Host's broker and
Action runner while part of its behaviour still lives in the Host. A Plugin in
its own repository should use recorded answers.

## Pages and collections

A Level 2 Plugin (see `PluginAPI/reference/pages.md`) may answer with a
page.
`run.answer()` reads it as the Host does, page rules included: `answer.page`
is the page the Host would draw, and a page it would not draw throws the
protocol violation that would end the View Session.

`PluginTestPage` drives a whole View Session by recorded gestures. It applies
every answer through the same page memory the Host uses, so what the user
typed, chose and selected survives refreshes and comes back with a
remembered page exactly as in the Host, and each gesture sends the event, with
its snapshot, the Host would send:

```swift
let page = PluginTestPage("emoji.search", of: plugin, helper: helper,
                          answering: RecordedHostServices(storage: PluginStorage(directory: directory)))
try page.open()
try page.type("cat", into: "query")        // field_changed, as after a pause in typing
try page.press(.down)                      // Up/Down in the search field move a grid row
try page.pressReturn(in: "query")          // the default item action on the selection
XCTAssertEqual(page.performed.first?.perform, "selection.replace")
```

`choose(_:in:)`, `select(_:)`, `doubleClick(_:)`, `menu(of:)`,
`choose(itemAction:on:)`, `copySelection()` (⌘C), `click(_:)` and
`scrollToEnd()` stand for the other gestures; a collection that gives its
`total` is filled by `load_range` as the Host fills it (below). Page and item actions that name a Host Service are performed by the
Host without running the script and are listed, with requested operations,
in `performed`. `composing` names text fields with an open input-method
composition, whose reset the Host drops.

`call(_:input:)` stands for calling the Plugin again while the session is
open, as a Menu Item does: by default the Action that handles the session,
or another Command of the Plugin with its input, Plugin Settings and the
Menu Item's overrides already merged. For a Level 2 Plugin it runs as
`called` from the last good state; only an answer with a page or view makes
that Action the `handler`, and a failed call throws and keeps the page, the
state and the handler. For a Level 1 Plugin the Action starts again:

```swift
try brew.call(input: .object(["scope": .string("outdated")]))   // the "Outdated" Menu Item
XCTAssertEqual(brew.choice(of: "scope"), "outdated")
XCTAssertEqual(brew.text(of: "query"), "py")  // what was typed stays
```

An answer the Host would end the session for closes the page (`isClosed`).

### Styles, images and progress

The page reads Component Styles, columns, icons, images and progress (#81)
as the Host does, so `page?.component(id)` gives each with its style.
`click(_:)` presses a `progress` component's cancel by its ID or title, only
while its state is `running`, as the Host draws it. `images(consentedHosts:)`
tells what each `image` would show, without the network: a package
resource is read and decoded within the Host's bounds (`.loaded`), and an
HTTPS source is `.loading` when the handler's Command declares
`contact_https` for its host (or the user added it), else `.failed` with
the reason the Host would show.

```swift
let track = PluginTestPage("media.track", of: plugin, helper: helper, input: .object(["offline": .bool(true)]))
try track.open()
guard case .loaded? = track.images()["artwork"] else { return XCTFail() }   // the package's own artwork
try brew.click("cancel")                                                   // the task's cancel View Action
```

### Windows, toggles and outcomes

For a collection that gives its `total`, `PluginTestPage` keeps the window
the Host keeps: `window` holds the items by position, `item(at:)` reads one,
and `selectedPosition` is where the selection is, its item held or not. The
screen follows the selection, or `scroll(to:)`; after every gesture and
answer the page asks for what the screen lacks with `load_range`, as the
Host does, and `scrollToEnd()` scrolls to the last item. `select(at:)` clicks
a position, a placeholder included.

```swift
try emoji.press(.end)                       // selects position 1905 and asks for its range
XCTAssertEqual(emoji.selectedItem?.id, emoji.item(at: 1905)?.id)
XCTAssertEqual(try emoji.menu(of: id), ["Insert", "Copy", "✓ Favourite"])  // a toggle checked by the item's marks
```

Page and item actions and requested operations reach the outcome recorded
in `operationOutcomes` (success by default; an insertion after a gesture
with no target shown is refused with `target_not_shown`), listed in
`outcomes`. A successful `closes_view` closes the page unless `isPinned`.
With `notify` the outcome runs as `operation_finished` in the session, an
item action's with the item; when the view closed, it runs once more without
a view, listed in `afterClose`, and its answer
may hold a toast and nothing else.
