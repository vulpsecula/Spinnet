// Type definitions for Spinnet Plugin scripts, Plugin API Level 1.
// SPDX-License-Identifier: MIT
//
// A skeleton: it types the globals the helper injects into a script today.
// The `spinnet` SDK object, `event` and `state`, and Plugin View answers are
// added here as each is implemented, and Level 1 may still change until it is
// published.

/** Any value that survives a round trip through JSON. */
export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

/** The Host Services a script can request, each subject to its Capability. */
export type HostServiceName =
  | "read_selected_text"
  | "read_current_clipboard"
  | "read_focused_window"
  | "read_clipboard_history"
  | "read_clipboard_history_content"
  | "write_clipboard"
  | "insert_text"
  | "open_url"
  | "open_local_path"
  | "set_focused_window_frame"
  | "toggle_focused_window_full_screen"
  | "restore_focused_window_frame"
  | "capture_screen"
  | "https_request"
  /** Presents the Host Surface for Clipboard History; needs `read_clipboard_history`. */
  | "present_clipboard_history"
  // Removed before Level 1 is published; their behaviour moves into Plugins.
  | "present_results"
  | "invoke_external_app"
  | "smart_jump";

declare global {
  /**
   * The Action's input: the Plugin Settings, then the Menu Item's overrides,
   * then the Command's own configured value.
   */
  const input: JSONValue;
  /** `input`, encoded as JSON. */
  const inputJSON: string;
  const pluginID: string;
  const actionID: string;
  const commandID: string;
  /** Identifies this one run of the Action. */
  const invocationID: string;

  /**
   * Asks the Host to perform a Host Service and returns its answer. The
   * Host checks the Capability and System Permission the service needs
   * before it performs it.
   */
  function requestHostService(name: HostServiceName, input?: JSONValue): JSONValue;
}

// A script's answer is the value of its last expression, which must be JSON.
