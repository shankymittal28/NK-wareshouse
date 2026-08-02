# NK Warehouse — Warehouse Learnings

Permanent operational knowledge about how Mittal Hardware's warehouse actually works. **Search this file before proposing any improvement.** If a learning already explains the situation, reuse it — do not rediscover it.

Every month the software should get *simpler* and this file should get *deeper*. If both aren't happening, we're optimizing the wrong thing.

## How this learning system works

Every investigation has two equally valid outputs — a **product change**, an **organizational learning**, or both — and sometimes the right outcome is **no code at all**. Success is not "did we ship." It is: **"Did today's work make tomorrow's decisions better?"** If yes, the investigation succeeded even if nothing was built.

**Admission test — record a learning only if it passes:** *If a new engineer or AI joined six months from now, would knowing this stop them from making a bad decision?* If no, don't record it. A bare fact does not qualify — every learning must end in a **Future Rule**. Facts explain the past; rules improve the future.

**Rules are provisional, never permanent truth.** When stronger evidence contradicts a rule, **replace it in place** (edit the rule) and log the change under *Rule revisions* — old understanding → new understanding → the evidence that forced it. **Never append a second, contradictory rule.** Preserve the *reason* the understanding changed, not the obsolete rule.

## Evidence hierarchy (work from the strongest available)

1. **Production behaviour** — database, event logs, usage stats, timings, errors.
2. **Real operations** — watching work, screen/warehouse recordings, photos, shadowing.
3. **Business context** — what the owner knows that the software cannot (warehouse still being organized, a step intentionally skipped, a process planned but not adopted).
4. **Operator feedback** — comments, complaints, suggestions.
5. **Code** — current implementation.
6. **Assumptions** — always weakest.

## Standing rules (harvested from the learnings below)

- **R1 — Never interpret low feature usage without understanding *why* it's low.** Candidates: unnecessary · broken · poor UX · wrong workflow · future business process · no training. Each is a different problem. *(from L004)*
- **R2 — A candidate friction isn't friction until production confirms it.** Don't optimize what the data shows is already fast or already solved. *(from L001, L002)*
- **R3 — Zero usage can be a business-process gap, not a software gap.** Check Level-3 business context (ask the owner) before changing the feature. *(from L003)*
- **R4 — A step that yields nothing on the highest-frequency path is waste.** Remove it from that path; keep the capability where it's actually used and reversible. *(from L005)*
- **R5 — One friction, one improvement, one metric, one deploy, then stop.** Reality gets the next turn. BUILD / WAIT / REMOVE / FIX / DO NOTHING are all valid outcomes.
- **R6 — Classify the operational context before trusting any production measurement.** Ask first: normal business · seasonal · migration · one-time cleanup · exceptional event? Temporary-phase evidence may justify building something that improves today's work — but it is the *evidence* that is temporary, never automatically the feature. Every feature carries its evidence history (why added · what evidence · when to re-evaluate), and its long-term fate is decided by future representative evidence, not by assumptions about the future. *(from the 2026-08-02 migration-bias correction)*

### Rule revisions
When a Standing Rule changes, edit it above and record the supersession here — so there are never two contradictory rules active, and the reason for the change is preserved.

| Date | Rule | Old understanding | New understanding | Evidence that forced it |
|------|------|-------------------|-------------------|-------------------------|
| — | (none yet) | | | |

## Template

```
# Warehouse Learning ###
Date · Workflow · Evidence (+ level) · Observation · Root Cause
Old Belief · New Understanding · Business Impact · Applies To · Status · Future Rule
```

## Index

| # | Applies to | New understanding (one line) | Impact | Status | Next |
|---|-----------|------------------------------|--------|--------|------|
| 001 | Receiving | Source is a per-truck constant, already carried forward | Low | Active | Do nothing |
| 002 | Plywood | Specs vary line-to-line; "repeat last" helps <10% of lines | Medium | Active | Reject |
| 003 | Receiving | Rack unused because the warehouse isn't organized yet | Medium | Waiting | Wait |
| 004 | Doors / photos | Near-zero photo use was broken *client-side* (camera launch + owner token), not the server pipeline | High | Active | Monitor |
| 005 | Plywood | The post-quantity placement screen was dead weight | Medium | Active | Monitor |
| 006 | Receiving | Item type repeats 97.4% — loop restarts at brand, not type | Medium | Active | Monitor |

---

# Warehouse Learning 001

**Date:** 2026-07-30 · **Workflow:** Receiving — picking the source ("From")
**Evidence (L1):** 329 consecutive intake lines — source matches the previous line **99.4%**; the app already remembers the last source (`nkg_src`).
**Observation:** Source is essentially never changed within a truck's unload.
**Root Cause:** Source is a per-truck constant, set once and correctly carried forward.
**Old Belief:** Re-picking the source each line might be repeated friction worth optimizing.
**New Understanding:** It's already frictionless — nothing to build.
**Business Impact:** Low · **Applies To:** Receiving · **Status:** Active
**Future Rule:** Before optimizing a "repeated" action, confirm in production that it actually repeats.

---

# Warehouse Learning 002

**Date:** 2026-07-30 · **Workflow:** Receiving plywood
**Evidence (L1):** 329 consecutive plywood-IN lines — next line repeats brand **36%**, brand + thickness **9.4%**. Median 24s/line.
**Observation:** Incoming plywood is a physically assorted pile; nearly every board is a different spec.
**Root Cause:** Plywood arrives mixed, not batched by SKU. The brand→thickness→size picks are real work, not redundant taps.
**Old Belief:** Bulk intake repeats brand/thickness, so a "repeat last item" shortcut would speed it up.
**New Understanding:** Repetition is too rare (<1 in 10 lines) to exploit; the shortcut would add UI for almost no gain. 24s/line is already fast.
**Business Impact:** Medium · **Applies To:** Plywood, Receiving · **Status:** Active
**Future Rule:** Measure repetition in production before building any "repeat last" shortcut.

---

# Warehouse Learning 003

**Date:** 2026-07-30 · **Workflow:** Receiving — rack / location
**Evidence (L1 + L3):** 0 of 488 entries recorded a rack/zone; owner (business context) confirms the warehouse isn't finished being organized.
**Observation:** Rack location is never recorded.
**Root Cause:** Physical, not digital — there are no stable racks to record against yet, so recording now would create work with no payoff.
**Old Belief:** Rack is unused because the feature is inconvenient or unneeded (a software problem).
**New Understanding:** Rack is unused because of an unfinished **business process**. Keep the capability; don't push it. Reopen when organization is complete. (L005 removed the rack *prompt* from the fast intake path — consistent with this — and is reversible.)
**Business Impact:** Medium · **Applies To:** Receiving · **Status:** Waiting (trigger: rack organization complete)
**Future Rule:** Zero usage can be a business-process gap, not a software gap — check Level-3 business context before touching the feature.

---

# Warehouse Learning 004

**Date:** 2026-07-30 · **Workflow:** Photo attachment (door builty / LR receipt; goods evidence)
**Evidence (L1 + L4):** Photo present on ~0.4% of 488 entries; operator (Shanky) reports staff must upload via the phone **gallery** and photos **fail to appear correctly on the owner side**.
**Observation:** Photo usage is near zero.
**Root Cause:** **Broken implementation, not low value.** The capture/upload/display path is unreliable, so people stopped using it.
**Old Belief:** Photos are unused → low value → safe to deprioritize or remove.
**New Understanding:** Usage is low *because the feature is broken*. **Photo usage stats are invalid evidence until the pipeline works end-to-end** (capture → upload → owner sees it). This supersedes any "photos unused, remove them" reasoning. The door builty photo is a real, valued workflow.
**Business Impact:** High · **Applies To:** Doors, and the general goods-evidence photo · **Status:** Active — investigated & fixed 2026-07-31.
**Resolution (2026-07-31):** Reproduced across all layers. The **server pipeline was healthy** — uploads land in the private bucket, rows link correctly, and owner-read RLS passes (`owner_sees=2, is_owner=true`). The failure was **two client defects**: (1) the camera input had no `capture` attribute, so tapping it opened a chooser not the camera — hence the gallery workaround; (2) `fetchPhoto` had no token refresh/retry, so a stale owner token showed a blank thumbnail with no recovery — hence "can't reliably see." Both fixed and deployed. **Monitor:** confirm the camera launches on a real phone, and that owner thumbnails stop going blank in real use.
**Future Rule:** *Never interpret low feature usage without understanding why usage is low.* (Held up exactly: usage was low because the feature was broken, and the break was client-side, not where the operator assumed.)

---

# Warehouse Learning 005

**Date:** 2026-07-30 · **Workflow:** Receiving plywood / hardware (incoming)
**Evidence (L1 + L5):** 488 entries; rack usage **0%**; tap-by-tap flow forced a placement screen ("और कुछ?" — rack + photo) plus a Save tap after every incoming line.
**Observation:** Every incoming plywood/hardware line ended on a screen the operator never used, then had to hunt for Save.
**Root Cause:** Rack is premature (L003) and plywood doesn't need photos (photos matter on the door builty, L004), so the screen delivered nothing on this path — a dead screen on the highest-frequency workflow.
**Old Belief:** A final placement step (rack + photo) is a reasonable optional close to an entry.
**New Understanding:** On incoming plywood/hardware it's pure waste. Made **quantity the final step** — completing it saves. Doors keep the placement/photo step; giving-out unchanged; reversible. *Justified by rack 0% + plywood-not-needing-photos, NOT by photo usage stats (invalid per L004).*
**Business Impact:** Medium (every incoming line) · **Applies To:** Plywood, Receiving · **Status:** Active — deployed
**Future Rule:** A step that produces nothing on the highest-frequency path is waste — remove it from that path, keep the capability reachable where it's used.

---

# Warehouse Learning 006

**Date:** 2026-08-02 · **Workflow:** Receiving — item-type step ("कौन सी चीज़?")
**Evidence (L1):** 456 consecutive incoming lines — the category repeats line-to-line **97.4%**; Plywood alone is 87.7% of lines. (Brand repeats only 36.8%, consistent with L002.)
**Observation:** After every save the wizard re-asked the item type, which is a per-truck constant, not a per-line decision.
**Root Cause:** Loop restarted one step too early — at a question whose answer almost never changes.
**Old Belief:** Each line should re-confirm what kind of item it is.
**New Understanding:** Item type is sticky like source (L001). The loop now restarts at the first attribute step (brand/door-type/category kept); changing type = one existing पीछे tap, costing 1 extra tap on ~2.6% of lines while saving a decision + tap on ~97.4%.
**Business Impact:** Medium (every incoming line) · **Applies To:** Receiving, all products · **Status:** Active — deployed
**Future Rule:** A wizard loop should restart at the first question whose answer actually changes line-to-line — measure repetition in production before deciding where the loop begins.

---

## Context reclassification — 2026-08-02 (migration bias)

**Owner correction:** NK Warehouse is currently in a **migration phase** — plywood is being moved first from old godowns (hence 87.7% plywood share and 97.4% category repetition), and the sources "Rice Mill 1/2/3, Dukaan, Transport" are temporary migration-verification labels that will disappear when migration completes. None of this represents the next 10 years of operations.

**Reclassified as migration-context evidence (not permanent):**
- **L001** (source per-truck constant) — re-verify with real suppliers post-migration.
- **L002** (assorted plywood, 24s/line, repeat <10%) — re-measure with normal mixed-category deliveries.
- **L006** (item type repeats 97.4% → loop restarts at brand) — **the evidence is temporary; the feature is not.** The implementation stays until representative post-migration data proves it should change. Evidence history: *Why added:* removes a repeated decision on ~97% of migration-phase lines. *Evidence:* 456-line category-repetition query, 2026-08-02, migration context. *Re-evaluate:* after migration completes, re-run the query on post-migration lines only; keep, change, or revert (`loopStart()`, one line) based on what that shows — not on assumptions.

**Future Rule:** now Standing Rule R6 — classify operational context before any measurement drives permanent design.
