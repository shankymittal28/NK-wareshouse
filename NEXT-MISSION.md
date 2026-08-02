# Next Mission — Owner-side reliability (recorded 2026-08-02, updated after UX mission)

> Update: the *display* half of the P0 was fixed in the Owner Dashboard UX
> mission — stock and khata now show honest loading/failed/stale states, and
> negative values render correctly. What remains below is the *functional*
> half: guarding the data itself.

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
- View/filter/group-by state resets on every load (no persistence).
- Owner surfaces have no pending-sync indicator (⏳ exists only on the staff
  add screen) — the owner can't see queued offline writes.
- Khata has no persistent stale-data badge (stock value card now has one).
- On a failed empty load, the value-card meta line still shows "0 pcs · 0
  entries today" between the '—' headline and the error message.
- Done in UX mission: refresh feedback, loading states, honest failure
  states, 'arrivals'→'entries' label, advance recolored sky, pinch-zoom
  restored.
