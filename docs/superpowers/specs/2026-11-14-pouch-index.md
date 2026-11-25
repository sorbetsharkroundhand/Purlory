# Tapered pouch index

The owner approved the interactive tapered-index design and requested native implementation on 2026-11-14. This is a presentation change to the existing local workspace tools.

- Align the index with the native window's top-right edge. Show only a small, mostly concealed tab while closed.
- Hover translates the tab outward by six points; it never scales. Clicking or dragging unfolds the same silhouette into an icon rail.
- Use a straight middle and a long lower Bézier taper whose final tangent joins the vertical window edge. Do not use a rounded bottom cap.
- Expose quick note, documents, characters, search, manuscript history, and writing environment. Tooltips and accessibility labels name each icon. Keep all existing tools available through the environment's overflow menu.
- Preserve editor focus, selection, marked text, undo, and all existing document routes. Opening the rail must not resize or reflow the manuscript.
- Use a nonactivating child panel; follow the parent window, hide with it, and move inward when the display edge prevents outward expansion. Keep the existing collapsed-workspace orb independent.
- Honor reduced motion, transparency and contrast. Following the owner's November 15 correction, use the same native glass and tint as the window; fill its top corner cutout and omit the internal border. Retain the shared opaque fallback for reduced transparency and inward presentation over the manuscript, without stacked glass. The grip stays clear on hover; lateral translation provides feedback.

Reference: the owner-approved `purlory-tapered-index.html` visualization in the current chat. Native geometry may adapt to the available screen height, preserving usable icon targets.

Verification: deterministic geometry and gesture tests, native focus/IME/lifecycle regression checks, builds and existing tests, plus synthetic native captures. Real keyboard IME and subjective feel remain owner checks; never use real manuscripts in test fixtures.
