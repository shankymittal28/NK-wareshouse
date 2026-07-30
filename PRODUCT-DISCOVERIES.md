# NK Warehouse — Product Discoveries

The memory of NK Warehouse. Before proposing any improvement, **search this file first** — if a discovery already explains the situation, reuse it instead of rediscovering it.

Only non-trivial, reusable findings are recorded here. Each entry uses the fixed format.

| # | Workflow | Decision in one line | Confidence | Action |
|---|----------|----------------------|------------|--------|
| 001 | Receiving — source | Source is already solved; don't optimize it | High | REJECT (no build) |
| 002 | Receiving plywood | Specs vary line-to-line; a "repeat last item" shortcut isn't worth building | High | REJECT (no build) |
| 003 | Receiving — rack/location | Rack unused because warehouse organization isn't finished; keep capability, don't push it yet | High | WAIT |
| 004 | Photo attachment | Near-zero usage is a reliability bug, not low value; usage stats invalid until fixed | Medium | BUILD |
| 005 | Receiving plywood/hardware | The post-quantity placement screen was dead weight; quantity is now the last step | High | MONITOR |

---

# Product Discovery 001

**Date:** 2026-07-30
**Workflow:** Receiving — picking the source ("From")
**Evidence:** 329 consecutive intake lines analysed. Source matches the previous line **99.4%** of the time; the app already remembers the last source per device (`nkg_src`).
**Observation:** The operator effectively never changes source within a truck's unload, and the software already carries it forward.
**Root Cause:** The workflow is correct — source is a per-truck constant, set once and reused. There is no repeated work here.
**Decision:** Do not add source shortcuts, defaults, or re-prompts. It is already frictionless.
**Result:** Prevented a wasted "smart source" iteration.
**Confidence:** High
**Action:** REJECT (no build)

---

# Product Discovery 002

**Date:** 2026-07-30
**Workflow:** Receiving plywood
**Evidence:** 329 consecutive plywood-IN lines. The next line repeats the previous **brand only 36%**, and **brand + thickness only 9.4%** of the time. Median 24s/line.
**Observation:** Intake is a physically mixed pile — nearly every board is a different spec. The pick steps (brand → thickness → size) are real work, not redundant tapping.
**Root Cause:** Plywood arrives assorted, not batched by SKU. There is no "same as last" pattern strong enough to exploit.
**Decision:** Do **not** build a "repeat last item / same brand+thickness" shortcut — it would help fewer than 1 line in 10, adding UI for little gain. Do not optimize the pick steps; 24s/line is already fast.
**Result:** Killed a plausible-but-wrong optimization (originally hypothesized, falsified by data).
**Confidence:** High
**Action:** REJECT (no build)

---

# Product Discovery 003

**Date:** 2026-07-30
**Workflow:** Receiving — rack / location
**Evidence:** 0 of 488 production entries recorded a rack/zone. Plus operator input (Shanky).
**Observation:** Rack location is never recorded.
**Root Cause:** **Not** because the feature lacks value. The warehouse has not yet completed its rack organization, so there is nothing stable to record against. Recording rack now would create work with no payoff. (Operator-stated; consistent with the data. Resolves the earlier open remove-vs-fix question.)
**Decision:** Keep the rack capability in the system; do not optimize, expand, or push it. Revisit **only after** warehouse rack organization is complete. Note: PD-005 removed the rack *prompt* from the fast plywood-intake path — consistent with "don't make operators do rack work now" — and is reversible for when organization is done.
**Result:** Avoids burdening operators with premature location data; sets a clear trigger (organization complete) for reopening.
**Confidence:** High
**Action:** WAIT

---

# Product Discovery 004

**Date:** 2026-07-30
**Workflow:** Photo attachment (door builty / LR receipt; goods evidence)
**Evidence:** Photo present on ~0.4% of 488 entries. Operator explanation (Shanky): staff must upload via the phone **gallery**, and photos **fail to appear correctly on the owner side**.
**Observation:** Photo usage is near zero.
**Root Cause:** **Implementation failure, not lack of business value.** The capture/upload/display path is unreliable (gallery-only upload; owner-side rendering fails). Low usage reflects the feature being broken, so people stopped using it.
**Decision:** Treat photo as a **reliability bug**. Do **not** use photo usage statistics to judge the feature's value until it works end-to-end (capture → upload → owner sees it). This **supersedes** any reasoning that "photos are unused, so deprioritize/remove them." The door builty photo is a real, valued workflow.
**Result:** Corrects a wrong assumption before it drove a bad decision. Flags the top BUILD candidate. (Mechanism not yet reproduced by us — verify the owner-side failure first, then fix.)
**Confidence:** Medium (strong operator report; failure mode not yet independently reproduced)
**Action:** BUILD (verify, then fix)

---

# Product Discovery 005

**Date:** 2026-07-30
**Workflow:** Receiving plywood / hardware (incoming)
**Evidence:** 488 production entries. After every incoming line, the operator hit a placement screen ("और कुछ?" — rack + photo). Rack usage **0%**; the tap-by-tap flow forced this screen + a Save tap on 100% of lines. Median 24s/line.
**Observation:** Every incoming plywood/hardware line ended on a screen the operator never used, then had to find Save.
**Root Cause:** Rack recording is premature (see PD-003) and plywood boards don't need photos (photos matter for the door builty — see PD-004, which is on the door flow). So the placement screen delivered nothing on the plywood/hardware path — a dead screen on the highest-frequency workflow. *(Justified by rack 0% + plywood-doesn't-need-photos, NOT by photo usage stats, which PD-004 marks invalid.)*
**Decision:** For incoming plywood/hardware, make **quantity the final step** — completing the quantity saves the entry. Doors keep the placement step (builty photo). Giving-out unchanged. One screen + one tap removed per line. Fully reversible.
**Result:** Deployed. Removes ~70 dead-screen transitions/day at current volume.
**Confidence:** High
**Action:** MONITOR — re-read production after real use: median seconds/line should drop; rack should stay ~0% (confirming it was waste); watch for anyone hunting for the removed photo option on plywood.
