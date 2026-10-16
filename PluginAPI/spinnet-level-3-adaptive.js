// SPDX-License-Identifier: MIT
// Stable Plugin API Level 3 adaptive cards and viewport fit.
(function (previous) {
  "use strict";
  const components = Object.assign({}, previous.ui.components);
  components.adaptive = function (o) {
    const value = {kind:"adaptive", id:o.id, content:o.content};
    if (o.minCardWidth !== undefined) value.min_card_width = o.minCardWidth;
    if (o.spacing !== undefined) value.spacing = o.spacing;
    if (o.maxColumns !== undefined) value.max_columns = o.maxColumns;
    if (o.fit !== undefined) value.fit = {profiles:o.fit.profiles.map(function(p) {
      const profile = {id:p.id, min_card_width:p.minCardWidth, min_card_height:p.minCardHeight};
      if (p.spacing !== undefined) profile.spacing = p.spacing;
      if (p.overrides !== undefined) profile.overrides = p.overrides.map(function(v) {
        const item = {id:v.id};
        if (v.text !== undefined) item.text = v.text;
        if (v.hidden !== undefined) item.hidden = v.hidden;
        if (v.style !== undefined) item.style = previous.ui.components.text({id:v.id,text:"",style:v.style}).style;
        return item;
      });
      return profile;
    })};
    return value;
  };
  return Object.freeze(Object.assign({},previous,{ui:Object.freeze(Object.assign({},previous.ui,{components:Object.freeze(components)}))}));
})
