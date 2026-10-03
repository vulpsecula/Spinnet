# Host Services

A Host Service is a controlled operation the Host performs for any Plugin
granted it, never shaped around one Plugin's feature. A script requests one
through its `spinnet` wrapper or `requestHostService(name, input)`. For every
request the Host reads the current manifest, grant and System Permission
afresh; a helper message never carries a Plugin identity or a Capability claim.
How a failure reaches the script is in [Scripts](scripts.md#failures); the
[catalogue](../README.md#what-level-1-offers) lists each service with its
wrapper, Capability and System Permission.

## Text

### detect_language

`detect_language` requires no Capability and no System Permission. Its input
is a text string the Plugin already holds; its result is the BCP 47 code of
that text, such as `en` or `zh-Hans`, decided on this Mac by the Natural
Language framework, or `null` when the text is too short or mixed to tell
(confidence below 0.5). Nothing leaves the machine. Other input fails with
`host_service_failed`.

### read_selected_text

`read_selected_text` requires the `read_selected_text` Capability and the
macOS Accessibility System Permission. Its input is `null` and its result is a
string. Every Plugin and Host Command that reads a selection goes through this
one reader.

The Host first reads the focused selection through Accessibility. When an App
exposes no readable selection, the Host may fall back to a targeted
`Command-C`, but only when the same Command also declares and receives a
text-scoped `read_current_clipboard` grant; without that separate grant the
Host stays Accessibility-only. The Host waits briefly for the copy, restores
the saved pasteboard only if the change stays stable while the target App is
frontmost, and keeps these temporary contents out of Clipboard History. A
completed copy with no clipboard change returns empty text, so a Plugin can
wait for text it is given instead; an interrupted or unavailable copy keeps the
Accessibility error. Some Apps write one Copy in several pasteboard steps, so
each further change while the target stays frontmost restarts the brief wait,
up to a quarter of a second. Apps that forbid copying leave the pasteboard
unchanged and read as empty. AppKit does not say which process wrote a
pasteboard change, so this is best-effort: a single unrelated text write in the
same moment may be taken for the copy. The separate Capability makes that
possible read explicit to the user. The Host never returns its saved pre-copy
snapshot.

A failed Host Service ends the Action, so a Plugin with its own fallback sends
`{ "best_effort": true }` instead of `null`. The result is then `null` when the
selection could not be read, and still a string, possibly empty, when it was.
Capability refusals and a missing Accessibility permission still fail the
request.

### insert_text

`insert_text` requires the `insert_into_focused_app` Capability and the
Accessibility System Permission. Its input is a string of at most 128 KiB, the
largest text an HTTPS response can carry, and its result is `null`. It replaces
the selection in the App in front with the text, as typing it would; it never
pastes and does not touch the clipboard.

The Host brings that App to the keyboard, which an open Plugin View gives up
(an unpinned view closes, as it does whenever it loses focus), and types the
text into it as keyboard events: a line break as Shift-Return and a tab as the
Tab key, so the App treats them as it treats those keys; in a terminal a line
break runs the line, as pasting it would. The call returns once
the text has been typed, which for a long text takes a while, and success
means the Host delivered it, not that the App kept it. The Host refuses, typing
nothing, when no other App is in front or it does not come to the keyboard
within about a second, when the focused field is a password field, and when the
text holds a control character other than a tab or a line break; it stops if
the App leaves the front while the text is typed.

## Clipboard

### write_clipboard

`write_clipboard` requires the `write_clipboard` Capability. Its input is a
string and its result is `null`.

### read_current_clipboard

`read_current_clipboard` requires its own `read_current_clipboard` Capability.
Input is `null`; the result is `{ "text": "…", "type": "text" }` or type `url`,
or `null` when no supported, permitted content is available. It does not read
Clipboard History.

## Clipboard History

`read_clipboard_history`, `read_clipboard_history_content` and
`present_clipboard_history` all require the `read_clipboard_history`
Capability, including the manifest's exact data-type scope. None of them
enables or resumes collection: only the Host collects clipboard changes, and
only while the user has turned collection on. Collection, pause, retention
(1, 7 or 30 days) and clearing are the user's settings, independent of any
grant.

The supported `data_types` are `text`, `url`, `image`, `rich_text`,
`file_reference`, and `binary`. Known UTType families are normalized to their
category, including UTF-16 plain-text aliases, which are decoded and returned
as UTF-8; a known textual representation cannot fall back to `binary` to bypass
its grant. One grant lists every requested type and discloses access to entries
retained before it. Adding a type requires new consent.

### present_clipboard_history

`present_clipboard_history` accepts `null`, opens the Clipboard History window,
and returns `null`. It is the one Host Surface: the user reads their own
history there and the Plugin learns nothing, so the granted Capability is all
it needs, whether the Plugin is Bundled or installed.

### read_clipboard_history

`read_clipboard_history` accepts `null` for the newest page or
`{ "offset": 50 }` for a nonnegative integer offset. The result has `state`
(`off`, `paused`, or `collecting`), `entries`, an optional `nextOffset`, and an
optional `expiresAt`. Dates are seconds since 2001-01-01 UTC. Off and paused
collections can still have retained entries; denied access is an error, not an
empty page.

Pages contain at most 50 copies and at most 512 KiB of encoded representation
metadata. Offsets count authorized representations, not copies. A copy is
deferred intact to the next page when it will not fit; if one copy alone
exceeds the metadata budget, its representations continue with the same
`copyID`, and `continuingCopyID` identifies that copy. Follow `nextOffset`; do
not assume a fixed page size. Pagination is a live view, not a transaction
across clipboard changes.

Each entry has `id` (UUID), `contentType`, `text` (a bounded display preview),
`sourceApplicationName`, `sourceBundleIdentifier`, and `copiedAt`. Payload
entries also have `byteCount` and `format` (the pasteboard type identifier;
textual payloads use UTF-8). The preview is bounded by characters and by bytes,
and stops at whichever bound it reaches first: at most 2048 characters for
every type, and at most 2048 UTF-8 bytes, raised to 8192 for a `rich_text`
representation. An incomplete trailing character can display as a replacement
character. Use the content service for the retained bytes, not the preview.
Each representation has its own type-scoped `id` for content reads. Entries
also carry `copyID` and a zero-based `itemIndex`: representations of one copy
share its `copyID`. Entries recorded before these fields existed lack them and
read as copies of their own.

A copy identical to a retained one moves that one to the newest position,
keeping its IDs and updating its time and source. Source attribution is the
App in front when the copy was sampled, not a verified pasteboard writer; no
window or document title is collected.

Additional type-scoped metadata:

- `imagePreview`: `pixelWidth`, `pixelHeight`, and optional `thumbnail` (base64
  JPEG, at most 32 KiB, at most 128 pixels on its longest edge). Unsupported or
  malformed images can keep their original bytes without a thumbnail.
- `fileReference`: `name`, `typeIdentifier`, optional `byteCount`,
  `previewIcon` (`doc` or `folder`), and optional `unavailableReason`. The Host
  keeps the copied name, type and size and checks the original file when it is
  read. Moved, deleted, replaced, or inaccessible files stay listed. Source
  paths are never exposed, source files are never read by content reads, and
  file promises are never fulfilled. An `imagePreview` may be kept for a
  regular, readable, non-symlink, non-cloud, local PNG/JPEG/TIFF/GIF/HEIC file
  of at most 20 MiB, at most 40 megapixels, and at most 20,000 pixels per
  dimension. These previews require the `file_reference` grant, not an `image`
  grant, and are hidden when the reference becomes unavailable or its
  modification date changes. File-reference representations take precedence
  over alternative representations of the same item, including `file:` URLs.

### read_clipboard_history_content

`read_clipboard_history_content` accepts exactly:

```json
{"entry_id":"11111111-1111-1111-1111-111111111111","offset":0,"length":196608}
```

`offset` is a nonnegative byte offset; `length` is an integer from 1 through
196608 (192 KiB). The result is:

```json
{"data":"AQID","offset":0,"totalBytes":3}
```

`data` is base64. If more bytes remain, `nextOffset` gives the next byte
offset; otherwise it is absent. An offset exactly at the end returns empty
data. Offsets past the end, malformed UUIDs, extra members, fractional offsets,
and excessive lengths are invalid input. Reassemble bytes before decoding UTF-8,
because chunks can split a character. File references have no retained payload
and reject content reads.

Every chunk rechecks the grant and type scope and expires old entries first.
Knowing another entry's UUID grants no access. Missing, cleared, expired, or
out-of-scope entries return an unavailable error; revocation returns
`capability_denied`. The 1 MiB message limit, the four-second deadline and the
helper's memory limit still apply, so process bounded chunks rather than
accumulating a large payload in one invocation.

## Focused window

`read_focused_window`, `set_focused_window_frame`,
`toggle_focused_window_full_screen` and `restore_focused_window_frame` require
the `position_focused_window` Capability and the Accessibility System
Permission. Coordinates are global points with the origin at the top-left of
the primary display and y growing downwards, as Accessibility reports window
frames. A Plugin never names a window, its application, or an accessibility
action.

### read_focused_window

It accepts `null` and returns the focused window's frame and the visible frame
of the screen holding most of it: the screen less the menu bar, the Dock, and
Stage Manager's strip while it is shown.

```json
{"frame":{"x":100,"y":120,"width":600,"height":400},
 "visibleFrame":{"x":0,"y":25,"width":1440,"height":875}}
```

The result also carries `displays`, every display's visible frame in the same
coordinates, left to right and then top to bottom, and `displayIndex`, the
position in it of the display holding the window. Nothing identifies the window
or its application.

### set_focused_window_frame

It accepts exactly `{"x":…,"y":…,"width":…,"height":…}` with finite numbers,
coordinates within ±100000, and a size greater than 0 and at most 100000, and
returns `null`. It applies only to the window `read_focused_window` last
returned, and only while that window is still focused; if focus moved in
between, the request fails and nothing moves. A missing focused window, or one
whose position or size cannot be set, fails with `host_service_failed` before
anything changes; a write the window rejects part-way restores its original
frame. A full-screen window fails with "leave full screen before choosing a
layout" and does not move.

### toggle_focused_window_full_screen

It accepts `null` and returns `null`, moving whichever window is focused into
or out of macOS full screen. A window that does not report its full-screen
state, or does not allow it to be set, fails with `host_service_failed` and
nothing changes.

### restore_focused_window_frame

It accepts only `null` and returns `null`. It returns the focused window to the
frame it had before Spinnet last moved it. Before each
`set_focused_window_frame` the Host records the window's frame, unless the
window is still where Spinnet last put it (within 2 points), so consecutive
layouts restore to the frame from before the first one. The Host keeps one
frame per window for the 50 most recently moved windows, in memory only, and
forgets a window's frame when it closes or is restored. A window Spinnet never
moved fails with "nothing to restore". Restoring needs no prior read: the frame
is looked up for the window focused when the request arrives.

## Opening

### open_url

`open_url` requires the `open_url` Capability and no System Permission. Its
input is a link string and its result is `null`. The Host trims the text and
opens it in the default browser only if it is an http or https link with a
host, no whitespace or control characters inside, and at most 2048 characters;
anything else fails with `host_service_failed` and nothing opens. The Plugin
learns nothing about the page, so opening a link is not fetching it.

### open_local_path

`open_local_path` requires its own `open_local_path` Capability and no System
Permission. It accepts an absolute local path or `~/path`, up to 4096 UTF-8
bytes, with no control characters or `//` prefix. The Host expands `~`, checks
that the target exists, and opens it in Finder or its default App, launching an
application if the path is one. It returns `null`, never file contents.

## Screen

### capture_screen

`capture_screen` requires the `capture_screen` Capability and the macOS Screen
Recording System Permission. It accepts
`{ "source": "area"|"fullscreen"|"window", "copy_to_clipboard": bool,
"save": null | { "folder": string, "format": "automatic"|"png"|"jpg" } }` and
returns `null` once the capture starts, because an interactive capture can
outlast the Action's deadline. At least one of copy or save is required, and
`save.folder` must equal a `folder` value the Action uses in its configuration,
so a Plugin saves only where the user chose. A missing or unwritable folder
fails with `host_service_failed` and names the Configuration Sheet as the
repair. The clipboard always gets a lossless PNG; a saved file is PNG, JPEG, or
Automatic (JPEG for photos, gradients and noise; PNG for text and flat
colours). Area and window selection are interactive and full screen captures
the main display; the Plugin never receives the image. Cancelling with Esc is
not a failure; a copy or save that fails afterwards is reported by the Host,
and a second capture while one is running is refused.

## HTTPS

### https_request

`https_request` requires `contact_https`. Its input, published with its result
in [`schemas/https-request.schema.json`](../schemas/https-request.schema.json),
is:

```json
{"method":"GET","url":"https://api.example.com/v2/translate",
 "headers":{"content-type":"application/json"},"body":"…",
 "credential_uses":[{"reference":"deepl","header":"Authorization",
                     "template":"DeepL-Auth-Key {credential}"}]}
```

`method` is `GET` or `POST`. The host must be declared in the scope's
`https_hosts` or added by the user through an `https_endpoint` field; the port
must be absent or 443 and the URL carries no credentials. Authorization,
Cookie, Host, framing, `proxy-*`, and `sec-*` headers are refused, and a
request has at most 32 headers. Request and response bodies are at most
128 KiB, so a response always fits one helper message. The Host follows at
most 3 redirects, only to consented hosts, and applies Credential Uses only on
the original host: a redirect to another host drops every placed or signed
value and sends the body as the Plugin wrote it. The Plugin never sees the
secret. A request has a 3-second budget inside the Action deadline and uses an
ephemeral session with no cookies, cache, or stored credentials. The result is
`{"status":200,"headers":{"content-type":…},"body":"…"}` with a UTF-8 body;
only `content-type`, `content-language`, and `retry-after` headers are
returned. A Host-Fetched Section sends the same input with its own budget (see
[Plugin Views](views.md#host-fetched-sections)).

### Credential Uses

A request names a stored credential only through `credential_uses`, an array of
at most 4 Credential Uses (ADR 0011). The Host looks each secret up by its
`reference`, the reference the Plugin's `credential` field holds, not the
field's key; a script reads it from its `input`, as
`{reference: input.deepl_credential, …}`. The Host computes the value and
places it as the request is sent. Neither the secret nor anything derived
from it is returned to the Plugin.

```json
{"reference":"baidu",
 "query":"sign",
 "signature":{"algorithm":"md5","message":"2015063000000001apple1435660288{credential}",
              "encoding":"hex"}}
```

Each use names exactly one placement:

- `header`: a header name. Authorization is allowed here, and only here.
- `query`: a query parameter, appended to the URL and refused if the URL
  already has it.
- `path_segment`: a zero-based index of the URL path segment to replace.
- `json_body`: an RFC 6901 pointer to an existing string in a JSON body; only
  that string changes.
- `form_body`: a form field, appended and refused if the body already has it.

The optional `template` wraps the value and holds it exactly once, as
`{credential}` for a plain use or `{signature}` for a signed one; by default it
is the value alone. Query, path and form values are percent-encoded to RFC 3986
unreserved characters.

A `signature` computes the value instead of placing the credential itself:

- `md5`, `sha1`, or `sha256` hash `message`, which holds `{credential}` exactly
  once.
- `hmac_sha1` or `hmac_sha256` sign `message` as written, keyed with `key`, a
  template holding `{credential}` exactly once (by default the credential
  alone). An optional `chain` of at most 8 texts is signed first, each keyed
  with the result of the one before, as in TC3-HMAC-SHA256.
- `encoding` is `hex`, `hex_upper`, or `base64`.

Templates, HMAC keys, and chain steps are at most 1024 characters. Everything
else a signature needs, such as a salt, a timestamp, or the normalised text, is
supplied by the Plugin. A Credential Use outside this set, or one naming no
placement or more than one, fails with `host_service_failed` before anything is
sent or any secret is read; a scheme the set cannot express needs a Host
release. This covers header-token services (DeepL, OpenAI), path and query
keys (ExchangeRate-API, UniRate), and signed APIs (Baidu, Youdao v3, Tencent
TC3). OAuth is not covered.

## External Apps

`perform_app_operation` and `open_deep_link` require the `control_external_app`
Capability, whose scope names each External App the Plugin reaches. Their
inputs, and every Reviewed App Interface the Host ships, are published in
[`schemas/external-apps.schema.json`](../schemas/external-apps.schema.json).
Which Command uses which operation or template is the Plugin's choice. When an
External App a Command reaches is not installed, its Menu Items are
unavailable with "Install <App> to use <App> Commands", naming the application
as the Plugin's manifest does.

### perform_app_operation

Its input is `{bundle_id, operation, arguments?}`, and its result is `null`.
The Host sends Apple Events only through a Reviewed App Interface it ships for
that application (ADR 0012): the scope's `operation_families` must include the
operation's family, the operation must be one the interface describes, and its
arguments must be exactly the interface's parameters within their budgets. The
Host then builds the one request the interface describes, sends it to the
interface's handler, and escapes the argument as an AppleScript string literal;
the Plugin cannot send AppleScript source, arbitrary Apple Events, or another
handler. macOS asks the user separately for Automation consent, which they
manage in System Settings > Privacy & Security > Automation.

Level 1 ships one Reviewed App Interface. Bob (`com.hezongyidev.Bob`), through
its `request` handler: the `translate` family's operations
`selectionTranslate`, `snipTranslate`, `inputTranslate`,
`pasteboardTranslate`, and `translateText`, which alone takes `text`,
non-blank and at most 128 KiB of UTF-8. Bob reads the selection, clipboard or
screen where asked and shows the result itself. Adding an application is a Host
release.

### open_deep_link

Its input is `{template, parameters?}`, and its result is `null`. A Plugin
declares Deep Link Templates in its `control_external_app` scope, under an
External App entry's `deep_link_templates`: each has an `id`, a `url` in the
app's own scheme (not http, https, or file, which have their own services), and
`parameters`, each a `choice` among URL-safe `choices` or `text` of at most
`max_length` characters, percent-encoded. Every placeholder sits after the host
and appears exactly once. The Host fills the template with exactly its
parameters, checks that the declared application handles the scheme, and opens
the link without bringing the application forward. Consent lists the
templates; because they are part of the scope, changing one asks the user
again. A Command may open a template declaratively with the `deep_link.open`
Host Command instead, so it needs no script.

## Plugin Storage

Each Plugin has its own key-value store of JSON values, kept between
invocations and launches, which no other Plugin can reach (ADR 0015). It needs
no Capability and no consent: a Plugin keeps there only what it already holds.
The Library shows how much each Plugin keeps and offers Clear Stored Data;
removing a Plugin deletes its store, so installing it again starts empty, and
an update keeps it. It is not the Keychain and never the place for a secret.
[`schemas/plugin-storage.schema.json`](../schemas/plugin-storage.schema.json)
publishes the inputs and results.

```js
const runs = (spinnet.storage.get("runs") ?? 0) + 1;
spinnet.storage.set({ key: "runs", value: runs });
```

A key is a non-empty string of at most 128 characters. `get_storage_value`
takes a key and answers its value or `null`; `set_storage_value` takes exactly
`{key, value}`, and a `null` value removes the key; `remove_storage_value`
takes a key; `list_storage_keys` and `clear_storage` take `null`, and the first
answers the sorted key names only. A value may be up to 512 KiB as JSON, so it
always fits in one helper message; a Plugin may keep up to 10 MiB, the default
capacity of Raycast's `Cache`, and it may keep up to 1000 keys, so the list of
its keys always fits in one message too. A write over a limit stores nothing and
fails with `storage_limit_exceeded`, the one Host Service failure the helper
throws into the script as an `Error` (with that `code`) the script may catch;
uncaught, it ends the Action as `host_service_failed`. A write replaces only
its own key's value, all at once.
