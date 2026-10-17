// SPDX-License-Identifier: MIT
import type { Globals, Page } from "../../spinnet-level-4";
declare const spinnet: Globals["spinnet"];
const c = spinnet.ui.components;
const page: Page = spinnet.ui.page({id:"tasks",title:"Tasks",content:[c.text({id:"log",text:"Waiting"})],
  sources:[spinnet.activities.list.source("activities", {every:1,deliver:true})]});
spinnet.ui.showPage(page);
// @ts-expect-error Activity sources cannot choose another Plugin's owner.
spinnet.activities.list.source("other", {owner:"someone-else",every:1,deliver:true});
