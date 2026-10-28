const entryMode = "update";
// SPDX-License-Identifier: MIT
// Presentation policy for Host-projected Homebrew objects. No process or I/O.
const brewCatalog = (() => {
  const sections = ["list","search","outdated","update","adopt","services","tap","doctor","cleanup"];
  const titles = ["Installed","Search","Available Upgrades","Update Catalog","Adopt Apps","Services","Taps","Doctor","Clean Up"];
  const key = item => item.kind + ":" + item.name;
  function id(value) {
    let a = 2166136261, b = 5381;
    for (let i = 0; i < value.length; i++) { a = Math.imul(a ^ value.charCodeAt(i),16777619); b = Math.imul(b,33) ^ value.charCodeAt(i); }
    return "row-" + (a >>> 0).toString(16) + "-" + (b >>> 0).toString(16);
  }
  const text = value => String(value == null ? "" : value).replace(/([\\`*_{}\[\]<>])/g,"\\$1");
  const queryValid = value => /^[a-z0-9+_.@][a-z0-9+_.@-]{1,63}$/.test(value);
  const tapValid = value => /^[a-z0-9][a-z0-9_.-]{0,63}\/[a-z0-9][a-z0-9_.-]{0,63}$/.test(value);
  function packages(result, inventory) {
    const installed = new Map((inventory && inventory.packages || []).map(item => [key(item),item]));
    const complete = !!inventory && !inventory.truncated;
    return (result && result.packages || []).map(item => {
      const previous = result.operation === "search" ? installed.get(key(item)) : null;
      const merged = Object.assign({},previous || {},item);
      merged.isInstalled = !!previous || !!item.installed_version || result.operation === "installed" || result.operation === "outdated";
      merged.installationKnown = merged.isInstalled || complete;
      if (result.operation === "outdated") merged.outdated = true;
      return merged;
    });
  }
  function primary(item) {
    if (!item.installationKnown || item.disabled || (item.isInstalled && item.pinned)) return "details";
    if (!item.isInstalled) return "install";
    return item.outdated ? "upgrade" : "details";
  }
  function actions(item) {
    const result = ["activate","details"];
    if (item.isInstalled) result.push("uninstall",item.pinned ? "unpin" : "pin");
    if (primary(item) === "install" || primary(item) === "upgrade") result.push("preview");
    return [...new Set(result)];
  }
  function group(item, screen) {
    if (screen === "outdated") return item.pinned ? "Pinned" : item.kind === "cask" ? "Cask Apps" : "Formulae";
    if (item.pinned) return item.kind === "cask" ? "Pinned Cask Apps" : "Pinned Formulae";
    if (item.kind === "cask") return "Cask Apps";
    return item.installed_as_dependency && !item.installed_on_request ? "Dependencies" : "Formulae";
  }
  function grouped(items, groupOf) {
    const groups = new Map();
    for (const item of items) { const name = groupOf(item); if (!groups.has(name)) groups.set(name,[]); groups.get(name).push(item); }
    const order = ["Running","Stopped","Ready to Adopt","Likely Adoptable","Unlikely Adoptions","Cannot Adopt","Pinned Cask Apps","Pinned Formulae","Cask Apps","Formulae","Dependencies","Pinned"];
    return [...groups].map(([title,items]) => ({id:id(title),title,items})).sort((a,b) => order.indexOf(a.title) - order.indexOf(b.title));
  }
  function byteLength(value) {
    const string = JSON.stringify(value);
    let size = 0;
    for (const character of string) { const point = character.codePointAt(0); size += point < 128 ? 1 : point < 2048 ? 2 : point < 65536 ? 3 : 4; }
    return size;
  }
  // A read result fits the wire budget, but the cache envelope also costs bytes.
  function bounded(result) {
    const copy = JSON.parse(JSON.stringify(result));
    if (byteLength(copy) <= 480 * 1024) return copy;
    for (const field of ["packages","applications","taps"]) if (Array.isArray(copy[field])) {
      while (copy[field].length && byteLength(copy) > 480 * 1024) copy[field].pop();
      copy.truncated = true;
    }
    return copy;
  }
  return {sections,titles,key,id,text,queryValid,tapValid,packages,primary,actions,group,grouped,bounded};
})();

// SPDX-License-Identifier: MIT
(() => {
  const c = spinnet.ui.components, model = brewCatalog;
  const e = event || {};
  const mode = model.sections.includes(entryMode) ? entryMode : "list";
  const s = Object.assign({screen:mode,section:mode,query:"",kind:"both",serial:0,instance:Date.now().toString(36) + Math.random().toString(36).slice(2),
    caches:{},read:null,queue:[],error:"",notice:"",detail:null,preview:null,origin:null,
    taskID:null,waiting:false,admitted:false,running:false,seen:[],output:"",truncated:false,
    taskTitle:"",taskResult:null,returnTo:null,catalogRefresh:false,report:"doctor",tap:"",adoptionFilter:"available",rawReturn:null},state || {});
  // Existing pinned views and task return routes use the surviving selection page.
  for (const field of ["screen","section"]) if (s[field] === "upgrade") s[field] = "outdated";
  if (s.returnTo && s.returnTo.section === "upgrade") s.returnTo = Object.assign({},s.returnTo,{section:"outdated"});
  const reset = [], cacheMemo = {};
  let operation;
  const busy = () => s.waiting || s.running;
  const pageID = () => "homebrew-" + s.screen;
  const collectionID = () => "objects-" + s.section;
  const prefix = "homebrew.browser.v3.";

  // Large inventories live in bounded Plugin Storage, never in the 64 KiB view state.
  // A generation mismatch cannot supply rows to an older view or its queued actions.
  function cached(slot) {
    if (!s.caches[slot]) return null;
    if (Object.prototype.hasOwnProperty.call(cacheMemo,slot)) return cacheMemo[slot];
    try {
      const saved = spinnet.storage.get(prefix + slot);
      return cacheMemo[slot] = saved && saved.generation === s.caches[slot] ? saved.data : null;
    } catch (error) { s.error = error.message || "Stored package data is unavailable. Refresh to retry."; return null; }
  }
  function save(slot,data) {
    const generation = s.instance + "-" + (++s.serial);
    try {
      const value = model.bounded(data);
      spinnet.storage.set({key:prefix + slot,value:{generation,data:value}});
      s.caches[slot] = generation; cacheMemo[slot] = value;
      return value;
    } catch (error) { s.error = error.message || "Package data could not be kept. Refresh to retry."; return null; }
  }
  function read(input,purpose,slot) { return {input:Object.assign({tool:"homebrew"},input),purpose,slot}; }
  function nextRead() {
    if (!s.read && s.queue.length) s.read = Object.assign({id:"read-" + (++s.serial)},s.queue.shift());
  }
  function request(requests) {
    s.read = null; s.queue = requests; s.error = "";
    for (const pending of requests) if (["details","preview","tap-details","report","raw","autoremove"].includes(pending.slot)) { s.caches[pending.slot] = null; delete cacheMemo[pending.slot]; }
    nextRead();
  }
  function refresh(section = s.section) {
    s.preview = null; s.error = "";
    if ((section === "outdated") && s.caches.selection && !cached("selection")) { s.caches.selection = null; delete cacheMemo.selection; s.error = ""; }
    if (["list","search"].includes(section)) {
      const requests = [read({operation:"installed"},"inventory","inventory")];
      if (section === "search" && model.queryValid(s.query.trim().toLowerCase())) requests.push(read({operation:"search",query:s.query.trim().toLowerCase()},"catalog","search"));
      request(requests);
    } else if ((section === "outdated")) request([read({operation:"outdated"},"upgrades","upgrades")]);
    else if (section === "services") request([read({operation:"services"},"catalog","services")]);
    else if (section === "tap") request([read({operation:"taps"},"catalog","taps")]);
    else if (section === "adopt") request([read({operation:"adoptionCandidates"},"catalog","adoption")]);
    else if (section === "cleanup") request([read({operation:"previewAutoremove"},"autoremove","autoremove")]);
    else if (section === "doctor") request([read({operation:"commandOutput",command:s.report},"report","report")]);
    else { s.read = null; s.queue = []; }
  }
  function navigate(section) {
    s.section = section; s.screen = section; s.origin = null; s.detail = null; s.preview = null;
    s.query = "";
    s.caches.search = null; delete cacheMemo.search;
    s.kind = "both"; s.notice = ""; s.output = ""; s.truncated = false; s.report = "doctor";
    reset.push("section","query-" + section,"kind","report");
    s.error = "";
    if (["outdated","adopt","tap"].includes(section)) startTask({operation:"refreshCatalog"},"Updating Homebrew Catalog");
    else refresh();
  }
  function finishCatalogRefresh(useLocal) {
    const route = s.returnTo || {section:s.section,query:s.query,kind:s.kind};
    s.catalogRefresh = false; s.taskID = null; s.taskResult = null;
    reset.push("section","query-" + route.section,"kind","report");
    s.screen = route.section; s.section = route.section; s.query = route.query; s.kind = route.kind;
    s.caches = {}; Object.keys(cacheMemo).forEach(key => { delete cacheMemo[key]; });
    s.notice = useLocal ? "Catalog update did not complete. Showing the last locally available Homebrew data." : "Catalog updated.";
    refresh();
  }
  function showOutput(value,truncated) {
    const raw = typeof value === "string" ? value : "";
    s.output = raw.slice(-12000);
    if (s.output.charCodeAt(0) >= 0xdc00 && s.output.charCodeAt(0) <= 0xdfff) s.output = s.output.slice(1);
    s.truncated = !!truncated || raw.length > 12000;
  }
  function currentPackages() {
    const slot = s.section === "list" ? "inventory" : s.section === "search" ? "search" : "upgrades";
    const data = cached(slot), inventory = cached("inventory");
    return {data,items:model.packages(data,inventory)};
  }
  function selected(item) {
    const selection = cached("selection");
    if (s.caches.selection && !selection) { s.error = "Upgrade selection is unavailable. Refresh and review the selection before retrying."; return false; }
    return !item.pinned && !(selection && (selection.excluded || []).includes(model.key(item)));
  }
  function details(item) {
    s.origin = {section:s.section,query:s.query,kind:s.kind,screen:s.screen === "tap-details" ? "tap-details" : s.section,tap:s.screen === "tap-details" && s.detail ? s.detail.tap : null};
    s.detail = {kind:item.kind,name:item.name,isInstalled:item.isInstalled,installationKnown:item.installationKnown};
    s.screen = "details"; s.preview = null;
    request([read({operation:"info",kind:item.kind,names:[item.name]},"details","details")]);
  }
  function autoremoveReady(result) {
    return result && result.available === true && result.succeeded === true && result.complete === true &&
      result.no_op === false && Array.isArray(result.packages) && result.packages.length > 0;
  }
  function startTask(task,title) {
    if (busy() || s.error) return;
    // Entry may request only the separately scoped fixed catalog refresh.
    // No read/Task completion queues a mutation, and a refusal never replays one.
    s.catalogRefresh = task.operation === "refreshCatalog";
    s.returnTo = s.origin || {section:s.section,query:s.query,kind:s.kind};
    s.read = null; s.queue = []; s.screen = "task";
    s.taskTitle = title; s.taskResult = null; s.taskID = null; s.waiting = true; s.admitted = false; s.running = false;
    s.seen = (spinnet.activities.list() || []).map(item => item.id);
    showOutput("",false);
    operation = spinnet.tools.startTask.operation(Object.assign({tool:"homebrew"},task),{id:"brew-task",notify:true});
  }
  function packageTask(action,item) {
    if (!["install","upgrade","uninstall","pin","unpin"].includes(action)) return;
    if (["install","upgrade"].includes(action) && item.disabled) return;
    if (action === "upgrade" && (item.pinned || !item.outdated)) return;
    startTask({operation:action,kind:item.kind,name:item.name},action[0].toUpperCase() + action.slice(1) + " " + item.name);
  }
  function actOnPackage(action,item) {
    if (action === "details") details(item);
    else if (action === "activate") {
      if ((s.section === "outdated") && item.pinned) packageTask("unpin",item);
      else if ((s.section === "outdated") && !selected(item)) {
        const selection = cached("selection") || {excluded:[]};
        save("selection",{excluded:(selection.excluded || []).filter(name => name !== model.key(item))});
      }
      else { const primary = model.primary(item); if (primary === "details") details(item); else packageTask(primary,item); }
    } else if (action === "preview") previewPackage(item);
    else if (["uninstall","pin","unpin"].includes(action) && item.isInstalled) packageTask(action,item);
  }
  function previewPackage(item) {
    const action = model.primary(item);
    if (!["install","upgrade"].includes(action)) return;
    s.origin = {section:s.section,query:s.query,kind:s.kind,screen:s.screen === "tap-details" ? "tap-details" : s.section,tap:s.screen === "tap-details" && s.detail ? s.detail.tap : null};
    s.screen = "preview"; s.preview = {task:{operation:action,kind:item.kind,name:item.name},title:"Preview " + action + " · " + item.name};
    request([read({operation:action === "install" ? "previewInstall" : "previewUpgrade",kind:item.kind,names:[item.name]},"preview","preview")]);
  }
  function previewSelection(kind) {
    const names = currentPackages().items.filter(item => item.kind === kind && selected(item)).map(item => item.name);
    if (!names.length || names.length > 50) return;
    s.origin = {section:s.section,query:s.query,kind:s.kind}; s.screen = "preview";
    s.preview = {task:{operation:"upgradeSelected",kind,names},title:"Preview selected " + (kind === "cask" ? "Cask Apps" : "Formulae")};
    request([read({operation:"previewUpgrade",kind,names},"preview","preview")]);
  }
  function ignoredApps() {
    if (!cacheMemo.ignored) {
      try {
        const saved = spinnet.storage.get(prefix + "ignored-apps");
        if (saved != null && (!Array.isArray(saved) || saved.some(item => typeof item !== "string"))) throw new Error("Ignored Apps data is invalid. Repair Plugin Storage before changing it.");
        cacheMemo.ignored = saved || [];
      } catch (error) { s.error = error.message || "Ignored Apps could not be read. Retry after repairing Plugin Storage."; return null; }
    }
    return new Set(cacheMemo.ignored);
  }
  function ignoreApp(identity,ignored) {
    const values = ignoredApps();
    if (!values) return;
    if (ignored) values.add(identity); else values.delete(identity);
    const next = [...values].slice(-256);
    try { spinnet.storage.set({key:prefix + "ignored-apps",value:next}); cacheMemo.ignored = next; }
    catch (error) { s.error = error.message || "Ignored Apps could not be saved. Retry after repairing Plugin Storage."; }
  }
  function returnToList() {
    const route = s.origin || s.returnTo || {section:s.section,query:"",kind:"both"};
    s.section = route.section; s.screen = route.screen || route.section; s.query = route.query; s.kind = route.kind;
    s.origin = null; s.detail = route.tap ? {tap:route.tap} : null; s.preview = null;
    s.read = null; s.queue = [];
    // Returning after a Task always reads reality, including partial failure/Stop.
    if (s.screen === "tap-details") {
      if (s.taskResult || !cached("tap-details")) request([read({operation:"taps",tap:s.detail.tap},"catalog","tap-details")]);
    } else if (s.taskResult || !cached(s.section === "list" ? "inventory" : s.section === "search" ? "search" : s.section === "outdated" ? "upgrades" : s.section === "tap" ? "taps" : s.section === "adopt" ? "adoption" : s.section)) refresh();
    s.taskResult = null;
  }
  function showRaw() {
    let input;
    if (s.screen === "details" && s.detail) input = {operation:"commandOutput",command:"info",kind:s.detail.kind,package:s.detail.name};
    else if (["list","search","outdated","services","tap"].includes(s.screen)) {
      if (s.section === "search" && !model.queryValid(s.query.trim().toLowerCase())) return;
      input = {operation:"commandOutput",command:s.section};
      if (["list","search","outdated"].includes(s.section) && s.kind !== "both") input.kind = s.kind;
      if (s.section === "search") input.package = s.query.trim().toLowerCase();
      if (s.section === "services") input.action = "list";
    }
    if (!input) return;
    s.rawReturn = {screen:s.screen,section:s.section,query:s.query,kind:s.kind,error:s.error}; s.screen = "raw";
    request([read(input,"raw","raw")]);
  }

  const starting = !state || !Object.keys(state).length;
  if (starting || (e.type === "called" && !busy())) navigate(mode);
  if (!busy() && e.type === "field_changed" && e.values) {
    if (e.field === "section" && model.sections.includes(e.values.section) && e.values.section !== s.section) navigate(e.values.section);
    else if (e.field === "query-" + s.section && typeof e.values[e.field] === "string") {
      s.query = e.values[e.field].slice(0,256); reset.push(collectionID());
      if (s.section === "search") {
        s.caches.search = null;
        const query = s.query.trim().toLowerCase();
        if (model.queryValid(query)) request([...(cached("inventory") ? [] : [read({operation:"installed"},"inventory","inventory")]),read({operation:"search",query},"catalog","search")]);
        else { s.read = null; s.queue = []; s.error = query && query.length >= 2 ? "Use 2–64 package-name characters: letters, numbers, +, _, ., @ or -." : ""; }
      }
    } else if (e.field === "kind" && ["both","formula","cask"].includes(e.values.kind)) { s.kind = e.values.kind; reset.push(collectionID()); }
    else if (e.field === "report" && ["doctor","config","version"].includes(e.values.report)) { s.report = e.values.report; refresh("doctor"); }
    else if (e.field === "tap-name" && typeof e.values["tap-name"] === "string") s.tap = e.values["tap-name"].trim().slice(0,129);
    else if (e.field === "adoption-filter" && ["available","ignored"].includes(e.values["adoption-filter"])) { s.adoptionFilter = e.values["adoption-filter"]; reset.push(collectionID()); }
  }
  if (e.type === "source_delivered" && s.read && e.source === s.read.id) {
    const pending = s.read; s.read = null;
    if (e.failure) { s.error = e.failure.message || "Homebrew could not be read. Retry or update the catalog."; s.queue = []; }
    else {
      const result = e.result || {};
      if (save(pending.slot,result)) {
        if (pending.purpose === "details") {
          const item = (result.packages || []).find(item => item.kind === s.detail.kind && item.name === s.detail.name);
          if (!item) s.error = "Package details are unavailable. Refresh its list before trying again.";
        }
        if (pending.purpose === "preview" && (!result.succeeded || result.available === false)) s.notice = result.summary || result.reason || "Homebrew did not approve this preview.";
      }
    }
    nextRead();
  }
  if (e.type === "operation_finished" && e.operation === "brew-task" && s.waiting) {
    s.admitted = e.outcome === "succeeded"; s.waiting = s.admitted;
    if (!s.admitted) s.taskResult = {outcome:e.outcome,reason:e.reason || "Task did not start"};
  }
  if (e.type === "source_delivered" && e.source === "brew-activities" && (busy() || s.taskID)) {
    if (e.failure) s.error = e.failure.message || "Task status is temporarily unavailable.";
    else {
      const activities = Array.isArray(e.result) ? e.result : [];
      const task = s.taskID ? activities.find(item => item.id === s.taskID) : s.waiting && s.admitted ? activities.find(item => item.kind === "task" && item.tool === "homebrew" && !s.seen.includes(item.id)) : null;
      if (task) {
        const endedNow = (s.running || s.waiting) && task.status === "ended";
        s.taskID = task.id; s.waiting = false; s.running = task.status !== "ended";
        showOutput(typeof task.output === "string" ? task.output : (task.log || []).join("\n"),task.output_truncated);
        if (!s.running) {
          s.taskResult = task.result || {outcome:"unknown"};
          if (endedNow && s.catalogRefresh && s.taskResult.outcome === "completed") finishCatalogRefresh(false);
          else if (endedNow && !s.catalogRefresh) refresh(s.returnTo && s.returnTo.section || s.section);
        }
      }
    }
  }

  if (!busy() && e.type === "item_action" && e.collection === collectionID()) {
    if (["list","search","outdated"].includes(s.screen)) {
      const item = currentPackages().items.find(item => e.item && model.id(model.key(item)) === e.item.id);
      if (item) {
        if (e.action === "include" && (s.section === "outdated") && !item.pinned) {
          const selection = cached("selection") || {excluded:[]}, excluded = new Set(selection.excluded || []), name = model.key(item);
          if (excluded.has(name)) excluded.delete(name); else excluded.add(name);
          save("selection",{excluded:[...excluded]});
        } else actOnPackage(e.action,item);
      }
    } else if (s.screen === "services") {
      const service = (cached("services") && cached("services").services || []).find(item => e.item && model.id(item.name) === e.item.id);
      if (service && service.user_owned === true) {
        const action = e.action === "activate" ? (["started","scheduled"].includes(service.status) ? "serviceStop" : "serviceStart") : e.action === "restart" ? "serviceRestart" : null;
        if (action) startTask({operation:action,name:service.name},action.replace("service","") + " " + service.name);
      }
    } else if (s.screen === "tap") {
      const tap = (cached("taps") && cached("taps").taps || []).find(item => e.item && model.id(item.name) === e.item.id);
      if (tap && ["activate","remove","trust","untrust"].includes(e.action)) {
        if (e.action === "activate") {
          s.origin = {section:s.section,query:s.query,kind:s.kind}; s.detail = {tap:tap.name}; s.screen = "tap-details";
          request([read({operation:"taps",tap:tap.name},"catalog","tap-details"),read({operation:"installed"},"inventory","inventory")]);
        } else if (!tap.official) startTask({operation:e.action === "remove" ? "untap" : e.action,tap:tap.name},(e.action === "remove" ? "Remove" : e.action === "trust" ? "Trust" : "Stop trusting") + " " + tap.name);
      }
    } else if (s.screen === "tap-details") {
      const data = cached("tap-details"), tap = data && (data.taps || []).find(item => item.name === s.detail.tap);
      const items = model.packages({operation:"search",packages:tap && tap.packages || []},cached("inventory"));
      const item = items.find(item => e.item && model.id(model.key(item)) === e.item.id);
      if (item) { s.origin = {section:"tap",screen:"tap-details",tap:s.detail.tap,query:s.query,kind:s.kind}; actOnPackage(e.action,item); }
    } else if (s.screen === "adopt") {
      const match = adoptionRows().find(item => e.item && item.id === e.item.id);
      if (match && (e.action === "ignore" || e.action === "restore" || e.action === "activate" && match.ignored)) ignoreApp(match.identity,e.action === "ignore");
      else if (match && e.action === "activate" && match.confidence !== "cannot") {
        s.origin = {section:s.section,query:s.query,kind:s.kind}; s.screen = "preview";
        s.preview = {title:"Preview adoption · " + match.name,adoption:true};
        request([read({operation:"adoptionPreview",target:match.target,name:match.cask},"preview","preview")]);
      }
    }
  }
  if (e.type === "action_chosen") {
    if (e.action === "stop" && s.running && s.taskID) operation = spinnet.activities.stop.operation({id:s.taskID},{id:"stop",notify:true});
    if (!busy()) {
      if (e.action === "back" && s.screen === "raw" && s.rawReturn) {
        const route = s.rawReturn; s.screen = route.screen; s.section = route.section; s.query = route.query; s.kind = route.kind; s.error = route.error;
        s.read = null; s.queue = []; s.rawReturn = null;
      } else if (e.action === "back") returnToList();
      else if (e.action === "raw-output") showRaw();
      else if (e.action === "retry-catalog" && s.screen === "task" && s.catalogRefresh) {
        s.error = ""; startTask({operation:"refreshCatalog"},"Updating Homebrew Catalog");
      } else if (e.action === "local-catalog" && s.screen === "task" && s.catalogRefresh) finishCatalogRefresh(true);
      else if (e.action === "refresh") refresh();
      else if (e.action === "cancel-read") { s.read = null; s.queue = []; s.notice = "Read cancelled. Refresh to retry."; }
      else if (e.action === "update-catalog" && s.screen === "update") startTask({operation:"update"},"Update Homebrew and package catalogs");
      else if (e.action === "cleanup" && s.screen === "cleanup") startTask({operation:"cleanup",days:120},"Clean downloads older than 120 days");
      else if (e.action === "autoremove" && s.screen === "cleanup" && !s.read && autoremoveReady(cached("autoremove"))) startTask({operation:"autoremove"},"Remove unused dependencies");
      else if (["upgrade-formula","upgrade-cask"].includes(e.action) && (s.screen === "outdated")) {
        const kind = e.action === "upgrade-cask" ? "cask" : "formula";
        const chosen = currentPackages().items.filter(item => item.kind === kind && selected(item));
        if (chosen.length && chosen.length <= 50) startTask({operation:"upgradeSelected",kind,names:chosen.map(item => item.name)},"Upgrade " + chosen.length + " selected " + (kind === "cask" ? "apps" : "formulae"));
        else s.error = "Select between 1 and 50 unpinned packages of one kind for this upgrade.";
      } else if (["select-all","select-none"].includes(e.action) && (s.screen === "outdated")) save("selection",{excluded:e.action === "select-none" ? currentPackages().items.map(model.key) : []});
      else if (["preview-formula","preview-cask"].includes(e.action) && (s.screen === "outdated")) previewSelection(e.action === "preview-cask" ? "cask" : "formula");
      else if (e.action === "add-tap" && s.screen === "tap" && model.tapValid(s.tap)) startTask({operation:"tap",tap:s.tap},"Add " + s.tap);
      else if (s.screen === "details" && ["install","upgrade","uninstall","pin","unpin"].includes(e.action)) {
        const item = detailItem(); if (item && model.actions(item).includes(e.action) || item && model.primary(item) === e.action) packageTask(e.action,item);
      } else if (s.screen === "details" && e.action === "preview") { const item = detailItem(); if (item) previewPackage(item); }
      else if (e.action === "confirm-preview" && s.screen === "preview") {
        const result = cached("preview");
        if (!s.read && result && result.succeeded && result.available !== false) {
          if (s.preview.adoption && result.target) startTask({operation:"adopt",target:result.target},"Adopt " + (result.name || "App"));
          else if (s.preview.task) startTask(s.preview.task,s.preview.title.replace("Preview ",""));
        }
      }
    }
  }
  nextRead();

  function detailItem() {
    if (!s.detail || !s.detail.name) return null;
    const result = cached("details"), record = result && (result.packages || []).find(item => item.kind === s.detail.kind && item.name === s.detail.name);
    if (!record) return null;
    return Object.assign({},record,{isInstalled:!!record.installed_version,installationKnown:true});
  }
  function adoptionRows() {
    const result = cached("adoption");
    const ignored = ignoredApps();
    if (!ignored) return [];
    return (result && result.applications || []).flatMap(app => (app.candidates && app.candidates.length ? app.candidates : [{name:"",confidence:"cannot",reason:"No reviewed cask match."}]).map(candidate => ({id:model.id((app.identity || app.target) + ":" + candidate.name),identity:app.identity || app.target,ignored:ignored.has(app.identity || app.target),name:app.name,cask:candidate.name,target:app.target,version:app.version,confidence:candidate.confidence,reason:candidate.reason})));
  }
  function buttons(id,values) { return c.actions({id,actions:values.map(([id,title]) => c.button({id,title}))}); }
  let clipped = false;
  function literal(id,text,title) {
    const raw = String(text || "");
    clipped = clipped || raw.length > 16000;
    return c.text({id,text:raw.slice(-16000),title,format:"output"});
  }
  const content = [], sources = [];
  if (!busy() && !["task","details","preview","tap-details","raw"].includes(s.screen)) content.push(c.row({id:"navigation",content:[c.choiceField({id:"section",title:"Homebrew",choices:model.sections,choiceTitles:model.titles,value:s.section}),buttons("refresh-controls",[["refresh","Refresh"]].concat(["list","outdated","services","tap"].includes(s.screen) || s.screen === "search" && model.queryValid(s.query.trim().toLowerCase()) ? [["raw-output","Raw Output"]] : []))]}));
  if (["details","preview","tap-details","raw"].includes(s.screen)) content.push(buttons("back-controls",[["back","Back"]]));
  if (s.notice) content.push(c.text({id:"notice",text:model.text(s.notice),style:{color:"secondary"}}));
  if (s.read) content.push(c.text({id:"loading",text:s.read.purpose === "autoremove" ? "Checking unused dependencies…" : "Loading…",style:{color:"secondary"}}));
  const browser = ["list","search","outdated","services","tap","adopt"].includes(s.screen);
  if (browser) {
    const bar = [c.textField({id:"query-" + s.section,title:s.screen === "search" ? "Search" : "Filter",value:s.query,placeholder:s.screen === "search" ? "Search packages…" : "Filter this list…",collection:collectionID()})];
    if (["list","search","outdated"].includes(s.screen)) bar.push(c.choiceField({id:"kind",title:"Packages",choices:["both","formula","cask"],choiceTitles:["All","Formulae","Cask Apps"],value:s.kind}));
    content.push(c.row({id:"search-bar",content:bar}));
    let groups = [], actions = [], empty = s.read ? "Loading…" : "No results.", limited = false;
    const query = s.query.trim().toLowerCase();
    if (["list","search","outdated"].includes(s.screen)) {
      const catalog = currentPackages();
      const items = catalog.items.filter(item => (s.kind === "both" || s.kind === item.kind) && (s.screen === "search" || [item.name,item.title,item.description].filter(Boolean).join(" ").toLowerCase().includes(query)));
      limited = !!(catalog.data && catalog.data.truncated);
      groups = model.grouped(items,item => model.group(item,s.screen)).map(group => Object.assign(group,{items:group.items.map(item => {
        const versions = item.installed_version && item.version && item.outdated ? item.installed_version + " → " + item.version : item.installed_version || item.version || "";
        const primary = model.primary(item);
        return {id:model.id(model.key(item)),title:item.title || item.name,subtitle:[item.title && item.title !== item.name ? item.name : "",versions,item.description].filter(Boolean).join(" · ").slice(0,256),accessory:((s.section === "outdated") && item.pinned ? "Unpin" : (s.section === "outdated") && !selected(item) ? "Select" : item.pinned ? "Pinned" : primary === "details" ? item.isInstalled ? "Installed" : "Details" : primary === "install" ? "Install" : "Upgrade"),icon:{symbol:item.kind === "cask" ? "app" : "shippingbox"},actions:(s.screen === "outdated") ? ["activate","details",item.pinned ? "unpin" : "pin"].concat(item.pinned ? [] : ["include"]).concat(primary === "upgrade" ? ["preview"] : []) : model.actions(item),marks:(s.screen === "outdated") && selected(item) ? ["included"] : []};
      })}));
      actions = [c.itemAction({id:"activate",title:"Open",default:true}),c.itemAction({id:"details",title:"Show Details"})];
      if ((s.screen === "outdated")) {
        actions.push(c.itemAction({id:"include",title:"Include in Upgrade",toggle:"included"}));
        const chosen = catalog.items.filter(selected), formulae = chosen.filter(item => item.kind === "formula"), casks = chosen.filter(item => item.kind === "cask");
        const upgradeButtons = [["select-all","Select All"],["select-none","Deselect All"]];
        if (formulae.length && formulae.length <= 50) upgradeButtons.push(["upgrade-formula","Upgrade " + formulae.length + " Formulae"],["preview-formula","Preview Formulae"]);
        if (casks.length && casks.length <= 50) upgradeButtons.push(["upgrade-cask","Upgrade " + casks.length + " Cask Apps"],["preview-cask","Preview Cask Apps"]);
        content.push(buttons("selection-controls",upgradeButtons));
        content.push(c.text({id:"selection-help",text:"Pinned packages are excluded. Formulae and Cask Apps run as separate confirmed Tasks; each selection supports up to 50 packages.",style:{color:"secondary",fontSize:11}}));
      } else actions.push(c.itemAction({id:"uninstall",title:"Uninstall…"}));
      actions.push(c.itemAction({id:"pin",title:"Pin"}),c.itemAction({id:"unpin",title:"Unpin"}),c.itemAction({id:"preview",title:"Preview Changes"}));
      empty = s.read ? "Loading packages…" : s.screen === "search" && query.length < 2 ? "Type at least two characters to search." : !catalog.data ? "Package data is unavailable. Refresh to retry." : (s.screen === "outdated") ? "No available upgrades." : "No matching packages.";
    } else if (s.screen === "services") {
      const data = cached("services"); limited = !!(data && data.truncated);
      const services = (data && data.services || []).filter(item => item.name.toLowerCase().includes(query));
      groups = model.grouped(services,item => ["started","scheduled"].includes(item.status) ? "Running" : "Stopped").map(group => Object.assign(group,{items:group.items.map(item => ({id:model.id(item.name),title:item.name,subtitle:item.status + (item.user_owned === true ? "" : " · Managed outside your user account"),accessory:item.user_owned === true ? (["started","scheduled"].includes(item.status) ? "Stop" : "Start") : "Read Only",actions:item.user_owned === true ? ["activate","restart"] : [],icon:{symbol:"server.rack"}}))}));
      actions = [c.itemAction({id:"activate",title:"Start / Stop Service",default:true}),c.itemAction({id:"restart",title:"Restart Service"})];
      empty = s.read ? "Loading services…" : data ? "No Homebrew services found." : "Services are unavailable. Refresh to retry.";
    } else if (s.screen === "tap") {
      const data = cached("taps"); limited = !!(data && data.truncated);
      groups = [{id:"taps",title:"Package Sources",items:(data && data.taps || []).filter(item => item.name.toLowerCase().includes(query)).map(item => ({id:model.id(item.name),title:item.name,subtitle:item.formula_count + " formulae · " + item.cask_count + " casks",accessory:item.official ? "Official" : item.trusted ? "Trusted" : "Not trusted",actions:item.official ? ["activate"] : ["activate","remove",item.trusted ? "untrust" : "trust"],icon:{symbol:"externaldrive"}}))}];
      actions = [c.itemAction({id:"activate",title:"Browse Tap",default:true}),c.itemAction({id:"remove",title:"Remove Tap…"}),c.itemAction({id:"trust",title:"Trust Tap…"}),c.itemAction({id:"untrust",title:"Stop Trusting Tap…"})];
      content.push(c.row({id:"tap-controls",content:[c.textField({id:"tap-name",title:"Add Tap",placeholder:"owner/repository",value:s.tap}),...(model.tapValid(s.tap) ? [buttons("add-tap-controls",[["add-tap","Add Tap…"]])] : [])]}));
      empty = s.read ? "Loading taps…" : data ? "No matching taps." : "Taps are unavailable. Refresh to retry.";
    } else if (s.screen === "adopt") {
      const data = cached("adoption"); limited = !!(data && data.truncated);
      const titles = {ready:"Ready to Adopt",likely:"Likely Adoptable",unlikely:"Unlikely Adoptions",cannot:"Cannot Adopt"};
      content.push(c.choiceField({id:"adoption-filter",title:"Apps",choices:["available","ignored"],choiceTitles:["Available","Ignored"],value:s.adoptionFilter}));
      groups = model.grouped(adoptionRows().filter(item => item.ignored === (s.adoptionFilter === "ignored") && (item.name + " " + item.cask).toLowerCase().includes(query)),item => titles[item.confidence]).map(group => Object.assign(group,{items:group.items.map(item => ({id:item.id,title:item.name,subtitle:[item.cask,item.version,item.reason].filter(Boolean).join(" · ").slice(0,256),accessory:item.ignored ? "Restore" : item.confidence === "cannot" ? "Unavailable" : "Preview",actions:item.ignored ? ["activate","restore"] : item.confidence === "cannot" ? ["ignore"] : ["activate","ignore"],icon:{symbol:"app.badge"}}))}));
      actions = [c.itemAction({id:"activate",title:"Open",default:true}),c.itemAction({id:"ignore",title:"Ignore App"}),c.itemAction({id:"restore",title:"Restore App"})];
      empty = s.read ? "Finding existing Apps…" : data ? "No matching adoptable Apps." : "App discovery is unavailable. Refresh to retry.";
    }
    const rows = groups.flatMap(group => group.items), start = e.type === "load_range" && e.collection === collectionID() ? Math.max(0,Math.min(rows.length,e.start || 0)) : 0;
    const count = e.type === "load_range" ? Math.max(1,Math.min(600,e.count || 80)) : 80;
    content.push(c.text({id:"result-count",text:rows.length + " results" + (limited ? " · partial results" : ""),style:{color:"secondary",fontSize:11}}));
    const headers = groups.filter(group => group.items.length).map(group => c.section({id:group.id,title:group.title,count:group.items.length}));
    // A 600-row window must still fit the 256 KiB page budget. Details remain
    // available on demand while large windows omit decorative/secondary fields.
    const window = rows.slice(start,start + count).map(row => c.item(count > 200 ? {id:row.id,title:row.title.slice(0,160),accessory:row.accessory,actions:row.actions,marks:row.marks} : row));
    content.push(c.list({id:collectionID(),rows:10,total:rows.length,start,items:window,sections:headers.length ? headers : undefined,actions,emptyText:empty}));
    if (limited) content.push(c.text({id:"partial",text:"This read reached a limit. Hidden packages are not included in a selected upgrade.",style:{color:"secondary"}}));
  } else if (s.screen === "details") {
    const item = detailItem();
    if (item) {
      content.push(c.text({id:"package-title",text:model.text(item.title || item.name),style:{fontSize:20,fontWeight:"semibold"}}));
      content.push(c.text({id:"package-description",text:model.text(item.description || item.name)}));
      content.push(literal("package-metadata",[item.kind === "cask" ? "Cask App" : "Formula",item.tap && "Tap: " + item.tap,item.installed_version && "Installed: " + item.installed_version,item.version && "Available: " + item.version,item.pinned && "Pinned",item.disabled && "Disabled",item.deprecated && "Deprecated",item.auto_updates && "Updates itself",item.homepage && "Homepage: " + item.homepage,item.dependencies && item.dependencies.length && "Dependencies: " + item.dependencies.join(", ")].filter(Boolean).join("\n"),"Details"));
      const primary = model.primary(item), actions = [];
      if (["install","upgrade"].includes(primary)) actions.push([primary,primary === "install" ? "Install…" : "Upgrade…"],["preview","Preview Changes"]);
      if (item.isInstalled) actions.push([item.pinned ? "unpin" : "pin",item.pinned ? "Unpin" : "Pin"],["uninstall","Uninstall…"]);
      actions.push(["raw-output","Raw Output"]);
      content.push(buttons("package-actions",actions));
    }
  } else if (s.screen === "tap-details") {
    const result = cached("tap-details"), tap = result && (result.taps || []).find(item => s.detail && item.name === s.detail.tap);
    if (tap) {
      content.push(c.text({id:"tap-title",text:model.text(tap.name),style:{fontSize:20,fontWeight:"semibold"}}));
      const items = model.packages({operation:"search",packages:tap.packages || []},cached("inventory"));
      const start = e.type === "load_range" && e.collection === collectionID() ? Math.max(0,Math.min(items.length,e.start || 0)) : 0;
      const count = e.type === "load_range" ? Math.max(1,Math.min(600,e.count || 80)) : 80;
      content.push(c.list({id:collectionID(),rows:10,total:items.length,start,items:items.slice(start,start + count).map(item => c.item({id:model.id(model.key(item)),title:item.name,accessory:model.primary(item) === "install" ? "Install" : item.isInstalled ? "Installed" : "Details",actions:model.actions(item)})),emptyText:"This tap has no listed packages.",actions:[c.itemAction({id:"activate",title:"Open",default:true}),c.itemAction({id:"details",title:"Show Details"}),c.itemAction({id:"uninstall",title:"Uninstall…"}),c.itemAction({id:"pin",title:"Pin"}),c.itemAction({id:"unpin",title:"Unpin"}),c.itemAction({id:"preview",title:"Preview Changes"})]}));
      if (tap.truncated) content.push(c.text({id:"partial-tap",text:"The tap package listing is partial."}));
    }
  } else if (s.screen === "preview") {
    const result = cached("preview");
    content.push(c.text({id:"preview-title",text:model.text(s.preview && s.preview.title || "Preview"),style:{fontSize:17,fontWeight:"semibold"}}));
    if (result) {
      content.push(literal("preview-output",[result.summary,result.stdout,result.stderr,...(result.warnings || [])].filter(Boolean).join("\n").slice(-12000),"Homebrew Preview"));
      if (!s.read && result.succeeded && result.available !== false && (s.preview.task || result.target)) content.push(buttons("preview-actions",[["confirm-preview",s.preview.adoption ? "Adopt App…" : "Continue…"]]));
    }
  } else if (s.screen === "task") {
    content.push(c.text({id:"task-title",text:model.text(s.taskTitle),style:{fontSize:17,fontWeight:"semibold"}}));
    const result = s.taskResult;
    content.push(c.text({id:"task-status",text:model.text(s.running ? "Running…" : s.waiting ? s.admitted ? "Waiting for task output…" : s.catalogRefresh ? "Starting catalog update…" : "Waiting for Host confirmation…" : result ? [result.outcome,result.reason,typeof result.exit_status === "number" ? "exit " + result.exit_status : ""].filter(Boolean).join(" · ") : "Task status unavailable"),style:{color:"secondary"}}));
    content.push(literal("task-output",s.output || (s.waiting || s.running ? "Waiting for output…" : result && result.outcome === "completed" ? "Completed with no output." : "No output was produced."),"Output"));
    if (s.truncated) content.push(c.text({id:"output-limit",text:"Showing the latest output; earlier text exceeded the display limit.",style:{color:"secondary"}}));
    if (!s.waiting && !s.running && s.catalogRefresh) content.push(buttons("task-controls",[["retry-catalog","Retry Catalog Update"],["local-catalog","Continue with Local Catalog"]]));
    else if (!s.waiting) content.push(buttons("task-controls",s.running ? [["stop","Stop"]] : [["back","Back to " + model.titles[model.sections.indexOf(s.returnTo && s.returnTo.section || s.section)]]]));
  } else if (s.screen === "raw") {
    const result = cached("raw");
    if (result) {
      content.push(literal("raw-output",result.output || "No output.","Homebrew Output"));
      content.push(c.text({id:"raw-status",text:"Exit status " + result.exit_status,style:{color:"secondary"}}));
      if (result.output_truncated) content.push(c.text({id:"raw-partial",text:"Homebrew output was truncated at the read limit."}));
    }
  } else if (s.screen === "doctor") {
    content.push(c.choiceField({id:"report",title:"Report",choices:["doctor","config","version"],choiceTitles:["Doctor","Configuration","Version"],value:s.report}));
    const result = cached("report");
    if (result) { content.push(literal("report-output",result.output || "No output.","Homebrew Output")); if (result.exit_status !== 0) content.push(c.text({id:"report-status",text:"Exit status " + result.exit_status})); }
  } else if (s.screen === "update") {
    content.push(c.text({id:"update-title",text:"Update Homebrew and package catalogs",style:{fontSize:20,fontWeight:"semibold"}}));
    content.push(c.text({id:"update-help",text:"Fetch the latest Homebrew, formula, cask and tap definitions. Installed packages are upgraded separately."}));
    content.push(buttons("update-actions",[["update-catalog","Update Catalog…"]]));
  } else if (s.screen === "cleanup") {
    content.push(c.text({id:"cleanup-title",text:"Clean up Homebrew",style:{fontSize:20,fontWeight:"semibold"}}));
    content.push(c.text({id:"cleanup-help",text:"Remove cached downloads older than 120 days, or review unused dependencies for removal."}));
    content.push(buttons("cleanup-actions",[["cleanup","Clean Old Downloads…"]]));
    if (!s.read) {
      const result = cached("autoremove");
      const empty = result && result.available === true && result.succeeded === true && result.complete === true &&
        result.no_op === true && Array.isArray(result.packages) && result.packages.length === 0;
      const ready = autoremoveReady(result);
      const status = empty ? "No unused dependencies to remove." : ready ?
        result.packages.length + (result.packages.length === 1 ? " unused dependency can be removed." : " unused dependencies can be removed.") :
        "Unused dependencies could not be checked. Refresh to retry.";
      content.push(c.text({id:"cleanup-status",text:status,style:{color:"secondary"}}));
      if (ready) content.push(buttons("autoremove-actions",[["autoremove","Remove Unused Dependencies…"]]));
    }
  }
  if (s.error) content.push(c.text({id:"error",text:model.text(s.error),style:{color:"red"}}));
  if (clipped) content.push(c.text({id:"display-limit",text:"Showing the latest output; earlier text exceeded the display limit.",style:{color:"secondary"}}));
  if (s.read) { sources.push(spinnet.tools.read.source(s.read.id,s.read.input,{deliver:true})); content.push(buttons("cancel-controls",[["cancel-read","Cancel Read"]])); }
  if (busy()) sources.push(spinnet.activities.list.source("brew-activities",{every:1,deliver:true}));
  const page = {id:pageID(),title:"Homebrew",resizable:{minWidth:720,minHeight:440},content};
  if (sources.length) page.sources = sources;
  const ids = [];
  function collect(nodes) { for (const node of nodes) { ids.push(node.id); if (node.content) collect(node.content); } }
  collect(content);
  const resets = [...new Set(reset)].filter(id => ids.includes(id));
  if (resets.length) page.reset = resets;
  return spinnet.ui.showPage(spinnet.ui.page(page),{state:s,operation});
})()
