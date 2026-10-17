import type {Spinnet,CommandOutputInput} from "../../spinnet-level-6";
declare const spinnet:Spinnet;
const input:CommandOutputInput={tool:"homebrew",operation:"commandOutput",command:"version"};
spinnet.ui.showPage(spinnet.ui.page({id:"output",title:"Output",sources:[spinnet.tools.read.source("version",input,{deliver:true})],content:[spinnet.ui.components.text({id:"output",text:"Waiting…",format:"output"})]}));
// @ts-expect-error A read cannot run an upgrade.
const mutation:CommandOutputInput={tool:"homebrew",operation:"commandOutput",command:"upgrade"};
