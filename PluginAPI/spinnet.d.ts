// Type definitions for Spinnet Plugin scripts, Plugin API Level 1.
// SPDX-License-Identifier: MIT
//
// It types the globals the helper injects into a script today, including the
// `spinnet` SDK object built by `spinnet.js`. `event` and `state` and Plugin
// View answers are added here as each is implemented, and Level 1 may still
// change until it is published.
//
// Each SDK wrapper names the one Host Service it requests with an `@service`
// tag; a test checks the tags against `spinnet.js` and the Host.

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
  /** Needs no Capability: the Plugin supplies the text. */
  | "detect_language"
  /**
   * Sends one operation of an External App's Reviewed App Interface:
   * `{bundle_id, operation, arguments?}`, answered with `null`. Needs
   * `control_external_app` with the operation's family in scope.
   */
  | "perform_app_operation"
  /**
   * Opens one of the Plugin's Deep Link Templates: `{template, parameters?}`,
   * answered with `null`. Needs `control_external_app`.
   */
  | "open_deep_link"
  /** Presents the Host Surface for Clipboard History; needs `read_clipboard_history`. */
  | "present_clipboard_history"
  // Removed before Level 1 is published; their behaviour moves into Plugins.
  | "present_results"
  | "smart_jump";

/** A rectangle in global points, origin at the top-left of the primary display. */
export interface WindowRect {
  x: number;
  y: number;
  width: number;
  height: number;
}

/** The focused window and the screens around it. */
export interface FocusedWindow {
  frame: WindowRect;
  /** The visible frame of the screen holding most of the window. */
  visibleFrame: WindowRect;
  /** Every display's visible frame, left to right, then top to bottom. */
  displays: WindowRect[];
  /** The position in `displays` of the display holding the window. */
  displayIndex: number;
}

/** The current clipboard, when it holds content the grant's scope allows. */
export interface ClipboardContent {
  text: string;
  type: "text" | "url";
}

/**
 * One page of Clipboard History. Follow `nextOffset` rather than assuming a
 * page size; the entries' fields are described in the Host's documentation.
 */
export interface ClipboardHistoryPage {
  state: "off" | "paused" | "collecting";
  entries: { [key: string]: JSONValue }[];
  nextOffset?: number;
  expiresAt?: number;
}

/** A chunk of one entry's retained bytes, `data` in base64. */
export interface ClipboardHistoryContent {
  data: string;
  offset: number;
  totalBytes: number;
  nextOffset?: number;
}

/**
 * A Credential Use: how the Host places a stored credential into the request,
 * or signs the request with it, as it is sent. It names exactly one placement.
 */
export interface CredentialUse {
  reference: string;
  header?: string;
  query?: string;
  path_segment?: number;
  json_body?: string;
  form_body?: string;
  template?: string;
  signature?: {
    algorithm: "md5" | "sha1" | "sha256" | "hmac_sha1" | "hmac_sha256";
    message: string;
    key?: string;
    chain?: string[];
    encoding: "hex" | "hex_upper" | "base64";
  };
}

/** One HTTPS request to a host the user consented to. */
export interface HTTPSRequest {
  method: "GET" | "POST";
  url: string;
  headers?: { [name: string]: string };
  body?: string;
  credential_uses?: CredentialUse[];
}

export interface HTTPSResponse {
  status: number;
  /** Only `content-type`, `content-language` and `retry-after`. */
  headers: { [name: string]: string };
  body: string;
}

/** A native screen capture the Host starts and the user finishes on screen. */
export interface ScreenCaptureRequest {
  source: "area" | "fullscreen" | "window";
  copy_to_clipboard: boolean;
  /** A folder configured on the Action, or null to only copy. */
  save: null | { folder: string; format: "automatic" | "png" | "jpg" };
}

/**
 * The `spinnet` object, one area per kind of Host functionality. Each
 * wrapper requests one Host Service with its argument as the input and
 * returns the answer; a refused Capability or System Permission ends the
 * whole invocation, even if the script catches the error.
 */
export interface Spinnet {
  readonly selection: SelectionArea;
  readonly clipboard: ClipboardArea;
  readonly window: WindowArea;
  readonly open: OpenArea;
  readonly http: HTTPArea;
  readonly apps: AppsArea;
  readonly text: TextArea;
  readonly screen: ScreenArea;
  readonly storage: StorageArea;
  readonly ui: UIArea;
  readonly environment: Environment;
}

export interface SelectionArea {
  /**
   * The focused App's selected text. With `{best_effort: true}` a selection
   * that cannot be read answers null instead of failing the invocation.
   * @service read_selected_text
   */
  readText(options?: { best_effort: true }): string | null;
  /**
   * Replaces the focused App's selection with `text`.
   * @service insert_text
   */
  replace(text: string): null;
}

export interface ClipboardArea {
  /**
   * The current clipboard, or null when it holds nothing the grant allows.
   * @service read_current_clipboard
   */
  read(): ClipboardContent | null;
  /** @service write_clipboard */
  write(text: string): null;
  /**
   * The newest page of Clipboard History, or the page at `offset`.
   * @service read_clipboard_history
   */
  history(page?: { offset: number }): ClipboardHistoryPage;
  /** @service read_clipboard_history_content */
  historyContent(chunk: { entry_id: string; offset: number; length: number }): ClipboardHistoryContent;
  /**
   * Opens the Clipboard History window, a Host Surface. The Plugin learns
   * nothing from it.
   * @service present_clipboard_history
   */
  showHistory(): null;
}

export interface WindowArea {
  /** @service read_focused_window */
  read(): FocusedWindow;
  /**
   * Moves and resizes the window `read` last returned, while it is focused.
   * @service set_focused_window_frame
   */
  setFrame(frame: WindowRect): null;
  /** @service toggle_focused_window_full_screen */
  toggleFullScreen(): null;
  /**
   * Returns the focused window to its frame before Spinnet last moved it.
   * @service restore_focused_window_frame
   */
  restore(): null;
}

export interface OpenArea {
  /**
   * Opens an http or https link in the default browser.
   * @service open_url
   */
  url(link: string): null;
  /**
   * Opens an absolute or `~/` path in Finder or its default App.
   * @service open_local_path
   */
  path(path: string): null;
}

export interface HTTPArea {
  /** @service https_request */
  request(request: HTTPSRequest): HTTPSResponse;
}

/** Reviewed App Interface operations and Deep Link Templates (W8 #55). */
export interface AppsArea {}

export interface TextArea {
  /**
   * The BCP 47 code of `text`, such as `en` or `zh-Hans`, decided on this
   * Mac, or null when it is too short or too mixed to tell. Needs no
   * Capability.
   * @service detect_language
   */
  detectLanguage(text: string): string | null;
}

export interface ScreenArea {
  /** @service capture_screen */
  capture(request: ScreenCaptureRequest): null;
}

/** Plugin Storage (W20 #67). */
export interface StorageArea {}

/** Pure builders for Plugin Views and standard actions (W11 #58). */
export interface UIArea {}

/** The Host the script runs under, and this invocation. */
export interface Environment {
  /** The highest Plugin API Level the Host supports. */
  readonly apiLevel: number;
  readonly hostVersion: string;
  /** The BCP 47 code of the user's first preferred language, such as `en-US`. */
  readonly preferredLanguage: string;
  readonly pluginID: string;
  readonly commandID: string;
  readonly actionID: string;
  /** Identifies this one run of the Action. */
  readonly invocationID: string;
}

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

  /** The SDK: camelCase wrappers over the Host Services, by area. */
  const spinnet: Spinnet;

  /**
   * Asks the Host to perform a Host Service and returns its answer. The
   * Host checks the Capability and System Permission the service needs
   * before it performs it. The `spinnet` wrappers call this.
   */
  function requestHostService(name: HostServiceName, input?: JSONValue): JSONValue;
}

// A script's answer is the value of its last expression, which must be JSON.
