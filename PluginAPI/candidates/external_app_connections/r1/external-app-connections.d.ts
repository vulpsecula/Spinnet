/** Manifest data only. Requires external_app_connections revision 1. */
export interface ExternalAppConnectionDeclaration {
  bundle_id: string;
  command_ids: [string, ...string[]];
}
export interface ExternalAppConnectionsManifest {
  external_app_connections?: ExternalAppConnectionDeclaration[];
}
