// SPDX-License-Identifier: MIT
// Contract type-check sample, including intentional errors; see ../README.md.
import type { Globals, Page, AutoremovePreview, SpotifyVolume, SpotifyNextOutcome } from "../../sdk/spinnet";
declare const spinnet: Globals["spinnet"];
const c = spinnet.ui.components;
const cards = c.adaptive({id:"cards", content:[c.text({id:"cpu",text:"CPU"})], fit:{profiles:[
  {id:"compact",minCardWidth:180,minCardHeight:80,overrides:[{id:"cpu",text:"Processor"}]}
]}});
const preview: AutoremovePreview = spinnet.tools.read({tool:"homebrew",operation:"previewAutoremove"});
const source = spinnet.tools.read.source("unused", {tool:"homebrew",operation:"previewAutoremove"});
const page: Page = spinnet.ui.page({id:"metrics",title:"Metrics",content:[cards],sources:[source]});
spinnet.ui.showPage(page);
spinnet.ui.request(spinnet.tools.startTask.operation({tool:"homebrew",operation:"autoremove"}));
const volume: SpotifyVolume = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"set_volume",arguments:{volume:50}});
const outcome: SpotifyNextOutcome = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"next_checked"});
void [preview, volume, outcome];

// View Actions compose through every public page container.
const removeUnused = spinnet.tools.startTask.action({tool:"homebrew",operation:"autoremove"}, {id:"remove",title:"Remove unused"});
const removeActions = c.actions({id:"remove-actions",actions:[removeUnused]});
const removeRow = c.row({id:"remove-row",content:[removeActions]});
const removeColumn = c.column({id:"remove-column",content:[removeRow]});
const removeCard = c.adaptive({id:"remove-card",content:[removeColumn]});
const removePage: Page = spinnet.ui.page({id:"remove-page",title:"Unused dependencies",content:[removeCard]});
spinnet.ui.showPage(removePage);
const typedRemove: import("../../sdk/spinnet").PerformAction<"tools.startTask"> = removeUnused;
void typedRemove;
const collection = c.list({id:"packages",items:[c.item({id:"package",title:"Unused package"})],
  actions:[c.itemAction({id:"copy",title:"Copy",perform:"clipboard.write"})]});
spinnet.ui.showPage(spinnet.ui.page({id:"collection-actions",title:"Unused packages",content:[collection,removeActions]}));
// The generic catalogue paths carry the same current inputs as the namespaces.
declare const globals: Globals;
const genericPreviewInput: import("../../sdk/spinnet").InputOf<"tools.read"> = {tool:"homebrew",operation:"previewAutoremove"};
const genericPreview: import("../../sdk/spinnet").ResultOf<"tools.read"> = globals.requestHostService("tools.read",genericPreviewInput);
const typedPreviewResult: import("../../sdk/spinnet").ResultOf<"tools.read"> = preview;
const genericPreviewSource = spinnet.ui.source("generic-preview","tools.read",genericPreviewInput);
const typedPreviewSource: import("../../sdk/spinnet").Source = genericPreviewSource;
const genericRemove: import("../../sdk/spinnet").RequestedOperation<"tools.startTask"> = {
  perform:"tools.startTask",input:{tool:"homebrew",operation:"autoremove"}
};
spinnet.ui.showPage(spinnet.ui.page({id:"generic-preview-page",title:"Unused dependencies",sources:[genericPreviewSource],content:[removeActions]}),{operation:genericRemove});
// @ts-expect-error mutating Tasks cannot be Host-run sources
spinnet.ui.source("invalid-task","tools.read",{tool:"homebrew",operation:"autoremove"});
// @ts-expect-error App sources read playback; they never execute controls
spinnet.ui.source("invalid-control","apps.perform",{bundle_id:"com.spotify.client",operation:"set_volume",arguments:{volume:50}});
void [genericPreview,typedPreviewResult,typedPreviewSource];

// Generic calls expose all current Spotify result shapes.
const genericVolume: import("../../sdk/spinnet").ResultOf<"apps.perform"> = volume;
const genericNextOutcome: import("../../sdk/spinnet").ResultOf<"apps.perform"> = outcome;
const genericVolumeCall = globals.requestHostService("apps.perform",{bundle_id:"com.spotify.client",operation:"volume"});
const genericNextCall = globals.requestHostService("apps.perform",{bundle_id:"com.spotify.client",operation:"next_checked"});
if (genericVolumeCall && "volume" in genericVolumeCall) {
  const currentVolume: number = genericVolumeCall.volume;
  void currentVolume;
}
if (genericNextCall && "outcome" in genericNextCall) {
  const nextOutcome: SpotifyNextOutcome["outcome"] = genericNextCall.outcome;
  void nextOutcome;
}
void [genericVolume,genericNextOutcome];
