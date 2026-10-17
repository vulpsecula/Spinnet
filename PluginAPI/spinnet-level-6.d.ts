// SPDX-License-Identifier: MIT
export * from "./spinnet-level-5";
import type * as Stable from "./spinnet-level-5";
export type CommandOutputInput = {tool:"homebrew"; operation:"commandOutput"} & (
  | {command:"list"|"outdated"; kind?:"formula"|"cask"; package?:string}
  | {command:"search"|"info"; kind?:"formula"|"cask"; package:string}
  | {command:"version"|"config"|"doctor"|"tap"}
  | {command:"services"; action?:"list"}
  | {command:"services"; action:"info"; package:string}
);
export type CommandOutputResult = {tool:"homebrew"; operation:"commandOutput"; output:string; output_truncated:boolean; exit_status:number};
export type ReviewedToolReadInput = Stable.ReviewedToolReadInput | CommandOutputInput;
export type ReviewedToolReadResult = Stable.ReviewedToolReadResult | CommandOutputResult;
export interface Operations extends Omit<Stable.Operations,"tools.read"> {
  "tools.read": {input:ReviewedToolReadInput; result:ReviewedToolReadResult};
}
export type InputOf<K extends Stable.OperationID> = Operations[K]["input"];
export type ResultOf<K extends Stable.OperationID> = Operations[K]["result"];
export type RequestHostService = <K extends Stable.CallID>(name:K,input?:InputOf<K>)=>ResultOf<K>;
export type CommandOutputSource = Omit<Stable.ToolSource,"input"> & {input:CommandOutputInput};
export type Source = Stable.Source | CommandOutputSource;
export type OutputText = Stable.TextBlock & {format?:"output"};
type OutputRead = ((input:CommandOutputInput)=>CommandOutputResult) & {
  source(id:Stable.ID,input:CommandOutputInput,options?:Pick<Stable.SourceOptions,"deliver">):CommandOutputSource;
};
export interface PageComponents extends Omit<Stable.PageComponents,"text"> {
  text(options:Parameters<Stable.PageComponents["text"]>[0] & {format?:"output"}):OutputText;
}
export type Page = Omit<Stable.Page,"sources"> & {sources?:Source[]};
export type Answer = Stable.Answer | {page:Page; state?:import("./spinnet").JSONValue; operation?:Stable.RequestedOperation; toast?:string};
export interface UI extends Omit<Stable.UI,"components"|"page"|"showPage"|"source"> {
  components:PageComponents;
  page(options:Page):Page;
  showPage(page:Page,options?:{state?:import("./spinnet").JSONValue;operation?:Stable.RequestedOperation;toast?:string}):Answer;
  source:Stable.UI["source"] & ((id:Stable.ID,perform:"tools.read",input:CommandOutputInput,options?:Pick<Stable.SourceOptions,"deliver">)=>CommandOutputSource);
}
export type Spinnet = Omit<Stable.Spinnet,"tools"|"ui"> & {
  readonly tools:Omit<Stable.Spinnet["tools"],"read"> & {readonly read:Stable.Spinnet["tools"]["read"] & OutputRead};
  readonly ui:UI;
};
export type Globals = Omit<Stable.Globals,"spinnet"|"requestHostService"> & {spinnet:Spinnet;requestHostService:RequestHostService};
