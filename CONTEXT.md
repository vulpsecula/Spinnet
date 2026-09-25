# Spinnet

Spinnet is a mouse-first macOS action environment centered on a radial menu. This glossary defines the language used to describe what the host and plugins offer, what users configure, and how authority is granted.

## Language

**Host**:
The trusted Spinnet application that presents menus, coordinates execution, and provides controlled access to operating-system facilities.
_Avoid_: Core, main app

**Plugin**:
An installable provider of Commands that extends Spinnet without becoming part of the Host.
_Avoid_: Extension, add-on

**Bundled Plugin**:
A first-party Plugin distributed with Spinnet. It follows the same Capability boundary and Documented Plugin Interface as an independently installed Plugin and may do nothing an installed one cannot. It is managed like any other Plugin: removing it removes it, and the user brings it back the way they would bring back any Plugin, by installing a copy of it, which is then an installed Plugin. Its files ship with the app and cannot be deleted, so a removed one stays suppressed underneath.
_Avoid_: Built-in Command, trusted Host code

**Host Command**:
An operation the Host implements itself, such as opening a URL or capturing the screen, which a Plugin's Command runs by naming it in its manifest instead of running a script. The Host has no Library entries of its own: Open URL, Screenshot and the rest are Bundled Plugins that run Host Commands, and the user may remove them like any other Plugin.
_Avoid_: Built-in Plugin, Built-in Preset, native Action

**Host Surface**:
A window the Host owns and presents on behalf of a Plugin, because the public view vocabulary cannot express it. Any Plugin granted the Capability it shows data from may request it; where the Plugin came from grants nothing.
_Avoid_: Plugin window, privileged UI

**Plugin Origin**:
Where a Plugin's package came from — shipped with the app, or installed by the user — which decides whether an install may replace it and how a removal is recorded. It grants no access.
_Avoid_: Plugin type, plugin kind, trust level

**Plugin Removal**:
Dropping a Plugin the user no longer wants. Its access decisions are forgotten and it leaves the Library, while Menu Items built from it are kept and reported as unavailable, exactly as a disabled Plugin's are. A removed Bundled Plugin stays removed across launches and app updates, whichever copies of its package are on disk.
_Avoid_: Delete Plugin, uninstall preset, clear Plugin

**Command**:
A callable operation declared by the Host or a Plugin, before user-specific configuration is applied.
_Avoid_: Action type, function

**Action**:
A configured instance of a Command that is ready to execute. Multiple Actions may be configured from the same Command.
_Avoid_: Command, operation

**Menu**:
A radial collection of Menu Items presented by the Host.
_Avoid_: Wheel, palette

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
The settings collection of Menu Item Presets available to add to a Menu, one per registered Plugin, in a single list.
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
A modal settings surface for editing one Menu Item's instance-specific configuration before saving or cancelling the changes.
_Avoid_: Submenu, secondary window, inspector

**Plugin Settings**:
Configuration shared by a Plugin across the Menu Items created from its Presets, filled in from the Library before any is placed. A setting the Plugin marks overridable may be set again on one Menu Item, and a Plugin may offer some of its settings as controls in its Plugin Views.
_Avoid_: Menu Item configuration, Preset defaults

**Plugin View**:
An interface a Plugin describes as data and the Host renders while one of its Actions runs, such as a form or a detail page. It never contains the Plugin's own markup or native UI.
_Avoid_: Popup, plugin window, custom UI

**View Session**:
The span from a Plugin View appearing until it closes, during which the Host keeps the view's state and hands each user interaction to the Plugin as a View Event.
_Avoid_: Long-running helper, view process

**View Event**:
One user interaction in a Plugin View, such as editing a field, submitting, or choosing an action, delivered to the Plugin, which answers with the next state of the view.
_Avoid_: Callback, UI message

**Host-Fetched Section**:
A part of a Plugin View whose request the Host sends and whose answer the Host shows, so the Plugin need not see the answer; the Plugin declares whether the answer is also delivered to it.
_Avoid_: Result popup, remote section

**Plugin Storage**:
Data a Plugin keeps for itself between invocations and launches, which only that Plugin can reach and which is deleted when the Plugin is removed. It holds the Plugin's own data, never the user's choices or a secret.
_Avoid_: LocalStorage, cache, Plugin data, Plugin Settings

**Appearance**:
The global visual configuration shared by a Menu's Editor Mode and Runtime Mode, excluding Menu Item-specific aliases, icons, and Action parameters.
_Avoid_: Menu Item configuration, Plugin theme

**Privacy & Permissions**:
The settings page where users manage Host System Permissions, Sensitive Data Collection, and the Capabilities granted to individual Plugins as separate layers of authority.
_Avoid_: Plugin Settings, macOS System Settings

**Status Item**:
Spinnet's icon in the macOS menu bar, distinct from the radial Menu.
_Avoid_: Menu, tray icon

**Menu Item**:
A configured entry that occupies a Menu Slot, binds one Primary Action, and may expose Alternate Actions.
_Avoid_: Sector, button

**Menu Slot**:
An evenly distributed position in a Menu that may be empty or occupied by one Menu Item.
_Avoid_: Empty Menu Item, sector

**Menu Item Alias**:
A user-defined display name for one Menu Item, independent of its Preset, Plugin, and Action names and not required to be unique.
_Avoid_: Action title, Plugin name

**Primary Action**:
The Action executed by the Menu Item's default gesture or left-click.
_Avoid_: Default command

**Alternate Action**:
An additional Action associated with a Menu Item that its configuration may expose in Runtime Mode rather than execute by the default gesture.
_Avoid_: Secondary command, option

**System Permission**:
Authority macOS grants to the Host, such as Accessibility, Input Monitoring, or Screen Recording.
_Avoid_: Capability, plugin permission

**Capability**:
Authority a user grants to a Plugin to access a protected category of Host functionality or data.
_Avoid_: System Permission, entitlement

**Host Service**:
A controlled operation provided by the Host for any Plugin that is granted it, never shaped around one Plugin's feature. Its availability may depend on a Capability and a System Permission.
_Avoid_: Capability, system API, Plugin-specific service

**Credential Use**:
A Plugin-declared way for the Host to place a stored credential into a request, or sign a request with it, as the request is sent. The Plugin never sees the credential or any value derived from it.
_Avoid_: Signing oracle, credential digest, API key access

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

**Sensitive Data Collection**:
An explicit Host-level opt-in that permits Spinnet to continuously collect and retain a named category of sensitive system data, such as clipboard history. It is separate from a Plugin's Capability to read collected data.
_Avoid_: Capability, System Permission, background Plugin permission

**Clipboard History Store**:
The Host-owned collection of retained clipboard entries, populated only while its Sensitive Data Collection setting is enabled and exposed to a Plugin only through granted Capabilities and Host Services.
_Avoid_: Clipboard History Plugin database, pasteboard

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

**Documented Plugin Interface**:
The public manifest schemas, message protocols, Command interfaces, Host Services, and Plugin APIs expressly supported for third-party Plugin interoperability, versioned by Plugin API Level.
_Avoid_: Host internals, private API, ABI

**Plugin API Level**:
The version of the Documented Plugin Interface a Plugin requires; a Host installs the Plugin only if it supports that level.
_Avoid_: SDK version, protocol version
