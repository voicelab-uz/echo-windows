# Mobile workspace icons

The mobile template assets use the actual artwork in `frontend/public/icons`, preserving paths, view boxes and stroke widths. XML declarations/DTDs are removed and `currentColor` resolves to black for the Xcode SVG importer.

Mappings: notes → file-text; settings → settings-2; mic → mic; calendar → calendar-days; history → clock-3; card-in-hand → credit-card; info → info; warning → triangle-alert; search → search; copy → copy; delete → trash-2; refresh → rotate-cw.

The frontend has no standalone profile, statistics, sign-out, external-link, chevron, check-circle, monitor or phone SVG in this folder. These mobile symbols are drawn with matching rounded outlines on a 512-unit grid. They are original geometry, not Lucide replacements.

`MobileIcon` applies the adaptive monochrome workspace foreground. Icons stay dark in light mode and light in dark mode, regardless of surrounding button tint. Native disclosure indicators remain under iOS control.
