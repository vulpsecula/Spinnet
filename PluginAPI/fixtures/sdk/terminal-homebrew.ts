// Contract type-check sample, including intentional errors; see ../README.md.
import type {Spinnet, TerminalHomebrewArguments} from "../../sdk/spinnet";
declare const spinnet: Spinnet;
const args: TerminalHomebrewArguments = {command:"upgrade",kind:"cask",package:"firefox"};
spinnet.apps.perform.operation({bundle_id:"com.apple.Terminal",operation:"homebrew",arguments:args});
// @ts-expect-error Arbitrary commands are not part of the interface.
const rejected: TerminalHomebrewArguments = {command:"sh"};
