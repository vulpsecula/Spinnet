const c = spinnet.ui.components;
if (input && input.sdkProbe) {
  spinnet.ui.showPage(spinnet.ui.page({id:"probe",title:"SDK",content:[c.text({id:"available",text:typeof c.adaptive})]}));
} else {
  spinnet.ui.showPage(spinnet.ui.page({id:"cards",title:"Metrics",resizable:true,content:[
    c.adaptive({id:"cards",minCardWidth:280,spacing:12,maxColumns:2,content:[
      c.column({id:"cpu",content:[c.text({id:"cpu-value",text:"12%",style:{fontSize:32,monospacedDigits:true}}),c.textField({id:"note",title:"Note",value:"initial"})]}),
      c.column({id:"memory",content:[c.text({id:"memory-value",text:"Memory pressure and available physical memory",style:{fontSize:24}})]})
    ]}), c.actions({id:"controls",actions:[c.button({id:"refresh",title:"Refresh"})]})
  ]}));
}
