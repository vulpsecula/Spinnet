/** Manifest data only. Current supported declaration; see reference/update-source.md. */
export interface UpdateSourceDeclaration {
  /** A public repository on github.com as "owner/repo". */
  github: `${string}/${string}`;
}
export interface UpdateSourceManifest {
  /** Where newer versions are published, as releases tagged `<id>/v<version>`. */
  update_source?: UpdateSourceDeclaration;
}
