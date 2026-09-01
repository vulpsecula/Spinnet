# Spinnet Plugin Exception 1.0 — legal draft

This is a draft additional permission under section 7 of GNU GPL version 3. It is not approved for release and must be reviewed by qualified counsel before it is attached to Spinnet distributions.

## Draft text

Additional permission under GNU GPL version 3 section 7:

The copyright holders of Spinnet grant you permission to create, use, reproduce, and distribute an Independent Plugin under licence terms of your choice, and to combine or use Spinnet with that Independent Plugin through the Documented Plugin Interface, without causing the Independent Plugin to be covered by the GNU General Public License solely because of that interaction.

You may convey Spinnet together with an Independent Plugin under different licences, provided that you comply with the GNU General Public License for Spinnet, comply with the applicable licence for the Independent Plugin, keep the works and their licence notices clearly distinguishable, and do not impose terms that restrict recipients from exercising the rights granted for Spinnet under the GNU General Public License.

For this exception:

- **Independent Plugin** means a work that is not based on Spinnet-Owned Code and interacts with Spinnet exclusively through the Documented Plugin Interface. A manifest, script, executable, resource, or other work does not become non-independent merely because Spinnet loads, interprets, invokes, or exchanges documented messages with it.
- **Documented Plugin Interface** means the public manifest schemas, message protocols, command interfaces, Host Services, and Plugin APIs that Spinnet expressly documents for third-party Plugin interoperability.
- **Spinnet-Owned Code** means the implementation of Spinnet that is covered by the GNU General Public License and to which this additional permission is attached.

This exception does not apply to modifications of Spinnet-Owned Code, works that copy or derive from non-interface Spinnet implementation code, or combinations that use undocumented Spinnet internals. It grants no permission to use Spinnet names, logos, or trademarks except as necessary for accurate attribution and compatibility statements.

When you modify Spinnet-Owned Code, you may extend this exception to your version or remove it, as permitted by section 7 of GNU GPL version 3.

## Packaging note

Until this exception has a registered SPDX exception identifier, source files should not use an invented `WITH` expression. The release process should use `SPDX-License-Identifier: GPL-3.0-or-later` for GPL-covered files and point distribution metadata to the accompanying exception document separately, subject to counsel and SPDX-tooling review.
