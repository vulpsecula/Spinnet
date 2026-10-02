// PROPOSAL ONLY (#70). Draft types for requested Host operations.
// SPDX-License-Identifier: MIT
//
// Not part of Plugin API Level 1, any stable Level, or any published
// Candidate Contract revision. `spinnet.js` implements none of this, and the
// helper injects none of it. The types extend `../../spinnet.d.ts` the way a
// candidate revision's declarations would; #75 decides where such
// declarations really live. `reference.md` states the rules behind them.

import type { JSONValue, ScriptAnswer, ViewDescription, ViewEvent } from "../../spinnet";

/** Members every requested Host operation may carry. */
export interface OperationCommon {
  /**
   * A label of at most 64 characters, echoed in `operation_finished`.
   * The Host never interprets it.
   */
  id?: string;
  /** Close the view once the operation succeeds, and only then. */
  closes_view?: boolean;
  /** Deliver `operation_finished` when the outcome is ready. */
  notify?: boolean;
}

/**
 * Inserts `text` (at most 128 KiB of UTF-8) into the App frontmost at
 * execution, through Accessibility only. Needs `insert_into_focused_app`
 * and Accessibility. Refused, with nothing written, when the App in front is
 * not the one the Host showed when the user acted.
 */
export interface InsertTextOperation extends OperationCommon {
  kind: "insert_text";
  text: string;
}

/** The operations this proposal revision offers. */
export type HostOperation = InsertTextOperation;

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
      kind: HostOperation["kind"];
      outcome: "refused" | "failed";
      reason: OperationReason;
    }
  | {
      type: "operation_finished";
      operation?: string;
      kind: HostOperation["kind"];
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

/** Proposed additions to `spinnet.ui`. Builders only; they request nothing. */
export interface CandidateUI {
  /**
   * Builds an `insert_text` operation to attach to an answer.
   * `ui.insertTextOperation({ text: "😀", closesView: true })`
   */
  insertTextOperation(options: { text: string; id?: string; closesView?: boolean; notify?: boolean }): InsertTextOperation;
  /** `show` as in Level 1, with an optional operation committed together with the view. */
  show(view: CandidateViewDescription, options?: { state?: JSONValue; toast?: string; operation?: HostOperation }): CandidateScriptAnswer;
  /** An answer with no view that requests one operation, optionally with a toast. */
  request(operation: HostOperation, options?: { toast?: string }): CandidateScriptAnswer;
}

/** The answer type stays assignable from Level 1's, which never carries an operation. */
export type _Level1AnswersRemainValid = ScriptAnswer extends CandidateScriptAnswer ? true : never;
