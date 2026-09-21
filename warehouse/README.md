# NK Warehouse core — Stage 0

The warehouse movement and stock-truth system: schema, write path and migration tooling.
Nothing here is wired to the live NK app yet, and nothing here touches the existing
Supabase project. Stage 1 is a separate approval.

## What this is

Stock is never a stored balance. It is computed from an opening baseline plus the
effective state of every confirmed line, ordered by the time the goods physically moved:

```
stock(material) = active opening.counted
                + Σ signed effective quantity of confirmed lines, effective_at > opening.effective_at
                + Σ approved adjustment deltas,                    effective_at > opening.effective_at
```

Because it is a query rather than an accumulator, a correction that moves a line from one
material to another removes it from the first and applies it to the second as one fact.
There is no sequence of writes that can half-succeed and no balance that can drift.

Three clocks, three jobs:

| column | meaning | used for |
|---|---|---|
| `effective_at` | when the goods physically moved | stock arithmetic and ordinary history |
| `confirmed_at` | when the person completed the record | accountability |
| `server_received_at` | when NK accepted it | sync questions and audit only |

They are never collapsed. A truck that arrived yesterday and synced this morning belongs
to yesterday's movements, and "when did NK learn this?" is a separate question with its
own answer.

## Layout

```
migrations/      versioned schema, applied in order; every file has a rollback in down/
tools/           legacy import, reconciliation, look-alike report, owner bootstrap
test/            the whole suite: run.sh builds a template database and runs each file
                 against its own fresh copy, so no test can depend on another
```

## Running it

Needs a Postgres 16 or 17 and `psql` on the path.

```
warehouse/test/run.sh                # migrations, then every suite
warehouse/test/rollback.sh           # apply, roll back, re-apply
warehouse/test/import_rehearsal.sh   # the legacy import on synthetic rows
warehouse/test/recovery_drill.sh     # back up, destroy, restore, then operate it
```

`test/000_supabase_stub.sql` recreates locally what Supabase provides: the `anon`,
`authenticated` and `service_role` roles, and `auth.uid()` with the same body Supabase
uses. It is never applied to a real project.

## The write path

No client role holds insert, update or delete on any table. Every write is a function,
one transaction, resolving the acting person from the credential rather than the payload.

| function | who | what it does |
|---|---|---|
| `draft_put(draft_id, rev, doc)` | staff, owner | mirrors an open draft; a revision that is not newer is a no-op |
| `submit_event(doc, rev)` | staff, owner | confirms atomically; idempotent by the device-minted id; refuses a draft the server has moved past |
| `correct_line(line, reason, material, qty, void)` | recorder, owner | appends a correction |
| `add_line(event, material, qty, reason)` | recorder, owner | a line noticed afterwards, visibly marked |
| `correct_event(event, reason, fields)` | recorder, owner | direction and type are owner-only |
| `record_opening(material, counted, at)` | staff, owner | refused if a baseline already exists |
| `supersede_opening(...)` | owner | replaces a wrong baseline, keeping the original |
| `report_count(material, counted, at, note)` | staff, owner | stores the basis as known at that moment |
| `approve_count(count, reason)` | owner | recomputes the basis; returns needs-review if history moved |
| `resolve_count(count, status, reason)` | owner | reject or ask for a recount |
| `set_rate(material, rate)` | owner | with history |
| `create_material(category, attrs)` | staff, owner | idempotent; reports look-alikes, merges nothing |
| `attach_evidence(event, path, ...)` | staff, owner | photographs |
| `activate_device(code, label)` | any signed-in phone | binds it to a person |
| `issue_activation_code(person)` / `revoke_device(device)` | owner | fleet management |

## Person, device, credential

A person is who history refers to. A device is one phone. A credential is one auth user,
belonging to one device.

- "Recorded by Raj" means the person Raj, because the event stores `person_id`.
- Raj may add or replace a phone with no change to any past record.
- A lost phone is revoked by marking one device row. No other device is affected and no
  history is rewritten.
- An unbound phone can do nothing at all: every function resolves credential to device to
  person and refuses when the chain is broken.

### The owner in a dedicated project

The warehouse project has its own auth realm, so an owner session from any other project
cannot sign him in here, and his existing password is never read, copied or exposed. The
deployer runs `wh.bootstrap_owner('Shanky')` once with the service key, which seeds the
owner person and returns one activation code. The owner then creates his own password in
this project, signs in, and redeems the code from his phone. From then on he issues codes
for everyone else. `bootstrap_owner` is revoked from every client role and refuses to run
once an owner device exists.

During the parallel period the app holds two Supabase sessions, one per project, under
separate storage keys, so neither forces a daily login.

## Quantities

Exact decimal, never floating point. Each material carries a unit, the permitted number of
decimals and an optional step, defaulted from its category. Sheets and pieces are whole;
glass is two decimals. A finer quantity than the material permits is refused by the write
path and again by a table trigger. Adding glass or aluminium later is a category row, not a
migration.

## Legacy history

The old rows are copied into `legacy_line` and `legacy_photo`, which the stock calculation
never reads. They appear in a material's trail below the baseline, marked as not counting.
Their recorder stays a plain name, because those writes were never authenticated, and
showing them as an accountable person would fabricate evidence that does not exist.

The import is deterministic: identities are derived from the old grouping key, so running
it twice produces the same materials and adds nothing. Identities that merely look alike
after normalising case, spaces and hyphens are **reported, never merged** — `tools/03_variant_report.sql`
produces that list for the owner to decide on.

## Backups

Supabase's own recovery is a project setting. Independently of it, the drill in
`test/recovery_drill.sh` is the standard this system is held to: back up the database and
the evidence objects, destroy both, restore, and then re-activate a phone, record a real
movement and open its photograph. A restore into a new project issues new keys, which ends
every phone session, so re-activation is part of recovery rather than an afterthought.
