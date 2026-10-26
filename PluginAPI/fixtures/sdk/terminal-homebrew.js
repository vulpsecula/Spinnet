// SPDX-License-Identifier: MIT
// Executable counterpart of usage.ts, checked through the real helper.
(function(){
return spinnet.ui.request(spinnet.apps.perform.operation({bundle_id:'com.apple.Terminal',operation:'homebrew',arguments:{command:'upgrade',kind:'cask',package:'firefox'}}));
})()
