/** Manifest data only. Available at Plugin API Level 3. */
export interface ExternalAppConnectionDeclaration {
  bundle_id: string;
  command_ids: [string, ...string[]];
}
export interface ExternalAppConnectionsManifest {
  external_app_connections?: ExternalAppConnectionDeclaration[];
}
