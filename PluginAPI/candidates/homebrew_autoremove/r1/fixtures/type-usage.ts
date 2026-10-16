import type { HomebrewAutoremoveSpinnet } from "../homebrew-autoremove";
import type { Spinnet } from "../../../../spinnet-level-2";
declare const spinnet: HomebrewAutoremoveSpinnet;
const source = spinnet.tools.read.source("preview", {tool: "homebrew", operation: "previewAutoremove"}, {deliver: true});
const task = spinnet.tools.startTask.operation({tool: "homebrew", operation: "autoremove"}, {notify: true});
const action = spinnet.tools.startTask.action({tool: "homebrew", operation: "autoremove"}, {id: "remove", title: "Review Removal"});
const actions = spinnet.ui.components.actions({id: "controls", actions: [action]});
const page = spinnet.ui.page({id: "preview", title: "Unused Dependencies", content: [actions], sources: [source]});
spinnet.ui.showPage(page, {operation: task});
spinnet.ui.request(task);
// Candidate read and task input stay unavailable through the stable declaration.
declare const stable: Spinnet;
// @ts-expect-error The preview requires homebrew_autoremove r1.
stable.tools.read({tool: "homebrew", operation: "previewAutoremove"});
// @ts-expect-error The removal requires homebrew_autoremove r1.
stable.tools.startTask.operation({tool: "homebrew", operation: "autoremove"});
