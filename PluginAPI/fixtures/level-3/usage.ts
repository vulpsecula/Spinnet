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
