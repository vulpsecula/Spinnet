// Types for Candidate Contract host_operations, revision 1.
// SPDX-License-Identifier: MIT
//
// Not part of any stable Plugin API Level. A Plugin that declares
// `{"name": "host_operations", "revision": 1}` beside the
// `{"name": "namespaces", "revision": 1}` it requires runs with the
// namespaced `spinnet` object of `../../namespaces/r1/namespaces.d.ts`,
// which `host_operations.js` extends as `OperationsSpinnet` below: every
// operation the catalogue offers as a request gets `.operation(input,
// options)`, `host.showPluginSettings` appears, and `spinnet.ui` takes and
// builds requests. `reference.md` states the rules; `host-operations.schema.json`
// the shapes.

import type { JSONValue, ScriptAnswer, ViewDescription, ViewEvent } from "../../../spinnet";
import type {
  AppsNamespace,
  ClipboardHistoryNamespace,
  ClipboardNamespace,
  InputOf,
  NamespacedSpinnet,
  OpenNamespace,
  SelectionNamespace,
} from "../../namespaces/r1/namespaces";

/** IDs an answer may request in this revision. */
export type RequestID =
  | "host.showPluginSettings" | "selection.replace" | "clipboard.write" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink";

/**
 * A Requested Host Operation: `{perform, input, id?, closes_view?, notify?}`,
 * performed by the Host after the answer that carries it commits. Only an
 * answer to a gesture (the Action's start, `submitted`, `action_chosen`) may
 * carry one.
 */
export interface RequestedOperation<K extends RequestID = RequestID> {
  perform: K;
  /** Left out only when the operation takes none. */
  input?: InputOf<K>;
  /** A label of at most 64 characters, echoed in `operation_finished`. */
  id?: string;
  /** Close the view once the operation succeeds, and only then. Not with `host.showPluginSettings`. */
  closes_view?: boolean;
  /** Deliver `operation_finished` when the outcome is ready. */
  notify?: boolean;
}

/** Options of `.operation(input, options)`. */
export interface OperationOptions {
  id?: string;
  closesView?: boolean;
  notify?: boolean;
}

type Args<K extends RequestID> = null extends InputOf<K>
  ? [input?: InputOf<K>, options?: OperationOptions]
  : [input: InputOf<K>, options?: OperationOptions];

/** Builds the request form of an operation. */
export interface Requestable<K extends RequestID> {
  operation(...args: Args<K>): RequestedOperation<K>;
}

/** The one terminal result of a request. */
export type OperationOutcome = "succeeded" | "refused" | "declined" | "expired" | "cancelled" | "failed";

/** Why a request was refused or failed. None names the App. */
export type OperationReason =
  | "capability_denied"
  | "system_permission_denied"
  | "automation_permission_denied"
  | "external_app_missing"
  | "external_app_operation_unsupported"
  | "host_service_failed"
  | "command_unavailable"
  | "target_changed"
  | "target_not_shown"
  | "no_target"
  | "secure_input"
  | "target_unresponsive";

/**
 * The event a script receives for an operation that asked to `notify`. It is
 * not a gesture: an answer to it may update the view and state but may not
 * request an operation.
 */
export type OperationFinishedEvent =
  | {
      type: "operation_finished";
      operation?: string;
      perform: RequestID;
      outcome: "refused" | "failed";
      reason: OperationReason;
    }
  | {
      type: "operation_finished";
      operation?: string;
      perform: RequestID;
      outcome: "succeeded" | "declined" | "expired" | "cancelled";
    };

/** A candidate script's `event` global. */
export type CandidateViewEvent = ViewEvent | OperationFinishedEvent;

/**
 * A Level 1 view plus `shows_insertion_target`, which asks the Host to draw a
 * line naming the App insertion would go to. The name is Host data; the
 * Plugin never receives it.
 */
export type CandidateViewDescription = ViewDescription & { shows_insertion_target?: boolean };

/** A candidate script's answer: Level 1's, plus `operation`, never with `close`. */
export type CandidateScriptAnswer =
  | null
  | { view: CandidateViewDescription; state?: JSONValue; toast?: string; operation?: RequestedOperation }
  | { close: true; toast?: string }
  | { toast?: string; operation: RequestedOperation }
  | { toast: string };

/** The answer type stays assignable from Level 1's, which never carries an operation. */
export type _Level1AnswersRemainValid = ScriptAnswer extends CandidateScriptAnswer ? true : never;

/** `spinnet.ui` under the candidate: Level 1's builders, with these changed or added. */
export interface OperationsUI extends Omit<NamespacedSpinnet["ui"], "view" | "show"> {
  /** Level 1's `view`, which also takes `showsInsertionTarget`. */
  view(value: Parameters<NamespacedSpinnet["ui"]["view"]>[0] & { showsInsertionTarget?: boolean }): CandidateViewDescription;
  /** `show` as in Level 1, with an optional operation committed together with the view. */
  show(view: CandidateViewDescription,
       options?: { state?: JSONValue; toast?: string; operation?: RequestedOperation }): CandidateScriptAnswer;
  /** An answer with no view that requests one operation, optionally with a toast. */
  request(operation: RequestedOperation, options?: { toast?: string }): CandidateScriptAnswer;
}

/** Spinnet's own UI, which the Plugin asks the Host to act on. */
export interface HostNamespace {
  /** Opens the Plugin's own Plugin Settings sheet after the answer commits. @id host.showPluginSettings @entry request */
  readonly showPluginSettings: Requestable<"host.showPluginSettings">;
}

/** The `spinnet` object under host_operations r1 and namespaces r1. */
export interface OperationsSpinnet extends Omit<NamespacedSpinnet,
  "selection" | "clipboard" | "clipboardHistory" | "open" | "apps" | "ui"> {
  readonly host: HostNamespace;
  readonly selection: Omit<SelectionNamespace, "replace"> & {
    /**
     * Callable as in namespaces r1; inside a View Session it is compared with
     * the target the Host showed at the gesture and fails with
     * `insertion_target_changed` when it changed.
     * @id selection.replace @entry request
     */
    readonly replace: SelectionNamespace["replace"] & Requestable<"selection.replace">;
  };
  readonly clipboard: Omit<ClipboardNamespace, "write"> & {
    /** @id clipboard.write @entry request */
    readonly write: ClipboardNamespace["write"] & Requestable<"clipboard.write">;
  };
  readonly clipboardHistory: Omit<ClipboardHistoryNamespace, "show"> & {
    /** @id clipboardHistory.show @entry request */
    readonly show: ClipboardHistoryNamespace["show"] & Requestable<"clipboardHistory.show">;
  };
  readonly open: {
    /** @id open.url @entry request */
    readonly url: OpenNamespace["url"] & Requestable<"open.url">;
    /** @id open.path @entry request */
    readonly path: OpenNamespace["path"] & Requestable<"open.path">;
    /** @id open.application @entry request */
    readonly application: OpenNamespace["application"] & Requestable<"open.application">;
  };
  readonly apps: {
    /** @id apps.perform @entry request */
    readonly perform: AppsNamespace["perform"] & Requestable<"apps.perform">;
    /** @id apps.openDeepLink @entry request */
    readonly openDeepLink: AppsNamespace["openDeepLink"] & Requestable<"apps.openDeepLink">;
  };
  readonly ui: OperationsUI;
}

/** The candidate script's globals that differ from namespaces r1's. */
export interface OperationsGlobals {
  spinnet: OperationsSpinnet;
  event: CandidateViewEvent | null;
}
