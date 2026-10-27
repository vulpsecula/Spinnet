# Spinnet

Spinnet is a mouse-first macOS action environment centered on a radial menu. This glossary defines the language used to describe what the host and plugins offer, what users configure, and how authority is granted.

## Language

### Host and Plugins

**Host**:
The trusted Spinnet application that presents menus, coordinates execution, and provides controlled access to operating-system facilities.
_Avoid_: Core, main app

**Plugin**:
An installable provider of Commands that extends Spinnet without becoming part of the Host.
_Avoid_: Extension, add-on

**Bundled Plugin**:
A first-party Plugin distributed with Spinnet, with the same authority and interface boundary as a user-added Plugin. Removing it suppresses the shipped copy; reinstalling a copy gives that copy a user-added Plugin Origin.
_Avoid_: Built-in Command, trusted Host code

**Plugin Origin**:
The source of a Plugin package: shipped with the app or added by the user. It affects replacement and removal, and grants no authority.
_Avoid_: Plugin type, plugin kind, trust level, installed Plugin

**Refused Plugin**:
A user-added Plugin whose package or interface declaration the Host cannot load. Its configuration and data remain available for replacement or removal, and its Menu Items report why it is unavailable.
_Avoid_: Unavailable Plugin, broken Plugin, disabled Plugin

**Plugin Removal**:
Removing a Plugin from the Library and forgetting its data, grants and Host view preferences, while retaining its Menu Items as unavailable. A removed Bundled Plugin remains suppressed across launches and app updates.
_Avoid_: Delete Plugin, uninstall preset, clear Plugin

**Plugin Update**:
Replacing an installed Plugin's package with a newer version of the same Plugin, keeping its Plugin Storage, Plugin Settings, Menu Items and Capability decisions; Capabilities the new version newly requests are left for the user to decide.
_Avoid_: Reinstall, upgrade

**Update Source**:
The GitHub repository a Plugin declares as where newer versions of it are published. The Host accepts a Plugin Update from it only for the same Plugin identity, and it grants no authority.
_Avoid_: Registry, update URL, marketplace

**Plugin Storage**:
Data a Plugin keeps for itself between invocations and launches, which only that Plugin can reach and which is deleted when the Plugin is removed. It holds the Plugin's own data, never the user's choices or a secret.
_Avoid_: LocalStorage, cache, Plugin data, Plugin Settings

### Commands and Actions

**Command**:
A callable operation a Plugin declares, before user-specific configuration is applied. A Command either runs one Host Service directly, which makes it a Host Command, or runs the Plugin's script, which may call Host Services.
_Avoid_: Action type, function

**Host Command**:
A Command that directly names a Host Service and uses the Action’s configuration as its input, without running a script. It is supplied by a Plugin and follows that Plugin’s declared interface vocabulary.
_Avoid_: Built-in Plugin, Built-in Preset, native Action

**Host Service**:
A controlled, Plugin-independent operation the Host performs under the caller’s authority. The current interface identifies it by one `namespace.verb` ID across supported entry points.
_Avoid_: Capability, system API, Plugin-specific service

**Action**:
A configured instance of a Command, ready to execute: the Command together with the user's input for it, held by a Menu Item. Multiple Actions may be configured from the same Command.
_Avoid_: Command, operation, a button in a Plugin View (that is a View Action)

**Primary Action**:
The Action executed by the Menu Item's default gesture or left-click.
_Avoid_: Default command

**Alternate Action**:
An additional Action associated with a Menu Item that its configuration may expose in Runtime Mode rather than execute by the default gesture.
_Avoid_: Secondary command, option

### Menus and configuration

**Menu**:
A radial collection of Menu Items presented by the Host.
_Avoid_: Wheel, palette

**Menu Slot**:
An evenly distributed position in a Menu that may be empty or occupied by one Menu Item.
_Avoid_: Empty Menu Item, sector

**Menu Item**:
A configured entry that occupies a Menu Slot, binds one Primary Action, and may expose Alternate Actions, all configured from the Commands of one Plugin.
_Avoid_: Sector, button

**Alternate Ring**:
An arc outside one Menu Item's wedge that presents its Alternate Actions in Runtime Mode, as the alternative to listing them in a context menu.
_Avoid_: Secondary Menu, submenu, sub-ring

**Menu Item Alias**:
A user-defined display name for one Menu Item, independent of its Preset, Plugin, and Action names and not required to be unique.
_Avoid_: Action title, Plugin name

**Menu Item Configuration**:
One Menu Item's own settings: its Actions and their inputs, its alias and icon, and which Alternate Actions it exposes. It is edited in the Menu Item's Configuration Sheet and is separate from the Plugin Settings it shares with other Menu Items.
_Avoid_: Plugin Settings, Preset defaults, instance configuration

**Menu Editor**:
The settings surface where a user configures a Menu by arranging Menu Items and the Actions they expose.
_Avoid_: Overview, wheel editor

**Editor Mode**:
The non-executing presentation of a Menu inside the Menu Editor.
_Avoid_: Preview Menu, test Menu

**Runtime Mode**:
The executable presentation of a Menu when the user invokes it outside Settings.
_Avoid_: Live preview, actual Menu

**Current App**:
The App in front when the user invokes a Menu, which stays in front behind the Menu. It selects the App Override that applies and is distinct from an Insertion Target.
_Avoid_: Focused App, App under the pointer, active App

**App Override**:
An App-specific replacement of the Menu Items in chosen Menu Slots, applied while that App is the Current App; every other Slot keeps the default Menu's Menu Item.
_Avoid_: App Menu, per-app profile, app-specific Menu

**Library**:
The settings collection from which the user adds Menu Items: one Menu Item Preset per Plugin in a single list, followed by any Refused Plugins with their reasons.
_Avoid_: Plugin list, Action list

**Menu Item Preset**:
A recipe exposed as one Library entry for creating a Menu Item. Each Plugin exposes one Preset that selects default Primary and Alternate Commands from those it provides.
_Avoid_: Plugin, template Menu Item, default Action

**Ready-to-Use Preset**:
A Menu Item Preset whose defaults are complete and valid, allowing it to create a Menu Item without initial configuration.
_Avoid_: Non-configurable Preset, simple Plugin

**Setup-Required Preset**:
A Menu Item Preset that needs user-specific values in a Configuration Sheet before it can create a Menu Item.
_Avoid_: Broken Preset, unavailable Plugin

**Configuration Sheet**:
A modal settings surface for editing one Menu Item's Menu Item Configuration before saving or cancelling the changes.
_Avoid_: Submenu, secondary window, inspector

**Plugin Settings**:
User configuration shared by a Plugin’s Menu Items, distinct from one Menu Item’s own configuration and from Plugin-owned data. A setting may allow a Menu Item override.
_Avoid_: Menu Item Configuration, Preset defaults

**Appearance**:
The global visual configuration shared by a Menu's Editor Mode and Runtime Mode, excluding anything in a Menu Item Configuration.
_Avoid_: Menu Item Configuration, Plugin theme

**Status Item**:
Spinnet's icon in the macOS menu bar, distinct from the radial Menu.
_Avoid_: Menu, tray icon

**Host Activity**:
A Host-generated entry for an ongoing resource owned by a Plugin, such as a keep-awake Effect or a Task. The Status Item names its owner and current state and offers the resource's Stop control; a Plugin can list and stop only its own entries.
_Avoid_: Plugin menu-bar content, background Plugin, status widget

**Effect**:
A Host-owned system condition intentionally held for a Plugin after its Action ends, such as keeping the Mac and display awake while idle. It survives Plugin View closure, has an explicit lifetime and releases its resource when stopped or its owner becomes invalid. It is separate from a Task's mutating work.
_Avoid_: Task, resident helper, background script

### Plugin Views

**Plugin View**:
The interface a Plugin describes as data and the Host renders in a panel while one of its Actions runs. It never contains the Plugin's own markup or native UI.
_Avoid_: Popup, plugin window, custom UI

**View Session**:
The span from a Plugin View appearing until it closes, during which the Host keeps each View Component's Immediate State and hands each user interaction to the Plugin as a View Event.
_Avoid_: Long-running helper, view process

**View Page**:
A destination within a Plugin View's interaction flow, such as a search, detail or editing step, identified by an ID the Plugin chooses: answering with the same ID again refreshes the page, and another ID changes page.
_Avoid_: Command, window, Settings page

**View Component**:
A supported element of a Plugin View, such as a field, collection or layout container, which a Plugin combines to express its interface.
_Avoid_: Native control, custom widget, HTML element

**Component Style**:
Visual attributes a View Component declares for its own content, such as colour, typography or background. The public contract determines their scope while the Host retains native interaction and accessibility.
_Avoid_: CSS, stylesheet, theme, Plugin theme

**Image Source**:
The package resource or authorized network location supplying a View Component’s picture. It grants no file or network authority of its own; system symbols are icons.
_Avoid_: Image URL, asset path, file path, image API

**Collection**:
A View Component presenting Plugin-owned items as a List or Grid. The Plugin owns data and ordering; the Host owns native selection, navigation, scrolling and bounded presentation.
_Avoid_: Table, results list, data source

**Collection Window**:
The positions of a Collection currently held by the Host around the visible region. Unheld positions appear as placeholders until the Plugin supplies the requested range.
_Avoid_: Page of results, batch, cache

**Immediate State**:
The Host-held editing and navigation state of a View Component, including composition, caret, focus, selection and scroll. It is distinct from Plugin business state and follows component identity and explicit reset.
_Avoid_: UI state, view state, draft

**View Event**:
One user interaction in a Plugin View, such as editing a field, submitting, or choosing a View Action, delivered to the Plugin, which answers with its next description of the view and its own state.
_Avoid_: Callback, UI message

**Explicit Call**:
The user executing a configured Action, including while its Plugin’s View Session is already open. The Plugin’s declared interface determines whether it enters that session or starts a replacement invocation.
_Avoid_: Re-invocation, relaunch, refresh

**View Action**:
A button or menu entry in a Plugin View that performs a Host Service or sends the Plugin a semantic View Event.
_Avoid_: Action (a Menu Item's), shortcut, command button

**Item Action**:
A View Action offered on an item of a Collection, with an optional default or toggle meaning.
_Avoid_: Primary Action (a Menu Item's), row button, shortcut

**Item Mark**:
A short name an item of a Collection carries, such as `favourite`, which the toggle Item Action naming it shows as checked. The Plugin decides which items carry it.
_Avoid_: Flag, tag, checked state

**Host-Run Source**:
A page-owned Host Service observation whose results update bound View Components and may be delivered to the Plugin. Its lifetime follows page visibility and it grants no authority of its own.
_Avoid_: Subscription, timer, polling, background refresh, live query

**Host-Fetched Section**:
A part of a Plugin View whose request the Host sends and whose answer the Host shows, so the Plugin need not see the answer; the Plugin declares whether the answer is also delivered to it.
_Avoid_: Result popup, remote section

**Host Surface**:
A window the Host owns and presents on behalf of a Plugin, because the public view vocabulary cannot express it. Any Plugin granted the Capability it shows data from may request it; where the Plugin came from grants nothing.
_Avoid_: Plugin window, privileged UI

**Insertion Target**:
The App receiving text inserted by the Host for a Plugin. Its identity and resolution time follow the Plugin’s declared contract and differ from the App owning the panel’s keyboard focus.
_Avoid_: Origin App, recent App, focused App (when the panel is meant)

**Requested Host Operation**:
A Host Service request committed with a script’s answer to a user gesture and executed outside that bounded invocation. The Host owns authorization, target resolution, required confirmation and outcome delivery.
_Avoid_: Callback, deferred Host Service, async call

**Host Confirmation**:
Trusted UI generated by the Host for an operation that requires confirmation, naming the Host-resolved target. It is distinct from a Plugin’s business confirmation and cannot be skipped or worded by the Plugin.
_Avoid_: Confirmation dialog (for a Plugin's own view), alert, consent

**App Target**:
A Plugin-scoped opaque reference to one running App, whose lifetime prevents it from silently referring to a replacement process. Reading an App’s identity and acting on it are separate authorities.
_Avoid_: Process ID, app handle, app token

### Authority

**System Permission**:
Authority macOS grants to the Host, such as Accessibility, Input Monitoring, or Screen Recording.
_Avoid_: Capability, plugin permission

**Capability**:
Authority a user grants to a Plugin to access a protected category of Host functionality or data.
_Avoid_: System Permission, entitlement

**Privacy & Permissions**:
The settings page where users manage Host System Permissions, Sensitive Data Collection, and the Capabilities granted to individual Plugins as separate layers of authority.
_Avoid_: Plugin Settings, macOS System Settings

**Sensitive Data Collection**:
An explicit Host-level opt-in that permits Spinnet to continuously collect and retain a named category of sensitive system data, such as clipboard history. It is separate from a Plugin's Capability to read collected data.
_Avoid_: Capability, System Permission, background Plugin permission

**Clipboard History Store**:
The Host-owned collection of retained clipboard entries, populated only while its Sensitive Data Collection setting is enabled and exposed to a Plugin only through granted Capabilities and Host Services.
_Avoid_: Clipboard History Plugin database, pasteboard

**Credential Use**:
A Plugin-declared way for the Host to place a stored credential into a request, or sign a request with it, as the request is sent. The Plugin never sees the credential or any value derived from it.
_Avoid_: Signing oracle, credential digest, API key access

### External Apps

**External App**:
An application installed outside Spinnet that exposes an app-owned integration interface, such as a URL scheme or Apple Events API.
_Avoid_: Plugin, dependency

**External App Adapter**:
A Plugin that maps its Commands to a specific External App's Reviewed App Interface or Deep Link Templates, without gaining general control over installed applications.
_Avoid_: External App, universal app integration

**External App Connection**:
A Plugin-declared prerequisite that certain Commands need an External App, checked and repaired through Host-owned Plugin Settings and shared by their Menu Items. It is separate from the authority granted by a Capability or System Permission and from each Action's configured input.
_Avoid_: Initializer, setup Action

**Reviewed App Interface**:
The Host's reviewed description of the Apple Events operations one External App accepts, from which an External App Adapter may choose. Adding one is a Host release.
_Avoid_: Host adapter, AppleScript bridge

**Deep Link Template**:
A link into an External App's documented URL interface, declared by a Plugin with bounded parameters and consented to by the user.
_Avoid_: URL action, custom scheme

**Reviewed Tool Profile**:
The Host-reviewed set of typed operations and bounded inputs/results offered for one external command-line tool. A Plugin selects among them without gaining arbitrary command execution.
_Avoid_: Shell access, command runner, tool integration

**Task**:
A Host-owned run of a confirmed mutating Reviewed Tool Profile operation, independent of its Plugin View and controllable through Host Activity. Stopping attempts cancellation without rollback; recovery reports existing work without repeating it.
_Avoid_: Job, background process, effect (an effect, such as keep-awake, has its own lifetime)

### Plugin interface

**Documented Plugin Interface**:
The public manifest schemas, message protocols, Command interfaces, Host Services, and Plugin APIs expressly supported for third-party Plugin interoperability, evolving with Host releases. Compatible Plugins use one current interface.
_Avoid_: Host internals, private API, ABI

**Host Compatibility**:
A Plugin's declared range of Host releases it can run on. The Host checks its own release against this range before registration; Capability grants remain separate.
_Avoid_: Plugin API Level, SDK version, protocol version

**Plugin API Namespace**:
The domain area forming the first segment of a catalogue Host Service ID, such as `clipboard` in `clipboard.write`. It organizes operations and grants no authority itself.
_Avoid_: SDK area, module, Capability

### PopClip compatibility and licensing

PopClip import and the Conversion Portal below are planned concepts, not
implemented Spinnet features. The licensing terms also apply to current Plugins.

**PopClip Extension**:
An extension package authored for PopClip, which a planned compatibility adapter would import rather than treat as a native Plugin.
_Avoid_: PopClip Plugin, native Plugin

**Compatibility Level**:
A planned named tier describing which categories of PopClip Extension behavior Spinnet would support, without implying complete PopClip equivalence.
_Avoid_: Compatibility percentage, full compatibility

**Compatibility Report**:
A planned per-extension account of supported, degraded, and unsupported behavior at import time.
_Avoid_: Validation result, support badge

**Conversion Portal**:
A planned, independently deployed online service to analyze a PopClip Extension and, when policy permits, produce an installable offline Spinnet Plugin. It would be separate from the Host and Plugin runtime.
_Avoid_: Compatibility runtime, URL importer, marketplace

**Spinnet-Owned Code**:
Source and other material in Spinnet's own repositories that Spinnet has the right to license. It excludes third-party Plugins, converted Plugins, dependencies, and separately licensed assets.
_Avoid_: Entire repository, all bundled code, open-source code

**Upstream Licence**:
The licence supplied by the rights holder of a third-party Plugin, PopClip Extension, dependency, or asset. It continues to govern that material when Spinnet processes or distributes it.
_Avoid_: Spinnet License, marketplace licence

**Independent Plugin**:
A Plugin that interacts with the Host exclusively through the Documented Plugin Interface and uses no Spinnet-Owned Code beyond what Spinnet publishes under a permissive licence for Plugin authors. Its Upstream Licence is not replaced by the Host's GPL solely because of that interaction.
_Avoid_: GPL Plugin, bundled code, Host module
