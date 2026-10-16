// SPDX-License-Identifier: MIT
import type { AppsNamespace, Spinnet } from "./spinnet-level-2";
export type SpotifyControlInput =
  | { bundle_id: "com.spotify.client"; operation: "play_pause" | "volume" | "next_checked"; arguments?: Record<string, never> }
  | { bundle_id: "com.spotify.client"; operation: "set_volume"; arguments: { volume: number } }
  | { bundle_id: "com.spotify.client"; operation: "adjust_volume"; arguments: { delta: number } };
/** Runtime validates finite integer volume 0..100 and delta -100..100. */
export interface SpotifyVolume { volume: number; }
export interface SpotifyNextOutcome { outcome: "changed" | "unconfirmed" | "no_current_track" | "stopped"; }
export interface SpotifyControlCallable {
  (input: Extract<SpotifyControlInput, {operation:"set_volume" | "adjust_volume"}>): SpotifyVolume;
  (input: {bundle_id:"com.spotify.client";operation:"volume";arguments?:Record<string,never>}): SpotifyVolume;
  (input: {bundle_id:"com.spotify.client";operation:"next_checked";arguments?:Record<string,never>}): SpotifyNextOutcome;
  (input: {bundle_id:"com.spotify.client";operation:"play_pause";arguments?:Record<string,never>}): null;
}
/** Level 3 controls on the existing apps namespace. */
export type SpotifyControlsSpinnet = Omit<Spinnet,"apps"> & {
  readonly apps: Omit<AppsNamespace,"perform"> & { readonly perform: SpotifyControlCallable & AppsNamespace["perform"] };
};
