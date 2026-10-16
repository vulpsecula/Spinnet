// SPDX-License-Identifier: MIT
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
export type HomebrewAutoremoveSpinnet = Omit<Spinnet,"tools"> & {
  readonly tools: Omit<ToolsNamespace,"read" | "startTask"> & {
    readonly read: AutoremoveRead & ToolsNamespace["read"];
    readonly startTask: AutoremoveTask & ToolsNamespace["startTask"];
  };
};
