# Workspace icons

The `WorkspaceIcon-*.imageset` vector assets are copied from the sibling
`frontend/public/icons` directory. They now cover navigation, onboarding,
microphone/keyboard setup, notes, vocabulary, sharing and status messages.

Paths, view boxes, and stroke widths are preserved. XML declarations/DTDs are
removed and CSS `currentColor` is resolved to black for Xcode's SVG importer.
The asset catalog preserves vectors and marks every image as a template;
`WorkspaceAssetIcon` applies the current SwiftUI foreground style at runtime.
No web renderer or runtime dependency on the frontend folder is required.

`AppIcon` maps semantic symbol names to these vectors, so existing localized
controls use one consistent icon set. `AppLabel` keeps native SwiftUI label
styles and accessibility. Icons without a matching frontend asset (theme,
window controls, arrows, checks, Globe, pinning and specialist professions)
retain SF Symbols rather than borrowing an unrelated image. Pass an explicit
`size` for decorative icons; vector images do not inherit a font's point size.
