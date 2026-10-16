// SPDX-License-Identifier: MIT
import type { Globals, Page, AutoremovePreview, SpotifyVolume, SpotifyNextOutcome } from "../../spinnet-level-3";
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

// Level 3 View Actions compose through every public page container.
const removeUnused = spinnet.tools.startTask.action({tool:"homebrew",operation:"autoremove"}, {id:"remove",title:"Remove unused"});
const removeActions = c.actions({id:"remove-actions",actions:[removeUnused]});
const removeRow = c.row({id:"remove-row",content:[removeActions]});
const removeColumn = c.column({id:"remove-column",content:[removeRow]});
const removeCard = c.adaptive({id:"remove-card",content:[removeColumn]});
const removePage: Page = spinnet.ui.page({id:"remove-page",title:"Unused dependencies",content:[removeCard]});
spinnet.ui.showPage(removePage);
const typedRemove: import("../../spinnet-level-3").PerformAction<"tools.startTask"> = removeUnused;
void typedRemove;
const collection = c.list({id:"packages",items:[c.item({id:"package",title:"Unused package"})],
  actions:[c.itemAction({id:"copy",title:"Copy",perform:"clipboard.write"})]});
spinnet.ui.showPage(spinnet.ui.page({id:"collection-actions",title:"Unused packages",content:[collection,removeActions]}));
// Earlier Levels retain their original reviewed Task vocabulary.
// @ts-expect-error autoremove was introduced at Level 3
const levelTwoRemove: import("../../spinnet-level-2").PerformAction<"tools.startTask"> = removeUnused;
void levelTwoRemove;

// The generic catalogue paths carry the same promoted inputs as the namespaces.
declare const globals: Globals;
const genericPreviewInput: import("../../spinnet-level-3").InputOf<"tools.read"> = {tool:"homebrew",operation:"previewAutoremove"};
const genericPreview: import("../../spinnet-level-3").ResultOf<"tools.read"> = globals.requestHostService("tools.read",genericPreviewInput);
const typedPreviewResult: import("../../spinnet-level-3").ResultOf<"tools.read"> = preview;
const genericPreviewSource = spinnet.ui.source("generic-preview","tools.read",genericPreviewInput);
const typedPreviewSource: import("../../spinnet-level-3").Source = genericPreviewSource;
const genericRemove: import("../../spinnet-level-3").RequestedOperation<"tools.startTask"> = {
  perform:"tools.startTask",input:{tool:"homebrew",operation:"autoremove"}
};
spinnet.ui.showPage(spinnet.ui.page({id:"generic-preview-page",title:"Unused dependencies",sources:[genericPreviewSource],content:[removeActions]}),{operation:genericRemove});
// @ts-expect-error earlier Levels do not declare the promoted preview
const levelTwoPreview: import("../../spinnet-level-2").InputOf<"tools.read"> = genericPreviewInput;
// @ts-expect-error mutating Tasks cannot be Host-run sources
spinnet.ui.source("invalid-task","tools.read",{tool:"homebrew",operation:"autoremove"});
// @ts-expect-error App sources read playback; they never execute controls
spinnet.ui.source("invalid-control","apps.perform",{bundle_id:"com.spotify.client",operation:"set_volume",arguments:{volume:50}});
void [genericPreview,typedPreviewResult,typedPreviewSource,levelTwoPreview];
