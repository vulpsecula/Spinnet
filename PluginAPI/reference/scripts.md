# Scripts

A Command whose `execution` is `javascript` names a UTF-8 script relative to
the package root. When its Action runs, the Host sends the script and the
Action's input to the Plugin's own helper, a separate process that runs it in
the system JavaScriptCore; the Host itself runs no JavaScript. The helper
exposes no operating-system API: a script reaches the Mac only through
[Host Services](host-services.md), which the Host checks before it performs
them.

## Globals

| Global | Meaning |
| --- | --- |
| `input` | The Action's JSON input: the Plugin Settings, then the Menu Item's overrides, then the Command's own configured value |
| `inputJSON` | The same value as JSON text |
| `pluginID`, `commandID`, `actionID`, `invocationID` | The current invocation; `invocationID` is fresh for every run |
| `event` | The [View Event](views.md#view-sessions) this run answers, or `null` when the Action starts |
| `state` | The state the script returned with its last view, or `null` |
| `spinnet` | The SDK object, from [`spinnet.js`](../sdk/spinnet.js) |
| `requestHostService(name, input)` | Sends a Capability-checked request to the Host and returns its JSON result |

[`spinnet.d.ts`](../sdk/spinnet.d.ts) types them all.

## The spinnet SDK

Every script receives the current `spinnet` object, organized by catalogue
namespace. Callable operations send their input to the Host and return its
answer. Offered requests and View Actions have pure `.operation(...)` and
`.action(...)` builders. `spinnet.ui` builds views, pages and answers. The
[catalogue](../catalogue.json) lists permitted entry points; `requestHostService`
accepts callable catalogue IDs only.

`spinnet.environment` is decided by the Host: `hostVersion` is the running Host
release; `preferredLanguage` is the BCP 47 code of the user's first preferred
language, such as `en-US`. Invocation IDs are separate globals. No environment
value grants authority.

## The answer

A script answers with the value of its last expression, as
[View Sessions](views.md#view-sessions) describes: `{view, state}`,
`{close: true}`, `null`, or any of them with a `toast`. Any other value is a
protocol violation: it fails an Action with `runtime_protocol_failed` and ends
a View Session. [`schemas/view-session.schema.json`](../schemas/view-session.schema.json)
publishes the answers and events, and [Plugin Views](views.md) what a view
holds.

## Failures

A refused required Capability or any System Permission ends the whole
invocation even if the script catches the error. A denied Capability the
manifest declares optional for the current Command is thrown as an `Error`
whose `code` is `capability_denied`; the script may catch it and offer another
path. Each later request still checks its own grant. An undeclared or
out-of-scope Capability is never recoverable, even when its optional grant is denied. The Host checks the request's target, operation and data scope independently before deciding whether a missing optional grant can be caught. A Plugin Storage write over a
limit is also catchable, with `code` `storage_limit_exceeded`. A business
error, such as a service answering 404, is a result the script handles,
not a failure.

A Host Service fails with one of these categories:

| Category | Meaning |
| --- | --- |
| `capability_denied` | The Plugin was not granted the Capability, or the target is outside its scope |
| `system_permission_denied` | Spinnet lacks the macOS permission the service needs |
| `automation_permission_denied` | macOS refused Spinnet's Apple Events to the application |
| `external_app_missing` | The External App is not installed |
| `external_app_operation_unsupported` | The application's Reviewed App Interface has no such operation |
| `host_service_failed` | The input was invalid, or the provider or request failed |
| `storage_limit_exceeded` | A Plugin Storage write would pass a limit, and stored nothing |

The Action then ends with the same category, which the Host shows with repair
guidance where there is one; an uncaught `storage_limit_exceeded` ends it as
`host_service_failed`. An Action may also end with
`scripted_action_failed` (the script threw), `timed_out`, `cancelled` (the user cancelled its progress),
`helper_unavailable` (the helper could not be started), `helper_crashed` (the
helper exited by a signal), `helper_terminated` (it was
ended for its memory), `runtime_protocol_failed` (the script's answer is not
an answer, or the helper broke the protocol), `command_unavailable` (its
Plugin or Command is missing, disabled or changed), or `invalid_configuration`
(its configured input does not suit the Command).

## Limits

- A scripted Action has a four-second deadline. After 500 ms the Host shows
  progress the user can cancel. Each View Event is an invocation with the same
  deadline.
- A helper message is at most 1 MiB of UTF-8 JSON, so no value a script sends
  or receives in one message may be larger.
- A helper whose `phys_footprint` stays at or above 64 MiB for two consecutive
  100 ms samples is ended with `helper_terminated`.
- Each invocation gets a fresh JavaScript context, so nothing a script keeps
  in memory survives to the next one; [Plugin Storage](host-services.md#plugin-storage)
  and a view's `state` do.
- One invocation runs at a time per Plugin. Consecutive invocations reuse the
  Plugin's helper, which exits after 30 seconds idle, and is ended at once
  when the Plugin is disabled, removed or updated, when a Capability it holds
  is revoked, or when Spinnet quits. Registering a Plugin, opening the Menu,
  and Host Commands start no helper.

## The helper protocol

The helper is part of Spinnet, so a Plugin never speaks this protocol itself;
it is published because it bounds what a script can do, and the Plugin test
kit runs the same helper. Messages are newline-delimited JSON objects of at
most 1 MiB each, the newline excluded, framed by protocol version `1.0`. The
Host starts an invocation:

```json
{
  "type": "invocation",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "plugin_id": "com.example.plugin",
  "action_id": "action-1",
  "command_id": "example.transform",
  "script_path": "transform.js",
  "script_source": "input",
  "input": "Selected text",
  "environment": {"host_version": "1.0.0", "preferred_language": "en-US"},
  "event": null,
  "state": null
}
```

The helper always installs the current SDK. Obsolete declaration members are
protocol errors; no invocation selects a historical mode.

While the script runs, the helper may request a Host Service. The request
carries only the invocation and Action identifiers; the Host takes the Plugin's
identity from the connection, never from a message, and checks the current
manifest, grant and System Permission for every request:

```json
{
  "type": "host_service_request",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "action_id": "action-1",
  "request_id": "host-service-1",
  "service": "selection.readText",
  "input": null
}
```

A Plugin's helper names the catalogue ID in `service`, such as
`"selection.readText"`, and the Host refuses a name the Plugin may not use
with `host_service_failed` and the reason.

```json
{
  "type": "host_service_response",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "action_id": "action-1",
  "request_id": "host-service-1",
  "outcome": {
    "kind": "succeeded",
    "result": "Selected text"
  }
}
```

A failed outcome carries one of the failure categories above. For a denied
optional Capability declared and scoped to the current Command, the Host
adds `"optional_capability_denied": true` to its response; this marks that
single denial as catchable and grants no authority. It is omitted otherwise
and valid only with a `capability_denied` failure. This is Host-to-helper
metadata, never a Plugin request or answer member.

Each invocation
ends in exactly one terminal message, `succeeded` with the script's answer as
`result`, or `failed` with a `failure`:

```json
{
  "type": "terminal",
  "protocol_version": "1.0",
  "invocation_id": "invocation-1",
  "action_id": "action-1",
  "terminal": {
    "kind": "succeeded",
    "result": {"toast": "Transformed"}
  }
}
```

After 30 seconds idle the Host sends `{"type":"shutdown","protocol_version":"1.0"}`
and closes the helper's input; a helper still alive 250 ms later is ended.
Unknown protocol versions, message types or terminal kinds, missing fields,
invalid values, messages over 1 MiB, and duplicate, out-of-order or unsolicited
messages close that helper's connection, and any waiting Action ends with
`runtime_protocol_failed`. A retired helper's work is never replayed.
