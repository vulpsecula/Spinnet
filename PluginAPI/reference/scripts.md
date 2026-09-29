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
| `spinnet` | The SDK object, from [`spinnet.js`](../spinnet.js) |
| `requestHostService(name, input)` | Sends a Capability-checked request to the Host and returns its JSON result |

[`spinnet.d.ts`](../spinnet.d.ts) types them all.

## The spinnet SDK

Every script runs with a `spinnet` global, organised by area. Each wrapper is
a camelCase name for exactly one Host Service: it sends its argument as the
service's input, unchanged (`null` when omitted), and returns the answer, so it
fails exactly as `requestHostService` does. `spinnet.ui` is the exception: its
builders only build views and answers, and request nothing. The
[catalogue](../README.md#what-level-1-offers) lists every wrapper and the
service it requests.

`spinnet.environment` is decided by the Host: `apiLevel`, the highest Plugin
API Level it supports; `hostVersion`, its bundle version; `preferredLanguage`,
the BCP 47 code of the user's first preferred language, such as `en-US`; and
the invocation's `pluginID`, `commandID`, `actionID` and `invocationID`.

## The answer

A script answers with the value of its last expression, as
[View Sessions](views.md#view-sessions) describes: `{view, state}`,
`{close: true}`, `null`, or any of them with a `toast`. Any other value is a
protocol violation: it fails an Action with `runtime_protocol_failed` and ends
a View Session. [`schemas/view-session.schema.json`](../schemas/view-session.schema.json)
publishes the answers and events, and [Plugin Views](views.md) what a view
holds.

## Failures

A refused Capability or System Permission ends the whole invocation even if the
script catches the error, so a denied request cannot fall through to a later
protected operation. The one failure a script may catch is a Plugin Storage
write over a limit, thrown as an `Error` whose `code` is
`storage_limit_exceeded`. A business error, such as a service answering 404,
is a result the script handles, not a failure.

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
  "environment": {"api_level": 1, "host_version": "0.1.0", "preferred_language": "en-US"},
  "event": null,
  "state": null
}
```

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
  "service": "read_selected_text",
  "input": null
}
```

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

A failed outcome carries one of the failure categories above. Each invocation
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
