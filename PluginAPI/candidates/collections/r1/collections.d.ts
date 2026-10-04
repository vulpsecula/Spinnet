// Types for Candidate Contract collections, revision 1.
// SPDX-License-Identifier: MIT
//
// Not part of any stable Plugin API Level. A Plugin that declares
// `{"name": "collections", "revision": 1}` beside the
// `{"name": "host_operations", "revision": 1}` and
// `{"name": "namespaces", "revision": 1}` it requires runs with the `spinnet`
// object of `../../host_operations/r1/host-operations.d.ts`, which
// `collections.js` extends as `CollectionsSpinnet` below: every operation the
// catalogue offers as a page action gets `.action(input, options)`, and
// `spinnet.ui` builds pages. `reference.md` states the rules;
// `collections.schema.json` the shapes.

import type { Accent, JSONValue } from "../../../spinnet";
import type {
  CandidateScriptAnswer,
  CandidateViewEvent,
  OperationsSpinnet,
  OperationsUI,
  RequestedOperation,
} from "../../host_operations/r1/host-operations";
import type { InputOf } from "../../namespaces/r1/namespaces";

/** A page, component, section, item or action ID: not blank, at most 64 characters. */
export type ID = string;

/** IDs a page action may perform. */
export type ViewActionID =
  | "host.showPluginSettings" | "selection.replace" | "clipboard.write" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink";

/** IDs an item action may perform on the item's text. */
export type ItemActionID = "selection.replace" | "clipboard.write";

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
   * host_operations: draw the non-interactive line naming the App insertion
   * would go to. Drawn as well when the collection has a `selection.replace` item action.
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

export type Leaf = TextField | ChoiceField | TextBlock | Actions;
export type Component = Row | Leaf | List | Grid;

/** Up to 4 leaf components side by side. */
export interface Row {
  kind: "row";
  id: ID;
  content: Leaf[];
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
  /** Close the view once the operation succeeds. Not with `host.showPluginSettings`. */
  closes_view?: boolean;
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
  /** More items exist; near the end the Host sends `load_more`. */
  has_more?: boolean;
  /** Up to 6, offered on every item unless the item lists its own. At most one default. */
  actions?: ItemAction[];
}

/** At most 2,000 items in all, in `items` or in up to 32 `sections`. */
export type List = CollectionMembers & { kind: "list" } & ({ items: Item[] } | { sections: Section[] });
export type Grid = CollectionMembers & {
  kind: "grid";
  /** Cells across, 2 to 12; 8 by default. */
  columns?: number;
} & ({ items: Item[] } | { sections: Section[] });

export interface Section {
  id: ID;
  title?: string;
  items: Item[];
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
  /** IDs of the collection's item actions this item offers; all when absent. */
  actions?: ID[];
}

/**
 * No shortcut. Return and double-click run the default; every action is in the
 * item's context menu, and ⌘C runs a sole `clipboard.write` action. The Host draws no
 * buttons for item actions.
 */
export type ItemAction =
  | { id: ID; title: string; default?: true }
  /** Performed on the item's text, which becomes the operation's primary member text. */
  | { id: ID; title: string; default?: true; perform: ItemActionID; closes_view?: boolean };

/** What a candidate script may answer: host_operations' answers, or a page instead of a view. */
export type CollectionsAnswer =
  | CandidateScriptAnswer
  | { page: Page; state?: JSONValue; toast?: string; operation?: RequestedOperation };

/** The item as shown when the user acted. */
export interface ItemSnapshot {
  id: ID;
  section?: ID;
  /** The item's resolved text, when it differs from its ID. */
  text?: string;
}

type Values = { [input: string]: JSONValue };
/** The page's collection mapped to its selected item, or null. Empty without a collection. */
type Selection = { [collection: string]: ID | null };

/** Events from a page. Level 1 events keep their shapes. */
export type PageEvent =
  | { type: "field_changed"; page: ID; field: ID; values: Values }
  | { type: "submitted"; page: ID; field: ID; values: Values; selection: Selection }
  | { type: "action_chosen"; page: ID; action: ID; values: Values; selection: Selection }
  | { type: "item_action"; page: ID; collection: ID; action: ID; item: ItemSnapshot; values: Values }
  | { type: "load_more"; page: ID; collection: ID; loaded: number };

export type CollectionsEvent = CandidateViewEvent | PageEvent;

/** Builders of page components. Camel-case options map to the snake-case members. */
export interface PageComponents {
  row(options: { id: ID; content: Leaf[] }): Row;
  textField(options: { id: ID; title: string; placeholder?: string; value?: string; status?: string; accent?: Accent; collection?: ID }): TextField;
  choiceField(options: { id: ID; title: string; choices: string[]; choiceTitles?: string[]; value?: string }): ChoiceField;
  text(options: { id: ID; text: string; title?: string }): TextBlock;
  actions(options: { id: ID; actions: PageAction[] }): Actions;
  /** A button delivering `action_chosen`. */
  button(options: { id: ID; title: string }): EventButton;
  list(options: { id: ID; items?: Item[]; sections?: Section[]; rows?: number; selected?: ID; emptyText?: string; hasMore?: boolean; actions?: ItemAction[] }): List;
  grid(options: { id: ID; items?: Item[]; sections?: Section[]; columns?: number; rows?: number; selected?: ID; emptyText?: string; hasMore?: boolean; actions?: ItemAction[] }): Grid;
  section(options: { id: ID; title?: string; items: Item[] }): Section;
  item(options: { id: ID; title: string; subtitle?: string; symbol?: string; accessory?: string; text?: string; actions?: ID[] }): Item;
  itemAction(options: { id: ID; title: string; default?: true; perform?: ItemActionID; closesView?: boolean }): ItemAction;
}

/** `spinnet.ui` under the candidate: host_operations' builders, with these added. */
export interface CollectionsUI extends OperationsUI {
  components: PageComponents;
  page(options: { id: ID; title: string; subtitle?: string; showsInsertionTarget?: boolean; focus?: ID; reset?: "page" | ID[]; content: Component[] }): Page;
  /** An answer showing `page`, with an optional state, toast and operation. */
  showPage(page: Page, options?: { state?: JSONValue; toast?: string; operation?: RequestedOperation }): CollectionsAnswer;
}

type ActionArgs<K extends ViewActionID> = null extends InputOf<K>
  ? [input?: InputOf<K>, options?: { id?: ID; title?: string; closesView?: boolean }]
  : [input: InputOf<K>, options?: { id?: ID; title?: string; closesView?: boolean }];

/** Builds the page action form of an operation. */
export interface Actionable<K extends ViewActionID> {
  action(...args: ActionArgs<K>): PerformAction<K>;
}

/** The `spinnet` object under collections r1, host_operations r1 and namespaces r1. */
export interface CollectionsSpinnet extends Omit<OperationsSpinnet,
  "host" | "selection" | "clipboard" | "clipboardHistory" | "open" | "apps" | "ui"> {
  readonly host: { readonly showPluginSettings: OperationsSpinnet["host"]["showPluginSettings"] & Actionable<"host.showPluginSettings"> };
  readonly selection: Omit<OperationsSpinnet["selection"], "replace"> & {
    /** @id selection.replace @entry view_action */
    readonly replace: OperationsSpinnet["selection"]["replace"] & Actionable<"selection.replace">;
  };
  readonly clipboard: Omit<OperationsSpinnet["clipboard"], "write"> & {
    /** @id clipboard.write @entry view_action */
    readonly write: OperationsSpinnet["clipboard"]["write"] & Actionable<"clipboard.write">;
  };
  readonly clipboardHistory: Omit<OperationsSpinnet["clipboardHistory"], "show"> & {
    /** @id clipboardHistory.show @entry view_action */
    readonly show: OperationsSpinnet["clipboardHistory"]["show"] & Actionable<"clipboardHistory.show">;
  };
  readonly open: {
    readonly url: OperationsSpinnet["open"]["url"] & Actionable<"open.url">;
    readonly path: OperationsSpinnet["open"]["path"] & Actionable<"open.path">;
    readonly application: OperationsSpinnet["open"]["application"] & Actionable<"open.application">;
  };
  readonly apps: {
    readonly perform: OperationsSpinnet["apps"]["perform"] & Actionable<"apps.perform">;
    readonly openDeepLink: OperationsSpinnet["apps"]["openDeepLink"] & Actionable<"apps.openDeepLink">;
  };
  readonly ui: CollectionsUI;
}

/** The candidate script's globals that differ from host_operations r1's. */
export interface CollectionsGlobals {
  spinnet: CollectionsSpinnet;
  event: CollectionsEvent | null;
}
