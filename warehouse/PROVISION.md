# Provisioning the dedicated warehouse project

Two steps need a person with the Supabase account and a payment method. Nothing in this
file can be done from a tool session, because creating an organisation and choosing a
plan both require the dashboard.

## Step 1 — a separate organisation

At supabase.com/dashboard, create a **new organisation** named `NK Warehouse`.

It must be separate from `Mittal Hardware`, because a Supabase subscription applies to a
whole organisation. Upgrading the existing one would put the Tally mirror and the current
NK data on the same plan and the same billing and lifecycle as the warehouse, which is
the coupling the transition plan exists to avoid.

## Step 2 — the plan, and the exact price

Choose the **Pro** plan for the new organisation, on the smallest compute size.

Before confirming, read the figure Supabase shows on the checkout page. That is the
number that counts. Do not accept a remembered price from anywhere, including from me.

**Do not add Point-in-Time Recovery.** It is a separate, much larger monthly add-on, it
has not been approved, and the independent backups in `BACKUP.md` cover the gap it would
close.

If the figure shown is materially different from about 25 US dollars a month for one base
project, stop and say so rather than confirming.

## Step 3 — the project

In the new organisation, create one project:

| Setting | Value |
|---|---|
| Name | `nk-warehouse` |
| Region | South Asia (Mumbai), `ap-south-1` |
| Plan | the organisation's Pro plan, smallest compute |

Mumbai matches where the existing projects run, so the phones in the godown keep the same
round trip.

## Step 4 — what to send back

Only the **project reference**, the short string in the project URL. Nothing else.

Never paste a service key, a database password, an anon key or a connection string into a
chat. Everything that needs a credential reads it from the environment at the moment it
runs.

## Then, in order, without further approval

1. Apply `warehouse/migrations/` in numerical order.
2. Create the private evidence bucket and its policies.
3. Seed the owner person and one activation code with `wh.bootstrap_owner`, and give the
   code to the owner to redeem once from his own phone.
4. Take a fresh read-only snapshot of the old table, run the import against that snapshot,
   and reconcile it.
5. Run the security and performance advisors and resolve or report every finding.
6. Run the recovery drill against the real project, with test data only.
7. Configure the independent backup on its schedule, to a destination outside this project.

None of that records a real warehouse movement. Real recording is Stage 1 and needs its
own approval.
