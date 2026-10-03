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
A first-party Plugin distributed with Spinnet. It follows the same Capability boundary and Documented Plugin Interface as any other Plugin and may do nothing a user-added one cannot. It is managed like any other Plugin: removing it removes it, and the user brings it back the way they would bring back any Plugin, by installing a copy of it, whose Plugin Origin is then the user's. Its files ship with the app and cannot be deleted, so a removed one stays suppressed underneath.
_Avoid_: Built-in Command, trusted Host code

**Plugin Origin**:
Where a Plugin's package came from: shipped with the app, making it a Bundled Plugin, or added by the user. It decides whether an install may replace the Plugin and how a removal is recorded, and it grants no access.
_Avoid_: Plugin type, plugin kind, trust level, installed Plugin

**Refused Plugin**:
A Plugin added by the user that the Host does not load at launch, because its package is broken or it declares a Plugin API Level or Candidate Contract revision this Host does not provide. Unlike a removed Plugin it stays: the Library lists it with the reason and can remove it, and its Menu Items, Plugin Settings, Plugin Storage and access decisions are kept until it is replaced or removed.
_Avoid_: Unavailable Plugin, broken Plugin, disabled Plugin

**Plugin Removal**:
Dropping a Plugin the user no longer wants. Its access decisions are forgotten and it leaves the Library, while Menu Items built from it are kept and reported as unavailable. A removed Bundled Plugin stays removed across launches and app updates, whichever copies of its package are on disk.
_Avoid_: Delete Plugin, uninstall preset, clear Plugin

**Plugin Storage**:
Data a Plugin keeps for itself between invocations and launches, which only that Plugin can reach and which is deleted when the Plugin is removed. It holds the Plugin's own data, never the user's choices or a secret.
_Avoid_: LocalStorage, cache, Plugin data, Plugin Settings

### Commands and Actions

**Command**:
A callable operation a Plugin declares, before user-specific configuration is applied. A Command either runs one Host Service directly, which makes it a Host Command, or runs the Plugin's script, which may call Host Services.
_Avoid_: Action type, function

**Host Command**:
A Command that runs one Host Service directly instead of a script, by naming the Service's ID in its manifest, such as `open.url` or `screen.capture`; the Action's configuration supplies the Service's input, and no script runs. Plugin API Level 1 has Host Command names of its own, such as `url.open` and `screen.capture_area`, which Level 1 Plugins keep. The Host has no Library entries of its own: Open URL, Screenshot and the rest are Bundled Plugins whose Commands are Host Commands, and the user may remove them like any other Plugin.
_Avoid_: Built-in Plugin, Built-in Preset, native Action

**Host Service**:
A controlled operation the Host performs for any Plugin that is granted it, never shaped around one Plugin's feature, listed once in the Plugin API catalogue under one `namespace.verb` ID, such as `clipboard.write`. From the first new UI contract on, every entry point names it by that ID: a script's call, a Host Command, a View Action and a Requested Host Operation. Plugin API Level 1 names the same operation differently at each entry point (`write_clipboard`, `clipboard.copy`, `copy_text`), and Level 1 Plugins keep those names. Its availability may depend on a Capability and a System Permission.
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
Configuration shared by a Plugin across the Menu Items created from its Presets, filled in from the Library before any is placed. A setting the Plugin marks overridable may be set again in one Menu Item's Menu Item Configuration, and a Plugin may offer some of its settings as controls in its Plugin Views.
_Avoid_: Menu Item Configuration, Preset defaults

**Appearance**:
The global visual configuration shared by a Menu's Editor Mode and Runtime Mode, excluding anything in a Menu Item Configuration.
_Avoid_: Menu Item Configuration, Plugin theme

**Status Item**:
Spinnet's icon in the macOS menu bar, distinct from the radial Menu.
_Avoid_: Menu, tray icon

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

**Collection**:
A View Component that presents a Plugin's items to select and act on, as a list or a grid. The Host owns selection, keyboard navigation, scrolling and asking for more items; the Plugin owns the items, their search and their order.
_Avoid_: Table, results list, data source

**Immediate State**:
What the Host keeps for a View Component while the user works with it: typed text, caret, input-method composition, focus, selection and scroll. It survives the Plugin's answers until the Plugin explicitly resets that component or its View Page, and it is separate from the state the Plugin keeps for itself.
_Avoid_: UI state, view state, draft

**View Event**:
One user interaction in a Plugin View, such as editing a field, submitting, or choosing a View Action, delivered to the Plugin, which answers with its next description of the view and its own state.
_Avoid_: Callback, UI message

**View Action**:
A button or menu entry a Plugin View offers, which either has the Host perform a Host Service, such as copying or inserting text, or sends the Plugin a View Event. A Plugin never binds keyboard shortcuts to it.
_Avoid_: Action (a Menu Item's), shortcut, command button

**Item Action**:
A View Action a Collection offers on each of its items. Its default Item Action runs on Return or double-click; the others are in the item's context menu.
_Avoid_: Primary Action (a Menu Item's), row button, shortcut

**Host-Fetched Section**:
A part of a Plugin View whose request the Host sends and whose answer the Host shows, so the Plugin need not see the answer; the Plugin declares whether the answer is also delivered to it.
_Avoid_: Result popup, remote section

**Host Surface**:
A window the Host owns and presents on behalf of a Plugin, because the public view vocabulary cannot express it. Any Plugin granted the Capability it shows data from may request it; where the Plugin came from grants nothing.
_Avoid_: Plugin window, privileged UI

**Insertion Target**:
The App that receives text the Host inserts for a Plugin. Under Plugin API Level 1 it is the App in front when the Plugin View appeared, or for a script's own insertion the App in front at that moment; under the first new UI contract it is the App in front at insertion, whose name the Host shows and never gives to the Plugin.
_Avoid_: Origin App, recent App, focused App (when the panel is meant)

**Requested Host Operation**:
Proposed for the first new UI contract: a Host Service a script asks the Host to perform after its invocation ends, by naming its ID in its answer to a user gesture; the Host checks authority, confirms when that Service requires it, resolves the target, performs it and reports one outcome.
_Avoid_: Callback, deferred Host Service, async call

**Host Confirmation**:
Proposed for the first new UI contract: a trusted confirmation the Host draws, with its own text and the target it resolved, before performing an operation whose kind requires it; a Plugin can neither skip nor word it.
_Avoid_: Confirmation dialog (for a Plugin's own view), alert, consent

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

**Reviewed App Interface**:
The Host's reviewed description of the Apple Events operations one External App accepts, from which an External App Adapter may choose. Adding one is a Host release.
_Avoid_: Host adapter, AppleScript bridge

**Deep Link Template**:
A link into an External App's documented URL interface, declared by a Plugin with bounded parameters and consented to by the user.
_Avoid_: URL action, custom scheme

### Plugin interface

**Documented Plugin Interface**:
The public manifest schemas, message protocols, Command interfaces, Host Services, and Plugin APIs expressly supported for third-party Plugin interoperability, versioned by Plugin API Level.
_Avoid_: Host internals, private API, ABI

**Plugin API Level**:
The version of the Documented Plugin Interface a Plugin requires; a Host installs the Plugin only if it supports that level.
_Avoid_: SDK version, protocol version

**Plugin API Namespace**:
Proposed for the first new UI contract: a named group of Host Services that act on or read the same thing, such as `selection`, `clipboard` or `open`. It is the first part of each Host Service's ID and the object that holds the Service in the `spinnet` SDK (`spinnet.clipboard.write`), so it also tells which target and authority apply. It grants nothing; Capabilities do.
_Avoid_: SDK area, module, Capability

**Candidate Contract**:
An explicitly provisional revision of the Documented Plugin Interface used to evaluate additions before they become part of a stable Plugin API Level.
_Avoid_: Stable release, Plugin version

### PopClip compatibility and licensing

**PopClip Extension**:
An extension package authored for PopClip that Spinnet imports through its compatibility adapter rather than treating as a native Plugin.
_Avoid_: PopClip Plugin, native Plugin

**Compatibility Level**:
A named tier describing which categories of PopClip Extension behavior Spinnet supports, without implying complete PopClip equivalence.
_Avoid_: Compatibility percentage, full compatibility

**Compatibility Report**:
Spinnet's per-extension account of supported, degraded, and unsupported behavior at import time.
_Avoid_: Validation result, support badge

**Conversion Portal**:
An independently deployed online service that analyzes a PopClip Extension and, when policy permits, produces an installable offline Spinnet Plugin. It is not part of the Host or a Plugin runtime.
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
