# Use a native macOS host

Spinnet's macOS MVP will use Swift with AppKit for global input, non-activating overlays, and system integration, and SwiftUI for settings and host-rendered declarative UI. Electron, Tauri, Flutter, and a shared Rust core were rejected for the MVP because the product's defining interaction depends on low-latency, permission-sensitive macOS behavior; platform neutrality will instead be preserved at the Command and Plugin protocol boundaries.
