import type {Globals, Adaptive} from "../adaptive-layout";
declare const spinnet: Globals["spinnet"];
const c = spinnet.ui.components;
const cards: Adaptive = c.adaptive({id:"cards",minCardWidth:320,spacing:12,maxColumns:2,content:[
  c.column({id:"cpu",content:[c.text({id:"cpu-value",text:"12%"})]}),
  c.column({id:"memory",content:[c.textField({id:"note",title:"Note",value:""})]})
]});
spinnet.ui.showPage(spinnet.ui.page({id:"metrics",title:"Metrics",resizable:true,content:[cards]}));
// @ts-expect-error A Collection is not an adaptive card.
c.adaptive({id:"bad",content:[c.grid({id:"items",items:[]})]});
// @ts-expect-error Nested adaptive containers are not cards.
c.adaptive({id:"bad-nested",content:[cards]});
