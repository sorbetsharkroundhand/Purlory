# Pouch glass and attachment finish

The owner reported that the opaque index did not match the glass workspace and that its top attachment looked cut off. This follow-up keeps the approved top alignment, lateral hover, drag, and long lower taper.

The index now reuses `WorkspaceLiquidGlass.Surface`, including the native glass style, tint, and opaque accessibility fallback, plus the workspace's grain texture. A window-sized material viewport prevents the narrow tab from acquiring separate small-pill optics. Material configuration is cached during geometry animation. An inward index uses the shared opaque fallback over manuscript pixels to avoid stacking glass.

The panel includes the 18-point rounded window corner cutout. Its internal boundary follows that curve, with a 1.5-point edge overlap to cover the native border's antialiasing. Only the exposed outer contour is stroked. Control positions remain relative to the exposed slice, so the corner bridge does not pull the handle into the window. Hover no longer draws an extra rounded capsule behind the grip.

Regression tests first reproduced the absent shared glass and missing corner bridge. Coverage verifies the corner cutout, exclusion of the window interior, window-sized material viewport, matching native material configuration, reduced transparency, and the existing focus/IME/gesture/window lifecycle contracts.

Native capture fixtures use the app's hidden-titlebar layout and a synthetic yellow backing window. Captures are limited to that synthetic window's rectangle; unlike per-window captures, this preserves the real backdrop samples used by glass. No real manuscripts are used.

Verification logs and captures: `.superpowers/sdd/2026-11-15-pouch-glass/`.

## Results

- Focused index, framed/native workspace and motion suites: 48 tests, zero failures, including the opt-in light/dark native captures.
- `swift build`, `swift build --product PurloryBench`, and `scripts/build-purlory-app.sh`: passed.
- Package privacy/notices/icons and `codesign --verify --deep --strict`: passed.
- Isolated launch smoke: clean no-model startup, normal shutdown, no crash report.
- `git diff --check`: passed. The full suite was not repeated for this presentation follow-up; the previous full-suite timing caveat remains documented separately.

Local bundle: `build/Purlory.app`. Executable SHA-256: `9f9f746ca98b40e335f2401ae95ca7b899ded9e0cbce716c7bd8dcb70dd1f82d`. Native previews: `build/pouch-glass-preview/`. No commit, push, or release approval is implied.
