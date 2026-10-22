// SPDX-License-Identifier: MIT
// Executable counterpart of usage.ts, checked through the real helper.
(function(){
return spinnet.ui.showPage(spinnet.ui.page({id:'catalog',title:'Updating Catalog',content:[spinnet.ui.components.text({id:'status',text:'Updating…'})]}),{operation:spinnet.tools.startTask.operation({tool:'homebrew',operation:'refreshCatalog'},{id:'catalog',notify:true})});
})()
