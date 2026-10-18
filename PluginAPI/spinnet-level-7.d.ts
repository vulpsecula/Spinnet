// SPDX-License-Identifier: MIT
export * from "./spinnet-level-6";
import type * as Stable from "./spinnet-level-6";
import type {JSONValue} from "./spinnet";
export type CatalogRefreshInput = {tool:"homebrew"; operation:"refreshCatalog"};
export type CatalogRefreshOperation = {perform:"tools.startTask"; input:CatalogRefreshInput; id?:string; notify?:boolean; closes_view?:boolean};
export type RequestedOperation = Stable.RequestedOperation | CatalogRefreshOperation;
export type ReviewedToolTaskInput = Stable.ReviewedToolTaskInput | CatalogRefreshInput;
export interface Operations extends Omit<Stable.Operations,"tools.startTask"> {
  "tools.startTask": {input:ReviewedToolTaskInput;result:Stable.Operations["tools.startTask"]["result"]};
}
export type InputOf<K extends Stable.OperationID> = Operations[K]["input"];
export type ResultOf<K extends Stable.OperationID> = Operations[K]["result"];
export type Answer = Stable.Answer | {page:Stable.Page;state?:JSONValue;operation?:RequestedOperation;toast?:string};
export interface UI extends Omit<Stable.UI,"showPage"> {
  showPage(page:Stable.Page,options?:{state?:JSONValue;operation?:RequestedOperation;toast?:string}):Answer;
}
export type CatalogRefreshBuilder = {
  operation(input:CatalogRefreshInput,options?:Stable.OperationOptions):CatalogRefreshOperation;
};
export type Spinnet = Omit<Stable.Spinnet,"tools"|"ui"> & {
  readonly tools:Omit<Stable.Spinnet["tools"],"startTask"> & {readonly startTask:Stable.Spinnet["tools"]["startTask"] & CatalogRefreshBuilder};
  readonly ui:UI;
};
export type Globals = Omit<Stable.Globals,"spinnet"> & {spinnet:Spinnet};
