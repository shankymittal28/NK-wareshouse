# The warehouse security boundary

One sentence, and a machine checks it on every commit:

> **The warehouse's caretaker owns nothing outside `wh`, and exactly nine
> functions are callable with the public key.**

`test/t_85_boundary.sql` is that check. It reads only the catalogue, so the
same file runs in CI and against the live project:

```
psql "$WH_DB_URL" -f warehouse/test/t_85_boundary.sql
```

Any `NOT OK` line fails the build, and the script raises at the end.

## How a phone becomes a person

```
phone                    a 256-bit secret, held in localStorage, sent in the POST body
  -> public.wh_*(p_token, ...)      the only functions the anon key may call
    -> wh.assume_device(token)      fingerprint -> device -> person -> role
      -> wh.current_person_id()     transaction-local; ends with the request
        -> recorder_person_id       DERIVED. A payload can never supply it.
```

The credential never appears in a URL, a log, an error, or an audit row.
`wh.audit` records the **device**, not the secret. Every refusal is the same
two-word answer, so nothing can be learned by probing.

## What defends what

| Credential | Entropy | Lifetime | Defence |
|---|---|---|---|
| Device token | 256 bits | until revoked, or 90 days unused | entropy alone; guessing is not a threat model |
| Activation code | 50 bits, 10 typed symbols | 15 minutes, single use | expiry, single use, 5 attempts per code, 20 activations per hour shop-wide |

The activation code is the only credential a person types, so it is the only
one worth attacking. It is short-lived, single-use and attempt-capped, and the
throttle is durable because there is no application server to hold a counter:
`wh.activate_device` **returns** a refusal rather than raising, so the counter
commits. A function that raised would silently disable its own rate limit.

The pepper in `wh.secret` is honest about its scope: for a 256-bit device token
it adds nothing that matters, because the entropy already puts the token beyond
guessing, and anyone who can read `wh.device` can read `wh.secret` too. It is
there for the short activation code, where a stray leak of one table should not
immediately be a crackable code. It is not claimed as protection for tokens.

Postgres has no slow key-derivation function without an extension, so the
activation code is protected by shape, not by cost: high entropy, 15-minute
expiry, single use, per-code attempt cap, shop-wide rate limit.

## Rules for anything added to the public API

Every function in `public` named `wh_*` must:

- be owned by `wh_owner`, never by `postgres`;
- be `SECURITY DEFINER` with `search_path = ''` and fully qualified names;
- build no SQL from client text;
- resolve device → person itself, and never trust a person named in a payload;
- have `EXECUTE` revoked from `PUBLIC` **before** it is granted — this project's
  default privileges hand `EXECUTE` on every new function in `public` to anon
  and authenticated, so a new function is callable by the world until we say
  otherwise;
- be added to the named list in `t_85_boundary.sql` by hand. Changing that list
  is a security decision and has to be visible in a diff.

## Owner identity

The owner keeps the Supabase account he already signs in with for NK. There is
no second owner realm and no password is copied anywhere. `wh.jwt_is_owner()`
reads the same signed email claim `public.is_owner()` reads, and the address is
configuration in `wh.setting`, seeded by `wh.bootstrap_owner` at deploy, not a
literal in this repository.

## What this boundary does not cover

The warehouse shares a Supabase project with the Tally mirror, StaffPay, the
travel tables and the legacy NK app. Inside the database the boundary is proven
and enforced. Above the database it is shared:

- a project paused, deleted, or hit by a regional outage takes the warehouse
  with it;
- **a whole-project restore performed to rescue another application silently
  rolls the warehouse back too** — and it must then be restored again from its
  own backup. `test/shared_recovery_drill.sh` proves warehouse-only recovery
  works in place, but nothing stops someone doing the project-wide thing first;
- whoever administers `public` can drop `wh`. The six-hourly independent backup
  bounds the loss; it does not prevent it.

`warehouse/BACKUP.md` carries the recovery procedure.
