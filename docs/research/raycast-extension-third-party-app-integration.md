# Raycast Extension integration and permission lessons for Spinnet

Researched 2026-09-04 against Raycast's official developer documentation and Store source repository, Apple's developer documentation, and the official Bob and Shottr integration documentation.

## Executive conclusion

Raycast does not provide one universal interface for controlling arbitrary macOS applications. A Raycast Extension is an adapter: it combines Raycast's Host APIs with whichever interface the target application or service exposes, such as a custom URL scheme, AppleScript/JXA dictionary, executable or CLI, or HTTP API. The Bob Extension in Raycast's official Store repository sends Bob's documented JSON request through AppleScript, while the repository's Shottr Extension opens Shottr's documented custom URLs. [Bob Extension source](https://raw.githubusercontent.com/raycast/extensions/main/extensions/bob/src/utils.ts) [Bob AppleScript integration](https://bobtranslate.com/guide/integration/applescript.html) [Shottr Extension source](https://github.com/raycast/extensions/blob/8a4409d03a593ea0b69b825b525c80753102a379/extensions/shottr/src/ssa.tsx) [Shottr URL schemes](https://www.shottr.cc/kb/urlschemes)

Spinnet should copy this *adapter pattern*, not Raycast's security boundary. Raycast explicitly says Extensions are not further sandboxed for file I/O, networking, or other Node.js facilities. By contrast, Spinnet already requires scripted Actions to run in a per-Plugin helper and obtain protected functionality only through Capability-checked Host Services. That decision in [ADR-0007](../adr/0007-isolate-scripted-actions-in-per-plugin-helpers.md) should remain intact. [Raycast security model](https://developers.raycast.com/information/security)

The practical MVP rule should be:

1. Prefer a narrow Host Service or a target application's documented URL scheme.
2. Use a target application's documented AppleScript interface when a deep link cannot carry the required operation or result.
3. Use a documented CLI only through an operation-specific Host Service with a fixed executable identity and structured arguments.
4. Do not grant a Plugin arbitrary shell, Apple Events, filesystem, or network authority merely because its implementation is scripted.
5. Treat Accessibility-based GUI scripting as a last-resort compatibility mechanism, not the normal third-party integration API.

## What Raycast Extensions can actually do

### Runtime and permission model

Raycast starts a child Node.js process and loads each Extension into its own V8 isolate with its own event loop, JavaScript engine, Node instance, and limited heap. Native Raycast operations cross a thin RPC protocol, but normal Node file I/O, networking, and other runtime features are not subject to a per-Extension permission sandbox. macOS-protected access is attributed to the parent Raycast application. [Raycast security model](https://developers.raycast.com/information/security)

The documented Extension manifest declares Commands, preferences, arguments, tools, and metadata, but has no general `permissions` or per-domain network allow-list field. Required preferences can block a Command until configured, and password preferences are stored in Raycast's encrypted database, isolated to the corresponding Extension. [Raycast manifest](https://developers.raycast.com/information/manifest) [Raycast preferences](https://developers.raycast.com/api-reference/preferences) [Raycast security model](https://developers.raycast.com/information/security)

This produces three different things that should not be conflated:

- `environment.canAccess(...)` reports product/API availability for APIs such as Raycast Pro's Window Management or the separately installed Browser Extension; it is not a general per-Extension security grant. [Window Management API](https://developers.raycast.com/api-reference/window-management) [Browser Extension API](https://developers.raycast.com/api-reference/browser-extension)
- Raycast asks before one Extension programmatically launches a Command from another Extension. This is a specific cross-Extension consent check, not a general Capability system. [Command API](https://developers.raycast.com/api-reference/command)
- AI Extension tools have their own per-tool confirmation setting. That feature applies to AI tool invocation and does not describe the authority of ordinary Extension Commands. [Raycast AI Extensions manual](https://manual.raycast.com/ai/ai-extensions)

### Integration mechanisms

| Mechanism | What Raycast supplies | What actually performs the integration | Permission implication |
| --- | --- | --- | --- |
| Raycast Host API | `open`, application discovery, selected text, clipboard, Window Management, and cross-Command launch | Raycast's native Host reached over its Extension RPC | macOS authority belongs to Raycast; some APIs have availability gates, but Raycast does not expose a general per-Extension Capability manifest. [System Utilities](https://developers.raycast.com/api-reference/utilities) [Environment APIs](https://developers.raycast.com/api-reference/environment) [Clipboard API](https://developers.raycast.com/api-reference/clipboard) [Window Management API](https://developers.raycast.com/api-reference/window-management) |
| URL scheme or deep link | `open(...)`, Node process execution, or an `open` CLI invocation | Launch Services dispatches the URL to the registered application | Usually no Automation prompt, but the target App must be installed and support the exact scheme. Custom schemes can be claimed by more than one App and parameters must be treated as untrusted. [Raycast System Utilities](https://developers.raycast.com/api-reference/utilities) [Apple custom URL schemes](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app) [NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace) |
| AppleScript or JXA | `runAppleScript`, supporting both AppleScript and JavaScript-for-Automation syntax | `osascript`/OSA sends Apple Events to a scriptable target application | Controlling another App is Automation, separate from Accessibility. A hardened client needs the Apple Events entitlement to be allowed to prompt. [Raycast `runAppleScript`](https://developers.raycast.com/utilities/functions/runapplescript) [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events) |
| Executable or CLI | Node `child_process`, Script Commands, or `useExec` | The invoked executable implements the operation | Raycast warns that shell mode is slower, platform-specific, and injection-prone. Script-triggered macOS consent is granted to Raycast, not Terminal. [Raycast `useExec`](https://developers.raycast.com/utilities/react-hooks/useexec) [Raycast Script Commands](https://manual.raycast.com/script-commands) |
| HTTP API | Node networking, standard `fetch`, libraries, or `useFetch` | A remote service implements the operation | Raycast does not apply per-Extension network restrictions. In an App Sandbox, Apple's outbound-network entitlement permits connections but is not per-Plugin or per-domain user consent. [Raycast `useFetch`](https://developers.raycast.com/utilities/react-hooks/usefetch) [Raycast security model](https://developers.raycast.com/information/security) [Apple security entitlements](https://developer.apple.com/documentation/bundleresources/security-entitlements) |
| Accessibility/UI automation | Raycast's own Host features or Extension scripts using macOS accessibility tooling | macOS Accessibility APIs inspect or control another App's UI | Requires the user to trust the controlling process as an Accessibility client. This is broader and more fragile than a documented target-App API. [Apple AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h) [Raycast Navigation permissions](https://manual.raycast.com/navigation) |

AppleScript is an execution language, not a capability category: one script may only transform local text, another may send Apple Events to Bob, and another may perform Accessibility GUI scripting through System Events. Spinnet must authorize the operation requested through the Host Service, not grant blanket authority because the Action is labelled “AppleScript.” Apple's App Sandbox documentation also calls out arbitrary Apple Events and accessibility APIs as restricted activities, reinforcing the need for narrow brokerage rather than a generic automation switch. [Apple App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)

## First-party integration examples

### Bob: documented Apple Events interface

Bob documents an OSA interface in which AppleScript or JXA sends a JSON object to `request` on application bundle identifier `com.hezongyidev.Bob`. Its documented actions include translating selected text, translating clipboard content, translating supplied text, showing its window, screenshot translation, and OCR. [Bob AppleScript integration](https://bobtranslate.com/guide/integration/applescript.html)

The Raycast Store's Bob Extension implements that contract rather than driving Bob's UI. Its shared helper calls `runAppleScript`, targets Bob by bundle identifier, and passes Bob's JSON request; individual Commands choose actions such as `selectionTranslate` or `translateText`. [Bob shared helper](https://raw.githubusercontent.com/raycast/extensions/main/extensions/bob/src/utils.ts) [Bob selection translation](https://raw.githubusercontent.com/raycast/extensions/main/extensions/bob/src/selectTranslate.tsx) [Bob supplied-text translation](https://raw.githubusercontent.com/raycast/extensions/main/extensions/bob/src/transArgument.tsx)

For Spinnet, there are two meaningfully different Bob adapters:

- **Delegate selection to Bob:** send Bob `selectionTranslate`. Spinnet needs permission to control Bob through Apple Events, while Bob is responsible for reading the selection and for any permissions its implementation needs.
- **Broker selection through Spinnet:** obtain selected text through a Capability-checked Host Service, then send Bob `translateText`. This gives Spinnet a clearer data-flow audit and avoids asking Bob to independently recapture context, but it also means the Host needs Accessibility and the Plugin needs selected-text authority. Bob documents both actions. [Bob AppleScript integration](https://bobtranslate.com/guide/integration/applescript.html)

The second design is the better fit for Spinnet when the selected text is already part of Action context: the Plugin receives only the authorized value and the app-specific adapter receives a structured payload. This is a design recommendation, not a claim about Raycast's implementation.

### Shottr: documented deep links

Shottr 1.8 and later documents a URL Scheme API that must be enabled in its Advanced settings. It exposes distinct URLs for fullscreen, area, previous-area, window, scrolling, delayed, and appended captures, OCR, clipboard-image loading, uploads, and settings. Capture links can also accept a structured `then` list such as `copy`, `save`, `edit`, `pin`, or `thumbnail`. [Shottr URL schemes](https://www.shottr.cc/kb/urlschemes)

The Store's Shottr Extension maps Raycast Commands to those links. For example, its area-capture Command closes Raycast if configured and opens `shottr://grab/area`; Raycast itself is not taking the screenshot. [Shottr Extension guide](https://www.raycast.com/fernando_barrios/shottr) [Shottr area-capture source](https://github.com/raycast/extensions/blob/8a4409d03a593ea0b69b825b525c80753102a379/extensions/shottr/src/ssa.tsx)

Therefore a Spinnet Shottr adapter that only opens a documented `shottr:` URL should not request Spinnet's Screen Recording permission. Shottr performs the capture and owns its own Screen Recording consent. Spinnet instead needs a narrowly scoped external-application/deep-link Capability, should check whether Shottr is installed, and must explain when Shottr's URL Scheme API is disabled. This permission conclusion is an inference from the documented call boundary.

## macOS authority behind the requested features

### Clipboard

macOS exposes the shared pasteboard through `NSPasteboard`; it contains values copied or cut by running applications and supports text, URLs, images, files, and other types. Apple's API documentation does not describe a user-facing TCC permission for ordinary general-pasteboard reads and writes. [Apple `NSPasteboard`](https://developer.apple.com/documentation/appkit/nspasteboard)

Raycast's Extension API can read the current clipboard and at most five prior offsets. Its full Clipboard History is a Host feature with configurable retention and a Disabled Applications list that prevents changes from selected Apps—including password managers in Raycast's examples—from being recorded. [Raycast Clipboard API](https://developers.raycast.com/api-reference/clipboard) [Raycast Clipboard History manual](https://manual.raycast.com/clipboard-history)

Spinnet should therefore treat complete Clipboard History as sensitive Host-owned data, not as an unrestricted Plugin database. Reading the current value, subscribing to future changes, querying full history, writing the pasteboard, and inserting content into another App are separate operations. Inserting into another App may additionally require Accessibility depending on the Host implementation; Raycast's own features document Accessibility for reading and replacing text in the focused App. [Raycast AI Commands permissions](https://manual.raycast.com/ai/ai-commands)

### Window position and selected text

Apple's AXUIElement APIs let a trusted Accessibility client inspect attributes, determine whether they are settable, set attribute values, and perform UI actions. Raycast's Switch Windows feature documents that Accessibility is required to read and switch open windows, and its Extension Window Management API exposes the active window and structured bounds updates. [Apple AXUIElement](https://developer.apple.com/documentation/applicationservices/axuielement_h) [Raycast Navigation permissions](https://manual.raycast.com/navigation) [Raycast Window Management API](https://developers.raycast.com/api-reference/window-management)

Raycast exposes `getSelectedText()` to Extensions. Raycast's newer Screen Awareness documentation explicitly says it reads selected text from the system accessibility layer without touching the clipboard, and requires Accessibility for focused-App content. [Raycast Environment APIs](https://developers.raycast.com/api-reference/environment) [Raycast Screen Awareness](https://manual.raycast.com/ai/screen-awareness)

These sources support Accessibility-backed Host Services for Spinnet's Window Position and Smart Jump features. They do not imply that the Plugin helper itself should become an Accessibility client.

### Screenshots and screen recording

When Spinnet captures screen content itself, ScreenCaptureKit requires user consent for Screen Recording; Apple's sample notes that the first run prompts and the application must restart after the grant. Apple recommends the system content-sharing picker for choosing capture sources. [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) [Apple macOS capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)

That differs from opening a Shottr deep link: in the latter case Shottr captures the screen, so Shottr owns the Screen Recording permission. A Plugin's UI should state which application will perform the capture instead of displaying the same permission explanation for both implementations.

### Network access

Raycast Extensions may call remote APIs directly and Raycast documents both `fetch`-style utilities and the absence of per-Extension network sandboxing. [Raycast `useFetch`](https://developers.raycast.com/utilities/react-hooks/usefetch) [Raycast security model](https://developers.raycast.com/information/security)

For a sandboxed macOS Host, `com.apple.security.network.client` allows outbound connections at the application level. It is an entitlement, not a per-domain Plugin grant or a runtime user prompt. Spinnet must implement its own Plugin Capability enforcement if it wants users to approve network access by Plugin or hostname. [Apple security entitlements](https://developer.apple.com/documentation/bundleresources/security-entitlements) [Apple App Sandbox configuration](https://developer.apple.com/documentation/xcode/configuring-the-macos-app-sandbox)

## Recommended Spinnet Capability and consent model

The following names are provisional API vocabulary for a future specification, not changes to the glossary:

| Capability requested by a Plugin | Host Service | Possible System Permission | Required scope |
| --- | --- | --- | --- |
| Read selected text | `selection.read` | Accessibility | Current selection only; no general UI tree |
| Read current clipboard | `clipboard.readCurrent` | None documented for ordinary `NSPasteboard` access | One value per invocation unless explicitly subscribed |
| Query clipboard history | `clipboard.queryHistory` | None documented for ordinary `NSPasteboard` access | Host-owned, retention-aware history; separate from current clipboard |
| Write clipboard | `clipboard.write` | None documented for ordinary `NSPasteboard` access | Declared data type and invocation |
| Insert into focused App | `focusedApp.insert` | Accessibility may be required | Supplied content only; no arbitrary key injection |
| Read or move focused window | `window.readActive`, `window.setBounds` | Accessibility | Active window and structured bounds only |
| Capture screen content | `screen.capture` | Screen Recording | User-selected area/window/display and declared result type |
| Request remote service | `network.request` | Host outbound-network entitlement; no per-domain TCC prompt | Declared HTTPS hostnames, methods, redirect policy, and credential references |
| Open web URL | `url.openExternal` | None normally | `https`/`http`, validated URL |
| Invoke target-App deep link | `application.openDeepLink` | None normally | Target bundle ID, scheme, and declared route/parameters |
| Send target-App operation | `application.sendAppleEvent` | Automation / Apple Events | Exact target bundle ID and declared operation family |
| Invoke target CLI | Future operation-specific service | Depends on operation | Signed executable identity and structured argument schema; never arbitrary shell text |

The three existing domain layers should remain visible in both code and UX:

- A **Capability** is the user's grant to one Plugin.
- A **System Permission** is macOS authority granted to the Host, potentially for a particular target App in the case of Automation.
- A **Host Service** is the operation the Host brokers after checking both.

### When consent should occur

1. **Install or inspect the Plugin:** show every declared Capability, target application bundle ID, remote hostname, and whether an external App is required. Do not trigger macOS permission prompts merely for installation.
2. **Add the Plugin Preset to a Menu Slot:** for a Ready-to-Use Preset, ask for any ungranted Plugin Capabilities before committing the Menu Item. For a Setup-Required Preset, request them when the user saves its Configuration Sheet. This ties consent to an intentional use and avoids surprising prompts during Runtime Mode.
3. **Enable the dependent Host function:** if the Capability is granted but the Host lacks Accessibility, Screen Recording, or Automation, the Configuration Sheet should offer an explicit enable step and explain which feature and target App need it. The actual system dialog remains macOS-owned.
4. **Invoke at runtime:** re-check the current grant, System Permission, target-App installation, URL/API availability, and resource validity. Revocation must make the Action unavailable; runtime invocation must never silently broaden authority.
5. **Change Plugin configuration or version:** require new consent only when the declared scope expands, such as a new hostname, new target bundle ID, clipboard-history access instead of current-value access, or screen capture instead of opening Shottr.

This differs deliberately from Raycast. Raycast's normal Extensions inherit broad Node and parent-process access; Spinnet should make the Plugin the Capability principal and keep the Host as the only System Permission principal. [Raycast security model](https://developers.raycast.com/information/security) [ADR-0007](../adr/0007-isolate-scripted-actions-in-per-plugin-helpers.md)

## Mapping the proposed MVP Plugins

| Plugin / implementation | Primary data flow | Plugin Capabilities | System Permissions on Spinnet | Notes |
| --- | --- | --- | --- | --- |
| **Clipboard History** | Host observes pasteboard changes, stores policy-filtered entries, and returns user-selected results | No Plugin Capability if implemented as a trusted built-in Preset; otherwise separately grant current-read, history-query, and write/insert operations | None for ordinary pasteboard observation; Accessibility may be required only for insertion into another App | Prefer a Host-owned built-in feature. Include retention, clear-history, pause, and Disabled Applications controls before offering full history to third-party Plugins. Raycast separates its Host history from the limited Extension clipboard API. [Raycast Clipboard API](https://developers.raycast.com/api-reference/clipboard) [Raycast Clipboard History](https://manual.raycast.com/clipboard-history) |
| **Window Position** | Host reads the focused window and applies a structured frame such as center, maximize, or left half | `window.readActive`, `window.setBounds` | Accessibility | Do not expose the general AX tree or arbitrary UI actions. Raycast similarly exposes structured active-window and bounds calls. [Raycast Window Management API](https://developers.raycast.com/api-reference/window-management) |
| **Translator — direct API script** | Host reads selected text, helper decides request content, Host sends an HTTPS request, and Host displays/copies/inserts the result | `selection.read`; `network.request` scoped to declared translation hosts; optional `clipboard.write` or `focusedApp.insert` | Accessibility for selected text and possibly focused-App insertion; no per-domain macOS network prompt | API keys should be secret references controlled by the Host, not raw values exposed to unrelated Plugins. Raycast's direct network freedom is not the desired security precedent. [Raycast security model](https://developers.raycast.com/information/security) |
| **Translator — Bob adapter** | Host reads selection and sends a structured `translateText` request to Bob, or delegates `selectionTranslate` to Bob | `selection.read` only for Host-brokered selection; `application.sendAppleEvent` scoped to Bob | Automation for Bob; Accessibility additionally if Spinnet reads the selection itself | Prefer Bob's documented JSON/AppleScript interface over GUI scripting. Declare Bob as a required external App. [Bob AppleScript integration](https://bobtranslate.com/guide/integration/applescript.html) |
| **Smart Jump** | Host reads selected text, validates it as an allowed URL, then asks `NSWorkspace` to open it | `selection.read`, `url.openExternal` | Accessibility for selection; no network permission merely for handing the URL to another App | Limit MVP schemes to `https` and `http`; opening a URL and fetching it inside the Plugin are different Capabilities. [Raycast Environment APIs](https://developers.raycast.com/api-reference/environment) [Apple custom URL schemes](https://developer.apple.com/documentation/xcode/defining-a-custom-url-scheme-for-your-app) |
| **Screenshot — Spinnet capture** | Host invokes ScreenCaptureKit and returns a capture reference; optional Host operations copy or save it | `screen.capture`; optional `clipboard.write` or user-selected file-save access | Screen Recording | Use Host-native UI and the system picker where appropriate. Do not give the helper raw screen APIs. [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) |
| **Screenshot — Shottr adapter** | Host hides the Menu and opens an allowed `shottr:` URL such as area, fullscreen, or window capture | `application.openDeepLink` scoped to Shottr and documented routes | No Screen Recording on Spinnet for deep-link-only use | Require Shottr 1.8+ and its URL Scheme API setting. Shottr owns capture permissions. `then` parameters can model default/Alternate Commands without introducing a nested Preset hierarchy. [Shottr URL schemes](https://www.shottr.cc/kb/urlschemes) |

## Boundaries for the UX specification

The Settings UX ticket can safely specify these user-visible requirements without committing to low-level implementation:

- Each Library Plugin entry identifies whether it is Host-native, uses a remote service, or requires a named external App.
- A Plugin's Configuration Sheet shows required Capabilities and missing System Permissions separately.
- A target-App adapter names its target and mechanism in diagnostic details: for example, “Controls Bob using Automation” or “Opens Shottr using its URL Scheme API.”
- Commands that share a Plugin may require different scopes. For example, Shottr deep-link Commands require no Spinnet screen capture, while a Spinnet-native capture Command does.
- A revoked or missing permission leaves the Menu Item in its Slot and marks the affected Primary or Alternate Action unavailable with a repair path.
- Plugins cannot draw arbitrary consent UI or request macOS authority directly; the Host owns all permission explanation, prompting, status, and revocation flows.

The ticket should not promise universal compatibility with installed Apps. An integration exists only when Spinnet has a documented adapter for a stable app-owned interface. URL schemes, AppleScript dictionaries, and CLIs are target-specific contracts that can disappear or change independently of Spinnet.

## Remaining uncertainties

- The public Raycast documentation does not specify the exact implementation or permission behavior of the older `getSelectedText()` Extension API. The newer Screen Awareness documentation confirms Accessibility-backed selection capture for that Host feature, but Spinnet still needs its own cross-App prototype on the oldest supported macOS version. [Raycast Environment APIs](https://developers.raycast.com/api-reference/environment) [Raycast Screen Awareness](https://manual.raycast.com/ai/screen-awareness)
- TCC attribution for an `osascript` process launched from Spinnet's per-Plugin helper must be tested with the intended signing and sandbox configuration. Regardless of attribution, the Capability decision must remain in the Host and be scoped to the target bundle identifier.
- Apple documents that sandboxed Apps cannot send Apple Events to arbitrary Apps. The Bob adapter therefore needs an implementation spike using the exact distribution, entitlement, and target configuration Spinnet will ship. [Apple App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox) [Apple Events entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.automation.apple-events)
- Clipboard retention defaults, sensitive-App exclusions, and whether third-party Plugins may ever query full history remain product-policy decisions. Raycast's Disabled Applications control is a useful floor, not a complete privacy specification. [Raycast Clipboard History](https://manual.raycast.com/clipboard-history)
