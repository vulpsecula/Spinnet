# Spinnet

Spinnet is a mouse-first macOS action environment centered on a radial menu. This glossary defines the language used to describe what the host and plugins offer, what users configure, and how authority is granted.

## Language

**Host**:
The trusted Spinnet application that presents menus, coordinates execution, and provides controlled access to operating-system facilities.
_Avoid_: Core, main app

**Plugin**:
An installable provider of Commands that extends Spinnet without becoming part of the Host.
_Avoid_: Extension, add-on

**Command**:
A callable operation declared by the Host or a Plugin, before user-specific configuration is applied.
_Avoid_: Action type, function

**Action**:
A configured instance of a Command that is ready to execute. Multiple Actions may be configured from the same Command.
_Avoid_: Command, operation

**Menu**:
A radial collection of Menu Items presented by the Host.
_Avoid_: Wheel, palette

**Menu Item**:
A position in a Menu that binds one Primary Action and may expose Alternate Actions.
_Avoid_: Sector, button

**Primary Action**:
The Action executed by the Menu Item's default gesture or left-click.
_Avoid_: Default command

**Alternate Action**:
An additional Action exposed from a Menu Item rather than executed by its default gesture.
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
