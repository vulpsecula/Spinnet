# Host-run sources (Plugin API Level 2)

Implemented by #82, #85, #86 and #87. A visible page may name up to eight `http.request`, `tools.read`, reviewed `apps.perform` or `system.metrics` sources.
The Host performs them without keeping the helper alive and renders each result
as plain text through bindings. HTTPS samples once and has a 15-second deadline;
`every` is refused. Homebrew reads also sample once with a 15-second deadline and the same scope and result as a call; see [Reviewed Homebrew reads](tools.md). The local Spotify playback adapter samples at a minimum of one second with a three-second deadline, without launching Spotify or prompting for Automation; see [Local Spotify](spotify.md). `system.metrics` reads aggregate CPU, memory, startup disk capacity and internal battery under `read_system_status`, with a one-second minimum and deadline; see [metric meanings, units and unavailable values](namespaces.md#systemmetrics-level-2-86). Its snapshots are bound without invoking a helper and its CPU baseline is discarded on hide, close or source replacement.

```js
const c = spinnet.ui.components;
return spinnet.ui.showPage(spinnet.ui.page({
  id: "weather", title: "Weather",
  sources: [spinnet.http.request.source("remote", {
    method: "GET", url: "https://example.com/weather"
  })],
  content: [c.text({id: "temperature", text: "Waiting",
    bind: c.bind("remote", "/json/temperature", {format: "decimal"})})]
}));
```

A source is `{id, perform, input, every?, deliver?, error_pointer?, status_messages?}`.
`input` is the operation's complete input, Credential Uses included. IDs are
unique within a page. `deliver: {}` also hands a changed result to the script;
`deliver: {pointer: "/json/version"}` watches only that RFC 6901 pointer. The
SDK's `deliver: true` builds `{}`. `ui.source(id, perform, input, options)` is the
generic builder; `http.request.source(id, input, options)` selects HTTPS and
`system.metrics.source(id, input, {every: 1})` selects basic system metrics.
`errorPointer` and `statusMessages` SDK options map to their snake-case members.

The HTTPS result is `{status, headers, body, json?}`: existing `http.request`
fields with the parsed JSON body when parsing succeeds. Only 2xx responses
succeed. A failed response uses `status_messages` first, then a nonblank string
at `error_pointer` in the JSON body, then the status message. Sources bypass
`FetchedResponseCache`. The Command must declare `contact_https`, its grant
must stand, and the destination must be among its current consented hosts.
Authority is read without prompting before each send and before showing or
queuing its result. A refused read may deliver its bounded failure metadata,
but never the refused result. Credential Uses never expose a stored secret to the script.

A text component's `bind` is `{source, pointer, format?, unavailable?}`. It must
name one of this page's sources. Until the first result the Host shows `text`;
a missing, null or wrongly typed value shows `unavailable` (default
"Unavailable"). `text` accepts strings and numbers, `integer` integral numbers,
`decimal` one fraction digit, `percent` fractions from 0 to 1, `bytes` nonnegative
integral byte counts, and `duration` nonnegative seconds as `m:ss` or `h:mm:ss`.
Formatting uses the user's locale; shown text is truncated at 4,096 characters.
Failure keeps the last good value dimmed and VoiceOver says "out of date";
without a good value the component shows the bounded failure message. A binding
changes neither Immediate State nor Plugin state and invokes no helper.

A page is visible only while its session is open, its current panel is ordered
in and unoccluded, the user's session is active and displays are awake. Hiding
cancels observations and drops their late results. Bound values become stale.
Showing resumes incomplete once samples; a completed successful HTTPS source
never repeats. Local adapters must publish a minimum of at least one second,
a sample deadline, authority checks and bounded result; future repeating
adapters use fixed delay from completion and allow only one sample in flight.
Timers have 10 percent leeway. This addition offers no background schedules.

With `deliver`, the first outcome is queued, then only changes to the watched
value or failure category. `source_delivered` contains `page`, `source`, positive
`sequence`, and exactly one of `result` and `failure: {category, message}`.
Supported failure categories are `capability_denied`, `host_service_failed` and
`timed_out`; reviewed App sources also offer `external_app_missing`,
`external_app_not_running`, `automation_permission_needed`,
`automation_permission_denied` and `external_app_operation_unsupported`, plus `tool_missing`, `tool_timed_out`, `tool_failed` and `output_too_large` for reviewed tool sources. It is not a gesture; its answer may not request an operation.
Deliveries of one source ID are at least 15 seconds apart, across redefinitions.
At most one waits per source; newer results replace older waiting ones. A floor-held
result waits while hidden and is considered on show; a result already queued in
the View Session may dispatch while hidden, because sampling has already ended.

Retention requires the same current page instance and handler Command, equal
complete source definition and unchanged credential generation. Equal answers
keep cadence, inflight sample, last value and pending delivery. Another page,
`reset: "page"`, another handler Command, redefinition or omission cancels the
old source and drops its provenance. Definitions carry all result/authority inputs;
Plugin Settings changes keep their current input until the next script answer.
Stored or removed referenced credentials replace affected records and discard
old-secret results. New definitions in non-gesture answers wait the adapter's
minimum interval before sampling. Queued provenance is tested at dispatch;
a dropped delivery is never redelivered. Ending the session, disable, update,
removal or Capability revocation cancels every source. Adding authority retries
a once source which failed for want of it.

Bounds: eight sources/page; at most one sample in flight/source; one pending
result/source; source result at most 512 KiB of encoded JSON; state and page
keep their existing 64 KiB/256 KiB budgets; pointer at most 512 characters;
bound text at most 4,096; failure message at most 512. Existing HTTPS limits
still apply (128 KiB response body, three redirects and four Credential Uses).
See [schemas](../schemas/host-run-sources.schema.json),
[recordings](../fixtures/sources/index.json), and [measurements](../fixtures/sources/measurements.md).
Level 1 Host-Fetched Sections and their cache/deadlines retain their existing contract.
