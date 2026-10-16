// SPDX-License-Identifier: MIT
import type * as Stable from "../../../spinnet-level-2";
import type {JSONValue} from "../../../spinnet";
import type { Spinnet, ToolsNamespace, SourceOptions, OperationOptions, RequestedOperation, PerformAction } from "../../../spinnet-level-2";
export interface AutoremovePreviewInput { tool: "homebrew"; operation: "previewAutoremove"; }
export interface AutoremoveTaskInput { tool: "homebrew"; operation: "autoremove"; }
export interface AutoremovePreview {
  tool: "homebrew"; operation: "previewAutoremove"; version: string;
  available?: boolean; reason?: "requires_homebrew_7" | "requires_reviewed_homebrew_version";
  dry_run?: true; succeeded?: boolean; complete?: boolean; no_op?: boolean; truncated?: boolean;
  packages?: {kind: "formula"; name: string}[];
  exit_status?: number; stdout?: string; stderr?: string;
}
export interface AutoremoveRead {
  (input: AutoremovePreviewInput): AutoremovePreview;
  source(id: string, input: AutoremovePreviewInput, options?: Pick<SourceOptions,"deliver">): {
    id: string; perform: "tools.read"; input: AutoremovePreviewInput; deliver?: {pointer?: string};
  };
}
export interface AutoremoveTask {
  operation(input: AutoremoveTaskInput, options?: OperationOptions): Omit<RequestedOperation<"tools.startTask">,"input"> & {input: AutoremoveTaskInput};
  action(input: AutoremoveTaskInput, options?: {id?: string; title?: string; closesView?: boolean; notify?: boolean}): Omit<PerformAction<"tools.startTask">,"input"> & {input: AutoremoveTaskInput};
}
/** Same SDK namespaces, extended only under the exact declaration. */
export type HomebrewAutoremoveSpinnet = Omit<Spinnet,"tools" | "ui"> & {
  readonly ui: UI;
  readonly tools: Omit<ToolsNamespace,"read" | "startTask"> & {
    readonly read: AutoremoveRead & ToolsNamespace["read"];
    readonly startTask: AutoremoveTask & ToolsNamespace["startTask"];
  };
};

/** Existing UI builders accept the candidate's Source without widening stable types. */
export type AutoremoveSource = ReturnType<AutoremoveRead["source"]>;
export type Page = Omit<Stable.Page,"sources"> & {sources?: (Stable.Source | AutoremoveSource)[]};
export type Answer = Stable.Answer | {page: Page; state?: JSONValue; toast?: string; operation?: Stable.RequestedOperation};
export interface UI extends Omit<Stable.UI,"page" | "showPage"> {
  page(options: Omit<Parameters<Stable.UI["page"]>[0],"sources"> & {sources?: Page["sources"]}): Page;
  showPage(page: Page, options?: Parameters<Stable.UI["showPage"]>[1]): Answer;
}
