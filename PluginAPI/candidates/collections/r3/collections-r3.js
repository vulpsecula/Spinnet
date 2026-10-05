// The spinnet SDK additions of Candidate Contract collections, revision 3.
// SPDX-License-Identifier: MIT
//
// The helper evaluates this file for a Plugin that declares collections r3,
// after `../../namespaces/r1/namespaces.js` and
// `../../host_operations/r1/host_operations.js`, which builds the request
// builders of host_operations r1 and r2 alike (r2 adds none). It calls the
// function it evaluates to with the raw `requestHostService` call, the
// invocation's environment and the object those two built, and the
// function's value becomes the script's `spinnet` global.
// `collections.d.ts` describes it.
//
// It is revision 1's `collections.js` with what revision 3 adds: `notify`
// on `.action(...)` and on performed item actions, `toggle` on item
// actions, `marks` on items, `total` and `start` on lists and grids, and
// `count` on the sections of a collection with a total; `hasMore` is gone
// with `load_more`. It has its own file name because the helper embeds
// every revision's SDK side by side.
//
// Every operation the catalogue offers as a page action gets
// `.action(input, options)`, which builds a button the Host performs without
// a View Event. `spinnet.ui.components` builds page components, `ui.page` a
// page and `ui.showPage` the answer that shows it. Camel-case options become
// the snake-case members the Host reads. Like every builder these are pure:
// they ask the Host for nothing, and the Host checks what the script answers
// with, so a page it would not draw still ends the View Session.
(function (requestHostService, environment, previous) {
  "use strict";

  // The catalogue IDs this revision lets a page action perform, by namespace.
  const viewActions = {
    host: ["showPluginSettings"],
    selection: ["replace"],
    clipboard: ["write"],
    clipboardHistory: ["show"],
    open: ["url", "path", "application"],
    apps: ["perform", "openDeepLink"]
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
  for (const key of Object.keys(previous)) sdk[key] = previous[key];

  for (const name of Object.keys(viewActions)) {
    const existing = previous[name] || {};
    const members = {};
    for (const verb of Object.keys(existing)) members[verb] = existing[verb];
    for (const verb of viewActions[name]) {
      const before = existing[verb];
      // A callable operation stays a function; its other builders stay.
      const member = typeof before === "function" ? function (input) { return before(input); } : {};
      if (before) for (const key of Object.keys(before)) member[key] = before[key];
      member.action = action(name + "." + verb);
      members[verb] = Object.freeze(member);
    }
    sdk[name] = Object.freeze(members);
  }

  function collection(kind, o) {
    return compact({
      kind: kind,
      id: o.id,
      items: o.items,
      sections: o.sections,
      columns: kind === "grid" ? o.columns : undefined,
      rows: o.rows,
      total: o.total,
      start: o.start,
      selected: o.selected,
      empty_text: o.emptyText,
      actions: o.actions
    });
  }

  const components = Object.freeze({
    row: function (o) { return compact({ kind: "row", id: o.id, content: o.content }); },
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
    text: function (o) { return compact({ kind: "text", id: o.id, title: o.title, text: o.text }); },
    actions: function (o) { return compact({ kind: "actions", id: o.id, actions: o.actions }); },
    button: function (o) { return compact({ id: o.id, title: o.title }); },
    list: function (o) { return collection("list", options(o)); },
    grid: function (o) { return collection("grid", options(o)); },
    section: function (o) { return compact({ id: o.id, title: o.title, items: o.items, count: o.count }); },
    item: function (o) {
      return compact({
        id: o.id, title: o.title, subtitle: o.subtitle, symbol: o.symbol, accessory: o.accessory,
        text: o.text, actions: o.actions, marks: o.marks
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
  for (const key of Object.keys(previous.ui)) ui[key] = previous.ui[key];
  ui.components = components;
  ui.page = function (value) {
    const o = options(value);
    return compact({
      id: o.id,
      title: o.title,
      subtitle: o.subtitle,
      shows_insertion_target: o.showsInsertionTarget,
      focus: o.focus,
      reset: o.reset,
      content: o.content
    });
  };
  ui.showPage = function (page, value) {
    const o = options(value);
    return compact({ page: page, state: o.state, toast: o.toast, operation: o.operation });
  };
  sdk.ui = Object.freeze(ui);

  return Object.freeze(sdk);
})
