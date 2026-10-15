// SPDX-License-Identifier: MIT
// Opt in with api_level:2 and candidate_contracts:[{name:"adaptive_layout",revision:2}].
import type * as Stable from "../../../spinnet-level-2";
import type {JSONValue} from "../../../spinnet";
export interface TextOverride { id: Stable.ID; text?: string; style?: Stable.TextStyle; hidden?: boolean }
export interface DensityProfile {
  id: Stable.ID; min_card_width: number; min_card_height: number; spacing?: number; overrides?: TextOverride[];
}
export interface Fit { profiles: DensityProfile[] }
export interface TextOverrideOptions { id: Stable.ID; text?: string; style?: Stable.StyleOptions; hidden?: boolean }
export interface DensityProfileOptions {
  id: Stable.ID; minCardWidth: number; minCardHeight: number; spacing?: number; overrides?: TextOverrideOptions[];
}
export interface FitOptions { profiles: DensityProfileOptions[] }
export interface Adaptive {
  kind: "adaptive";
  id: Stable.ID;
  /** 1–8 identified components; no nested Adaptive or Collection. */
  content: (Stable.Leaf | Stable.Row | Stable.Column)[];
  /** Minimum desired width160–600pt, default200; a narrower viewport wins. */
  min_card_width?: number;
  /** Horizontal and vertical gap0–24pt, default12. */
  spacing?: number;
  /** Maximum equal-width columns1–4, default4. */
  max_columns?: number;
  /** Sole page-content region; ordered least to most detailed profiles. */
  fit?: Fit;
}
export type Page = Omit<Stable.Page, "content"> & {content: (Stable.Component | Adaptive)[]};
export type Answer = Stable.Answer | {page: Page; state?: JSONValue; toast?: string; operation?: Stable.RequestedOperation};
export interface Components extends Stable.PageComponents {
  adaptive(options: {id: Stable.ID; content: Adaptive["content"]; minCardWidth?: number; spacing?: number; maxColumns?: number; fit?: FitOptions}): Adaptive;
}
export interface UI extends Omit<Stable.UI, "components" | "page" | "showPage"> {
  components: Components;
  page(options: Omit<Parameters<Stable.UI["page"]>[0], "content"> & {content: Page["content"]}): Page;
  showPage(page: Page, options?: Parameters<Stable.UI["showPage"]>[1]): Answer;
}
export type Spinnet = Omit<Stable.Spinnet, "ui"> & {ui: UI};
export type Globals = Omit<Stable.Globals, "spinnet"> & {spinnet: Spinnet};
