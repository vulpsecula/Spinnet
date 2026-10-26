/** Manifest data only. Current supported declaration. */
export interface ExternalAppConnectionDeclaration {
  bundle_id: string;
  command_ids: [string, ...string[]];
}
export interface ExternalAppConnectionsManifest {
  external_app_connections?: ExternalAppConnectionDeclaration[];
}
