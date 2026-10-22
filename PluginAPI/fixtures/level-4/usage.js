// SPDX-License-Identifier: MIT
// Executable counterpart of usage.ts, checked through the real helper.
(function(){
const c=spinnet.ui.components; return spinnet.ui.showPage(spinnet.ui.page({id:'tasks',title:'Tasks',content:[c.text({id:'log',text:'Waiting'})],sources:[spinnet.activities.list.source('activities',{every:1,deliver:true})]}));
})()
