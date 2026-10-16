// SPDX-License-Identifier: MIT
// Stable Plugin API Level 3. Declare api_level: 3, without candidate_contracts.
export * from "./spinnet-level-2";
export type { ExternalAppConnectionDeclaration, ExternalAppConnectionsManifest } from "./external-app-connections";
export type { SpotifyControlInput, SpotifyVolume, SpotifyNextOutcome } from "./spotify-controls";
export type { Adaptive, Fit, FitOptions, DensityProfile, DensityProfileOptions } from "./adaptive-layout";
export type { AutoremovePreviewInput, AutoremoveTaskInput, AutoremovePreview } from "./homebrew-autoremove";
import type * as Stable from "./spinnet-level-2";
import type * as Adaptive from "./adaptive-layout";
import type * as Autoremove from "./homebrew-autoremove";
import type { SpotifyControlCallable } from "./spotify-controls";
import type { JSONValue } from "./spinnet";

export type RequestedOperation = Stable.RequestedOperation | ReturnType<Autoremove.AutoremoveTask["operation"]>;
export type Page = Omit<Adaptive.Page, "sources"> & {
  sources?: (Stable.Source | Autoremove.AutoremoveSource)[];
};
export type Answer = Stable.Answer | {
  page: Page; state?: JSONValue; toast?: string; operation?: RequestedOperation;
} | { operation: RequestedOperation; state?: JSONValue; toast?: string };
export interface UI extends Omit<Adaptive.UI, "page" | "showPage" | "request" | "show"> {
  page(options: Omit<Parameters<Adaptive.UI["page"]>[0], "sources"> & {sources?: Page["sources"]}): Page;
  showPage(page: Page, options?: {state?: JSONValue; toast?: string; operation?: RequestedOperation}): Answer;
  show(view: Stable.View, options?: {state?: JSONValue; toast?: string; operation?: RequestedOperation}): Answer;
  request(operation: RequestedOperation, options?: {toast?: string}): Answer;
}
export type Spinnet = Omit<Stable.Spinnet, "ui" | "tools" | "apps"> & {
  readonly ui: UI;
  readonly tools: Omit<Stable.ToolsNamespace, "read" | "startTask"> & {
    readonly read: Autoremove.AutoremoveRead & Stable.ToolsNamespace["read"];
    readonly startTask: Autoremove.AutoremoveTask & Stable.ToolsNamespace["startTask"];
  };
  readonly apps: Omit<Stable.AppsNamespace, "perform"> & {
    readonly perform: SpotifyControlCallable & Stable.AppsNamespace["perform"];
  };
};
export type Globals = Omit<Stable.Globals, "spinnet"> & {spinnet: Spinnet};
