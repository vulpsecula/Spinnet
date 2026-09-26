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

## Using the Host's own services

`run(_:of:answering:)` accepts any `PluginHostServiceBroker`, and
`PluginTestHelper` is also a `ScriptedActionExecutor`. Tests inside the Spinnet
repository use this to run a Bundled Plugin through the Host's broker and
Action runner while part of its behaviour still lives in the Host. A Plugin in
its own repository should use recorded answers.
