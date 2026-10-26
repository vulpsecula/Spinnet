# Interface scope

These constraints explain why the interface stays bounded. They describe
current design limits; new functionality needs its own demonstrated Plugin
use, authority model and Host release. [Compatibility rules](compatibility.md) describe admission and migration.

| Not offered | Why |
| --- | --- |
| Live Command metadata, such as a title or subtitle updated in the Menu | It needs a script running while the Menu is idle; Spinnet keeps no resident runtime, and a helper lives only for a bounded invocation |
| Menu bar extras | The same: a Plugin's item in the menu bar would need a script kept alive to update it |
| Background schedules | The same: a script that runs on a timer runs when the user asked for nothing, outside any invocation the Host can bound and show |
| Browser extension access | It reaches pages, tabs and history in another App, which no Capability can disclose precisely enough to consent to |
| Arbitrary file operations | Reading, writing or deleting any path reaches far beyond what one Capability can disclose; current offers opening a path and Plugin Storage instead, and exports would come as user-chosen destinations |
| AI tools | Handing a Plugin's operations to a model lets the model, not the user, decide what runs and with what data, which consent to a Capability cannot cover |

Host-owned Effects, Tasks and their Status Item controls are available through
[keep-awake and Host Activities](keep-awake.md); they do not keep Plugin scripts resident.
