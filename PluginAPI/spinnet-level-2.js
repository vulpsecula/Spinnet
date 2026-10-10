// The spinnet SDK object, Plugin API Level 2.
// SPDX-License-Identifier: MIT
//
// The helper evaluates this file, instead of handing a script Level 1's
// object, for a Plugin whose manifest declares `"api_level": 2`. It calls
// the function it evaluates to with the raw `requestHostService` call, the
// invocation's environment and Level 1's object, built by `spinnet.js`, and
// the function's value becomes the script's `spinnet` global.
// `spinnet-level-2.d.ts` describes it, `catalogue.json` lists every
// operation and `reference/namespaces.md` states the rules.
//
// Every operation a script can call is a function at `spinnet.<id>`, where
// <id> is its catalogue ID: it requests exactly that ID, with its argument as
// the input, unchanged (`null` when omitted), and returns the answer, so it
// fails exactly as `requestHostService` does. Every operation an answer may
// request gets `.operation(input, options)`, and every operation a page
// action may perform `.action(input, options)`; an operation only those
// reach, `host.showPluginSettings`, is an object holding the two builders.
// `ui` keeps Level 1's builders, since a Level 2 Plugin may still answer a
// Level 1 view, and adds the page builders (`ui.components`, `ui.page`,
// `ui.showPage`) and `ui.request`. Like every builder these are pure: they
// ask the Host for nothing, and the Host checks what the script answers
// with. `environment` is Level 1's.
(function (requestHostService, environment, levelOne) {
  "use strict";

  // The catalogue IDs a script can call, by namespace.
  const calls = {
    selection: ["readText", "replace"],
    clipboard: ["read", "write"],
    clipboardHistory: ["read", "readContent", "show"],
    open: ["url", "path", "application"],
    apps: ["perform", "openDeepLink", "frontmost"],
    window: ["read", "setFrame", "toggleFullScreen", "restore"],
    screen: ["capture"],
    http: ["request"],
    text: ["detectLanguage"],
    storage: ["get", "set", "remove", "keys", "clear"],
    activities: ["list"],
    tools: ["read"],
    system: ["metrics"]
  };

  // The catalogue IDs an answer may request and a page action may perform,
  // by namespace: the same ones.
  const performed = {
    host: ["showPluginSettings"],
    selection: ["replace"],
    clipboard: ["write"],
    clipboardHistory: ["show"],
    open: ["url", "path", "application"],
    apps: ["perform", "openDeepLink", "quit", "close"],
    system: ["keepAwake"],
    activities: ["stop"],
    tools: ["startTask"]
  };

  function compact(members) {
    const result = {};
    for (const key of Object.keys(members)) {
      if (members[key] !== undefined) result[key] = members[key];
    }
    return result;
  }

  function options(value) {
    return value === undefined || value === null ? {} : value;
  }

  function validateManagementRead(v) {
    function invalid() { throw new TypeError("tools.read contains unsupported management input"); }
    const globals = ["version", "doctor", "adoptionCandidates"];
    const name = n => typeof n === "string" && n.length <= 160 && /^([a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*$/.test(n);
    let allowed = ["tool", "operation"];
    if (v.operation === "services") {
      allowed.push("kind");
      if (v.kind !== undefined && v.kind !== "formula") invalid();
    } else if (v.operation === "taps") {
      allowed.push("tap");
      if (v.tap !== undefined && (typeof v.tap !== "string" || v.tap.length > 96 || !/^[a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*$/.test(v.tap))) invalid();
    } else if (["previewInstall", "previewUpgrade", "packageAnalytics"].includes(v.operation)) {
      allowed.push("kind", "names");
      if (!["formula", "cask"].includes(v.kind) || !Array.isArray(v.names) || !v.names.length || v.names.length > 20 || new Set(v.names).size !== v.names.length || v.names.some(n => !name(n))) invalid();
      if (v.operation === "packageAnalytics" && v.names.length !== 1) invalid();
    } else if (v.operation === "adoptionPreview") {
      allowed.push("target", "name");
      if (typeof v.target !== "string" || !v.target.startsWith("app_") || v.target.length > 80 || !name(v.name)) invalid();
    } else if (v.operation === "vulnerabilityDetail") {
      allowed.push("id");
      if (typeof v.id !== "string" || v.id.length > 128 || !/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(v.id)) invalid();
    } else if (v.operation === "vulnerabilities") {
      allowed.push("names", "offset");
      if (v.names !== undefined && (v.offset !== undefined || !Array.isArray(v.names) || !v.names.length || v.names.length > 20 || new Set(v.names).size !== v.names.length || v.names.some(n => !name(n)))) invalid();
      if (v.offset !== undefined && (!Number.isInteger(v.offset) || v.offset < 0 || v.offset > 1999)) invalid();
    } else if (!globals.includes(v.operation)) invalid();
    if (Object.keys(v).some(k => !allowed.includes(k))) invalid();
  }
  function validateToolRead(v) {
    function invalid() { throw new TypeError("tools.read contains unsupported members, names or kinds"); }
    if (!v || typeof v !== "object" || Array.isArray(v) || v.tool !== "homebrew") invalid();
    if (["version", "taps", "services", "doctor", "adoptionCandidates", "adoptionPreview", "previewInstall", "previewUpgrade", "packageAnalytics", "vulnerabilities", "vulnerabilityDetail"].includes(v.operation)) return validateManagementRead(v);
    const keys = {installed: ["tool", "operation", "kind"], outdated: ["tool", "operation", "kind", "greedy"], search: ["tool", "operation", "kind", "query"], info: ["tool", "operation", "kind", "names"]}[v.operation];
    if (!keys || Object.keys(v).some(k => !keys.includes(k))) invalid();
    if (v.kind !== undefined && !["formula", "cask"].includes(v.kind)) invalid();
    if (v.greedy !== undefined && typeof v.greedy !== "boolean") invalid();
    if (v.operation === "search" && (typeof v.query !== "string" || v.query.length < 2 || v.query.length > 64 || !/^[a-z0-9+_.@][a-z0-9+_.@-]*$/.test(v.query))) invalid();
    if (v.operation === "info" && (v.kind === undefined || !Array.isArray(v.names) || v.names.length < 1 || v.names.length > 50 || new Set(v.names).size !== v.names.length || v.names.some(n => typeof n !== "string" || n.length > 160 || !/^([a-z0-9][a-z0-9_.-]*\/[a-z0-9][a-z0-9_.-]*\/)?[a-z0-9][a-z0-9+_.@-]*$/.test(n)))) invalid();
  }
  function call(id) {
    return function (input) {
      if (id === "tools.read") validateToolRead(input);
      return requestHostService(id, input === undefined ? null : input);
    };
  }

  // A Requested Host Operation for the answer to a gesture.
  function operation(id) {
    return function (input, value) {
      const o = options(value);
      return compact({
        perform: id,
        input: input === null ? undefined : input,
        id: o.id,
        closes_view: o.closesView,
        notify: o.notify
      });
    };
  }

  // A page action: a button the Host performs without a View Event.
  function action(id) {
    return function (input, value) {
      const o = options(value);
      return compact({
        perform: id,
        input: input === null ? undefined : input,
        id: o.id,
        title: o.title,
        closes_view: o.closesView,
        notify: o.notify
      });
    };
  }

  const sdk = {};
  for (const name of Object.keys(calls)) {
    const members = {};
    for (const verb of calls[name]) members[verb] = call(name + "." + verb);
    sdk[name] = members;
  }
  for (const name of Object.keys(performed)) {
    const members = sdk[name] || {};
    for (const verb of performed[name]) {
      const callable = members[verb];
      // A callable operation stays a function; one only an answer or a
      // page action reaches is an object holding its builders.
      const member = callable ? function (input) { return callable(input); } : {};
      member.operation = operation(name + "." + verb);
      member.action = action(name + "." + verb);
      if (name === "apps" && verb === "perform") member.source = function (id, input, value) {
        if (!input || input.bundle_id !== "com.spotify.client" || input.operation !== "playback" || (input.arguments && Object.keys(input.arguments).length)) throw new Error("apps.perform sources require Spotify playback");
        return source(id, "apps.perform", input, value);
      };
      members[verb] = Object.freeze(member);
    }
    sdk[name] = members;
  }
  function source(id, perform, input, value) {
    const o = options(value);
    return compact({ id: id, perform: perform, input: input, every: o.every,
      deliver: o.deliver === true ? {} : o.deliver,
      error_pointer: o.errorPointer, status_messages: o.statusMessages });
  }
  sdk.system.metrics.source = function (id, input, value) { return source(id, "system.metrics", input, value); };
  sdk.http.request.source = function (id, input, value) { return source(id, "http.request", input, value); };
  sdk.tools.read.source = function (id, input, value) { validateToolRead(input); return source(id, "tools.read", input, value); };
  sdk.activities.list.source = function (id, value) { return source(id, "activities.list", null, value); };
  for (const name of Object.keys(sdk)) sdk[name] = Object.freeze(sdk[name]);

  function collection(kind, o) {
    return compact({
      kind: kind,
      id: o.id,
      items: o.items,
      sections: o.sections,
      columns: kind === "grid" ? o.columns : undefined,
      min_cell_size: kind === "grid" ? o.minCellSize : undefined,
      rows: o.rows,
      total: o.total,
      start: o.start,
      selected: o.selected,
      empty_text: o.emptyText,
      actions: o.actions
    });
  }

  // A Component Style (#81), its camel-case options as snake-case members.
  // Colours and Image Sources pass unchanged.
  function style(o) {
    if (o === undefined || o === null) return undefined;
    return compact({
      color: o.color,
      background: o.background,
      font_size: o.fontSize,
      font_weight: o.fontWeight,
      monospaced_digits: o.monospacedDigits,
      padding: o.padding,
      corner_radius: o.cornerRadius
    });
  }

  const components = Object.freeze({
    bind: function (source, pointer, value) {
      const o = options(value);
      return compact({ source: source, pointer: pointer, format: o.format, unavailable: o.unavailable });
    },
    row: function (o) { return compact({ kind: "row", id: o.id, content: o.content, style: style(o.style) }); },
    column: function (o) { return compact({ kind: "column", id: o.id, content: o.content, style: style(o.style) }); },
    icon: function (o) {
      return compact({ kind: "icon", id: o.id, source: o.source, label: o.label, size: o.size, style: style(o.style) });
    },
    image: function (o) {
      return compact({
        kind: "image", id: o.id, source: o.source, label: o.label, width: o.width, height: o.height, fit: o.fit,
        style: style(o.style)
      });
    },
    progress: function (o) {
      return compact({
        kind: "progress", id: o.id, title: o.title, value: o.value, status: o.status, stages: o.stages,
        stage: o.stage, state: o.state, cancel: o.cancel, style: style(o.style)
      });
    },
    activityList: function (o) { return compact({kind: "activity_list", id: o.id, empty_text: o.emptyText}); },
    textField: function (o) {
      return compact({
        kind: "text_field", id: o.id, title: o.title, placeholder: o.placeholder, value: o.value,
        status: o.status, accent: o.accent, collection: o.collection
      });
    },
    choiceField: function (o) {
      return compact({
        kind: "choice_field", id: o.id, title: o.title, choices: o.choices, choice_titles: o.choiceTitles,
        value: o.value
      });
    },
    text: function (o) {
      return compact({ kind: "text", id: o.id, title: o.title, text: o.text, style: style(o.style), bind: o.bind });
    },
    actions: function (o) { return compact({ kind: "actions", id: o.id, actions: o.actions }); },
    button: function (o) { return compact({ id: o.id, title: o.title }); },
    list: function (o) { return collection("list", options(o)); },
    grid: function (o) { return collection("grid", options(o)); },
    section: function (o) { return compact({ id: o.id, title: o.title, items: o.items, count: o.count }); },
    item: function (o) {
      return compact({
        id: o.id, title: o.title, subtitle: o.subtitle, symbol: o.symbol, accessory: o.accessory,
        text: o.text, actions: o.actions, marks: o.marks, icon: o.icon
      });
    },
    itemAction: function (o) {
      return compact({
        id: o.id, title: o.title, default: o.default === true ? true : undefined, perform: o.perform,
        closes_view: o.closesView, toggle: o.toggle, notify: o.notify
      });
    }
  });

  const ui = {};
  for (const key of Object.keys(levelOne.ui)) ui[key] = levelOne.ui[key];
  const levelOneView = levelOne.ui.view;
  ui.view = function (value) {
    const o = options(value);
    const view = levelOneView(value);
    if (o.showsInsertionTarget !== undefined) view.shows_insertion_target = o.showsInsertionTarget;
    return view;
  };
  ui.show = function (view, value) {
    const o = options(value);
    return compact({ view: view, state: o.state, toast: o.toast, operation: o.operation });
  };
  ui.request = function (requested, value) {
    const o = options(value);
    return compact({ toast: o.toast, operation: requested });
  };
  ui.components = components;
  ui.source = source;
  ui.page = function (value) {
    const o = options(value);
    return compact({
      id: o.id,
      title: o.title,
      subtitle: o.subtitle,
      shows_insertion_target: o.showsInsertionTarget,
      focus: o.focus,
      reset: o.reset,
      resizable: o.resizable === undefined || typeof o.resizable === "boolean" ? o.resizable
        : compact({ min_width: o.resizable.minWidth, min_height: o.resizable.minHeight }),
      content: o.content,
      sources: o.sources
    });
  };
  ui.showPage = function (page, value) {
    const o = options(value);
    return compact({ page: page, state: o.state, toast: o.toast, operation: o.operation });
  };
  sdk.ui = Object.freeze(ui);
  sdk.environment = levelOne.environment;

  return Object.freeze(sdk);
})
