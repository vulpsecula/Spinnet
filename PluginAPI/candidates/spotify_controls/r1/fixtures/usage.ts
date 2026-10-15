// SPDX-License-Identifier: MIT
import type { SpotifyControlsSpinnet, SpotifyNextOutcome, SpotifyVolume } from "../spotify-controls";
declare const spinnet: SpotifyControlsSpinnet;
const volume: SpotifyVolume = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"set_volume",arguments:{volume:50}});
const adjusted: SpotifyVolume = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"adjust_volume",arguments:{delta:-5}});
const observed: SpotifyVolume = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"volume"});
const outcome: SpotifyNextOutcome = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"next_checked"});
const toggled: null = spinnet.apps.perform({bundle_id:"com.spotify.client",operation:"play_pause"});
// The stable generic operation accepts JSON, so opt-in input typing is checked
// directly for construction; runtime remains authoritative for numeric bounds.
import type { SpotifyControlInput } from "../spotify-controls";
// @ts-expect-error Volume input is numeric, never a text percent.
const badVolume: SpotifyControlInput = {bundle_id:"com.spotify.client",operation:"set_volume",arguments:{volume:"50"}};
// @ts-expect-error There is no reviewed queue mutation operation.
const badQueue: SpotifyControlInput = {bundle_id:"com.spotify.client",operation:"queue_clear"};
void [volume, adjusted, observed, outcome, toggled, badVolume, badQueue];
