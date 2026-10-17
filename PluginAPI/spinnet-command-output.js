// SPDX-License-Identifier: MIT
// Plugin API Level 6 command output, promoted from homebrew_command_output r1.
(function (previous, requestHostService) {
  "use strict";
  const matches = input => input && input.tool === "homebrew" && input.operation === "commandOutput";
  const read = function (input) {
    return matches(input) ? requestHostService("tools.read", input) : previous.tools.read(input);
  };
  read.source = function (id, input, options) {
    return matches(input) ? previous.ui.source(id, "tools.read", input, options) : previous.tools.read.source(id, input, options);
  };
  const components = Object.freeze(Object.assign({}, previous.ui.components, {text: function (options) {
    const value = previous.ui.components.text(options);
    return options.format === undefined ? value : Object.assign({}, value, {format: options.format});
  }}));
  return Object.freeze(Object.assign({}, previous, {
    tools: Object.freeze(Object.assign({}, previous.tools, {read: Object.freeze(read)})),
    ui: Object.freeze(Object.assign({}, previous.ui, {components}))
  }));
})
