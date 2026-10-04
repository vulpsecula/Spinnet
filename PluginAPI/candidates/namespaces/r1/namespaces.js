// The spinnet SDK object under Candidate Contract namespaces, revision 1.
// SPDX-License-Identifier: MIT
//
// The helper evaluates this file, instead of handing a script Plugin API
// Level 1's object, for a Plugin that declares namespaces r1. It calls the
// function it evaluates to with the raw `requestHostService` call, the
// invocation's environment and Level 1's object, built by `../../../spinnet.js`,
// and the function's value becomes the script's `spinnet` global.
// `namespaces.d.ts` describes it.
//
// Every operation a script can call is a function at `spinnet.<id>`, where
// <id> is its catalogue ID (`catalogue.json`): it requests exactly that ID,
// with its argument as the input, unchanged (`null` when omitted), and returns
// the answer, so it fails exactly as `requestHostService` does. A namespace
// whose operations no script can call in this revision, such as `keyboard`,
// `system` and `host`, is absent. `ui` and `environment` are Level 1's, so a
// Plugin still answers with a Level 1 view.
(function (requestHostService, environment, levelOne) {
  "use strict";

  function call(id) {
    return function (input) {
      return requestHostService(id, input === undefined ? null : input);
    };
  }

  function namespace(name, verbs) {
    const members = {};
    for (const verb of verbs) members[verb] = call(name + "." + verb);
    return Object.freeze(members);
  }

  return Object.freeze({
    selection: namespace("selection", ["readText", "replace"]),
    clipboard: namespace("clipboard", ["read", "write"]),
    clipboardHistory: namespace("clipboardHistory", ["read", "readContent", "show"]),
    open: namespace("open", ["url", "path", "application"]),
    apps: namespace("apps", ["perform", "openDeepLink"]),
    window: namespace("window", ["read", "setFrame", "toggleFullScreen", "restore"]),
    screen: namespace("screen", ["capture"]),
    http: namespace("http", ["request"]),
    text: namespace("text", ["detectLanguage"]),
    storage: namespace("storage", ["get", "set", "remove", "keys", "clear"]),
    ui: levelOne.ui,
    environment: levelOne.environment
  });
})
