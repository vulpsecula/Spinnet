// PROPOSAL ONLY (#71). Draft types for Host-run sources.
// SPDX-License-Identifier: MIT
//
// A draft Level 2 addition, not a Candidate Contract: #82 would merge these
// into `../../spinnet-level-2.d.ts` and implement the builders in
// `../../spinnet-level-2.js`. Nothing here is offered yet. `reference.md`
// states the rules; `host-run-sources.schema.json` the shapes.

import type { JSONValue } from "../../spinnet";
import type { ID, InputOf, Page, ResultOf, TextBlock } from "../../spinnet-level-2";

/** Catalogue IDs a page may name in a source's `perform`. #86 adds "system.metrics"; #85 Spotify's read. */
export type SourceID = "http.request";

/** What a source's result is: an operation's result, plus `json` for http.request. */
export type SourceResult<K extends SourceID> = K extends "http.request"
  ? ResultOf<"http.request"> & { json?: JSONValue }
  : ResultOf<K>;

/**
 * A Host-run source. Sampled only while its page is visible, one sample at a
 * time; kept while an answer keeps the page and the Command and gives it an
 * equal definition.
 */
export interface Source<K extends SourceID = SourceID> {
  id: ID;
  perform: K;
  input: InputOf<K>;
  /** Seconds from the end of one sample to the start of the next; absent: once while visible. */
  every?: number;
  /** Deliver results as `source_delivered`, on change of the value at `pointer` (the whole result without one). */
  deliver?: { pointer?: string };
  /** http.request only: a failed response's message, read in `json`. */
  error_pointer?: string;
  /** http.request only: the message for a failed status, which wins over error_pointer. */
  status_messages?: Record<string, string>;
}

/** A page may carry up to 8 sources. */
export interface PageWithSources extends Page {
  sources?: Source[];
  content: Page["content"];
}

export type BindingFormat = "text" | "integer" | "decimal" | "percent" | "bytes" | "duration";

/** The Host shows the value at `pointer` of the source's latest result, without running the script. */
export interface Binding {
  source: ID;
  pointer: string;
  format?: BindingFormat;
  /** Shown for an absent, null or mistyped value; default "Unavailable". */
  unavailable?: string;
}

/** A text component that binds; `text` shows until the first result. */
export interface BoundTextBlock extends TextBlock {
  bind?: Binding;
}

export type SourceFailureCategory =
  | "capability_denied"
  | "system_permission_denied"
  | "automation_permission_needed"
  | "automation_permission_denied"
  | "external_app_missing"
  | "external_app_not_running"
  | "external_app_operation_unsupported"
  | "host_service_failed"
  | "timed_out";

/** Not a gesture: an answer to it may not request an operation. */
export type SourceDeliveredEvent = {
  type: "source_delivered";
  page: ID;
  source: ID;
  /** The sample's number within this definition, from 1. */
  sequence: number;
} & ({ result: JSONValue; failure?: never } | { failure: { category: SourceFailureCategory; message: string }; result?: never });

export interface SourceOptions {
  every?: number;
  deliver?: { pointer?: string } | true;
  errorPointer?: string;
  statusMessages?: Record<string, string>;
}

/** Proposed builders. Camel-case options become snake-case members; `deliver: true` is `{}`. */
export interface SourceBuilders {
  /** `spinnet.ui.source(id, perform, input, options)` */
  source<K extends SourceID>(id: ID, perform: K, input: InputOf<K>, options?: SourceOptions): Source<K>;
  /** `spinnet.ui.components.bind(source, pointer, options)` */
  bind(source: ID, pointer: string, options?: { format?: BindingFormat; unavailable?: string }): Binding;
}

/** `spinnet.http.request.source(id, input, options)`, the same as `ui.source(id, "http.request", ...)`. */
export interface SourceOf<K extends SourceID> {
  source(id: ID, input: InputOf<K>, options?: SourceOptions): Source<K>;
}
