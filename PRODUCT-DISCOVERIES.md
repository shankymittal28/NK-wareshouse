# NK Warehouse — Product Discoveries

The memory of NK Warehouse. **Search this file before proposing any improvement.** If a discovery already explains the situation, reuse it instead of rediscovering it. Only non-trivial, reusable findings belong here.

## Template

```
# Product Discovery ###

Type
□ Product  □ UX  □ Workflow  □ Business Process  □ Technical
□ Operational  □ Data Interpretation  □ Assumption Proven Wrong

Evidence
...
Discovery
...
What changed our mind?
...
Old belief
...
New belief
...
Impact
□ Low  □ Medium  □ High
Applies to
□ Receiving  □ Doors  □ Plywood  □ Entire Application  □ Future Modules
Status
□ Active  □ Waiting  □ Superseded  □ Invalidated

→ Next action: Build / Wait / Monitor / Reject
```

## Index

| # | Applies to | Discovery (one line) | Type | Impact | Status | Next |
|---|-----------|----------------------|------|--------|--------|------|
| 001 | Receiving | Source is a per-truck constant, already carried forward | Data Interpretation | Low | Active | Reject |
| 002 | Plywood | Intake is a mixed pile; "repeat last item" would help <10% of lines | Assumption Proven Wrong | Medium | Active | Reject |
| 003 | Receiving | Rack unused because warehouse organization isn't finished | Business Process | Medium | Waiting | Wait |
| 004 | Doors | Near-zero photo use is a reliability bug, not low value | Technical / Assumption Proven Wrong | High | Active | Build |
| 005 | Plywood | The post-quantity placement screen was dead weight | UX / Workflow | Medium | Active | Monitor |

---

# Product Discovery 001

**Type:** ☑ Data Interpretation
**Evidence:** 329 consecutive intake lines — source matches the previous line **99.4%** of the time; the app already remembers the last source per device (`nkg_src`).
**Discovery:** Source is a per-truck constant: set once when the truck arrives, correctly carried forward for every line.
**What changed our mind?** We listed "re-picking the source each line" as a candidate friction; the data cleared it.
**Old belief:** Source selection might be repeated friction worth optimizing.
**New belief:** Source is already frictionless; nothing to build.
**Impact:** ☑ Low
**Applies to:** ☑ Receiving
**Status:** ☑ Active
→ **Next action: Reject** (no build)

---

# Product Discovery 002

**Type:** ☑ Assumption Proven Wrong
**Evidence:** 329 consecutive plywood-IN lines — the next line repeats the previous **brand 36%**, **brand + thickness only 9.4%**. Median 24s/line.
**Discovery:** Incoming plywood is a physically assorted pile; nearly every board is a different spec. The brand → thickness → size pick steps are real work, not redundant taps.
**What changed our mind?** Production measurement of consecutive lines.
**Old belief:** Bulk intake repeats brand/thickness, so a "same as last / repeat last item" shortcut would speed it up.
**New belief:** Repetition is too rare (<1 in 10 lines) to exploit; a repeat-last shortcut would add UI for almost no gain. 24s/line is already fast.
**Impact:** ☑ Medium
**Applies to:** ☑ Plywood ☑ Receiving
**Status:** ☑ Active
→ **Next action: Reject** (no build)

---

# Product Discovery 003

**Type:** ☑ Business Process ☑ Operational
**Evidence:** 0 of 488 production entries recorded a rack/zone. Operator input (Shanky).
**Discovery:** Rack location is never recorded — and the reason is physical, not digital.
**What changed our mind?** Operator explanation resolved an open remove-vs-fix question the data alone couldn't answer.
**Old belief:** Rack is unused either because the feature is inconvenient or because it isn't needed.
**New belief:** Rack is unused because the warehouse hasn't finished organizing into fixed racks — there's nothing stable to record against yet. Recording rack now would create work with no payoff.
**Impact:** ☑ Medium
**Applies to:** ☑ Receiving
**Status:** ☑ Waiting — reopen only when rack organization is complete.
→ **Next action: Wait.** Keep the capability; don't push it. (PD-005 removed the rack *prompt* from the fast intake path, consistent with this, and is reversible for when organization is done.)

---

# Product Discovery 004

**Type:** ☑ Technical ☑ Assumption Proven Wrong
**Evidence:** Photo present on ~0.4% of 488 entries. Operator explanation (Shanky): staff must upload via the phone **gallery**, and photos **fail to appear correctly on the owner side**.
**Discovery:** The near-zero photo usage reflects a broken pipeline, not a lack of need. The door builty / LR receipt photo is a real, valued workflow.
**What changed our mind?** Operator explanation of *why* the number is low.
**Old belief:** Photos are unused → low value → safe to deprioritize or remove.
**New belief:** Photos are unused because the capture/upload/display path is unreliable. **Photo usage statistics are invalid evidence until the pipeline works end-to-end.** This supersedes any "photos unused, so remove them" reasoning.
**Impact:** ☑ High
**Applies to:** ☑ Doors (also the general goods-evidence photo)
**Status:** ☑ Active — failure mode operator-reported, not yet reproduced by us.
→ **Next action: Build** — first reproduce the owner-side failure (capture → upload → does the owner actually see it?), turn it into evidence, then fix as one iteration.

---

# Product Discovery 005

**Type:** ☑ UX ☑ Workflow
**Evidence:** 488 production entries. Rack usage **0%**; the tap-by-tap flow forced a placement screen ("और कुछ?" — rack + photo) plus a Save tap after every incoming line. Median 24s/line.
**Discovery:** Every incoming plywood/hardware line ended on a screen the operator never used, then had to hunt for Save — a dead screen on the highest-frequency workflow.
**What changed our mind?** Production data (0% rack) plus tap-by-tap flow analysis showed the step delivered nothing on this path.
**Old belief:** A final placement step (rack + photo) is a reasonable optional close to an entry.
**New belief:** On incoming plywood/hardware it's pure waste — rack is premature (PD-003) and plywood doesn't need photos (photos matter on the door builty, PD-004). *Justified by rack 0% + plywood-not-needing-photos, NOT by photo usage stats (PD-004 marks those invalid).*
**Impact:** ☑ Medium (every incoming line)
**Applies to:** ☑ Plywood ☑ Receiving
**Status:** ☑ Active — deployed; doors keep the placement/photo step; giving-out unchanged; reversible.
→ **Next action: Monitor** — re-read production after real use: median seconds/line should drop; rack should stay ~0% (confirming it was waste); watch for anyone hunting for the removed photo option on plywood.
