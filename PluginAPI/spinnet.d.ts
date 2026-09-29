// Type definitions for Spinnet Plugin scripts, Plugin API Level 1.
// SPDX-License-Identifier: MIT
//
// It types the globals the helper injects into a script, including the
// `spinnet` SDK object built by `spinnet.js`, `event` and `state`, the answer
// a script gives, and the Plugin View it may describe. `reference/` states
// the rules behind each type.
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
  | "clear_storage";

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
  /**
   * The visible frame of the screen holding most of the window: the screen
   * less the menu bar, the Dock, and Stage Manager's strip of recent apps
   * while it is shown.
   */
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
 * page size; `reference/host-services.md` describes the entries' fields.
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
   * Opens the Clipboard History window, the one Host Surface. Any Plugin
   * granted `read_clipboard_history` may open it, Bundled or installed, and
   * learns nothing from it.
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

/** Reviewed App Interface operations and Deep Link Templates. */
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
 * is at most 512 KiB, and a Plugin keeps at most 10 MiB in at most 1000
 * keys. A write over a limit stores nothing and throws a
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

/**
 * Pure builders for Plugin Views: each returns a new plain object in the
 * shape of `schemas/plugin-view.schema.json`, leaving out members that are
 * undefined, and asks the Host for nothing. Options are camelCase; the
 * objects they build use the view's own snake_case members. The Host checks
 * a view when the script answers with it, and one it would not draw ends the
 * View Session as a protocol violation.
 */
export interface UIArea {
  /** A whole view: a title and at least one of `form`, `detail` or `actions`. */
  view(options: {
    title: string;
    subtitle?: string;
    settings?: SettingControl[];
    form?: ViewForm;
    detail?: ViewDetail;
    actions?: ViewAction[];
  }): ViewDescription;
  /**
   * A control for one of the Plugin's own `choice` or `toggle` settings.
   * `swapWith` names the `choice` control that follows this one and offers
   * the same choices, to draw a swap button between the two.
   */
  setting(key: string, options?: { swapWith?: string }): SettingControl;
  /**
   * `submitOnReturn` makes Return submit from any field, a multiline one
   * included, where Shift-Return starts a new line; the form then draws no
   * submit button and takes no `submitTitle`.
   */
  form(options: { fields: FormField[]; submitTitle?: string; submitOnReturn?: boolean }): ViewForm;
  textField(options: {
    key: string; title: string; placeholder?: string; value?: string; accent?: Accent; status?: string;
  }): TextFormField;
  multilineTextField(options: { key: string; title: string; placeholder?: string; value?: string }): TextFormField;
  urlField(options: {
    key: string; title: string; placeholder?: string; value?: string; accent?: Accent; status?: string;
  }): TextFormField;
  toggleField(options: { key: string; title: string; value?: boolean }): ToggleFormField;
  choiceField(options: {
    key: string;
    title: string;
    choices: string[];
    choiceTitles?: string[];
    value?: string;
  }): ChoiceFormField;
  detail(options: { sections: DetailSection[] }): ViewDetail;
  /** A section of text in the Markdown subset, or a Host-Fetched Section with `fetch`. */
  section(options: { id: string; title?: string; text?: string; fetch?: SectionFetch }): DetailSection;
  /** An action that delivers `action_chosen` with its ID. */
  action(options: { id: string; title: string; shortcut?: Shortcut }): EventAction;
  /** Copies `text`; needs `write_clipboard`. Titled "Copy" unless given a title. */
  copyText(options: { text: string; title?: string; shortcut?: Shortcut; closesView?: boolean }): StandardAction;
  /** Opens an http or https link; needs `open_url`. Titled "Open in Browser" unless given a title. */
  openURL(options: { url: string; title?: string; shortcut?: Shortcut; closesView?: boolean }): StandardAction;
  /**
   * Inserts `text` into the App the view came from, in place of its
   * selection; needs `insert_into_focused_app` and Accessibility. Titled
   * "Insert" unless given a title.
   */
  insertText(options: { text: string; title?: string; shortcut?: Shortcut; closesView?: boolean }): StandardAction;
  /** Opens the Plugin's own Plugin Settings; needs no Capability. */
  openPluginSettings(options?: { title?: string; shortcut?: Shortcut }): StandardAction;
  /** The answer that shows or updates the view, with the state to keep. */
  show(view: ViewDescription, options?: { state?: JSONValue; toast?: string }): ScriptAnswer;
  /** An answer that only shows a toast: in the view, or near the pointer without one. */
  toast(text: string): ScriptAnswer;
  /** The answer that closes the view. */
  close(options?: { toast?: string }): ScriptAnswer;
}

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
  /** A swap button exchanged two settings; the Host has already stored both. */
  | { type: "settings_swapped"; keys: [string, string] }
  /** A deliver section's response; the script answers with the section's text. */
  | { type: "section_delivered"; section: string; response: HTTPSResponse };

/**
 * A Detail section's `fetch`: a request the Host sends with the Plugin's
 * Credential Uses applied, within its own 15-second budget, alongside the
 * view's other fetched sections (at most 8). `show` shows the answer at
 * `pointer` without the script seeing it; `deliver` sends the response to the
 * script as a `section_delivered` event and shows the section's `text` from
 * the view it answers with. The section keeps what it fetched while its `id`
 * and `fetch` are unchanged. `cache` lets the Host answer the same request
 * again from its last 2xx answer, for up to 10 minutes.
 */
export type SectionFetch =
  | {
      request: HTTPSRequest;
      mode: "show";
      /** RFC 6901 pointer to the answer, a string, in a 2xx JSON response. */
      pointer: string;
      /** RFC 6901 pointer to a message in a failed JSON response. */
      error_pointer?: string;
      /** A message for a failed status, which wins over `error_pointer`. */
      status_messages?: { [status: string]: string };
      cache?: boolean;
    }
  | { request: HTTPSRequest; mode: "deliver"; cache?: boolean };

// Plugin Views (ADR 0010). A view is data the Host draws: a title, the
// Plugin's own setting controls, a Form, a Detail and Actions, in that order.
// It never contains the Plugin's own markup. `spinnet.ui` builds each part.

/** A Plugin View description, at most 256 KiB of JSON. */
export interface ViewDescription {
  title: string;
  subtitle?: string;
  /** At most 6, each naming one of the Plugin's `choice` or `toggle` settings. */
  settings?: SettingControl[];
  form?: ViewForm;
  detail?: ViewDetail;
  /** At most 12. */
  actions?: ViewAction[];
}

/**
 * A control for one of the Plugin's own settings. The Host shows what is
 * stored, stores a change as Plugin Settings are, then delivers
 * `setting_changed`; the Action does not run again.
 */
export interface SettingControl {
  key: string;
  /**
   * On a `choice` control, the key of the `choice` control right after it,
   * which offers the same choices.
   * The Host draws a swap button between the two, as between two languages,
   * which stores both values exchanged and then delivers one
   * `settings_swapped` whose `keys` name this one first.
   */
  swap_with?: string;
}

/**
 * Fields whose values arrive with `field_changed` and `submitted`. Return in
 * a one-line field, the submit button, or Command-Return submits.
 */
export interface ViewForm {
  /** 1 to 20, with distinct keys. */
  fields: FormField[];
  /** Defaults to "Submit". Not with `submit_on_return`. */
  submit_title?: string;
  /**
   * Return submits from any field, a multiline one included, where
   * Shift-Return starts a new line; no submit button is drawn.
   */
  submit_on_return?: boolean;
}

export type FormField = TextFormField | ToggleFormField | ChoiceFormField;

/**
 * While the answer to the user's own typing arrives, a field keeps what they
 * typed; any other answer with a view sets each field to its `value`, which
 * is how a script clears or fills one.
 */
export interface TextFormField {
  /** At most 64 characters, unique in the form. */
  key: string;
  kind: "text" | "multiline_text" | "url";
  title: string;
  placeholder?: string;
  /** Defaults to "". */
  value?: string;
  /** Tints the box and status line of a `text` or `url` field, never a `multiline_text` one. */
  accent?: Accent;
  /**
   * One line of plain text, not blank, drawn in a `text` or `url` field's
   * box under what is typed, in the accent's colour and shortened in the
   * middle when it does not fit: what the Plugin makes of the text.
   */
  status?: string;
}

export interface ToggleFormField {
  key: string;
  kind: "toggle";
  title: string;
  /** Defaults to false. */
  value?: boolean;
}

export interface ChoiceFormField {
  key: string;
  kind: "choice";
  title: string;
  /** 1 to 100 distinct values. */
  choices: string[];
  /** What to show for each choice, in the same order. */
  choice_titles?: string[];
  /** One of `choices`; defaults to the first. */
  value?: string;
}

export interface ViewDetail {
  /** 1 to 20, with distinct IDs. */
  sections: DetailSection[];
}

/**
 * A section of Detail text. Without `fetch` it shows `text` in the Markdown
 * subset: bold, italic, inline code, fenced code blocks, and http(s) links,
 * which open under the `open_url` rules; anything else shows as plain text.
 * With `fetch` it is a Host-Fetched Section, whose request the Host sends.
 * Each section with text has a Copy button, the user's own copy.
 */
export interface DetailSection {
  /** At most 64 characters, unique in the view. */
  id: string;
  title?: string;
  text?: string;
  fetch?: SectionFetch;
}

/**
 * A system colour the Host tints a text or url field's box with, its
 * background, border and status line, in the shade for the current appearance: a live
 * status for what is typed. A Plugin names a colour, never a value, and its
 * view still says in words what the colour stands for.
 */
export type Accent =
  | "blue" | "indigo" | "purple" | "pink" | "red" | "orange" | "green" | "teal" | "gray";

/**
 * A keyboard shortcut such as `cmd+shift+k`: modifiers from `cmd`, `ctrl`,
 * `option` and `shift`, at least `cmd` or `ctrl`, each once, then a
 * lowercase letter, a digit, or `return`. The view keeps Command-W, -Q, -C,
 * -V, -X, -A, -Z, Shift-Command-Z and Command-Return for itself.
 */
export type Shortcut = string;

export type ViewAction = EventAction | StandardAction;

/** Delivers `action_chosen` with `id`. Without a form, Return chooses the first action. */
export interface EventAction {
  /** At most 64 characters, unique among the view's actions. */
  id: string;
  title: string;
  shortcut?: Shortcut;
}

/**
 * An action the Host performs itself, without a View Event, under the
 * Capability its Host Service needs. A refusal shows in the view with the
 * way to repair it. With `closes_view`, the view closes once it succeeds.
 */
export type StandardAction = {
  title: string;
  shortcut?: Shortcut;
  closes_view?: boolean;
} & (
  | { perform: "copy_text"; text: string }
  | { perform: "open_url"; url: string }
  /** At most 128 KiB of text. */
  | { perform: "insert_text"; text: string }
  | { perform: "open_plugin_settings" }
);

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
  | { view: ViewDescription; state?: JSONValue; toast?: string }
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
