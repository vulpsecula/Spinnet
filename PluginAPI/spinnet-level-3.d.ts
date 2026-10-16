// SPDX-License-Identifier: MIT
// Stable Plugin API Level 3. Declare api_level: 3, without candidate_contracts.
export * from "./spinnet-level-2";
export type { ExternalAppConnectionDeclaration, ExternalAppConnectionsManifest } from "./external-app-connections";
export type { SpotifyControlInput, SpotifyVolume, SpotifyNextOutcome } from "./spotify-controls";
export type { Fit, FitOptions, DensityProfile, DensityProfileOptions } from "./adaptive-layout";
export type { AutoremovePreviewInput, AutoremoveTaskInput, AutoremovePreview } from "./homebrew-autoremove";
import type * as Stable from "./spinnet-level-2";
import type * as Layout from "./adaptive-layout";
import type * as Autoremove from "./homebrew-autoremove";
import type { SpotifyControlCallable } from "./spotify-controls";
import type { JSONValue } from "./spinnet";

/** Catalogue types include the promoted Homebrew inputs at every entry point. */
export type ReviewedToolReadInput = Stable.ReviewedToolReadInput | Autoremove.AutoremovePreviewInput;
export type ReviewedToolReadResult = Stable.ReviewedToolReadResult | Autoremove.AutoremovePreview;
export type ReviewedToolTaskInput = Stable.ReviewedToolTaskInput | Autoremove.AutoremoveTaskInput;
export interface Operations extends Omit<Stable.Operations, "tools.read" | "tools.startTask"> {
  "tools.read": {input: ReviewedToolReadInput; result: ReviewedToolReadResult};
  "tools.startTask": {input: ReviewedToolTaskInput; result: null};
}
export type InputOf<K extends Stable.OperationID> = Operations[K]["input"];
export type ResultOf<K extends Stable.OperationID> = Operations[K]["result"];
export type RequestHostService = <K extends Stable.CallID>(name: K, input?: InputOf<K>) => ResultOf<K>;
export type RequestedOperation<K extends Stable.RequestID = Stable.RequestID> =
  Omit<Stable.RequestedOperation<K>, "input"> & {input?: InputOf<K>};
export type PerformAction<K extends Stable.ViewActionID = Stable.ViewActionID> =
  Omit<Stable.PerformAction<K>, "input"> & {input?: InputOf<K>};
export type ToolSource = Omit<Stable.ToolSource, "input"> & {input: ReviewedToolReadInput};
export type Source = Exclude<Stable.Source, Stable.ToolSource> | ToolSource;
export type SourceResult = Stable.SourceResult | Autoremove.AutoremovePreview;
type SourceFor<K extends Stable.SourceID> = Extract<Source, {perform: K}>;
export type PageAction = Stable.EventButton | PerformAction;
export type Actions = Omit<Stable.Actions, "actions"> & {actions: PageAction[]};
export type Leaf = Exclude<Stable.Leaf, Stable.Actions> | Actions;
export interface Row extends Omit<Stable.Row, "content"> { content: (Leaf | Column)[] }
export interface Column extends Omit<Stable.Column, "content"> { content: (Leaf | Row)[] }
export interface Adaptive extends Omit<Layout.Adaptive, "content"> { content: (Leaf | Row | Column)[] }
// Collection Item Actions retain their clipboard.write / selection.replace boundary.
export type Component = Leaf | Row | Column | Adaptive | Stable.List | Stable.Grid | Stable.ActivityList;
export interface PageComponents extends Omit<Layout.Components, "actions" | "row" | "column" | "adaptive"> {
  actions(options: {id: Stable.ID; actions: PageAction[]}): Actions;
  row(options: {id: Stable.ID; content: Row["content"]; style?: Stable.StyleOptions}): Row;
  column(options: {id: Stable.ID; content: Column["content"]; style?: Stable.StyleOptions}): Column;
  adaptive(options: Omit<Parameters<Layout.Components["adaptive"]>[0], "content"> & {content: Adaptive["content"]}): Adaptive;
}
export type Page = Omit<Stable.Page, "sources" | "content"> & {
  sources?: Source[];
  content: Component[];
};
export type Answer = Stable.Answer | {
  page: Page; state?: JSONValue; toast?: string; operation?: RequestedOperation;
} | { operation: RequestedOperation; state?: JSONValue; toast?: string };
export interface UI extends Omit<Layout.UI, "components" | "page" | "showPage" | "request" | "show" | "source"> {
  source<K extends Stable.SourceID>(id: Stable.ID, perform: K, input: SourceFor<K>["input"], options?: Stable.SourceOptions & {every?: number}): SourceFor<K>;
  components: PageComponents;
  page(options: Omit<Parameters<Stable.UI["page"]>[0], "sources" | "content"> & {sources?: Page["sources"]; content: Component[]}): Page;
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
export type Globals = Omit<Stable.Globals, "spinnet" | "requestHostService"> & {spinnet: Spinnet; requestHostService: RequestHostService};
