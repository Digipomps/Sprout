# sprout-macos

macOS client for consuming signed `PortholeAccessContract` handoff artifacts.

Current status:
- Builds as `sprout-macos` via SwiftPM on macOS.
- Imports signed contract JSON files.
- Starts an embedded web session for `web` contracts.
- Previews/copies native binding descriptors for `native` contracts.
- Does not perform bootstrap itself; it consumes the signed output of Sprout bootstrap.
