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
A first-party Plugin distributed with Spinnet that follows the same Capability boundary as an independently installed Plugin, even when its Commands rely on Host-owned services.
_Avoid_: Built-in Command, trusted Host code

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
The settings collection of Menu Item Presets available to add to a Menu, grouped by built-in and Plugin-provided sources.
_Avoid_: Plugin list, Action list

**Menu Item Preset**:
A recipe exposed as one Library entry for creating a Menu Item. A built-in Preset describes one Host-provided function; a Plugin exposes one Preset that selects default Primary and Alternate Commands from those it provides.
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
Configuration shared by a Plugin across the Menu Items created from its Presets.
_Avoid_: Menu Item configuration, Preset defaults

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
A controlled operation provided by the Host, whose availability may depend on a Capability and a System Permission.
_Avoid_: Capability, system API

**External App**:
An application installed outside Spinnet that exposes an app-owned integration interface, such as a URL scheme or Apple Events API.
_Avoid_: Plugin, dependency

**External App Adapter**:
A Plugin that maps its Commands to the documented integration interface of a specific External App without granting the Plugin general control over installed applications.
_Avoid_: External App, universal app integration

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
Source and other material in the main repository that Spinnet has the right to license. It excludes third-party Plugins, converted Plugins, dependencies, and separately licensed assets.
_Avoid_: Entire repository, all bundled code, open-source code

**Upstream Licence**:
The licence supplied by the rights holder of a third-party Plugin, PopClip Extension, dependency, or asset. It continues to govern that material when Spinnet processes or distributes it.
_Avoid_: Spinnet License, marketplace licence

**Independent Plugin**:
A Plugin that is not based on Spinnet-Owned Code and interacts with the Host exclusively through the Documented Plugin Interface. Its Upstream Licence is not replaced by the Host's GPL solely because of that interaction.
_Avoid_: GPL Plugin, bundled code, Host module

**Documented Plugin Interface**:
The public manifest schemas, message protocols, Command interfaces, Host Services, and Plugin APIs expressly supported for third-party Plugin interoperability.
_Avoid_: Host internals, private API, ABI
