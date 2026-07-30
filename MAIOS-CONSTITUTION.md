# MAIOS CONSTITUTION

*The enduring principles by which MAIOS systems are designed. Implementation changes; this does not. When a decision is unclear, this document decides.*

---

## 1. WHY MAIOS EXISTS

Every business runs on a handful of numbers that people must trust without checking: how much stock is on the shelf, how much a customer owes, how much a worker was paid, what was promised and to whom. When those numbers are right, the business runs quietly. When they drift, everything downstream breaks — stock is sold that isn't there, customers are chased for money they've paid, workers are shorted, decisions are made on fiction.

The numbers drift for one reason: ordinary software lets people **overwrite reality silently**. A quantity is a box you type over. A balance is a field you edit. A status is a dropdown you change. Nothing records who changed it, when, or why — and nothing ever checks the number against the world it claims to describe. The screen and the shelf slowly disagree, and by the time anyone notices, the history that could explain the gap is gone.

MAIOS exists to make business records that are **always explainable and always checkable**. Every number it shows can be traced back to specific things that happened, recorded by specific people, at specific times, for specific reasons — and every number is periodically brought back to reality and corrected in the open. The owner should be able to walk in at any hour, ask any figure, and receive not a stored guess but an account: *this is the number, this is everything that produced it, and this is when we last confirmed it against the world.*

That is the whole purpose. Not features. Not automation. **A system of record a business can trust when no one is watching.**

---

## 2. THE BOUNDARY

This Constitution governs one kind of information: **facts a business creates by acting** — the discrete, accountable events it generates itself, and everything computed from them. Inside this boundary the three Laws are absolute.

Three kinds of information sit **outside** the boundary. They are real and necessary, but they obey different rules, and forcing the Laws onto them produces worse software, not better. Every field in a MAIOS system must be placed on the correct side of this line before it is built.

**External reality** — prices, exchange rates, weather, GPS position, the current time. The business does not create these; it observes them. The truth lives outside the system and is stale the moment it is recorded. These are **cached observations**, not accountable claims. You do not "correct" yesterday's price; you fetch today's. Trust here means *freshness*, not history.

**Reference knowledge** — tax slabs, statutory rates, holiday calendars, the product catalogue, unit definitions. These do not *happen*; they *are*. They are set by an authority and change by publishing a new version with an effective date. They are the **rulers** you measure with, and old measurements must keep using the ruler that was in force when they were taken.

**Legally erasable personal data** — personal notes, private messages, sensitive identifiers. The law can compel their deletion, and the subject can demand it. The core Law that records are never destroyed *cannot* apply here. This data is **quarantined**: kept where it can be truly deleted on request, referenced by the trust core only through a stable identifier, never woven into the permanent event log.

Why the separation matters: the trust core is built on the promise that nothing is ever silently changed or destroyed. External data must be refreshed, reference data must be re-versioned, and personal data must be deletable. Mixing any of them into the core either breaks that promise or makes the system unusable. Keep them adjacent, referenced by identity, and governed separately.

---

## 3. THE THREE LAWS

Three principles, each independent of the others, together sufficient. A system that obeys all three can be trusted; a system that violates any one cannot.

### Law I — ACCOUNTABILITY

**Intuition.** Nothing changes by itself. Every difference in what the system claims is true is the result of someone doing something, and that doing must be on the record.

**Wording.** *Every change to a business claim is itself a recorded act that names its author, the time it happened, the time it was recorded, and its reason. Changes to a quantity also name the other side that absorbs the difference. No change may be silent, anonymous, or partial.*

**Consequences.** There is no "edit" and no "delete" of the past — only new acts that add to or reverse earlier ones. A quantity cannot rise in one place without falling somewhere else, so loss and damage are recorded as movements into named accounts, not as numbers that vanish. A single business action that touches several ledgers is one act: it lands everywhere or nowhere.

**Common mistakes.** An `UPDATE` that overwrites a value in place. A `DELETE` that removes a record with no trace. A `created_by` column that is allowed to be null. A quantity that decreases with no counterpart. A multi-step action that can half-complete and leave the ledgers disagreeing.

### Law II — DERIVATION

**Intuition.** The current state of anything — how much, where, what stage, how much owed — is not a fact you store. It is a conclusion you compute from the acts you recorded. Store the acts; calculate the state.

**Wording.** *Everything the system reports as currently true is a reproducible function of recorded acts. State is never an independent, editable value. To reproduce any answer, three things must be pinned: the recorded acts, the interpretation rule in force, and the point in time being asked about.*

**Consequences.** Balances, on-hand quantities, statuses, totals, and scores are never authoritative columns; they are projections that can be dropped and rebuilt from the event log at any time. Because a mistake asks two different questions — *what did we believe then* and *what do we now know was true then* — every act carries both when it happened and when it was recorded. Because the rules of calculation change over time, those rules are themselves versioned data, and replaying an old act uses the rule that was in force when it happened.

**Common mistakes.** A stored `status` enum. A `balance` column that is updated. The same fact written into two tables. A total that is cached but cannot be rebuilt from events. A tax rate or threshold hard-coded as a constant, so last year's numbers silently recompute with this year's rule.

### Law III — RECONCILIATION

**Intuition.** The record is a careful model of reality, not reality itself. People miscount, forget, and lie. The only defense is to go back to the world, look again, and record what you find — including the gap.

**Wording.** *The record is periodically re-checked against the reality it models. Any difference is recorded as another accountable act. The record is never silently adjusted to match reality; reality is observed, and the discrepancy is posted in the open.*

**Consequences.** Every trust-core module has a reconciliation act — a stock count, a bank match, a synchronization with the accounting system of record — that captures the observed reality and the computed variance, stamped with who checked and when. The record never becomes "the truth"; it becomes *auditable and current*. A module with no reconciliation mechanism is, by definition, not yet trustworthy, no matter how clean its events.

**Common mistakes.** No count, match, or sync anywhere in the module. A reconciliation that overwrites the balance to equal the physical figure instead of posting the difference as an adjustment. Treating the last import as gospel rather than as one more attested observation.

---

## 4. THE FIELD CLASSIFIER (A–E)

Before any field is built, route it. Ask the questions in order and stop at the first yes.

1. **Does it record something that happened — by someone, at a time, for a reason?** → **A · Accountable Claim.** It lives in the event log. Source of truth. Never edited, never deleted, corrected only by new acts.
2. **Can it be computed from Category A?** → **B · Derived State.** Never a source of truth. If shown live, compute it (B-projection). If stored for speed or as a snapshot, it must be stamped with its rule-version and as-of, must never be hand-edited, and must be rebuildable from events (B-materialized).
3. **Is it a rule or lookup that simply *is*, set by an authority, changing by version?** → **C · Reference.** Effective-dated. Old versions kept. Referenced, not copied.
4. **Does it come from outside the business and go stale?** → **D · External.** A cached observation with a freshness limit. Re-fetched, not corrected. Disposable.
5. **Is it personal data that may have to be forgotten on request?** → **E · Erasable.** Quarantined where it can be truly deleted. Referenced by the core only through a stable id.

If a field seems to be two categories at once, it is two fields. Split it. **Only Category A belongs in the trust core.** Everything else references A or derives from it.

---

## 5. THE SIX GATE QUESTIONS

Mandatory. Every pull request, every schema change, every new feature answers all six before merge. An answer of "I'm not sure" blocks the change.

1. **Table:** Is this a log of things that happened, or a snapshot of how things are now? *(If a snapshot, it is derived — find the events behind it.)*
2. **Field:** Can this always be computed from events I already record? *(If yes, don't store it.)*
3. **Edit button:** Should this be a new event instead of a change to an old row? *(If it describes what is true in the world, it is.)*
4. **Delete:** What will explain this deletion in six months? *(If nothing, it is forbidden — reverse or tombstone instead.)*
5. **Status field:** Is this a fact I'm asserting, or a conclusion I'm computing? *(If computable, compute it.)*
6. **Trusted number:** Can I reproduce this exact figure later — same events, same rule-version, same as-of? *(If not, pin the inputs until I can.)*

---

## 6. THE TEN RULES

Constitutional articles. Each is a hard constraint, not a suggestion.

**Article 1 — One log per substance.** Each conserved quantity or lifecycle thing has exactly one append-only event table. Receiving, issuing, moving, and adjusting are the same insert with different fields — not separate tables and not in-place updates.

**Article 2 — Every event is witnessed.** Each event row carries `actor`, `occurred_at`, `recorded_at`, and `reason`. Quantity events also carry the `from` and `to` accounts. None of these may be null.

**Article 3 — Never store what you can derive.** Derived values are computed on read. If materialized for performance, they are stamped and rebuildable, and dropping them loses nothing.

**Article 4 — Correct by appending.** Mistakes are fixed by a new event that reverses or supersedes the old one. Existing events are never edited or deleted. The sole exception is Category E data under a lawful erasure request.

**Article 5 — Status is computed.** Lifecycle state is derived from an entity's events. No stored, editable status column.

**Article 6 — Rules are versioned data.** Rates, thresholds, and calculation methods live in effective-dated reference data, never as code constants. Replaying an event uses the rule in force when it occurred.

**Article 7 — Answers are reproducible.** Any reported figure pins the events, the rule-version, and the as-of point that produced it, so it recomputes identically later.

**Article 8 — Cross-ledger actions are atomic.** An action that touches more than one ledger commits entirely or not at all. Partial application is a corrupt state, not a saved one.

**Article 9 — Reconciliation is an event.** Checking the record against reality produces an act carrying the observed value and the variance. Balances are never silently overwritten to match.

**Article 10 — Identity before reference.** A thing is referenced by one canonical identifier, resolved before the event is written. Never by free text.

---

## 7. ARCHITECTURAL SMELLS

Each of these looks harmless in a code review and destroys trust over months. Learn them by sight.

| Smell | Example | Why it destroys trust |
|---|---|---|
| **In-place overwrite** | `UPDATE items SET qty = 40` | The prior value and the reason for the change are gone. The number can no longer be explained, only believed. |
| **Silent delete** | `DELETE FROM movements WHERE id = …` | History now has a hole no one can see. The remaining events no longer sum to reality, and nothing signals why. |
| **Stored status** | `orders.status = 'ready'` | Two sources of truth — the status column and the events — drift apart. The column wins on screen and is wrong. |
| **Cached balance, no rebuild** | `customers.balance` updated by a trigger | When the cache and the events disagree, there is no way to know which is right, so neither can be trusted. |
| **Nullable actor / no reason** | `created_by` nullable | A change no one owns is indistinguishable from tampering. Accountability is void. |
| **One-sided quantity** | stock drops with no counterpart | Goods appear to vanish. Loss, theft, and typos become impossible to tell apart. |
| **Magic constant** | `total * 0.18` in code | Change the rate and every historical figure silently recomputes with the new one. The past becomes editable by deploy. |
| **Duplicate fact** | customer name in three tables | The three copies diverge; "the same" customer becomes three, and every rollup is quietly wrong. |
| **Free-text identity** | joining on `customer = 'Ramesh'` | "Ramesh", "Ramesh F.", "ramesh" split one party into many. Conservation and history break at the seam. |
| **No reconciliation** | module never counts or matches | The derived numbers are internally consistent and externally false, and nothing ever catches it. |
| **Half-committed action** | goods issued, receivable not created | The ledgers disagree from birth. Every report built on them inherits the lie. |

The common thread: each smell either lets the present change without an account, or lets the present float free of the events and the world. Both end the same way — a number on the screen that no one can defend.

---

## 8. MODULE AUDIT TEMPLATE

Every new module answers this **before any code is written**. If a question cannot be answered, the module is not understood well enough to build.

```
MODULE: ______________________

1. REALITY
   What real-world substance does this module preserve?
   Is it a conserved quantity, an identified lifecycle, or both?
   (List each substance separately.)

2. ACCOUNTABLE CLAIMS  (Category A — the trust core)
   For each substance:
   - What is the single event that changes it?
   - What are its accounts / states?
   - What fields make it accountable (actor, times, reason, from/to)?

3. DERIVED STATE  (Category B)
   What will the module report that is computed from the events?
   For each: projection (live) or materialized (stamped + rebuildable)?

4. REFERENCE  (Category C)
   What rules/rates/lookups does calculation depend on?
   How are they versioned and effective-dated?

5. EXTERNAL  (Category D)
   What does the module observe from outside?
   What is its freshness limit?

6. ERASABLE  (Category E)
   What personal data does it hold?
   Where is it quarantined so it can be deleted on request?

7. RECONCILIATION  (Law III)
   How is each substance re-checked against reality?
   What act records the observation and the variance?
   (If there is no answer here, the module is not trustworthy — stop.)

8. CROSS-LEDGER ACTIONS
   Which actions touch more than one substance?
   How are they made atomic?

9. IDENTITY
   What are the canonical identifiers, and how are they resolved
   before events are written?
```

---

## 9. THE MAIOS TEST

One question decides whether a proposed feature belongs in the trust core.

> **Can it state the accountable claim it records, the derived state it produces, and how reality will reconcile it?**

If it can answer all three, build it inside the core, under the Laws.

If it cannot — if it records no clear claim, or produces a number nothing can rebuild, or has no way of ever being checked against the world — then it does not belong in the trust core. It may still exist as a convenience, a report, or an external integration, but it must live outside the boundary and must never become something the business is asked to trust.

*Everything the business trusts is an account of what happened, checked against what is. Anything that cannot be both does not get to be trusted.*
