// SPDX-License-Identifier: MIT
// Shared values, form/detail Plugin Views and pure UI builders.
/** Any value that survives a round trip through JSON. */
export type JSONValue =
  | null
  | boolean
  | number
  | string
  | JSONValue[]
  | { [key: string]: JSONValue };

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
  /**
   * The reference the Plugin's `credential` field holds, read from `input`,
   * such as `input.deepl_credential`; not the field's key.
   */
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

/** What `spinnet.storage.set` throws when a write would pass a limit. */
export interface StorageLimitError extends Error {
  readonly code: "storage_limit_exceeded";
}

/** A denied optional Capability declared for the current Command; later calls still check their grants. */
export interface OptionalCapabilityError extends Error {
  readonly code: "capability_denied";
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

/** The Host release and language. Invocation identity is exposed as globals. */
export interface Environment {
  readonly hostVersion: string;
  /** The BCP 47 code of the user's first preferred language, such as `en-US`. */
  readonly preferredLanguage: string;
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
  | { perform: "clipboard.write"; text: string }
  | { perform: "open.url"; url: string }
  /** At most 128 KiB of text. */
  | { perform: "selection.replace"; text: string }
  | { perform: "host.showPluginSettings" }
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
