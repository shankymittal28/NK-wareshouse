# MAIOS Learning System

How MAIOS learns and evolves. The Constitution defines what software must be;
this document defines how evidence changes it. Project-level reality lives in
each project's Learnings file (e.g. NK Warehouse's `WAREHOUSE-LEARNINGS.md`).

Status: validated in one project (NK Warehouse, 2026-08-02). Earns MAIOS-wide
doctrine status only after surviving multiple independent projects — a gate
this document applies to itself.

## MAIOS Design Law — Evidence Has a Half-Life

A feature and the evidence that justified it are different things.

**Every feature must carry an evidence record:** why it was introduced · what evidence justified it · what assumptions that evidence depended on · under what future conditions it must be re-evaluated.

**Evidence is never timeless.** Before any measurement justifies permanent design, classify the operational context that produced it: normal operation · seasonal variation · migration · cleanup · emergency · exceptional event · experiment. Evidence from a temporary phase may justify improving that phase, but never automatically becomes the basis of permanent product design.

**When the phase ends, the evidence expires — the feature does not.** A feature remains until newer, more representative evidence demonstrates that another design serves reality better.

Therefore: never preserve a feature because of history; never remove a feature because of history. Preserve or remove only because current evidence supports doing so.

**Software evolves by replacing evidence, not by replacing opinions.**


### Mechanics

- **Evidence record per feature:** why introduced · evidence · assumptions · re-evaluation conditions.
- **Operational-context classification** before trusting any measurement: normal · seasonal · migration · cleanup · emergency · exceptional · experiment.
- **Temporary vs representative evidence:** temporary-phase evidence may improve that phase; permanent design requires representative evidence.
- **Evidence expiration & re-evaluation triggers:** dated evidence with explicit re-measurement conditions; confidence downgrades when context shifts.
- **Worked example:** NK Warehouse L006 (sticky item-type loop) — migration-phase evidence, feature retained, post-migration re-evaluation trigger recorded.
