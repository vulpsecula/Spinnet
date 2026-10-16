# Historical inputs for Host tests

These seven packages are frozen from Host commit
`91ff874f5494f4e67548626b93e81f24e9dfb4cd`, before #66. They are test fixtures,
never packaging inputs. Do not refresh them when official Plugins change.
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
| `SpinnetHostTests/ShippedPluginPackages` | Packaging resolver and lock: checks and integrations explicitly describing what ships must use the actual shipped revision. |
| `SpinnetHostTests/ArchitectureGuardTests` | `ShippedPluginPackages`: forbidden literals must come from the manifests that actually ship. |
| `UIPreviewRenderer` | Separate `PluginSettingsPreview.spinnetplugin` Host fixture: rendering a settings form should not depend on a live official Plugin. |
| `PluginUnderTest` named lookup | Host readers now use explicit fixture paths. Generic parent/`Plugins` lookup remains available for independent Plugin repositories; it has no Host-repository default. |
| `Tests/BundledPluginTests` | Moved with history to SpinnetPlugins: official package behaviour evolves with its packages, against the commit-pinned public kit and real helper. Private imports are removed. |
