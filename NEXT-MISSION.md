# Next Mission — Owner-side reliability (recorded 2026-08-02, not started)

Findings from the dual-agent design review that are **functional, not visual** —
explicitly excluded from the owner-visuals branch and queued for the next mission.
Source: `.impeccable/critique/2026-08-02T13-19-18Z__index-html.md`.

## P0 — The dashboard lies when loading fails
`api()` returns `null` on any failure and `loadStock` coerces it to an empty
list, so a network failure renders **"Stock value ₹0" and "No stock yet."** —
indistinguishable from a genuinely empty warehouse. For a money screen checked
from dead-signal corners of the warehouse this is the worst failure mode.
Direction: separate the error state from the empty state, cache the last good
snapshot, and show a "couldn't refresh — showing older numbers" banner.

## P1 — Destructive-action hygiene
- `delItem` in Manage (staff / brands / sources / zones) deletes instantly with
  no confirmation and no undo.
- Bill lines and `confirmDeduct` allow giving out more than is in stock (the
  sheet warns, but saving isn't blocked).
- `.xdel` delete targets on log rows measure ~21×24px (too small to tap safely).

## P2 — Smaller functional items
- Refresh gives no visible feedback; owner lists have no loading state.
- View/filter/group-by state resets on every load (no persistence).
- "Today" arrivals tile counts give-outs too (`list.length` counts both directions).
- Khata "advance" is shown in green although it is goods owed to a customer.
- `user-scalable=no` blocks pinch-zoom (WCAG 1.4.4) — trivial to change but it
  alters page behavior, so it belongs in this mission, not the visual one.
