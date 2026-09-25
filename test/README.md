# Web tests (the app shell, `index.html`)

The repository's CI (`.github/workflows/warehouse.yml`) proves the **warehouse
backend** — the SQL schema, its write path and migrations — on every push that
touches `warehouse/**`. It does **not** exercise the web app (`index.html`),
because that is a single static file served by GitHub Pages.

This folder holds a real-browser test for the web layer, run manually.

## `wh_preview_web.cjs` — Owner Warehouse Preview

Drives the owner-only, read-only Warehouse Preview in a real Chromium with the
Supabase calls route-mocked, so it needs no live project and writes nothing
anywhere. It checks:

- **Flag off** (the shipped default before Stage 1A): the app is unchanged and
  the preview stays hidden.
- **Flag on**: the honest wording holds ("Old records suggest…", "Opening not
  verified", "Not available yet"), and the Stage 1B inspection tools work —
  category chips with live counts, multi-word search across the joined
  attributes, each "Show" filter, neutral sorting, the honest
  "Old records below zero" indicator, and review tap-throughs into a material's
  old-records trail.
- **Discipline**: only the three owner READ rpcs are ever called, never a write
  rpc, and there is no horizontal scroll at phone width (360px).

### Run it

```bash
npm i -D playwright-core     # or set PLAYWRIGHT_CORE to an existing install
node test/wh_preview_web.cjs
```

## `wh_movement_web.cjs` — Stage 1D staff Goods In / Out + owner devices

Drives the warehouse **staff movement** app and the owner **device-management**
screen in a real Chromium with every Supabase RPC route-mocked. It checks:
device activation (token kept on the phone, no Supabase Auth), the staff home
hiding rates/value, the category-first material picker, quantity precision, a
multi-line IN, the OUT-over-recorded warning that still allows the movement, the
honest "no verified opening yet → untrusted" note, that **no event is submitted
until Confirm**, that the recorder is **not** in the payload (server derives it
from the credential), idempotent re-submit, and the owner issuing an activation
code / listing / revoking phones. Run it the same way:

```bash
node test/wh_movement_web.cjs
```

Optional environment overrides:

- `PLAYWRIGHT_CORE` — path to a `playwright-core` module folder.
- `CHROMIUM_EXE` — path to a Chromium/Chrome executable (otherwise it looks
  under `PLAYWRIGHT_BROWSERS_PATH`, default `/opt/pw-browsers`).

Exit code is `0` when every assertion passes, `1` on a failed assertion, `2` on
a setup problem (no browser, no playwright-core).
