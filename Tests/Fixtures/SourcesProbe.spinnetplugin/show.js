(() => {
const source = spinnet.http.request.source("remote", {method:"GET", url:"https://example.com/weather"}, input.deliver ? {deliver:true} : {});
const binding = spinnet.ui.components.bind("remote", "/json/temperature", {format:"decimal"});
if (event && event.type === "source_delivered") spinnet.ui.toast("Recorded " + event.sequence);
return spinnet.ui.showPage(spinnet.ui.page({id:"weather",title:"Weather",sources:[source],content:[spinnet.ui.components.text({id:"temperature",text:"Waiting",bind:binding})]}), {state: event ? event.sequence : 0});

})()
