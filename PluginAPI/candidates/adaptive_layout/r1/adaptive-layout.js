// SPDX-License-Identifier: MIT
// Evaluated only for a Plugin declaring adaptive_layout r1, over Level 2.
(function (previous) {
  "use strict";
  const components = Object.assign({}, previous.ui.components);
  components.adaptive = function (o) {
    const value = {kind: "adaptive", id: o.id, content: o.content};
    if (o.minCardWidth !== undefined) value.min_card_width = o.minCardWidth;
    if (o.spacing !== undefined) value.spacing = o.spacing;
    if (o.maxColumns !== undefined) value.max_columns = o.maxColumns;
    return value;
  };
  const ui = Object.assign({}, previous.ui, {components: Object.freeze(components)});
  return Object.freeze(Object.assign({}, previous, {ui: Object.freeze(ui)}));
})
