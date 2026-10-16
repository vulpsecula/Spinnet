// SPDX-License-Identifier: MIT
// Evaluated only for homebrew_autoremove r1 over the stable Level 2 SDK.
(function (previous, requestHostService) {
  "use strict";
  function preview(input) {
    if (!input || input.tool !== "homebrew" || input.operation !== "previewAutoremove") return false;
    if (Object.keys(input).some(key => !["tool", "operation"].includes(key))) throw new TypeError("previewAutoremove takes no selectors");
    return true;
  }
  const read = function (input) {
    return preview(input) ? requestHostService("tools.read", input) : previous.tools.read(input);
  };
  read.source = function (id, input, options) {
    return preview(input) ? previous.ui.source(id, "tools.read", input, options) : previous.tools.read.source(id, input, options);
  };
  const tools = Object.assign({}, previous.tools, {read: Object.freeze(read)});
  return Object.freeze(Object.assign({}, previous, {tools: Object.freeze(tools)}));
})
