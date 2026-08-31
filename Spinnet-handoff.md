# Spinnet — design handoff

**Purpose:** Portable context for a fresh session that will continue product design and then prototype **Spinnet**.

**Status:** Product exploration; no implementation repository or production code has been created in this conversation. The project name **Spinnet** is confirmed.

## 1. Product thesis

Spinnet is intended to be a **free, open-source, macOS-first productivity tool inspired by Quicker**, centered on a mouse-first marking/pie menu:

- Press a mouse side button to summon a circular menu at the pointer.
- Move toward a sector and release to run the action using muscle memory.
- Ship useful first-party actions such as screenshots, clipboard history, opening apps/files/URLs, and processing selected text.
- Provide an open Action/plugin architecture rather than a closed action ecosystem.
- Reuse an existing macOS ecosystem where feasible; **partial PopClip extension compatibility** is the current primary target. Full Raycast compatibility is not.

The creator is treating this as an open-source interest project, not a subscription product. The current intended initial audience is ordinary macOS office users who use a mouse, although this positioning remains a product risk because the design requires side-button hardware and several sensitive macOS permissions.

The working value proposition is **one-handed, low-memory, mouse-native actions without reaching for the keyboard**. The creator considers the Quicker-style interaction intrinsically useful and does not want to re-litigate that premise before prototyping. Nevertheless, latency and ergonomics still need runnable validation.

## 2. Confirmed decisions

### 2.1 Name and platform strategy

- Product name: **Spinnet**.
- **macOS first**; do not simultaneously ship Windows MVP.
- Preserve a platform-neutral Action/plugin protocol so a native Windows host can be built later.
- Mouse is a first-class input. A global keyboard shortcut can be added later as a fallback, but it is not the initial selling point.
- The first implementation should be native macOS: **Swift + AppKit + SwiftUI**.
  - AppKit is expected to own event taps, non-activating overlay/window behavior, and lower-level system integration.
  - SwiftUI is suitable for settings and the constrained declarative plugin UI.
- Do not make Electron, Tauri, Flutter, or a premature shared Rust core the MVP foundation.

### 2.2 Exact radial interaction state machine

The agreed interaction has **no hold-delay mode switch**:

1. User presses the configured mouse side button.
2. The radial menu appears at the pointer.
3. Movement beyond a configurable distance/dead-zone selects a sector.
4. Releasing the side button after directional movement immediately executes that sector's **primary action**.
5. Pressing and releasing without meaningful movement leaves the radial menu open in persistent mode.
6. In persistent mode:
   - left-click an item: execute its primary action;
   - right-click an item: open alternate actions and configuration;
   - click outside or press Escape: dismiss.
7. Directional release and left-click are semantically equivalent: both invoke the same primary action.

Each action is expected to expose a primary action plus alternate actions/preferences. Screenshot mode selection is the motivating example: the primary action may be configured as full-screen, region, or window capture; right-click exposes the other modes and settings.

### 2.3 MVP scope and first-party actions

Confirmed MVP direction:

- Open an application.
- Open a file, directory, or URL.
- Screenshot action/tool.
- Clipboard history (the creator explicitly wants this in MVP, despite its cost).
- Smart selected-text action, inspired by Quicker's EVER 智识, implemented as a **plugin**, not core intent-routing logic.
- Radial layout/action configuration.
- Local plugin enable/disable and permission management.

The creator does **not** require an external marketplace in MVP. Action API, Plugin SDK/runtime, and Marketplace are separate layers:

- MVP: common Action model, first-party actions, developer/local plugin loading.
- Later: community index/marketplace if real demand appears.

#### Screenshot MVP boundary

Confirmed first slice:

- Capture region, window, one display, or all displays.
- Copy, save, and/or drag out the result.
- Produce a typed image result that can be passed to a subsequent Action.
- Do **not** initially include annotation canvas, OCR, pin-to-screen, or scrolling capture.

The primary screenshot action can use a user-selected default mode. Alternate modes live in the item's right-click menu. The overlay must disappear in time not to appear in the screenshot.

#### Clipboard-history working boundary

Clipboard history is in MVP. The accepted working design is:

- text, images, and file URLs;
- local-only storage, no cloud sync;
- configurable retention, provisionally seven days by default;
- search, preview, delete, and provisionally pin/favorite;
- default exclusion of Passwords, Keychain Access, and common password managers, plus user-defined excluded apps;
- an Action/plugin can mark copied data `concealed` so it is not stored;
- no OCR or cross-device sync in the first version;
- explicit privacy explanation during onboarding.

The exact database, encryption, retention defaults, and exclusion implementation still require design/prototype work.

#### Selected-text behavior

- User highlights text, then invokes the Action manually through Spinnet.
- Example routing: URL → browser; POSIX path → Finder; otherwise search or another rule.
- The EVER-like recognizer is one official plugin; recognition is not baked into the core protocol.
- Selected-text acquisition strategy is confirmed as:
  1. Accessibility API first;
  2. optional user-enabled simulated `⌘C` fallback;
  3. preserve/restore the prior pasteboard as safely as possible;
  4. allow manual input if acquisition still fails.
- Spinnet is not committed to PopClip's automatic “show after any selection” trigger. It may cover much of PopClip's workflow through manual radial invocation without being a pixel-for-pixel replacement.

### 2.4 Distribution and macOS permissions

- Distribution target: **Developer ID signed and notarized DMG**, plus **Homebrew Cask**.
- Mac App Store is not the MVP target because sandbox restrictions conflict with broad scripts/plugins and automation.
- The creator prefers a first-run onboarding wizard that configures all required macOS permissions up front:
  - Input Monitoring for global mouse trigger;
  - Screen Recording for capture;
  - Accessibility for selected text, simulated input, and automation.
- The app should still be engineered so denial of one permission disables only dependent capabilities rather than breaking the entire menu; this degraded-mode behavior was recommended and should be reconfirmed during prototype work.

### 2.5 Action and plugin boundaries

Confirmed third-party ceiling for the initial architecture:

- **A: execute actions and return results**;
- **B: show host-provided declarative UI**.

Do not initially allow arbitrary embedded plugin UI, native dynamic libraries in the host process, independent global hooks, or unrestricted background mini-apps.

First-party and third-party capabilities follow the same public conceptual API, but first-party signed plugins can receive a higher/default trust level. Third-party installation must show source and requested capabilities.

The working declarative UI baseline is:

- `List`
- `Form`
- `ActionPanel`
- `Toast` / `Progress`

`Detail`, `Grid`, and arbitrary HTML/WebView were deferred. Screenshot selection UI is a host capability, not evidence that every plugin needs custom embedded UI.

### 2.6 Plugin runtime and IPC

Confirmed runtime direction:

- A **language-neutral external executable protocol** over stdin/stdout JSON-RPC.
- An official JavaScript/TypeScript runner and SDK on top of that protocol.
- No third-party `.dylib` loaded into the main application.
- Plugins run in separate processes.
- Process lifecycle choice: lazy-start a process per plugin on first use, keep it warm briefly, then terminate it after inactivity. Exact idle timeout is not frozen; five minutes was a recommendation.
- Cache manifests and radial layout in the host so opening/selection never waits for plugin startup.

Confirmed package direction:

- Development mode loads a plugin directory.
- Distribution uses a double-clickable/archivable plugin package containing a manifest, built entrypoint, assets, README, and license.
- The manifest must include stable plugin ID, plugin version, host API version, platforms, commands, and declared capabilities.
- Do not treat npm metadata itself as the plugin format.

Confirmed trust model:

- Official plugins: default trust based on Spinnet signing/provenance.
- Third-party plugins: installation-time disclosure of source, executable-code status, and capabilities.
- New capabilities on upgrade require renewed confirmation.
- Initial capability vocabulary should cover selected text, clipboard read/write, screen capture, file access/opening, and network access.

A typed invocation context is the working direction so plugins receive only declared/authorized fields, such as selected text, current application, pointer location, selected files, modifiers, and invocation method (radial gesture, radial click, future keyboard). Avoid a universal `getEverything()` API.

### 2.7 Result passing and chaining

Confirmed workflow scope:

- MVP supports host-controlled chaining:
  - after an Action completes, the user can choose “send to…”; and/or
  - configure a fixed next Action.
- The host passes typed outputs such as screenshot images into the next Action.
- Do not initially allow plugins to invoke arbitrary other plugins directly.
- Do not build a full visual workflow editor in MVP.
- The protocol may preserve a path to arbitrary multi-step workflows later.

The exact general `ActionResult` schema and side-effect model are **not yet confirmed**; see deferred decisions.

### 2.8 PopClip compatibility

PopClip is now the primary existing plugin ecosystem to investigate, ahead of Raycast.

Confirmed compatibility strategy:

- It is acceptable to support only a subset and produce an explicit compatibility report.
- First compatibility level should target static PopClip actions:
  - URL;
  - Shortcut;
  - macOS Service;
  - key press;
  - Shell;
  - AppleScript;
  - basic `requirements`, regex matching, and options;
  - result behaviors such as copy, paste, and show.
- Architecture should preserve a future Level 2 shim for common JavaScript APIs (`popclip.input`, context/options, copy/paste/show/open URL/key press, HTTPS networking).
- Do not promise full dynamic modules, dynamic action population/submenus, or behavioral equivalence with all PopClip APIs.
- Apple Shortcuts bridge and possibly Raycast/Alfred invocation may come later.

PopClip package formats (`.popclipext`, `.popclipextz`, YAML/JSON/plist/JS/TS config) and its documented context model make it more tractable than Raycast. Licensing and provenance must still be handled per extension.

### 2.9 Performance targets

Accepted as prototype/engineering budgets, not yet measured guarantees:

- side-button press → first visible radial frame: target **≤50 ms**;
- release → primary action dispatch begins: target **≤100 ms**;
- radial rendering and sector feedback must not wait on a plugin;
- show progress if a cold plugin takes longer than roughly **300 ms**;
- plugin work must never block the UI/main thread.

## 3. Researched facts and competitor landscape

### 3.1 Existing research artifacts

Do not duplicate the detailed findings; read these primary handoff artifacts:

- Raycast compatibility: `/Users/zeke/.pi/agent/sessions/--Users-zeke--/subagent-artifacts/outputs/13dc5583-269a-4001-8133-a38f1c8d1b58/raycast-compat.md`
- macOS/Windows global overlay and permissions: `/Users/zeke/.pi/agent/sessions/--Users-zeke--/subagent-artifacts/outputs/13dc5583-269a-4001-8133-a38f1c8d1b58/global-overlay.md`
- Plugin/automation ecosystems: `/Users/zeke/.pi/agent/sessions/--Users-zeke--/subagent-artifacts/outputs/13dc5583-269a-4001-8133-a38f1c8d1b58/plugin-ecosystems.md`

Key conclusion only: a macOS implementation should use a native input adapter (`CGEventTap`) and a native non-activating overlay (`NSPanel`). A read-only event tap typically maps to Input Monitoring; suppressing/replacing the original side-button event can increase permission/review complexity. Full-screen Spaces can be supported with appropriate collection behavior, but secure UI/login screens and exclusive full-screen content cannot be promised.

### 3.2 Raycast conclusion

Full Raycast extension compatibility is not a reasonable initial promise. Raycast extensions depend on a managed Node/worker runtime, JSON-RPC to the native host, a custom React reconciler/AppKit UI, and host/service APIs such as OAuth, AI, browser integration, storage, navigation, and command registry.

Possible later work is limited source compatibility or migration for simple `no-view` commands. Treat Raycast as a design reference or bridge target, not Spinnet's plugin ABI.

Primary source: <https://www.raycast.com/blog/how-raycast-api-extensions-work>

### 3.3 Quicker references

- Quick screenshot behavior and action handoff: <https://getquicker.net/KC/Manual/Doc/quick-shot>
- Screenshot module/types: <https://getquicker.net/kc/help/doc/screencapture>
- EVER 智识 reference: <https://getquicker.net/Sharedaction?code=4f8b0df2-d031-4309-173c-08d7079ea819>

These references show that screenshot is best treated as a privileged host capability that produces typed image/context output, while EVER-style classification is an ordinary plugin consuming selected text.

### 3.4 PopClip facts

- Developer documentation: <https://www.popclip.app/dev/>
- Extension directory: <https://www.popclip.app/extensions/>
- Official/community source repository: <https://github.com/pilotmoon/PopClip-Extensions>

PopClip supports snippets and packages, static action types, JavaScript/TypeScript, Shell, AppleScript, URL, key press, Services, and Shortcuts. The main official repository says its source is MIT unless an individual extension states otherwise; the directory now accepts multiple source repositories, so each imported extension still needs license/provenance inspection. PopClip's signature must not automatically become Spinnet trust.

### 3.5 Direct competitors

The idea is not novel as a generic “macOS radial automation menu.” Differentiation must come from the combination of native side-button behavior, open plugin protocol, PopClip compatibility, and focused first-party capabilities.

1. **Radial** — <https://radial.appverge.net/>
   - Closed, paid macOS automation/pie-menu product.
   - Cursor-centered gesture menu, multi-step visual workflows, app context, scripts, Shortcuts, community presets, window management, AI.
   - Official changelog dates first release to 2025-11-30 and shows very rapid iteration; mouse triggers appeared later.
   - Changelog: <https://radial.appverge.net/changelog>

2. **Kando** — <https://kando.menu/> / <https://github.com/kando-menu/kando>
   - Free MIT open-source, Windows/macOS/Linux, gesture navigation and deep submenus, app-specific menus, IPC.
   - No built-in direct mouse-button binding on macOS; documentation suggests BetterTouchTool/Karabiner/BetterMouse or driver mappings.
   - This means “open-source cross-platform pie menu” alone is not differentiation.

3. **Vorssaint Utils** — <https://github.com/vorssaintapp/vorssaint-utils>
   - GPL open-source native macOS utility suite.
   - Includes an Action/Radial Wheel, extra mouse-button trigger, apps/files/links/actions/submenus, screenshot/recording, and clipboard-related features.
   - Extremely close in individual capabilities, but positioned as a broad macOS utility suite; no equivalent open plugin protocol or PopClip compatibility was found in the research.

4. **Radiant** — <https://radiantmenu.com/en>
   - Closed commercial macOS radial/list launcher.
   - Explicit middle/side-button triggers, click-or-release execution, dead-zone control, macros, submenus, windows/system actions, and JSON import/export.
   - Its core mouse interaction is particularly close to Spinnet.

5. **BetterTouchTool Floating Menus** — <https://docs.folivora.ai/docs/1600_floating_menus.html>
   - Can build circular menus at the pointer triggered by right-click/mouse/trackpad gestures.
   - Rich scripting, submenus, controls, JSON sharing, and native Swift widget plugins.
   - Powerful but complex; not a focused open Action host.

Secondary radial launchers include Pie Menu, Charmstone, Orbit Launcher, Pieoneer, and Launchy. They mainly launch/switch apps or expose shortcuts and are less relevant to the plugin-host ambition.

### 3.6 Current differentiation

No single item below is unique by itself:

- mouse-side-button radial menus already exist;
- open-source radial menus already exist;
- screenshot/clipboard tools already exist;
- scriptable automation already exists.

The defensible product thesis, if retained, is the **combination**:

> A focused, native macOS, mouse-side-button-first marking menu with a permissioned, language-neutral Action/plugin protocol, useful screenshot/clipboard/selected-text primitives, and partial PopClip extension compatibility.

## 4. Provisional recommendations (not confirmed)

Do not silently promote these to decisions:

- Use a small explicit typed `ActionResult` union (`none`, text, image, files, URL, error) plus host-controlled preferred effects (copy, paste, preview, open, save, pass onward).
- Keep system side effects in the host and expose them through capability-checked JSON-RPC rather than letting plugins manipulate the app directly.
- Use declarative preference field types such as string, password, boolean, number, select, application, file, and directory; store secrets in Keychain.
- Use GPLv3 for the app and Apache-2.0 for the plugin protocol/SDK, balancing the open-source motivation with a permissive plugin ecosystem.
- Import user-downloaded PopClip packages and link to the upstream directory instead of scraping or rehosting it.
- Keep a plugin worker warm for an inactivity period (five minutes was suggested), restart at most once after a crash, and require a separate `background` capability for any persistent process.
- Request all three macOS permissions in an onboarding wizard as the creator prefers, but still explain each capability and support degraded operation if one is denied.

## 5. Explicitly deferred/open decisions

The creator asked to defer detailed choices until after a prototype. In particular, the prior Q42–Q45 topics remain open:

1. **Plugin preferences:** exact field types, secret storage/export behavior, settings-change events.
2. **Result/side effects:** final `ActionResult` schema and whether plugins may perform any direct system operations versus returning host-executed effects.
3. **Licensing:** app license and separate SDK/protocol license.
4. **PopClip provenance/distribution:** local import only vs directory links/indexing, conversion metadata, notices, signature treatment, and whether anything may be mirrored.

Additional open decisions/risks:

- Whether the side-button event is passed through or suppressed. Passing it through can also trigger browser Back/Forward; suppressing it may require a non-listen-only event tap and more sensitive permissions. This is a key prototype decision.
- Hardware/driver compatibility and button numbering across Logitech, Razer, Microsoft, generic HID mice, and vendor remapping software.
- Exact dead-zone geometry, sector hysteresis, edge-of-screen repositioning, multi-display behavior, animation, and accidental activation rules.
- Whether up-front permission requests harm onboarding for the intended ordinary-user audience.
- Clipboard database/encryption, retention, duplicate handling, pasteboard-format fidelity, source-app detection, and secure-field/password-manager exclusions.
- Screenshot implementation details: ScreenCaptureKit flow, window enumeration, selection overlay, overlay-dismiss timing, file formats, drag-out behavior, and multi-display coordinates.
- Cross-application reliability of AX selected text and pasteboard restoration after simulated Copy.
- Final plugin package extension/name, manifest schema, API negotiation/versioning, timeout/resource limits, logs, crashes, cancellation, and updater behavior.
- Stable declarative UI semantics and whether `Detail`/`Grid` become necessary for real PopClip samples.
- Measured PopClip compatibility coverage. A static scan/sample corpus is needed before claiming a useful percentage.
- Legal/trademark review for PopClip import branding and per-extension licenses.
- Whether a local SDK should remain explicitly unstable until at least three first-party plugins exercise it.
- Whether clipboard history and a full screenshot tool make the MVP too large.
- Target-user tension: ordinary users value built-ins but may avoid side-button requirements, open-source installs, and three permissions; plugin architecture primarily attracts advanced users/developers.
- Competitor strategy: decide whether Spinnet should interoperate with, fork from, contribute to, or deliberately differ from Kando/Vorssaint rather than independently duplicating their native/interaction work.

## 6. Recommended next-session plan

1. **Create/open a dedicated Spinnet repository** before further design work.
2. Read this handoff and the three research artifacts above.
3. Run a short hands-on competitor teardown—especially Vorssaint, Radiant, Radial, Kando, and BetterTouchTool—and record only concrete gaps relevant to Spinnet.
4. Use `grill-with-docs` to create a persistent domain glossary and ADRs. Define terms such as Action, Command, Plugin, Capability, InvocationContext, ActionResult, Primary Action, Alternate Action, and Menu.
5. Build a throwaway native prototype before freezing Q42–Q45.
6. Fold measured findings back into `CONTEXT.md`/ADRs, then produce a spec and tracer-bullet tickets only after the product seam is clear.

### Prototype questions, in priority order

**Prototype A — native interaction seam**

- Can `CGEventTap` reliably detect actual side buttons across representative mice?
- Is event suppression required to prevent Back/Forward behavior?
- Can a non-activating `NSPanel` appear in ≤50 ms without stealing focus or losing text selection?
- Does press → move beyond dead zone → release feel correct with no hold delay?
- Does click-without-movement reliably enter persistent mode?
- How should the circle shift near screen edges and across displays?
- Does it behave correctly in normal full-screen Spaces, after sleep, and after permission revocation?

**Prototype B — selected-text and screenshot capabilities**

- AX selected-text success rate in Safari, Chrome, Finder, Notes, Office, Electron apps, and PDF viewers.
- Whether the `⌘C` fallback can preserve rich pasteboard contents without races.
- ScreenCaptureKit permission/onboarding behavior and capture latency.
- How early the radial overlay must disappear to avoid being captured.

**Prototype C — plugin seam**

- Load one manifest and run one isolated TypeScript worker via JSON-RPC.
- Populate a `List` or `Form` from a declarative response without blocking the radial UI.
- Pass an `InvocationContext` containing selected text and frontmost app.
- Return a typed text/image result and chain it through the host.
- Measure cold/warm startup and cancellation/crash behavior.
- Import a small corpus of static PopClip extensions and produce per-field compatibility reports.

## 7. Suggested skills

The next agent should call these through the **Skill tool** as appropriate:

1. **`setup-matt-pocock-skills`** — first, if the new Spinnet repository has not yet been configured for the workflow's issue tracker/doc layout.
2. **`grill-with-docs`** — continue product/architecture decisions in the repository and persist the shared glossary in `CONTEXT.md` plus hard-to-reverse decisions as ADRs.
3. **`domain-modeling`** — resolve overloaded vocabulary around Action, Plugin, Command, Context, Capability, Result, and Menu.
4. **`prototype`** — build throwaway native programs for the three prototype questions above. If the prototype is placed in a separate directory/branch, use `handoff` at the boundary.
5. **`research`** — only for focused primary-source work that still needs a cited Markdown artifact, such as PopClip API coverage/licensing or competitor source architecture.
6. **`to-spec`** — once prototype evidence settles the open decisions.
7. **`to-tickets`** — split the accepted spec into tracer-bullet issues with blocking edges.
8. **`implement`** — build each ticket after the spec/tickets exist; it will drive TDD and code review internally.
9. **`handoff`** — write another portable summary when moving to a new harness/directory or colleague.

Do not jump directly from this handoff into a full implementation. The highest-value next step is the native interaction prototype, because it resolves the side-button event, focus preservation, permission, and latency questions on which the rest of the product depends.
