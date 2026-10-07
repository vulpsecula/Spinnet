// Type definitions for Spinnet Plugin scripts, Plugin API Level 2.
// SPDX-License-Identifier: MIT
//
// A Plugin whose manifest declares `"api_level": 2` runs with the `spinnet`
// object `spinnet-level-2.js` builds, typed as `Spinnet` below, in place of
// Level 1's: every Host Service is named by its one catalogue ID
// (`catalogue.json`), every operation a script can call is a function at
// `spinnet.<id>`, an operation an answer may request has `.operation(input,
// options)`, one a page action may perform `.action(input, options)`, and
// `spinnet.ui` builds pages beside Level 1's views. `requestHostService`
// takes catalogue IDs only. The rules are in `reference/namespaces.md`,
// `reference/host-operations.md` and `reference/pages.md`; the shapes in
// `schemas/namespaces.schema.json`, `schemas/host-operations.schema.json` and
// `schemas/pages.schema.json`.
//
// Level 1's `spinnet.d.ts` declares the script's globals with Level 1's
// types. A Level 2 script's globals have the types of `Globals` below; to
// type-check one, declare them in the module that imports this file, which
// shadows Level 1's:
//
//   import type { Globals } from "./spinnet-level-2";
//   declare const spinnet: Globals["spinnet"];
//   declare const event: Globals["event"];
//   declare const requestHostService: Globals["requestHostService"];
//
// Each function names the operation it reaches with an `@id` tag and the
// entry points it offers with `@entry`; a test checks the tags against the
// catalogue and the Host.

import type {
  Accent,
  ClipboardContent,
  ClipboardHistoryContent,
  ClipboardHistoryPage,
  Environment,
  FocusedWindow,
  HTTPSRequest,
  HTTPSResponse,
  JSONValue,
  ScriptAnswer,
  UIArea,
  ViewDescription,
  ViewEvent,
  WindowRect,
} from "./spinnet";

// MARK: Operations

/** Input and result of every operation Level 2 offers, by catalogue ID. */
export interface Operations {
  "host.toast": { input: string | { text: string }; result: null };
  "host.closeView": { input: null; result: null };
  "host.showPluginSettings": { input: null; result: null };
  "selection.readText": { input: null | { best_effort: true }; result: string | null };
  "selection.replace": { input: string | { text: string }; result: null };
  "selection.copy": { input: null; result: null };
  "selection.cut": { input: null; result: null };
  "selection.paste": { input: null; result: null };
  "keyboard.press": { input: KeyboardShortcut; result: null };
  "clipboard.read": { input: null; result: ClipboardContent | null };
  "clipboard.write": { input: string | { text: string }; result: null };
  "clipboardHistory.read": { input: null | { offset: number }; result: ClipboardHistoryPage };
  "clipboardHistory.readContent": { input: { entry_id: string; offset: number; length: number }; result: ClipboardHistoryContent };
  "clipboardHistory.show": { input: null; result: null };
  "open.url": { input: string | { url: string }; result: null };
  "open.path": { input: string | { path: string }; result: null };
  "open.application": { input: string | { application: string }; result: null };
  "apps.perform": { input: { bundle_id: string; operation: string; arguments?: Record<string, JSONValue> }; result: null };
  "apps.openDeepLink": { input: { template: string; parameters?: Record<string, string> }; result: null };
  "system.runShortcut": { input: string | { name: string; input?: string }; result: null };
  "system.runService": { input: string | { name: string; input?: string }; result: null };
  "window.read": { input: null; result: FocusedWindow };
  "window.setFrame": { input: WindowRect; result: null };
  "window.toggleFullScreen": { input: null; result: null };
  "window.restore": { input: null; result: null };
  "screen.capture": { input: ScreenCapture; result: null };
  "http.request": { input: HTTPSRequest; result: HTTPSResponse };
  "text.detectLanguage": { input: string | { text: string }; result: string | null };
  "storage.get": { input: string | { key: string }; result: JSONValue };
  "storage.set": { input: { key: string; value: JSONValue }; result: null };
  "storage.remove": { input: string | { key: string }; result: null };
  "storage.keys": { input: null; result: string[] };
  "storage.clear": { input: null; result: null };
}

export type OperationID = keyof Operations;
export type InputOf<K extends OperationID> = Operations[K]["input"];
export type ResultOf<K extends OperationID> = Operations[K]["result"];

/** IDs a script may call. */
export type CallID =
  | "selection.readText" | "selection.replace" | "clipboard.read" | "clipboard.write"
  | "clipboardHistory.read" | "clipboardHistory.readContent" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink"
  | "window.read" | "window.setFrame" | "window.toggleFullScreen" | "window.restore"
  | "screen.capture" | "http.request" | "text.detectLanguage"
  | "storage.get" | "storage.set" | "storage.remove" | "storage.keys" | "storage.clear";

/** IDs a manifest Command with `execution: "host"` may name in `host_command`. */
export type HostCommandID =
  | "host.toast" | "host.showPluginSettings" | "selection.copy" | "selection.cut" | "selection.paste"
  | "keyboard.press" | "clipboard.write" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink"
  | "system.runShortcut" | "system.runService" | "window.toggleFullScreen" | "window.restore"
  | "screen.capture";

/** IDs an answer to a gesture may request. */
export type RequestID =
  | "host.showPluginSettings" | "selection.replace" | "clipboard.write" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink";

/** IDs a page action may perform: the same as a request's. */
export type ViewActionID = RequestID;

/** IDs an item action may perform on the item's text. */
export type ItemActionID = "selection.replace" | "clipboard.write";

/** A key by name or by virtual key code (0 to 127), with modifiers. */
export type KeyboardShortcut =
  | { key: string; modifiers?: ("command" | "shift" | "option" | "control")[] }
  | { key_code: number; modifiers?: ("command" | "shift" | "option" | "control")[] };

/**
 * A screen capture. A source alone copies or saves as the user's screenshot
 * preferences say; otherwise both members say it, as Level 1's
 * `capture_screen` does.
 */
export type ScreenCapture =
  | "area" | "fullscreen" | "window"
  | { source: "area" | "fullscreen" | "window" }
  | {
      source: "area" | "fullscreen" | "window";
      copy_to_clipboard: boolean;
      save: null | { folder: string; format: "automatic" | "png" | "jpg" };
    };

/** An input that may be left out where the operation takes null. */
type Args<K extends OperationID> = null extends InputOf<K> ? [input?: InputOf<K>] : [input: InputOf<K>];

/** Calls the operation now and returns its result, or fails the invocation as a Host Service does. */
export interface Callable<K extends CallID> {
  (...args: Args<K>): ResultOf<K>;
}

/** `requestHostService` at Level 2: catalogue IDs only. */
export type RequestHostService = <K extends CallID>(name: K, input?: InputOf<K>) => ResultOf<K>;

// MARK: Requested Host Operations

/**
 * A Requested Host Operation: `{perform, input, id?, closes_view?, notify?}`,
 * performed by the Host after the answer that carries it commits. Only an
 * answer to a gesture (the Action's start, `called`, `submitted`,
 * `action_chosen`, `item_action`) may carry one.
 */
export interface RequestedOperation<K extends RequestID = RequestID> {
  perform: K;
  /** Left out only when the operation takes none. */
  input?: InputOf<K>;
  /** A label of at most 64 characters, echoed in `operation_finished`. */
  id?: string;
  /** Close the view once the operation succeeds, unless the user pinned it. Not with `host.showPluginSettings`. */
  closes_view?: boolean;
  /** Deliver `operation_finished` when the outcome is ready, after the view closed too. */
  notify?: boolean;
}

/** Options of `.operation(input, options)`. */
export interface OperationOptions {
  id?: string;
  closesView?: boolean;
  notify?: boolean;
}

type OperationArgs<K extends RequestID> = null extends InputOf<K>
  ? [input?: InputOf<K>, options?: OperationOptions]
  : [input: InputOf<K>, options?: OperationOptions];

/** Builds the request form of an operation. */
export interface Requestable<K extends RequestID> {
  operation(...args: OperationArgs<K>): RequestedOperation<K>;
}

/** The one terminal result of a requested or performed operation. */
export type OperationOutcome = "succeeded" | "refused" | "declined" | "expired" | "cancelled" | "failed";

/** Why an operation was refused or failed. None names the App. */
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
 * The event a script receives for an operation that asked to `notify`: a
 * request, a page action or an item action. It is not a gesture: an answer
 * to it may update the view or page and state but may not request an
 * operation. With `view_closed`, the view closed while the operation ran and
 * this is one viewless invocation of the requesting Action, which may answer
 * `null` or a toast, and nothing else.
 */
export type OperationFinishedEvent = {
  type: "operation_finished";
  /** The request's or action's `id`. */
  operation?: string;
  perform: RequestID;
  /** The item a performed item action acted on, as shown when the user acted. */
  item?: ItemSnapshot;
} & (
  | { outcome: "refused" | "failed"; reason: OperationReason; view_closed?: true }
  | { outcome: "succeeded"; view_closed?: true }
  | { outcome: "declined" | "expired" | "cancelled" }
);

// MARK: Pages and collections

/** A page, component, section, item or action ID: not blank, at most 64 characters. */
export type ID = string;

/**
 * One View Page. The same `id` refreshes the page on screen and keeps what the
 * user is doing in it; another `id` changes page, and the Host remembers up to
 * 4 earlier pages' immediate state by ID.
 */
export interface Page {
  id: ID;
  title: string;
  subtitle?: string;
  /**
   * Draw the non-interactive line naming the App insertion would go to. Drawn
   * as well when the collection has a `selection.replace` item action.
   */
  shows_insertion_target?: boolean;
  /** Focused when the page is new or reset. Answers cannot move focus otherwise. */
  focus?: ID;
  /**
   * One-shot: start these components (or, with "page", the whole page and its
   * memory) again from this description. Dropped for a text field whose
   * input-method composition is open.
   */
  reset?: "page" | ID[];
  /** Top to bottom; at most 40 components counting row children, at most one collection. */
  content: Component[];
}

export type Leaf = TextField | ChoiceField | TextBlock | Actions | Icon | Image | Progress;
export type Component = Row | Column | Leaf | List | Grid;

/** Up to 4 components side by side: leaves and columns, never a row directly. Containers nest at most 3 deep. */
export interface Row {
  kind: "row";
  id: ID;
  content: (Leaf | Column)[];
  style?: BoxStyle;
}

// MARK: Styles, images and progress (#81, appended to Level 2)

/** A colour: `#RRGGBB` or `#RRGGBBAA` in sRGB, a named colour that follows the appearance, or one for each appearance. */
export type SingleColor =
  | `#${string}`
  | "primary" | "secondary" | "tertiary" | "accent"
  | "blue" | "indigo" | "purple" | "pink" | "red" | "orange" | "yellow" | "green" | "teal" | "gray";
export type Color = SingleColor | { light: SingleColor; dark: SingleColor };

/** A text component's own style; nothing inherits it. */
export interface TextStyle {
  color?: Color;
  background?: Color;
  /** 9 to 40 points at the default text size, scaled with it. */
  font_size?: number;
  font_weight?: "regular" | "medium" | "semibold" | "bold";
  monospaced_digits?: boolean;
  /** 0 to 24 points. */
  padding?: number;
  /** 0 to 16 points. */
  corner_radius?: number;
}
/** A row's or column's own background. */
export interface BoxStyle { background?: Color; padding?: number; corner_radius?: number }
export interface ImageStyle { background?: Color; corner_radius?: number }
export interface TintStyle { color?: Color }

/** Up to 8 components top to bottom: leaves and rows, never a column directly. */
export interface Column {
  kind: "column";
  id: ID;
  content: (Leaf | Row)[];
  style?: BoxStyle;
}

/** A system symbol by its SF Symbols name, such as `cpu`. */
export interface SymbolSource { symbol: string }
/** A PNG or JPEG in the package, or at an https address the handler may contact under its own `contact_https`. */
export type ImageSource = { resource: string } | { url: string };

/** A system symbol; decoration unless it has a label. */
export interface Icon {
  kind: "icon";
  id: ID;
  source: SymbolSource;
  label?: string;
  /** 10 to 64 points, default 16. */
  size?: number;
  style?: TintStyle;
}

/** A picture the Host loads into a frame of width × height points (16 to 412); at most 8 per page. */
export interface Image {
  kind: "image";
  id: ID;
  source: ImageSource;
  /** What VoiceOver reads. */
  label: string;
  width: number;
  height: number;
  fit?: "fit" | "fill";
  style?: ImageStyle;
}

export type ProgressState = "running" | "cancelling" | "succeeded" | "failed" | "cancelled";

/** A task's progress as the Plugin describes it. Indeterminate unless `value` is given; the Host derives none. */
export interface Progress {
  kind: "progress";
  id: ID;
  title?: string;
  /** A fraction from 0 to 1 the Plugin knows. */
  value?: number;
  status?: string;
  /** 2 to 8 steps. */
  stages?: { id: ID; title: string }[];
  /** The stage under way, one of `stages`. */
  stage?: ID;
  state?: ProgressState;
  /** Drawn while `running`; sends `action_chosen` with this ID. */
  cancel?: { id: ID; title?: string };
  style?: TintStyle;
}

/** Style options as the builders take them, in camel case. */
export interface StyleOptions {
  color?: Color;
  background?: Color;
  fontSize?: number;
  fontWeight?: TextStyle["font_weight"];
  monospacedDigits?: boolean;
  padding?: number;
  cornerRadius?: number;
}

/** A one-line text field. `value` is applied only when the field is new or reset. */
export interface TextField {
  kind: "text_field";
  id: ID;
  title: string;
  placeholder?: string;
  value?: string;
  status?: string;
  accent?: Accent;
  /** The page's collection this field searches: Up/Down move its selection, Return performs its default item action. */
  collection?: ID;
}

export interface ChoiceField {
  kind: "choice_field";
  id: ID;
  title: string;
  choices: string[];
  choice_titles?: string[];
  /** Applied only when the field is new or reset. */
  value?: string;
}

/** Text in Level 1's Markdown subset. */
export interface TextBlock {
  kind: "text";
  id: ID;
  title?: string;
  text: string;
  style?: TextStyle;
}

/** Up to 8 buttons; none has a shortcut. */
export interface Actions {
  kind: "actions";
  id: ID;
  actions: PageAction[];
}

/** A button delivering `action_chosen`. */
export interface EventButton {
  id: ID;
  title: string;
}

/**
 * A button the Host performs by catalogue ID without a View Event, built by
 * `spinnet.<id>.action(input, options)`. Its title defaults to the
 * catalogue's `default_title`.
 */
export interface PerformAction<K extends ViewActionID = ViewActionID> {
  perform: K;
  /** Left out only when the operation takes none. */
  input?: InputOf<K>;
  id?: ID;
  title?: string;
  /** Close the view once the operation succeeds, unless the user pinned it. Not with `host.showPluginSettings`. */
  closes_view?: boolean;
  /** Deliver `operation_finished` once the Host has performed it. */
  notify?: boolean;
}

export type PageAction = EventButton | PerformAction;

interface CollectionMembers {
  id: ID;
  /** Rows visible initially, 1 to 12. */
  rows?: number;
  /** The item selected when the collection is new or reset; else the first. */
  selected?: ID;
  /** Shown when there are no items. */
  empty_text?: string;
  /** Up to 6, offered on every item unless the item lists its own. At most one default. */
  actions?: ItemAction[];
}

/**
 * Every item given: at most 2,000 in `items` or in up to 32 `sections`. Or,
 * with `total`, a window: `total` items (at most 2,000), of which this answer
 * gives the slice `items` from position `start`; sections are headers that
 * count their items. The Host keeps a window of the items around what the user
 * sees, draws placeholders for the rest, and asks for them with `load_range`.
 */
export type Contents =
  | { items: Item[]; sections?: never; total?: never; start?: never }
  | { sections: Section[]; items?: never; total?: never; start?: never }
  | { total: number; start?: number; items?: Item[]; sections?: SectionHeader[] };

export type List = CollectionMembers & { kind: "list" } & Contents;
export type Grid = CollectionMembers & {
  kind: "grid";
  /** Cells across, 2 to 12; 8 by default. */
  columns?: number;
} & Contents;

export interface Section {
  id: ID;
  title?: string;
  items: Item[];
}

/** A section of a collection with `total`: its items come in the collection's `items`, by position. */
export interface SectionHeader {
  id: ID;
  title?: string;
  count: number;
}

export interface Item {
  /** Unique in the collection, sections included. */
  id: ID;
  /** Row text, cell tooltip and VoiceOver label; at most 256 characters. */
  title: string;
  subtitle?: string;
  /** A short glyph, at most 32 characters: the grid cell's content. */
  symbol?: string;
  /** Trailing row text, at most 64 characters. */
  accessory?: string;
  /** Text for Copy and Insert item actions and the event snapshot; else `symbol`, else `title`. */
  text?: string;
  /**
   * IDs of the collection's item actions this item offers; all when absent.
   * Valid, but where it only picks one of two states use a toggle and `marks`.
   */
  actions?: ID[];
  /** Marks the collection's toggle item actions name; each shows its action checked. */
  marks?: ID[];
  /** A system symbol as the row's leading icon or the grid cell; not with `symbol`. */
  icon?: SymbolSource;
}

/**
 * No shortcut. Return and double-click run the default; every action is in the
 * item's context menu, and ⌘C runs a sole `clipboard.write` action. The Host draws no
 * buttons for item actions.
 */
export type ItemAction =
  | { id: ID; title: string; default?: true }
  /** Delivers `item_action` and shows checked for an item whose `marks` include `toggle`. */
  | { id: ID; title: string; default?: true; toggle: ID }
  /**
   * Performed on the item's text, which becomes the operation's primary member
   * text; with `notify`, `operation_finished` reports the outcome with the item.
   */
  | { id: ID; title: string; default?: true; perform: ItemActionID; closes_view?: boolean; notify?: boolean };

/** The item as shown when the user acted. */
export interface ItemSnapshot {
  id: ID;
  section?: ID;
  /** The item's resolved text, when it differs from its ID. */
  text?: string;
  /** The marks it carried, when any. */
  marks?: ID[];
}

type Values = { [input: string]: JSONValue };
/** The page's collection mapped to its selected item, or null. Empty without a collection. */
type Selection = { [collection: string]: ID | null };

/** Events from a page. */
export type PageEvent =
  | { type: "field_changed"; page: ID; field: ID; values: Values }
  | { type: "submitted"; page: ID; field: ID; values: Values; selection: Selection }
  | { type: "action_chosen"; page: ID; action: ID; values: Values; selection: Selection }
  | { type: "item_action"; page: ID; collection: ID; action: ID; item: ItemSnapshot; values: Values }
  /** The Host needs positions `start` to `start + count`; not a gesture. */
  | { type: "load_range"; page: ID; collection: ID; start: number; count: number };

/**
 * An Explicit Call of one of the Plugin's Actions while its View Session is
 * open: the Menu Item's Action runs in the session instead of restarting
 * it. It carries nothing; `input` holds the called Action's effective input
 * and `state` the session's last good state. It names no page and is never
 * dropped for a page change. A gesture.
 */
export type CallEvent = { type: "called" };

/** A Level 2 script's `event` global: null when the Action starts. */
export type ScriptEvent = ViewEvent | PageEvent | CallEvent | OperationFinishedEvent;

// MARK: Answers

/**
 * A Level 1 view plus `shows_insertion_target`, which asks the Host to draw a
 * line naming the App insertion would go to. The name is Host data; the
 * Plugin never receives it.
 */
export type View = ViewDescription & { shows_insertion_target?: boolean };

/** A Level 2 script's answer: a page or a Level 1 view, with an optional operation, never both page and view. */
export type Answer =
  | null
  | { view: View; state?: JSONValue; toast?: string; operation?: RequestedOperation }
  | { page: Page; state?: JSONValue; toast?: string; operation?: RequestedOperation }
  | { close: true; toast?: string }
  | { toast?: string; operation: RequestedOperation }
  | { toast: string };

/** Level 1's answers stay valid at Level 2. */
export type _Level1AnswersRemainValid = ScriptAnswer extends Answer ? true : never;

// MARK: The SDK

/** Builders of page components. Camel-case options map to the snake-case members. */
export interface PageComponents {
  row(options: { id: ID; content: (Leaf | Column)[]; style?: StyleOptions }): Row;
  column(options: { id: ID; content: (Leaf | Row)[]; style?: StyleOptions }): Column;
  icon(options: { id: ID; source: SymbolSource; label?: string; size?: number; style?: StyleOptions }): Icon;
  image(options: { id: ID; source: ImageSource; label: string; width: number; height: number; fit?: "fit" | "fill"; style?: StyleOptions }): Image;
  progress(options: { id: ID; title?: string; value?: number; status?: string; stages?: { id: ID; title: string }[]; stage?: ID; state?: ProgressState; cancel?: { id: ID; title?: string }; style?: StyleOptions }): Progress;
  textField(options: { id: ID; title: string; placeholder?: string; value?: string; status?: string; accent?: Accent; collection?: ID }): TextField;
  choiceField(options: { id: ID; title: string; choices: string[]; choiceTitles?: string[]; value?: string }): ChoiceField;
  text(options: { id: ID; text: string; title?: string; style?: StyleOptions }): TextBlock;
  actions(options: { id: ID; actions: PageAction[] }): Actions;
  /** A button delivering `action_chosen`. */
  button(options: { id: ID; title: string }): EventButton;
  list(options: { id: ID; items?: Item[]; sections?: Section[] | SectionHeader[]; total?: number; start?: number; rows?: number; selected?: ID; emptyText?: string; actions?: ItemAction[] }): List;
  grid(options: { id: ID; items?: Item[]; sections?: Section[] | SectionHeader[]; total?: number; start?: number; columns?: number; rows?: number; selected?: ID; emptyText?: string; actions?: ItemAction[] }): Grid;
  /** With `items`, a section of a whole collection; with `count`, a header of one with a total. */
  section(options: { id: ID; title?: string; items: Item[] }): Section;
  section(options: { id: ID; title?: string; count: number }): SectionHeader;
  item(options: { id: ID; title: string; subtitle?: string; symbol?: string; accessory?: string; text?: string; actions?: ID[]; marks?: ID[]; icon?: SymbolSource }): Item;
  itemAction(options: { id: ID; title: string; default?: true; perform?: ItemActionID; closesView?: boolean; notify?: boolean; toggle?: ID }): ItemAction;
}

/**
 * `spinnet.ui` at Level 2: Level 1's builders, for a Level 1 view, which a
 * Level 2 Plugin may still answer and whose standard actions keep Level 1's
 * names, with these changed or added. `ui.toast` and `ui.close` build the
 * answer forms of `host.toast` and `host.closeView`.
 */
export interface UI extends Omit<UIArea, "view" | "show"> {
  /** Level 1's `view`, which also takes `showsInsertionTarget`. */
  view(value: Parameters<UIArea["view"]>[0] & { showsInsertionTarget?: boolean }): View;
  /** `show` as in Level 1, with an optional operation committed together with the view. */
  show(view: View, options?: { state?: JSONValue; toast?: string; operation?: RequestedOperation }): Answer;
  /** An answer with no view or page that requests one operation, optionally with a toast. */
  request(operation: RequestedOperation, options?: { toast?: string }): Answer;
  components: PageComponents;
  page(options: { id: ID; title: string; subtitle?: string; showsInsertionTarget?: boolean; focus?: ID; reset?: "page" | ID[]; content: Component[] }): Page;
  /** An answer showing `page`, with an optional state, toast and operation. */
  showPage(page: Page, options?: { state?: JSONValue; toast?: string; operation?: RequestedOperation }): Answer;
}

type ActionArgs<K extends ViewActionID> = null extends InputOf<K>
  ? [input?: InputOf<K>, options?: { id?: ID; title?: string; closesView?: boolean; notify?: boolean }]
  : [input: InputOf<K>, options?: { id?: ID; title?: string; closesView?: boolean; notify?: boolean }];

/** Builds the page action form of an operation. */
export interface Actionable<K extends ViewActionID> {
  action(...args: ActionArgs<K>): PerformAction<K>;
}

/** An operation an answer may request and a page action may perform. */
export type Performable<K extends RequestID> = Requestable<K> & Actionable<K>;

/** Spinnet's own UI and flow, which the Plugin asks the Host to act on. */
export interface HostNamespace {
  /** Opens the Plugin's own Plugin Settings sheet. @id host.showPluginSettings @entry request view_action */
  readonly showPluginSettings: Performable<"host.showPluginSettings">;
}

/** The focused App's selection. Every operation here targets the focused App. */
export interface SelectionNamespace {
  /** The focused App's selected text. @id selection.readText @entry call */
  readonly readText: Callable<"selection.readText">;
  /**
   * Types text into the App in front in place of its selection. Called
   * inside a View Session, it goes ahead only after a gesture in a view or
   * page that showed the target, and fails with `insertion_target_changed`
   * when another App is in front.
   * @id selection.replace @entry call request view_action
   */
  readonly replace: Callable<"selection.replace"> & Performable<"selection.replace">;
}

/** The current clipboard's content; nothing here targets an App. */
export interface ClipboardNamespace {
  /** The current clipboard's text or link. @id clipboard.read @entry call */
  readonly read: Callable<"clipboard.read">;
  /** Puts text on the clipboard. @id clipboard.write @entry call request view_action */
  readonly write: Callable<"clipboard.write"> & Performable<"clipboard.write">;
}

/** The Clipboard History Store, under its own Capability, `read_clipboard_history`. */
export interface ClipboardHistoryNamespace {
  /** One page of Clipboard History. @id clipboardHistory.read @entry call */
  readonly read: Callable<"clipboardHistory.read">;
  /** A chunk of one entry's retained bytes. @id clipboardHistory.readContent @entry call */
  readonly readContent: Callable<"clipboardHistory.readContent">;
  /** Opens the Clipboard History window, the one Host Surface. @id clipboardHistory.show @entry call request view_action */
  readonly show: Callable<"clipboardHistory.show"> & Performable<"clipboardHistory.show">;
}

/** Handing a link, path or application to the App that opens it. */
export interface OpenNamespace {
  /** Opens an http or https link in the default browser. @id open.url @entry call request view_action */
  readonly url: Callable<"open.url"> & Performable<"open.url">;
  /** Opens an absolute or `~/` path. @id open.path @entry call request view_action */
  readonly path: Callable<"open.path"> & Performable<"open.path">;
  /** Opens an application by path or bundle identifier; needs open_local_path. @id open.application @entry call request view_action */
  readonly application: Callable<"open.application"> & Performable<"open.application">;
}

/** External Apps through reviewed interfaces and Deep Link Templates. */
export interface AppsNamespace {
  /** One operation of a Reviewed App Interface. @id apps.perform @entry call request view_action */
  readonly perform: Callable<"apps.perform"> & Performable<"apps.perform">;
  /** One of the Plugin's Deep Link Templates. @id apps.openDeepLink @entry call request view_action */
  readonly openDeepLink: Callable<"apps.openDeepLink"> & Performable<"apps.openDeepLink">;
}

/** The focused window. */
export interface WindowNamespace {
  /** @id window.read @entry call */
  readonly read: Callable<"window.read">;
  /** Moves the window `read` last returned, while it is focused. @id window.setFrame @entry call */
  readonly setFrame: Callable<"window.setFrame">;
  /** @id window.toggleFullScreen @entry call */
  readonly toggleFullScreen: Callable<"window.toggleFullScreen">;
  /** @id window.restore @entry call */
  readonly restore: Callable<"window.restore">;
}

export interface ScreenNamespace {
  /** Starts a capture the Plugin never receives. @id screen.capture @entry call */
  readonly capture: Callable<"screen.capture">;
}

export interface HTTPNamespace {
  /** One HTTPS request with Credential Uses. @id http.request @entry call */
  readonly request: Callable<"http.request">;
}

export interface TextNamespace {
  /** @id text.detectLanguage @entry call */
  readonly detectLanguage: Callable<"text.detectLanguage">;
}

/** Plugin Storage, as Level 1's `StorageArea` describes it. */
export interface StorageNamespace {
  /** @id storage.get @entry call */
  readonly get: Callable<"storage.get">;
  /** Throws a StorageLimitError the script may catch. @id storage.set @entry call */
  readonly set: Callable<"storage.set">;
  /** @id storage.remove @entry call */
  readonly remove: Callable<"storage.remove">;
  /** @id storage.keys @entry call */
  readonly keys: Callable<"storage.keys">;
  /** @id storage.clear @entry call */
  readonly clear: Callable<"storage.clear">;
}

/**
 * The `spinnet` object at Level 2, by namespace. An operation offered only
 * as a Command (`selection.paste`, `keyboard.press`, `system.runShortcut`,
 * ...) or only as an answer member (`host.toast`, `host.closeView`) has no
 * member here: the manifest and `spinnet.ui` reach those, so `keyboard` and
 * `system` are absent.
 */
export interface Spinnet {
  readonly host: HostNamespace;
  readonly selection: SelectionNamespace;
  readonly clipboard: ClipboardNamespace;
  readonly clipboardHistory: ClipboardHistoryNamespace;
  readonly open: OpenNamespace;
  readonly apps: AppsNamespace;
  readonly window: WindowNamespace;
  readonly screen: ScreenNamespace;
  readonly http: HTTPNamespace;
  readonly text: TextNamespace;
  readonly storage: StorageNamespace;
  readonly ui: UI;
  /** Level 1's; `apiLevel` is the highest stable Level the Host supports. */
  readonly environment: Environment;
}

/** A Level 2 script's globals whose types differ from Level 1's. */
export interface Globals {
  spinnet: Spinnet;
  event: ScriptEvent | null;
  requestHostService: RequestHostService;
}
