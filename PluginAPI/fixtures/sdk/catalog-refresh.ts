// Contract type-check sample, including intentional errors; see ../README.md.
import type {Spinnet,CatalogRefreshInput} from "../../sdk/spinnet";
declare const spinnet:Spinnet;
const input:CatalogRefreshInput={tool:"homebrew",operation:"refreshCatalog"};
spinnet.ui.showPage(spinnet.ui.page({id:"catalog",title:"Updating Catalog",content:[spinnet.ui.components.text({id:"status",text:"Updating…"})]}),{operation:spinnet.tools.startTask.operation(input,{id:"catalog",notify:true})});
// @ts-expect-error Catalog refresh never accepts package selectors.
const invalid:CatalogRefreshInput={tool:"homebrew",operation:"refreshCatalog",name:"wget"};
