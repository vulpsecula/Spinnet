// PROPOSAL ONLY (#74). Draft types for pages and collections.
// SPDX-License-Identifier: MIT
//
// Not part of Plugin API Level 1, any stable Level, or any published
// Candidate Contract revision. `spinnet.js` implements none of this, and the
// helper injects none of it. The types extend `../../spinnet.d.ts` and the
// draft `host_operations` types the way a candidate revision's declarations
// would; once published they would live with the revision under
// `../../candidates/collections/r1/`, never in the stable `spinnet.d.ts`.
// `reference.md` states the rules behind them.

import type { Accent, JSONValue, ScriptAnswer, ViewEvent } from "../../spinnet";
import type { HostOperation } from "../bounded-host-operations/host-operations";
import type { ItemActionID, PerformAction } from "../namespaces/namespaces";

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

/**
 * An event action, or a page action that performs a Host Service by its
 * catalogue ID (#99), built by `spinnet.<id>.action(input, options)`.
 */
export type PageAction =
  | { id: ID; title: string }
  | PerformAction;

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

/** What a candidate script may answer. */
export type CandidateAnswer =
  | ScriptAnswer
  | { page: Page; state?: JSONValue; toast?: string; operation?: HostOperation }
  | { operation: HostOperation; toast?: string };

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

/** Events from a page, and explicit calls, under the candidate. Level 1 events keep their shapes. */
export type PageEvent =
  | { type: "field_changed"; page: ID; field: ID; values: Values }
  | { type: "submitted"; page: ID; field: ID; values: Values; selection: Selection }
  | { type: "action_chosen"; page: ID; action: ID; values: Values; selection: Selection }
  | { type: "item_action"; page: ID; collection: ID; action: ID; item: ItemSnapshot; values: Values }
  | { type: "load_more"; page: ID; collection: ID; loaded: number }
  | { type: "called" };

export type CandidateEvent = ViewEvent | PageEvent;

/** Proposed builders, in the style of `spinnet.ui`. Camel-case options map to the snake-case members. */
export interface PageComponents {
  row(options: { id: ID; content: Leaf[] }): Row;
  textField(options: { id: ID; title: string; placeholder?: string; value?: string; status?: string; accent?: Accent; collection?: ID }): TextField;
  choiceField(options: { id: ID; title: string; choices: string[]; choiceTitles?: string[]; value?: string }): ChoiceField;
  text(options: { id: ID; text: string; title?: string }): TextBlock;
  actions(options: { id: ID; actions: PageAction[] }): Actions;
  list(options: { id: ID; items?: Item[]; sections?: Section[]; rows?: number; selected?: ID; emptyText?: string; hasMore?: boolean; actions?: ItemAction[] }): List;
  grid(options: { id: ID; items?: Item[]; sections?: Section[]; columns?: number; rows?: number; selected?: ID; emptyText?: string; hasMore?: boolean; actions?: ItemAction[] }): Grid;
  section(options: { id: ID; title?: string; items: Item[] }): Section;
  item(options: { id: ID; title: string; subtitle?: string; symbol?: string; accessory?: string; text?: string; actions?: ID[] }): Item;
  itemAction(options: { id: ID; title: string; default?: true; perform?: ItemActionID; closesView?: boolean }): ItemAction;
}

export interface PageUI {
  components: PageComponents;
  page(options: { id: ID; title: string; subtitle?: string; showsInsertionTarget?: boolean; focus?: ID; reset?: "page" | ID[]; content: Component[] }): Page;
  showPage(page: Page, options?: { state?: JSONValue; toast?: string; operation?: HostOperation }): CandidateAnswer;
}

