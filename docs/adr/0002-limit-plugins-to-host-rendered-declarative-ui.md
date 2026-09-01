# Limit plugins to host-rendered declarative UI

Third-party Plugins may request UI from a constrained declarative vocabulary rendered by the Host, but may not embed arbitrary native UI, HTML, or WebViews. This trades unrestricted presentation for consistent interaction, accessibility, permission enforcement, and process isolation while still supporting the List, Form, ActionPanel, Toast, and Progress experiences required by the initial Plugin model.
