/** Manifest data only. Current supported declarations; see reference/manifest.md#plugin-icon. */
export interface SymbolIconDeclaration {
  /** An SF Symbols name: lower-case letters, digits and dots, at most 64 characters. */
  symbol: string;
}
/** A PNG or PDF inside the package; see reference/manifest.md#icon-pictures. */
export type PictureIconDeclaration =
  | {
      /** Package-relative path to a .png or .pdf file, at most 256 characters. */
      image: string;
      /** The Host tints the picture's shape like a system symbol. */
      template: true;
      dark_image?: never;
    }
  | {
      image: string;
      template?: false;
      /** The picture shown in a Dark appearance. */
      dark_image?: string;
    };
export type IconDeclaration = SymbolIconDeclaration | PictureIconDeclaration;
export interface PluginIconManifest {
  /** The Plugin Icon the Library and the radial Menu show. Absent, the Host shows a neutral symbol. */
  icon?: IconDeclaration;
}
