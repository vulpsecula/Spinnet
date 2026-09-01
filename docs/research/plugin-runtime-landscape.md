# Plugin runtime landscape: PopClip, Vorssaint, and Kando

Researched 2026-09-01 against first-party documentation, current source trees, and the locally installed PopClip 2026.7.1 application. The source snapshots inspected were PopClip Extensions `eda50d7e0286909f3437004ee47fd5316c37fcc3`, Vorssaint `ed882cd30888775281624ee9575b624875afcbc1`, and Kando `13c3739992bce8994c7a39943aae0e63863af089`.

## Executive conclusion

Spinnet should not use one universal runtime for every Command. A tiered runtime is both closer to PopClip and substantially more memory-efficient:

1. Execute static and first-party Commands directly in the native Host.
2. Adapt PopClip URL, Key Press, Service, and Shortcut actions into Host Commands without starting a Plugin process.
3. Execute PopClip JavaScript through the system JavaScriptCore framework, either inside the Host or in one shared, idle-terminable helper. Prototype both placements before choosing.
4. Spawn Shell Script and AppleScript interpreters only for an invocation; never keep them resident.
5. Reserve independent external processes for advanced native Spinnet Plugins that need a language-neutral protocol.
6. Do not load third-party `.dylib` files into the Host.

This preserves PopClip compatibility without paying for one Node/V8 process per installed or recently used Plugin.

## Comparison

| Product | Extensibility model | Where behavior runs | Memory implication | Ecosystem implication |
| --- | --- | --- | --- | --- |
| PopClip | Declarative actions plus JavaScript/TypeScript, Shell Script, and AppleScript | Static actions in the Host; JavaScript in PopClip's sandbox; shell languages in invoked interpreters | Hybrid, with no evidence of one persistent process per extension | Mature extension packages and the most relevant compatibility target |
| Vorssaint | Hard-coded native radial item kinds; no Plugin system | Swift code in the application process | Lowest structural overhead | No external Plugin ecosystem to reuse |
| Kando | Built-in workflow action registry, JSON configuration/themes, commands, and local WebSocket IPC | Built-in actions in Electron's main process; shell commands in child processes; external integrations remain separate clients | Electron establishes a larger baseline; IPC clients add only when used | Flexible integration surface, but not a packaged in-process Plugin ecosystem |

## PopClip

### Runtime shape

PopClip officially supports seven action types: URL, Key Press, Service, Shortcut, Shell Script, AppleScript, and JavaScript. It recommends JavaScript, while the four static action types require no extension code. [PopClip Developer Documentation](https://www.popclip.app/dev/)

JavaScript and TypeScript run in PopClip's own restricted JavaScript environment. The documented sandbox cannot access the filesystem unless PopClip exposes an operation through its API. [JavaScript environment](https://www.popclip.app/dev/js-environment) [JavaScript actions](https://www.popclip.app/dev/js-actions)

Shell actions invoke a named interpreter or executable script, receive context through environment variables or stdin, and return text through stdout plus an exit status. This is process-per-invocation behavior rather than a resident Plugin worker. [Shell Script actions](https://www.popclip.app/dev/shell-script-actions)

The documentation does not explicitly guarantee whether JavaScript runs inside the main process or a helper process. Local inspection of PopClip 2026.7.1 found:

- the main executable links Apple's system `JavaScriptCore.framework`;
- the bundle contains only the main executable and a separate `PopClipEventMonitor` executable, not a visible per-extension runner;
- binary symbols include `PopJSExtensionImplementation`, `JSValue`, and `Extensions Shared Context`.

This is strong evidence that normal JavaScript extensions use embedded JavaScriptCore and shared Host infrastructure, not one Node/V8 process per Plugin. It remains an inference from a closed-source binary, not a documented compatibility guarantee.

### Ecosystem shape

The official extension repository rejects compiled binaries and asks authors to prefer JavaScript over Shell Script or AppleScript. [PopClip Extensions contribution rules](https://github.com/pilotmoon/PopClip-Extensions)

At the inspected commit, the repository contained 219 extension packages:

- 85 legacy `Config.plist` packages;
- 65 `Config.json` packages;
- 22 `Config.yaml` packages;
- 13 `Config.js` packages;
- 32 `Config.ts` packages;
- 2 `Config.applescript` packages.

Therefore 174 of 219 packages use a non-module configuration container, while 45 use JavaScript/TypeScript module configuration. A non-module config can still point to a script, so these counts describe package structure, not full behavioral coverage. [Inspected PopClip Extensions snapshot](https://github.com/pilotmoon/PopClip-Extensions/tree/eda50d7e0286909f3437004ee47fd5316c37fcc3)

This supports a compatibility ladder: parse all package/config formats first; execute static actions next; add JavaScript API coverage incrementally; treat dynamic modules and uncommon APIs as later levels with an explicit compatibility report.

### Directory and update precedent

PopClip's current directory already behaves like a source-to-package pipeline. An author hosts a `.popclipext` source directory in a public GitHub repository, installs the PopClip Directory GitHub app, and publishes version tags. The directory fetches the tagged source, processes it, signs and zips a `.popclipextz`, and makes accepted releases eligible for automatic updates. [Submit an Extension](https://www.popclip.app/extensions/submit) [Extensions user guide](https://www.popclip.app/guide/extensions)

This is a strong technical precedent for a Spinnet Conversion Portal, but not a grant of rights to Spinnet. PopClip's submission agreement explicitly gives Pilotmoon permission to store, package, sign, distribute, and update the submitted files. A Spinnet marketplace needs its own author opt-in or a source license that permits modification and redistribution. The main official PopClip Extensions repository is MIT by default unless an individual extension says otherwise, while extensions hosted in other repositories may use different or absent licenses. [PopClip submission agreement](https://www.popclip.app/extensions/submit) [Official extension repository license policy](https://github.com/pilotmoon/PopClip-Extensions)

PopClip config contains an extension identifier and a minimum PopClip build, but the current directory derives release versions from source-repository tags. Therefore an arbitrary downloadable package URL does not necessarily provide a stable version stream. Reliable automatic conversion updates require a discoverable source repository and version/tag channel, or explicit update metadata supplied by the Spinnet portal.

### Memory reference

On the research machine, an idle, configured PopClip 2026.7.1 snapshot showed approximately 42.9 MiB RSS for the main process and 11.4 MiB for `PopClipEventMonitor`, about 54.3 MiB combined. RSS double-counts some shared pages and varies with installed extensions and recent activity, so this is a directional reference, not a benchmark or acceptance threshold.

## Vorssaint

Vorssaint is a native Swift executable with two small system-library targets and no third-party package dependencies in `Package.swift`. [Package manifest at inspected commit](https://github.com/vorssaintapp/vorssaint-utils/blob/ed882cd30888775281624ee9575b624875afcbc1/Package.swift)

Its contribution policy explicitly says a Plugin system has already been declined because Vorssaint avoids adding permanent subsystems and runtime dependencies. [Contribution policy](https://github.com/vorssaintapp/vorssaint-utils/blob/ed882cd30888775281624ee9575b624875afcbc1/CONTRIBUTING.md)

The radial model is a closed Swift enum containing app, file, URL, shortcut, tool, quick toggle, window layout, media, and submenu kinds. Selection dispatches through a Swift `switch` directly to native services. [Radial item model](https://github.com/vorssaintapp/vorssaint-utils/blob/ed882cd30888775281624ee9575b624875afcbc1/Sources/Vorssaint/Services/RadialMenu/RadialMenuSupport.swift) [Radial execution](https://github.com/vorssaintapp/vorssaint-utils/blob/ed882cd30888775281624ee9575b624875afcbc1/Sources/Vorssaint/Services/RadialMenu/RadialMenuService.swift)

Vorssaint demonstrates the resource advantage of native, closed-set actions, but offers no Plugin architecture for Spinnet to imitate. Its useful lesson is to keep frequent first-party behavior inside the Host and make optional subsystems truly optional.

## Kando

Kando 3 is an Electron application using React and an Electron 43 runtime. [Package manifest at inspected commit](https://github.com/kando-menu/kando/blob/13c3739992bce8994c7a39943aae0e63863af089/package.json)

Its current workflow action types are registered in code and executed sequentially by an in-process registry. The execute-command action launches a shell child process when selected. [Action registry](https://github.com/kando-menu/kando/blob/13c3739992bce8994c7a39943aae0e63863af089/src/common/action-type-registry.ts) [Workflow executor](https://github.com/kando-menu/kando/blob/13c3739992bce8994c7a39943aae0e63863af089/src/main/workflow-executor.ts) [Command execution](https://github.com/kando-menu/kando/blob/13c3739992bce8994c7a39943aae0e63863af089/src/main/actions/execute-command.ts)

Kando's public integration API is a local, language-neutral WebSocket service. External applications can send JSON menu trees and observe selections. This is an integration boundary for tools living outside Kando, not a resident packaged-Plugin runtime. [Kando WebSocket interface](https://kando.menu/ipc-interface/) [IPC server source](https://github.com/kando-menu/kando/blob/13c3739992bce8994c7a39943aae0e63863af089/src/common/ipc/ipc-server.ts)

An open pull request proposes a packaged Plugin system, but it is not part of the inspected main branch and must not be treated as current Kando behavior. Kando's existing extensibility instead comes from configuration, themes, shell commands, and external IPC clients.

Kando is a useful reference for a simple JSON integration seam, but its Electron baseline conflicts with Spinnet's goal of feeling like a low-overhead macOS system facility.

## Recommended Spinnet runtime tiers

### Tier 0: Host Commands

Menu rendering, pointer interaction, opening apps/files/URLs, key presses, Shortcuts, Services, screenshots, and other trusted first-party Commands execute natively in the Host. These are the hot path and require no Plugin runtime.

### Tier 1: PopClip compatibility adapter

Install a PopClip package by parsing its existing config and translating supported static actions into Host Commands. Cache the translated manifest and requirements so opening a Menu never parses or starts anything.

### Tier 2: PopClip JavaScript runtime

Use Apple's system JavaScriptCore rather than bundling Node/V8. Expose only capability-checked bridge functions matching the supported PopClip API. Keep one JavaScript runtime facility rather than one runtime process per Plugin.

Two placements require measurement:

- **In-Host JavaScriptCore**: lowest memory and likely closest to PopClip, but a runaway script or engine fault shares the Host's failure domain.
- **One shared helper with JavaScriptCore**: one modest process overhead, but the Host can terminate and restart all script execution without losing the radial UI.

Each Plugin should still receive a separate logical context and authorized bridge, even if contexts share one JavaScript virtual machine or helper.

### Tier 3: Invocation-only scripts

Run Shell Script and AppleScript actions as child processes only when invoked. Pass the minimum authorized context and terminate them on timeout. Do not keep interpreters warm.

### Tier 4: Advanced Spinnet Plugins

Only Plugins that exceed the PopClip model use the language-neutral external executable protocol. Start them lazily, default to terminating immediately after completion or after a short measured idle period, and never load their `.dylib` code into the Host.

## Prototype measurements required

Before accepting the Plugin-runtime ADR, compare these on the oldest supported macOS version and Apple Silicon generation:

1. Host baseline after launch and after ten minutes idle.
2. Added private memory from one JavaScriptCore context and from 10, 50, and 200 installed-but-idle extensions.
3. Added private memory and cold/warm latency for one shared JavaScriptCore helper.
4. Cold invocation and peak memory for representative PopClip JavaScript, Shell Script, and AppleScript actions.
5. Recovery from an exception, infinite loop, excessive allocation, helper crash, and revoked Capability.
6. Menu-open latency while every Plugin runtime is stopped.

Use private/dirty memory and memory pressure in addition to RSS; RSS alone counts shared framework pages and can exaggerate the cost of using system JavaScriptCore.

## Remaining uncertainty

- PopClip's exact JavaScript process boundary is undocumented and cannot be treated as ABI.
- Static-format counts do not equal behavioral compatibility; a package may reference scripts or APIs elsewhere.
- A sample-level compatibility scanner is still required before claiming a coverage percentage.
- The shared-helper design improves failure isolation but is not a security sandbox by itself; its filesystem, network, process, and IPC surface must still be constrained.
- Memory and latency claims require prototypes on real hardware rather than conclusions from source structure.
