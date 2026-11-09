/** Manifest data only. Current supported declaration; see reference/manifest.md#plugin-tags. */
/** A tag in the published vocabulary (plugin-tags.json), which the Library offers as a filter. */
export type VocabularyPluginTag =
  | "window" | "media" | "apps" | "text" | "clipboard" | "files" | "browser" | "developer" | "system";
export interface PluginTagsManifest {
  /**
   * At most 3 distinct tags, each lower-case ASCII letters and digits joined by single hyphens, at most
   * 32 characters. A well-formed tag outside the vocabulary is admitted and kept but offers no filter.
   */
  tags?: (VocabularyPluginTag | (string & {}))[];
}
