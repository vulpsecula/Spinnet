// Type definitions for Spinnet Plugin scripts, Plugin API Level 1.
// SPDX-License-Identifier: MIT
//
// It types the globals the helper injects into a script today, including the
// `spinnet` SDK object built by `spinnet.js`, `event` and `state`, and the
// answer a script gives. The view components are added as they are
// implemented (W11 #58), and Level 1 may still change until it is published.
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
  /**
   * Plugin Storage, which needs no Capability: the value kept under a key
   * string, or `null` when there is none.
   */
  | "get_storage_value"
  /** Keeps `{key, value}`, answered with `null`; a `null` value removes the key. */
  | "set_storage_value"
  /** Forgets a key string, answered with `null`. */
  | "remove_storage_value"
  /** The Plugin's keys, sorted, without their values. */
  | "list_storage_keys"
  /** Forgets every key, answered with `null`. */
  | "clear_storage"
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
 * whole invocation, even if the script catches the error. Only a Plugin
 * Storage write over a limit throws an error the script may catch.
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
export interface AppsArea {
  /**
   * Sends one operation of an External App's Reviewed App Interface, such as
   * `{bundle_id: "com.hezongyidev.Bob", operation: "translateText",
   * arguments: {text}}`. Needs `control_external_app` with the operation's
   * family in scope; a missing application or an operation the interface
   * does not review fails the invocation.
   * @service perform_app_operation
   */
  perform(request: {
    bundle_id: string;
    operation: string;
    arguments?: Record<string, JSONValue>;
  }): null;
  /**
   * Opens one of the Plugin's Deep Link Templates by name, filling its
   * parameters, without activating the App. Needs `control_external_app`
   * with that template in the consented scope.
   * @service open_deep_link
   */
  openDeepLink(request: { template: string; parameters?: Record<string, JSONValue> }): null;
}

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

/**
 * Plugin Storage: the Plugin's own key-value store of JSON values, kept
 * between invocations and launches, which no other Plugin can reach. It needs
 * no Capability. The user sees how much it holds in the Library and may clear
 * it there; removing the Plugin deletes it, and an update keeps it. It is not
 * for secrets.
 *
 * A key is a non-empty string of at most 128 characters. A value, as JSON,
 * is at most 512 KiB, and a Plugin keeps at most 10 MiB, with the list of its
 * keys at most 512 KiB. A write over a limit stores nothing and throws a
 * `StorageLimitError` the script may catch and carry on from; any other
 * failure ends the invocation, as a failed Host Service does.
 */
export interface StorageArea {
  /**
   * The value kept under `key`, or null when there is none.
   * @service get_storage_value
   */
  get(key: string): JSONValue;
  /**
   * Keeps `value` under `key`, replacing what was there. A null value
   * removes the key. Only this key's file is rewritten.
   * @throws {StorageLimitError} when the value or the store would pass a limit.
   * @service set_storage_value
   */
  set(entry: { key: string; value: JSONValue }): null;
  /**
   * Forgets `key`; a key the Plugin does not keep is no error.
   * @service remove_storage_value
   */
  remove(key: string): null;
  /**
   * Every key the Plugin keeps, sorted, without their values.
   * @service list_storage_keys
   */
  keys(): string[];
  /**
   * Forgets every key, as Clear Stored Data in the Library does.
   * @service clear_storage
   */
  clear(): null;
}

/** What `spinnet.storage.set` throws when a write would pass a limit. */
export interface StorageLimitError extends Error {
  readonly code: "storage_limit_exceeded";
}

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

// View Sessions (ADR 0010). While a script's Plugin View is open, the Host
// keeps its state and runs the script again for each View Event, with the
// event and that state as globals. Nothing lives in the helper between events.

/**
 * One user interaction in the script's Plugin View. A field change arrives
 * after a 100 ms pause in typing, and only the latest waiting one arrives.
 */
export type ViewEvent =
  | { type: "field_changed"; field: string; values: { [field: string]: JSONValue } }
  | { type: "submitted"; values: { [field: string]: JSONValue } }
  | { type: "action_chosen"; action: string }
  /** The Host has already stored the new value as Plugin Settings. */
  | { type: "setting_changed"; key: string; value: JSONValue }
  | { type: "section_delivered"; section: string; response: JSONValue };

/**
 * What a script evaluates to. `view` shows or updates its Plugin View and
 * `state` (at most 64 KiB of JSON) comes back with the next event; the view
 * description is at most 256 KiB. `{close: true}` closes the view, and `null`
 * shows nothing, or changes nothing while a view is open. Any answer may add
 * a `toast`; without a view the Host shows it near the pointer. Anything
 * else ends the View Session as a protocol violation.
 */
export type ScriptAnswer =
  | null
  | { view: { [key: string]: JSONValue }; state?: JSONValue; toast?: string }
  | { close: true; toast?: string }
  | { toast: string };

declare global {
  /**
   * The Action's input: the Plugin Settings, then the Menu Item's overrides,
   * then the Command's own configured value.
   */
  const input: JSONValue;
  /** The View Event this run answers, or null when the Action starts. */
  const event: ViewEvent | null;
  /** The state the script returned with its last view, or null. */
  const state: JSONValue;
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

// A script's answer is the value of its last expression, a `ScriptAnswer`.
