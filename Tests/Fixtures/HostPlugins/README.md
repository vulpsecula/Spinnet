# Fixed inputs for Host tests

These seven test-only packages derive from Host commit
`91ff874f5494f4e67548626b93e81f24e9dfb4cd`, before #66. They exercise fixed Host behaviours, never packaging. Their declarations and
Host Service names follow the current public interface; their configuration and
behaviour inputs remain fixed. Update them only for Host contract changes.
The original package bytes are retained in the local audit archive.
Their original first-party GPL-3.0-only licence remains the Host's licence.
The live official packages and their behaviour tests moved to SpinnetPlugins.
Historical `Tests/RegressionBaseline/` files are unchanged.

| Former repository reader | New source and reason |
| --- | --- |
| `SpinnetCoreTests/ClipboardHistoryTests` | Clipboard History fixture: install precedence and replacement rules belong to the Host. |
| `SpinnetCoreTests/PluginRuntimeTests` | Clipboard History fixture: the Host Surface and helper lifecycle need a fixed request. |
| `SpinnetCoreTests/BundledPluginFixtures` | Window Position and Translator fixtures: historical registration, configuration and grant inputs. |
| `SpinnetCoreTests/OpenTargetSetupTests` | Open File and Open URL fixtures: Host placement/input validation and update retention. |
| `SpinnetHostTests/RichClipboardHistoryTests` | Clipboard History fixture: master collection consent and data disclosure belong to the Host. |
| `SpinnetHostTests/DeepLinkMigrationTests` | Shottr fixture: a historical reviewed grant must migrate only onto equivalent templates. |
| `SpinnetHostTests/PluginSettingsModelTests` | Translator and Smart Jump fixtures: ordered settings and editable rows belong to the Host. |
| `Tests/Support/ShippedPluginPackages` | Packaging resolver and lock: checks and integrations explicitly describing what ships must use the actual shipped revision. |
| `SpinnetHostTests/ArchitectureGuardTests` | `ShippedPluginPackages`: forbidden literals must come from the manifests that actually ship. |
| `UIPreviewRenderer` | Separate `PluginSettingsPreview.spinnetplugin` Host fixture: rendering a settings form should not depend on a live official Plugin. |
| `PluginUnderTest` named lookup | Host readers now use explicit fixture paths. Generic parent/`Plugins` lookup remains available for independent Plugin repositories; it has no Host-repository default. |
| `Tests/BundledPluginTests` | Moved with history to SpinnetPlugins: official package behaviour evolves with its packages, against the commit-pinned public kit and real helper. Private imports are removed. |

`ManifestSchemaTests` validates the actual shipped manifests against the Host's
published schema. `RegressionBaselineTests` migrates historical user data against
the actual shipped registry. Both now share the locked-source resolver; neither
changes the historical baseline or substitutes a fixture for what ships.
