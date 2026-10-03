// PROPOSAL ONLY (#70). Draft types for requested Host operations.
// SPDX-License-Identifier: MIT
//
// Not part of Plugin API Level 1, any stable Level, or any published
// Candidate Contract revision. `spinnet.js` implements none of this, and the
// helper injects none of it. The types extend `../../spinnet.d.ts` the way a
// candidate revision's declarations would; once published they would live
// with the revision under `../../candidates/host_operations/r1/`, never in
// the stable `spinnet.d.ts`. `reference.md` states the rules behind them.
// An operation names its Host Service by the catalogue ID of the namespaces
// proposal (#99), whose types define each operation's input.

import type { JSONValue, ScriptAnswer, ViewDescription, ViewEvent } from "../../spinnet";
import type { PerformID, RequestedOperation } from "../namespaces/namespaces";

/**
 * A requested Host operation: `{perform, input, id?, closes_view?, notify?}`,
 * built by `spinnet.<id>.operation(input, options)`. Every ID the catalogue
 * offers at the request entry point may be requested.
 */
export type HostOperation = RequestedOperation;

/**
 * `selection.replace`, the first operation requested this way: inserts its
 * text (at most 128 KiB of UTF-8) into the App frontmost at execution, typed
 * as keyboard events. Needs `insert_into_focused_app` and Accessibility.
 * Refused, with nothing written, when the App in front is not the one the
 * Host showed when the user acted, when focus has moved to another element of
 * that App, or when nothing showed a target (always the case without a view).
 */
export type SelectionReplaceOperation = RequestedOperation<"selection.replace">;

/** The one terminal result of a request. */
export type OperationOutcome = "succeeded" | "refused" | "declined" | "expired" | "cancelled" | "failed";

/**
 * Why a request was refused or failed. Provisional: the insertion reasons
 * wait on the Accessibility evidence of #69. None names the App.
 */
export type OperationReason =
  | "capability_denied"
  | "system_permission_denied"
  | "command_unavailable"
  | "target_changed"
  | "target_not_shown"
  | "no_target"
  | "no_text_input"
  | "secure_input"
  | "text_rejected"
  | "target_unresponsive";

/**
 * The event a script receives for an operation that asked to `notify`.
 * It is not a gesture: an answer to it may update the view and state but
 * may not request an operation.
 */
export type OperationFinishedEvent =
  | {
      type: "operation_finished";
      operation?: string;
      perform: PerformID;
      outcome: "refused" | "failed";
      reason: OperationReason;
    }
  | {
      type: "operation_finished";
      operation?: string;
      perform: PerformID;
      outcome: "succeeded" | "declined" | "expired" | "cancelled";
    };

/** A candidate script's `event` global. */
export type CandidateViewEvent = ViewEvent | OperationFinishedEvent;

/**
 * A candidate view: the view of its view schema plus `shows_insertion_target`,
 * which asks the Host to draw a line naming the App insertion would go to.
 * The name is Host data; the Plugin never receives it.
 */
export type CandidateViewDescription = ViewDescription & { shows_insertion_target?: boolean };

/**
 * A candidate script's answer. Only an answer to a gesture (the Action's
 * start, `submitted`, `action_chosen`) may carry `operation`, and never
 * together with `close`.
 */
export type CandidateScriptAnswer =
  | null
  | { view: CandidateViewDescription; state?: JSONValue; toast?: string; operation?: HostOperation }
  | { close: true; toast?: string }
  | { toast?: string; operation: HostOperation }
  | { toast: string };

/**
 * Proposed additions to `spinnet.ui`. Builders only; they request nothing.
 * The operation itself is built where its Host Service lives:
 * `spinnet.selection.replace.operation({ text: "😀" }, { closesView: true })`.
 */
export interface CandidateUI {
  /** `show` as in Level 1, with an optional operation committed together with the view. */
  show(view: CandidateViewDescription, options?: { state?: JSONValue; toast?: string; operation?: HostOperation }): CandidateScriptAnswer;
  /** An answer with no view that requests one operation, optionally with a toast. */
  request(operation: HostOperation, options?: { toast?: string }): CandidateScriptAnswer;
}

/** The answer type stays assignable from Level 1's, which never carries an operation. */
export type _Level1AnswersRemainValid = ScriptAnswer extends CandidateScriptAnswer ? true : never;
