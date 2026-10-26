// SPDX-License-Identifier: MIT
// Executable counterpart of usage.ts, checked through the real helper.
(function(){
return spinnet.ui.showPage(spinnet.ui.page({id:'output',title:'Output',sources:[spinnet.tools.read.source('version',{tool:'homebrew',operation:'commandOutput',command:'version'},{deliver:true})],content:[spinnet.ui.components.text({id:'output',text:'Waiting…',format:'output'})]}));
})()
