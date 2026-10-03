// PROPOSAL ONLY (#99). Draft types for the namespaced SDK of candidate namespaces r1.
// SPDX-License-Identifier: MIT
//
// Not part of Plugin API Level 1, any stable Level, or any published
// Candidate Contract revision. `spinnet.js` implements none of this, and the
// helper injects none of it. Under the candidate the helper would inject a
// `spinnet` object laid out as below instead of Level 1's; once published, the
// types would live with the revision under `../../candidates/namespaces/r1/`,
// never in the stable `spinnet.d.ts`. `reference.md` states the rules.
//
// Every operation a script can reach is at `spinnet.<id>`, where <id> is its
// catalogue ID (`catalogue.json`). Its `@entry` tag says how:
//
// - `call`: the member is a function that calls the operation now, inside the
//   invocation, and returns its result: `spinnet.clipboard.write("😀")`.
// - `view_action`: `.action(input, options)` builds a page action that the
//   Host performs on the user's click without a View Event (collections).
// - `request`: `.operation(input, options)` builds a Requested Host Operation
//   for the answer to a gesture (host_operations).
//
// An operation offered only as a Command (`selection.paste`,
// `keyboard.press`, `system.runShortcut`, ...) or only as an answer member
// (`host.toast`, `host.closeView`) has no member here; the manifest and
// `spinnet.ui` reach those. IDs are exactly `namespace.verb`, so every
// namespace is one object directly under `spinnet`. check.py holds every `@id` and `@entry` tag, and
// the ID lists below, to the catalogue.

import type {
  ClipboardContent,
  ClipboardHistoryContent,
  ClipboardHistoryPage,
  Environment,
  FocusedWindow,
  HTTPSRequest,
  HTTPSResponse,
  JSONValue,
  UIArea,
  WindowRect,
} from "../../spinnet";
import type { CandidateUI } from "../bounded-host-operations/host-operations";
import type { PageUI } from "../collections/collections";

/** Input and result of every operation offered in r1, by catalogue ID. */
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

/** IDs a page action may perform and an answer may request; the two lists are the same in r1. */
export type PerformID =
  | "host.showPluginSettings" | "selection.replace" | "clipboard.write" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink";

/** IDs an item action may perform on the item's text. */
export type ItemActionID = "selection.replace" | "clipboard.write";

/** IDs a manifest Command with `execution: "host"` may name in `host_command`. */
export type HostCommandID =
  | "host.toast" | "host.showPluginSettings" | "selection.copy" | "selection.cut" | "selection.paste"
  | "keyboard.press" | "clipboard.write" | "clipboardHistory.show"
  | "open.url" | "open.path" | "open.application" | "apps.perform" | "apps.openDeepLink"
  | "system.runShortcut" | "system.runService" | "window.toggleFullScreen" | "window.restore"
  | "screen.capture";

/** A key by name or by virtual key code (0 to 127), with modifiers. */
export type KeyboardShortcut =
  | { key: string; modifiers?: ("command" | "shift" | "option" | "control")[] }
  | { key_code: number; modifiers?: ("command" | "shift" | "option" | "control")[] };

/**
 * A screen capture. A source alone copies or saves as the user's screenshot
 * preferences say (decision N9); otherwise both members say it, as Level 1's
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

/**
 * A page action that performs an operation (collections): the Host performs
 * it on the user's click, without a View Event, under the Capability the
 * operation needs. `title` defaults to the catalogue's `default_title`.
 */
export interface PerformAction<K extends PerformID = PerformID> {
  perform: K;
  input?: InputOf<K>;
  id?: string;
  title?: string;
  /** Not with `host.showPluginSettings`. */
  closes_view?: boolean;
}

/**
 * A Requested Host Operation (host_operations): performed after the answer
 * that carries it commits. Only an answer to a gesture may carry one.
 */
export interface RequestedOperation<K extends PerformID = PerformID> {
  perform: K;
  input?: InputOf<K>;
  /** A label of at most 64 characters, echoed in `operation_finished`. */
  id?: string;
  /** Not with `host.showPluginSettings`. */
  closes_view?: boolean;
  /** Deliver `operation_finished` when the outcome is ready. */
  notify?: boolean;
}

/** An input that may be left out where the operation takes null. */
type Args<K extends OperationID, O> = null extends InputOf<K>
  ? [input?: InputOf<K>, options?: O]
  : [input: InputOf<K>, options?: O];

/** Calls the operation now and returns its result, or fails the invocation as a Level 1 Host Service does. */
export interface Callable<K extends CallID> {
  (...args: Args<K, never>): ResultOf<K>;
}

/** Builds the two forms that perform the operation after the user's gesture. */
export interface Performable<K extends PerformID> {
  action(...args: Args<K, { title?: string; id?: string; closesView?: boolean }>): PerformAction<K>;
  operation(...args: Args<K, { id?: string; closesView?: boolean; notify?: boolean }>): RequestedOperation<K>;
}

/** `requestHostService` under the candidate: catalogue IDs only. */
export type RequestHostService = <K extends CallID>(name: K, input?: InputOf<K>) => ResultOf<K>;

/**
 * The `spinnet` object under namespaces r1. Namespaces whose r1 operations a
 * script cannot reach (`keyboard`, `system`) are absent; they appear when a
 * later revision offers one of their operations to scripts (decision N8).
 * `host` holds only `showPluginSettings` in r1; `host.confirm` and
 * `host.launchCommand` join it when they are defined.
 */
export interface NamespacedSpinnet {
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
  readonly ui: NamespacedUI;
  readonly environment: Environment;
}

/** Spinnet's own UI and flow, which the Plugin asks the Host to act on. */
export interface HostNamespace {
  /** Opens the Plugin's own Plugin Settings sheet. @id host.showPluginSettings @entry view_action request */
  readonly showPluginSettings: Performable<"host.showPluginSettings">;
}

/** The focused App's selection. Every operation here targets the focused App. */
export interface SelectionNamespace {
  /** The focused App's selected text. @id selection.readText @entry call */
  readonly readText: Callable<"selection.readText">;
  /**
   * Replaces the focused App's selection with text, typed as keyboard events.
   * In a View Session of a Plugin declaring host_operations, every form checks
   * the App the Host showed (ADR 0018). @id selection.replace @entry call view_action request
   */
  readonly replace: Callable<"selection.replace"> & Performable<"selection.replace">;
}

/** The current clipboard's content; nothing here targets an App. */
export interface ClipboardNamespace {
  /** The current clipboard's text or link. @id clipboard.read @entry call */
  readonly read: Callable<"clipboard.read">;
  /** Puts text on the clipboard. @id clipboard.write @entry call view_action request */
  readonly write: Callable<"clipboard.write"> & Performable<"clipboard.write">;
}

/** The Clipboard History Store, under its own Capability, `read_clipboard_history`. */
export interface ClipboardHistoryNamespace {
  /** One page of Clipboard History. @id clipboardHistory.read @entry call */
  readonly read: Callable<"clipboardHistory.read">;
  /** A chunk of one entry's retained bytes. @id clipboardHistory.readContent @entry call */
  readonly readContent: Callable<"clipboardHistory.readContent">;
  /** Opens the Clipboard History window, the one Host Surface. @id clipboardHistory.show @entry call view_action request */
  readonly show: Callable<"clipboardHistory.show"> & Performable<"clipboardHistory.show">;
}

/** Handing a link, path or application to the App that opens it. */
export interface OpenNamespace {
  /** Opens an http or https link in the default browser. @id open.url @entry call view_action request */
  readonly url: Callable<"open.url"> & Performable<"open.url">;
  /** Opens an absolute or `~/` path. @id open.path @entry call view_action request */
  readonly path: Callable<"open.path"> & Performable<"open.path">;
  /** Opens an application by path or bundle identifier; needs open_local_path. @id open.application @entry call view_action request */
  readonly application: Callable<"open.application"> & Performable<"open.application">;
}

/** External Apps through reviewed interfaces and Deep Link Templates. */
export interface AppsNamespace {
  /** One operation of a Reviewed App Interface. @id apps.perform @entry call view_action request */
  readonly perform: Callable<"apps.perform"> & Performable<"apps.perform">;
  /** One of the Plugin's Deep Link Templates. @id apps.openDeepLink @entry call view_action request */
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
 * `spinnet.ui` under the candidate: Level 1's builders, kept for Level 1
 * views (collections C9) with their four standard-action builders, which build
 * Level 1's names and only fit a Level 1 view; the page builders of
 * collections; and host_operations' `show` with `operation` and `request`. A
 * page's buttons that perform an operation come from the operation itself:
 * `spinnet.clipboard.write.action("😀")`. `ui.toast` and `ui.close` build the
 * answer forms of `host.toast` and `host.closeView`.
 */
export type NamespacedUI = UIArea & PageUI & Pick<CandidateUI, "show" | "request">;

/** The candidate script's globals that differ from Level 1's. */
export interface NamespacedGlobals {
  spinnet: NamespacedSpinnet;
  requestHostService: RequestHostService;
}
