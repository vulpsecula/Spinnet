// The spinnet SDK additions of Candidate Contract host_operations, revision 1.
// SPDX-License-Identifier: MIT
//
// The helper evaluates this file for a Plugin that declares host_operations
// r1, after `../../namespaces/r1/namespaces.js`, which that revision
// requires. It calls the function it evaluates to with the raw
// `requestHostService` call, the invocation's environment and the namespaced
// object, and the function's value becomes the script's `spinnet` global.
// `host-operations.d.ts` describes it.
//
// Every operation the catalogue offers as a request gets
// `.operation(input, options)`, which builds a Requested Host Operation for
// the answer to a gesture; one a script can also call stays callable. `host`
// appears, holding `host.showPluginSettings`, which only a request reaches.
// `ui.show` takes an `operation`, `ui.request` answers with one and no view,
// and `ui.view` takes `showsInsertionTarget`. Like every builder these are
// pure: they ask the Host for nothing, and the Host checks what the script
// answers with.
(function (requestHostService, environment, namespaced) {
  "use strict";

  // The catalogue IDs this revision lets an answer request, by namespace.
  const requests = {
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

  const sdk = {};
  for (const key of Object.keys(namespaced)) sdk[key] = namespaced[key];

  for (const name of Object.keys(requests)) {
    const existing = namespaced[name] || {};
    const members = {};
    for (const verb of Object.keys(existing)) members[verb] = existing[verb];
    for (const verb of requests[name]) {
      const call = existing[verb];
      // A callable operation stays a function; one only a request reaches
      // is an object holding its builder.
      const member = call ? function (input) { return call(input); } : {};
      member.operation = operation(name + "." + verb);
      members[verb] = Object.freeze(member);
    }
    sdk[name] = Object.freeze(members);
  }

  const ui = {};
  for (const key of Object.keys(namespaced.ui)) ui[key] = namespaced.ui[key];
  const levelOneView = namespaced.ui.view;
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
  sdk.ui = Object.freeze(ui);

  return Object.freeze(sdk);
})
