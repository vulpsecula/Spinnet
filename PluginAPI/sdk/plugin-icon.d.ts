/** Manifest data only. Current supported declaration; see reference/manifest.md#plugin-icon. */
export interface SymbolIconDeclaration {
  /** An SF Symbols name: lower-case letters, digits and dots, at most 64 characters. */
  symbol: string;
}
export interface PluginIconManifest {
  /** The Plugin Icon the Library and the radial Menu show. Absent, the Host shows a neutral symbol. */
  icon?: SymbolIconDeclaration;
}
