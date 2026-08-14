# MAIOS Document Standard v1

Every printable MAIOS business document inherits this. Individual documents choose
their *class* and their body; they never invent their own header, numbers, typography
or disclosure.

---

## 1. Philosophy (practical)

1. **A document is a declaration, not a screen dump.** It is produced to be detached
   from the app and still hold up.
2. **It states what it knows, how it knows it, and what it does not know.** Missing
   inputs are disclosed, never estimated and never silently omitted.
3. **It reconciles.** Every subtotal ties to its total; every total ties to the summary.
   A reader can spot-check any branch.
4. **It is deterministic.** Same data in, byte-identical document out. Nothing sorts by
   "relevance", nothing depends on who is looking.
5. **It is complete without explanation.** A stranger holding the paper knows whose it
   is, what it covers, when it was true, and where the figures came from.
6. **It is quiet.** No logos, no brand colour, no decoration, no interaction furniture.
   Hierarchy comes from typography, alignment and space.

## 2. Canonical anatomy — three document classes

All classes share the same **header, footer, typography, number rules and disclosure
rules**. They differ only in the body contract.

| Class | What it is | Examples | Body contract |
|---|---|---|---|
| **A — Statement** | Derived aggregate, point in time | Stock Statement, Inventory Valuation, Exception Report, Customer Statement | Summary → Attention → grouped body with subtotals → grand total → notes |
| **B — Record** | One real event, as it happened | Dispatch Challan, Goods Receipt Note, Payment Receipt, Job Card | Parties → line items → totals → **acknowledgement block (signature/received-by)** → notes |
| **C — Register** | Chronological movements over a period | Movement Register, Customer Ledger | Opening balance → dated rows (running balance) → closing balance → period totals → notes |

Universal section order (skip a section only if the class does not define it — never
reorder):

1. **Header** — identity block + metadata block
2. **Summary** (Class A only)
3. **Attention / exceptions** (whenever any material uncertainty exists)
4. **Body**
5. **Totals / reconciliation**
6. **Acknowledgement** (Class B only)
7. **Notes & basis of preparation**
8. **Footer** (repeats on every page)

**Rejected from the standard:** a separate "version" field (the document number encodes
generation time, which *is* the version) and revision history (MAIOS documents are
regenerated, not edited — a corrected issue is a new number carrying `Supersedes: <no.>`).

## 3. Universal header

Every field must justify itself; these did:

| Field | Why it exists |
|---|---|
| Business name | Who is asserting this |
| Unit / premises | Which part of the business |
| Document title | What this is |
| Document number | How to cite it later, uniquely |
| As on / For the period | The time the figures speak for |
| Generated at | When it was produced (deliberately distinct from "as on") |
| Prepared from | Which register or source the figures came from |
| Data status | Live · stale · refresh failed · N entries pending sync |
| Prepared by | The accountable human |

**Document number format:** `<UNIT>/<TYPE>/<YYYYMMDD>-<HHMM>` (IST) — e.g.
`NKW/STK/20260813-0949`. Type codes: `STK` statement, `MOV` movement register,
`CHL` challan, `GRN` goods receipt, `LDG` ledger, `RCP` receipt, `JOB` job card,
`EXC` exception report, `VAL` valuation.

## 4. Universal footer

Repeats on every page, three fields left→right, plus page numbering:

`<Business> · <Unit>` | `<Document number>` | `Generated <date, time IST> · MAIOS`

The trailing `MAIOS` is the provenance mark — the identity signal, carried by structure
and wording rather than a logo.

## 5. Typography system

One family (system sans). **Tabular figures mandatory everywhere** (`font-variant-numeric: tnum`).

| Element | Size / weight | Treatment |
|---|---|---|
| Business name | 19 / 800 | — |
| Unit line | 12.5 / 400 | grey |
| Document title | 15 / 800 | UPPERCASE, tracking .14em |
| Section heading | 12 / 800 | UPPERCASE, tracking .13em, 1.5px bottom rule |
| Group label (brand/party) | 13.5 / 800 | — |
| Body row | 13.5 / 400 (11pt print) | item text indented 14px per level |
| Numeric cell | 13.5 / 400 | right-aligned on one spine, never wrapped |
| Subtotal | 13.5 / 700 | 1px top rule |
| Section total | 14 / 800 | 1.5px top rule |
| Grand total | 17 / 800 | 2.5px rules above and below |
| Notes | 11.5 / 400 | numbered list |
| Footer | 11 / 400 | grey |

Line height 1.45 body, 1.3 in tables. **Colour: black on white.** Exactly one accent is
permitted — negative red `#a3001c`, dark enough to survive photocopying and greyscale.

## 6. Number formatting rules

| Kind | Rule |
|---|---|
| Currency | `₹` prefix, en-IN grouping, whole rupees. If paise are ever required, two decimals **throughout** that document — never mixed |
| Negative currency | Minus **before** the symbol: `-₹28,500`, in negative red. Never parentheses |
| Quantity | Integer, en-IN grouping, unit word after (`pcs`) |
| Percentage | Integer + `%`; one decimal only below 1% |
| Zero | `0` only when the value is genuinely zero |
| **Not known** | `—` (em dash). Never `0`, never blank |
| Not applicable | blank cell |
| Aggregate with no valued members | the words `not valued` — never `₹0` |
| Dates (header) | `13 August 2026` — never numeric-only, which is ambiguous across regions |
| Dates (dense tables) | `13-08-2026` |
| Times | 24-hour with zone: `09:49 IST` |
| Rounding | Never round in the body; round only at display, and state the rule if one applies |

## 7. Disclosure rules (inherited automatically)

- **D1 Coverage.** If a document values or aggregates a set, state how many of the set
  are included: "3 of 4 items valued · 75%".
- **D2 No substitution.** Never estimate a missing input. Show the quantity, withhold
  the value, say why.
- **D3 Exceptions before body.** Any figure a reader would dispute if unexplained
  (negative balance, oversold, out-of-range) appears in Attention *before* the body,
  with the action it requires.
- **D4 Freshness.** State data status in the header; if stale or the refresh failed,
  repeat it in Attention.
- **D5 Pending.** Records not yet synced are declared and counted as excluded.
- **D6 Basis.** Every document ends by naming its source and stating whether it is a
  **book record** or a **physical verification**.
- **D7 Supersession.** A reissued document carries `Supersedes: <document number>`.
- **D8 No hiding behind pagination.** A summary figure must never depend on a page the
  reader might not print.

## 8. Print / PDF standard

- A4 **portrait** by default; landscape only when a table needs more than six numeric columns.
- Margins **14mm** all round (`@page`).
- Column headings repeat on every page (`thead { display: table-header-group }`).
- Rows never split (`tr { break-inside: avoid }`); section headings never orphaned
  (`break-after: avoid`).
- Page numbering `Page X of Y` in the footer region (the browser's own print footer
  satisfies this until a paginator exists).
- No interactive furniture in print — toolbars, buttons and links carry `.noprint`.
- No background fills or heavy rules: must survive a mono laser printer and a photocopy.
- Minimum printed body size **10pt**.
- **PDF is produced by the browser's own print dialog** — no export pipeline.
- Share as **PDF, never a screenshot**. Filename = document number with slashes
  replaced: `NKW-STK-20260813-0949.pdf` (set via the page title).

## 9. Rules every future MAIOS document must obey

1. Declare its class (A/B/C) before design begins.
2. Use the universal header — all nine fields, no substitutions.
3. Use the universal footer, repeating, with the MAIOS provenance mark.
4. Use the typography scale and tabular figures; introduce no new sizes or weights.
5. Use the number rules; a document never invents its own formatting.
6. Every subtotal reconciles to its total, and totals reconcile to the summary.
7. Deterministic ordering, and the ordering is *stated* in the notes.
8. Any uncertainty is disclosed per D1–D8 — no estimates, ever.
9. Exceptions appear before the body, never after.
10. Nothing interactive inside the document body — it is a sheet of paper that happens
    to be on a screen.
11. It must be legible in black and white, at 10pt, on a photocopy.
12. It must be understandable by a reader who has never seen MAIOS.

## 10. Pre-implementation checklist

A new document may not be built until every line is ticked.

- [ ] Class declared (Statement / Record / Register)
- [ ] Purpose stated in one sentence: what decision does this document serve?
- [ ] All nine header fields sourced — including data status and preparer
- [ ] Document number type code assigned
- [ ] Body hierarchy defined, with the sort order chosen and written into the notes
- [ ] Every subtotal → total → summary path reconciles arithmetically
- [ ] Uncertainties enumerated and mapped to D1–D8
- [ ] Attention section defined (what appears there, and the action each entry demands)
- [ ] Basis-of-preparation sentence written (book record or physical verification)
- [ ] Acknowledgement block designed (Class B only)
- [ ] Opening / closing balance logic defined (Class C only)
- [ ] Print check: A4 portrait, headers repeat, no split rows, ≥10pt, mono-safe
- [ ] Phone check: no horizontal overflow at 390px
- [ ] Filename convention wired to the document number
- [ ] Nothing interactive inside the document body

---

## 11. Language rule (MAIOS-wide)

Each surface family has one language, never two:

| Surface | Language | Why |
|---|---|---|
| **Staff workspace** | 100% Hindi | The men on the floor read Hindi; a second language is a second reading tax on every screen, hundreds of times a day |
| **Owner console** | 100% English | An analytical surface, read the way business is read here |
| **Business documents** | 100% English by default | They leave the building — auditors, bankers, suppliers, archives |

No surface is bilingual. A string's language is decided by the surface it appears on,
never by the developer's convenience or the shared function it happens to live in — a
helper used by both families must take its wording from its caller.
