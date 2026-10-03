# cis_bridge — documentation

**Version 1.1.0.** One adapter, and one conformance test, per third-party
target.

**Security posture.** The Discord URL is an allow-list, the one player-reachable
handler is rate limited, and both are unit tested rather than asserted. See §7.

---

## §0 — Read this first

Everything on your server that is not us has exactly **one file** here, and
nothing outside this resource knows any of their names.

| Resource | Owns tables | Price |
|---|---|---|
| `cis_libs` | never | free, always |
| `cis_core` | one | free with purchase |
| **`cis_bridge`** | no | free with purchase |
| `cis_keys` | yes | paid, private |

An adapter's whole job is: **check that my target is running, and if it is,
register myself as the capability.** That is small, which is why every adapter
uses the shared helper rather than hand-rolling it — and why the helper's
conditions are tested.

If you are integrating this, **[API.md](API.md)** — every export, its signature,
realm and stability, generated from `api.lua` — is the reference. §2 (the
registration rules) and §3 (the adapter contracts) are what you need next. §4 is
the part that will save you a support thread, and §5 is the boot report, which
exists for the same reason.

API.md is **generated** and `npm run docs:check` fails if it is not what
`api.lua` and the source would produce. A hand-written reference is wrong within
two releases; this one is wrong only if somebody skips the check.

---

## §1 — Why it is a separate resource

**Because `ox_inventory` is GPL-3.0.** That is not a formality. It is on roughly
half of all servers, actively maintained, and a hard dependency of Qbox.
Vendoring it, or modifying it, or wrapping it in a way that is hard to separate
puts our licence and our customers' servers in a position nobody wants to be in.

**One adapter file, optional, never vendored, never modified** is the entire
mitigation — and the isolation is only real if nothing outside that file names
`ox_inventory`. That is an invariant this resource is built around, not a habit.

The same reason, less sharply, applies to everything else here. A target we do
not support is a target a customer cannot use, and the cost of that is paid by
them. One file per target is the unit of support, and the conformance test is
the unit of proof.

---

## §2 — Install and registration

```cfg
ensure cis_libs
ensure cis_core
ensure cis_bridge
```

The configuration this resource reads is §6.5. The live-verification
procedure is **[test/live/RUNBOOK.md](test/live/RUNBOOK.md)**.

**Start order does not matter.** An adapter waits up to 60 seconds for its
target to start, so `ensure cis_bridge` above `ensure ox_target` is fine. This
was not true in 1.0.0: the adapter checked once, gave up, and never registered
for the lifetime of the process — so the platform worked on the machine the
author tested it on and had no target on half the servers that installed it.

### 2.1 The conditions

Every adapter calls the same helper, and each condition has a real failure
behind it:

```lua
Bridge.register(slot, target, configured, probeExport, exportName)
```

| # | Condition | The failure it prevents |
|---|---|---|
| 1 | `configured` matches `target`, or is unset, or is `AUTO` / `NONE` | A server with `ox_target` installed and `qb-target` configured registering the one that is present — working by accident on a server where the operator never tested the other one. `AUTO` and `NONE` are *answers*, not rival names: `AUTO` means "work it out from what is started" and `NONE` is what the config summary reports for a slot nobody configured. Reading either as a resource name made every adapter refuse on a stock server. |
| 2 | `target` reaches `started`, within 60s | Registering against a target nobody has, or against one that is still starting, and then raising on every call in a product that looks installed. |
| 3 | **every** export in `probeExport` exists | Calling a missing export **raises**. One export is not enough to establish compatibility — an adapter that calls six of a target's exports has six ways to be wrong. Every missing name is named in the refusal. |
| 4 | `RegisterCapability` was not refused | A bridge registering twice on a partial restart silently replacing a working provider. |

`probeExport` takes a single name or a list. The list form exists because of
condition 3.

The configuration is checked **before** the wait, because it costs nothing and
answering it first means a server configured for a resource it does not have is
told so at once rather than after a minute of silence.

`missing` is answered immediately and `stopped` is waited on, because FiveM uses
them for different situations: `missing` means the resource is not on the server
at all and no amount of waiting changes that; `stopped` is exactly what a
resource that starts after us looks like from in here.

### 2.2 One export name per adapter, not one per slot

This is the shape decision the whole resource turns on.

Two adapters registering the same export name means the second silently replaces
the first, so **whichever file loaded last answers for every capability** — and a
server with `ox_target` and no `qb-target` ends up served by whichever qb
adapter ran last, which fails on every call and names a resource that is not
even installed.

So `Bridge.register` takes the calling adapter's own export name and refuses
without one. It is a required argument, not a derived one.

### 2.3 First registration wins

Inherited from `cis_libs`. Two products both believing they own the database is
a real failure and it is invisible until something is mysteriously not taking
effect. The attempt is refused and the holder is named.

### 2.4 Publishing the adapter

After a successful registration the adapter calls `Bridge.publish(slot, methods)`
with its own method table. That is what lets the conformance suite test **this
resource's code** rather than whatever capability happens to be answering — see
§4.2, where getting this wrong made four healthy adapters report FAIL.

---

## §3 — The adapters

### 3.1 Targets (client)

Registered into `cis_libs` as the `target` capability.

| Export | Target | Required exports |
|---|---|---|
| `CisBridgeTargetOx` | `ox_target` | `addSphereZone`, `addBoxZone`, `removeZone`, `addLocalEntity`, `removeLocalEntity` |
| `CisBridgeTargetQb` | `qb-target` | `AddBoxZone`, `AddCircleZone`, `RemoveZone`, `AddTargetEntity`, `RemoveTargetEntity` |

```lua
Adapter.create(spec)   --> ok, reason
Adapter.remove(name, spec, isPed)  --> ok, reason
Adapter.exists(name)   --> boolean
Adapter.available()    --> boolean
Adapter.name()         --> 'ox_target' | 'qb-target'
```

`spec` is a plain table: `{ zoneType, name, coords, size, rotation, debug,
targetOptions, options }`, where `zoneType` is `'box' | 'sphere' | 'ped'`.

**Why two files and not one with a flag.** `qb-target` takes a box zone as
*three numbers* and derives `minZ`/`maxZ` from the centre; `ox_target` takes a
*vector3* size. That is a different API, not a parameter. And `qb-target`
accepts `{1, 1, 1}` where `ox_target` wants `{x=, y=, z=}` — the adapter
normalises both, because callers write it either way and neither is wrong.

**Removals return nothing.** Both providers' removal calls return `nil`, so
their return value cannot be used as a success flag — reading it reports failure
for a removal that worked. Success is decided from the adapter's own record,
which it clears on failure as well as success, because a half-removed target the
abstraction still believes in is a leak.

### 3.2 Inventory (server only)

Registered into `cis_libs` as the `inventoryProvider` capability, **behind** the
inventory service in `cis_core`.

| Export | Target | The difference that matters |
|---|---|---|
| `CisBridgeInventoryOx` | `ox_inventory` | GPL-3.0, isolated to this one file |
| `CisBridgeInventoryQb` | `qb-inventory` | Takes **no** metadata (4th arg is a slot flag); reports failure as a **string** — which is truthy in Lua, so every call coerces explicitly |
| `CisBridgeInventoryQs` | `qs-inventory` | `GetItemTotal` rather than a count export |
| `CisBridgeInventoryCodem` | `codem-inventory` | The only one with **no boolean** in its contract: `AddItem` answers counts and `nil` |

**None of these is registered on the client.** The client gets its counts from a
snapshot the server pushes. A client-side provider would be a second source of
truth about what a player is carrying.

Two hops on purpose: the service in `cis_core` is the `name -> amount`
normalisation every consumer depends on, and the provider here is the
third-party call underneath it. Either can be replaced alone.

#### `count` is `GetItemCount`, not `Search`

Both ox_inventory exports answer the question, and they answer **differently**:

| | item the player does not have | inventory that does not exist yet |
|---|---|---|
| `GetItemCount(inv, item)` | `0` | `0` |
| `Search(inv, 'count', item)` | `0` | `false` |

A caller asking "does this player hold three of X" gets `0` from one and `nil`
from the other, and `nil` reads as "I could not tell" — so on the `Search` path
a player who has not finished spawning looks like an inventory outage. The slot
contract promises a number, so the adapter uses the export that returns a number.

On a build too old for `GetItemCount`, the adapter falls back to `Search` and
keeps `false` as `nil` rather than collapsing it to zero, because zero means
"they have none" and `nil` means "unknown" — and that reading gates every dupe
check in the platform.

### 3.3 Databases (server)

Registered into `cis_libs` as the `database` capability. All are **await-style**:
they yield and answer `nil` at their deadline.

| Export | Target | Notes |
|---|---|---|
| `CisBridgeDatabaseOxmysql` | `oxmysql` | **The only one that supports `Cis.db.transaction`** |
| `CisBridgeDatabaseMysqlConnector` | `mysql-connector` | Callback-first, bridged to await. **Not** `mysql-async` — see below |
| `CisBridgeDatabaseGhmatti` | `ghmattimysql` | Deprecated upstream; kept so installing the bridge does not break the last server still running it |
| `CisBridgeDatabaseMongodb` | `mongodb` | **Registers in order to say it is unsupported** |

```lua
Adapter.query(sql, params)  --> rows
Adapter.single(sql, params) --> row|nil
Adapter.scalar(sql, params) --> cell
Adapter.insert(sql, params) --> id
Adapter.update(sql, params) --> affected
Adapter.transaction(queries) --> ok, err
Adapter.ready()             --> boolean
Adapter.name()              --> string
```

#### Transactions, and the bind key they silently dropped

This is the most consequential thing this resource does, and it is worth
reading twice before writing a consumer against it.

`cis_libs` documents a transaction entry as `{ query = sql, params = { ... } }`,
and that is the shape every consumer on this platform writes, because it is the
shape the contract tells them to write.

oxmysql's own type is:

```ts
type TransactionQuery = { query: string | string[]; parameters?: CFXParameters; values?: CFXParameters }
```

There is **no `params`**. Its parser reads `query.parameters or query.values`
and, finding neither, falls back to the transaction's *outer* parameter array.

So an entry written to the documented contract is not rejected. It is **ignored**.
Every `?` in that statement goes unbound, and there is nothing to notice: the
transaction commits and reports success. A migration written as `WHERE id = ?`
with `params = { id }` writes whichever row the unbound bind resolves to, or
fails at the driver, and both look like somebody else's bug for weeks.

The adapter normalises every accepted spelling — `values`, `parameters` and
`params` — into `values`, in oxmysql's own precedence order, so a caller who set
more than one gets the same answer here as it would have got there. The `[sql,
binds]` array form is passed through untouched, because rewriting it would
destroy an object used for named placeholders.

A malformed entry is **refused before the driver opens a transaction**, naming
the index. oxmysql opens the transaction and only then walks the array, so
leaving it to the driver means discovering a bad entry at position 7 after the
connection has committed to six statements.

#### The oxmysql `single` fallback

`oxmysql` grew a `single` export. Builds before it do not have one, and calling
a missing export **raises** — so a server on an older build would get an error
on every `Cis.db.single` call, from a resource that looks like it supports it.

The adapter **probes at registration** and falls back to the first row of a
query. Both halves matter: probing without the fallback registers an adapter
that cannot serve a method it advertised.

The probe captures the **value**, not merely the absence of an error. Indexing a
missing export in FiveM yields `nil` rather than raising, so a bare `pcall`
around the index records "yes, supported" for every build ever seen.

`single` and `transaction` are deliberately **not** in the required-exports list.
Both are probed and answered below — one has a fallback, the other a refusal —
and requiring them would refuse registration on the old installs the fallback
was written for.

#### Why the callback bridge has a deadline

`mysql-connector` is callback-first. A driver that never calls back parks the
caller's coroutine **forever**, and a coroutine parked forever is a request
amplifier — a consumer that retries on `nil` retries into a thread that cannot
finish.

Every await therefore has a ceiling and answers `nil` at it. `nil` is
deliberately indistinguishable from "the driver answered with nothing": a caller
cannot tell them apart, and pretending it can is how a missing row becomes a
hang.

#### Why `transaction` refuses

Only `oxmysql` supports one. A driver that cannot be honest about atomicity has
one option: say no.

The refusal is **immediate**, not after the timeout. A caller holding a write
lock for 15 seconds in order to be told no is worse than an error. And running
the statements one at a time and reporting success — the alternative — turns a
half-applied write into a successful-looking one.

#### `mysql-async` is not supported, and the name was wrong

`mysql-async` exports `mysql_fetch_all`, `mysql_fetch_scalar` and
`mysql_execute`. This adapter calls `mysql_query`, `mysql_scalar`, `mysql_insert`
and `mysql_update`, which are mysql-connector's. Pointed at a mysql-async server
it would register — the resource is started, and the probe export is not the one
that would have caught this — and then raise on the first query.

Naming it accurately is the difference between "not supported" and "supported,
and broken".

#### Why mongodb registers at all

The capability contract is SQL-shaped and MongoDB is not. Rather than pretend,
every method refuses with "not a SQL driver".

It is here because a server running MongoDB would otherwise install the bridge,
find no database capability, and read that as a **broken product** rather than
an **unsupported target**. An adapter that says "not supported" is worth more
than no adapter at all.

### 3.4 Discord (server)

`CisBridgeDiscord`. **The only outbound network request in the whole platform**,
which is why it is a file here rather than a function in a library.

```lua
Adapter.log(webhookUrl, title, message, color, ping)  --> accepted
Adapter.depth()                                        --> depth, dropped
```

The method names are the **slot's** names, lower case, because that is what
`CisRegistry.call('discord', 'log', ...)` passes.

Bounded, rate-limited, and it never blocks the caller: a slow or dead webhook
drops entries rather than growing without limit.

**`depth` returns depth *and* cumulative drops.** Depth alone looks healthy on a
server that has been quietly truncating for an hour.

Registering is not sending. `cis_libs` checks `Config.Printing.UseDiscordLogs`
*before* it ever reaches the capability, so being asked to log **is** the switch.
What is left to decide here is whether the URL is real, and a stock config ships
placeholder URLs — those are discarded silently, because posting to one would
send every log line the server produces to whoever owns the placeholder domain.

#### The embed, and why it was a 400 on every message

The embed used to be built like this:

```lua
thumbnail = cfg.Thumbnail and { url = cfg.Thumbnail } or nil,
footer    = { text = cfg.FooterText, icon_url = cfg.FooterIcon },
```

`cfg` was **always empty**. It was read first as a `DiscordConfig` global, which
lives in cis_core's Lua state and is therefore always `nil` here; then, after
that was fixed, through cis_libs' `GetDiscordConfig`, which hands a foreign
caller an empty table **by design** — it will not re-export webhook
configuration across a resource boundary, because a URL printed into another
resource's console is how a secret ends up in a support ticket.

Either way the footer object was built with both fields `nil`, `json.encode`
dropped both keys, and the payload carried `"footer":{}`. Discord validates
embeds and **rejects one whose `footer` carries neither text nor an icon**, with
a 400 for the whole request.

So every message this platform has ever sent to Discord was a 400. The adapter
counted that as an unhappy endpoint, backed off to sixty seconds, and the
operator saw a webhook that "stopped working some time ago" and no error naming
the cause.

The rule is now: **omit an optional section entirely rather than include it
empty**, and the builder lives in `adapters/discord/embed.lua` so it can be
loaded and tested without the engine.

#### The destination is an allow-list, not a filter

`log(webhookURL, ...)` takes its destination as an **argument**. cis_libs passes
its own configured links, but every other resource on the server can call this
capability with whatever it likes.

A rule that only rejects the literal string `CHANGE-ME` therefore means every
other URL is a live request target, and the resource that supplied it can point
the server wherever it likes — its own collector, an internal service, a
metadata endpoint. That is server-side request forgery built out of a logging
adapter, and it takes nothing more than a call.

So the destination is a property of the adapter:

| | |
|---|---|
| Scheme | `https` only |
| Host | `discord.com`, `discordapp.com`, `canary.discord.com`, `ptb.discord.com` — a table, not a pattern |
| Path | `/api/webhooks/<digits>/<token>` |

Everything else is discarded before it reaches the queue. The worst outcome of a
hostile caller is a dropped log line, which is what a log line is worth to a
caller that should not have had one.

It is written as a table rather than as a Lua pattern because Lua patterns have
no alternation — `(app)` is five literal characters, not a group. The first
version of this rule was a pattern, it matched **nothing**, and the adapter
silently stopped sending. That is the exact failure the empty-footer bug was,
arriving again through a different door, and it is why there is now a test
asserting that a well-formed webhook is *accepted* and not only that a bad one
is refused. There are no cosmetics, because cis_libs
will not re-export them and there is nothing truthful to put in one. An operator
who wants a footer has exactly one function to edit.

---

## §4 — Conformance

```
cis_bridge              # everything
cis_bridge test database  # one target
cis_bridge report       # what is wired up, and what to do about it
```

### 4.1 Why

Third-party resources change under us, and every one of those changes arrived
here as a bug report that looked like a bug in somebody's server:

- `ox_target` changed how it handles zones;
- `qb-target` returns nothing from a removal, so a truthiness test reports
  failure for a removal that worked;
- `oxmysql` grew a `single` export and calling it on an older build raises.

Each was a real incident and each was invisible until somebody's server broke.
An adapter that ships without a test is an adapter whose next upstream release
is a production incident.

### 4.2 What a test is pointed at, which is the whole design

**At this resource's own adapter. Never at a capability that happens to be
answering.**

The inventory tests used to call `Cis.inventory.count`, which cis_libs routes to
the `inventory` slot — the service **cis_core** owns — while cis_bridge fills the
`inventoryProvider` slot underneath it. So the suite was testing somebody else's
code: on a server running cis_bridge without cis_core it reported four broken
inventory adapters on a perfectly healthy install, and on a server with both it
proved nothing about the adapters that are this resource's responsibility.

Every test now reaches the adapter through `Bridge.adapterFor(slot)`. The only
`Cis.*` call left in the suite is the database one, where the abstraction is
genuinely part of what the adapter has to be correct about: cis_libs calls it,
not the adapter directly, and an adapter that serves a direct call and not a
routed one is broken for every consumer on the platform.

### 4.3 The check every adapter gets

`GetCapabilities()` asks cis_libs to work out which methods the registered
provider **cannot serve**. An empty `missing` is cis_libs saying "the thing you
registered answers everything I might call on it" — the exact class of bug this
suite exists to find, checked for free, and checked the same way for all eleven
adapters rather than eleven times over in eleven slightly different ways.

It has also caught the specific defect a per-adapter check cannot: a provider
whose method table answers `Log` where the dispatcher sends `log`.

### 4.4 What a test checks

**The contract, not the implementation.** "Does `addSphereZone` exist" is worth
knowing and is not what breaks. What breaks is: *does a zone I create come back
when I ask whether it exists, and does removing one answer rather than raise.*

### 4.5 What a test does not do

**Nothing is sent and nothing is written to a player.** The tests create and
remove their own names, use obviously-synthetic ids, and touch no inventory — a
conformance test that gives a player an item to see whether the inventory works
is a test that can leave a player with an item.

The one exception is the database test, which creates and drops a table with a
conformance prefix. A test that leaves a table on a customer's database is
litter. It then asks `information_schema` whether the table is gone rather than
assuming the `DROP` worked — and reports `SKIP` rather than `FAIL` if the
database user cannot read `information_schema`, because that has told us nothing
about the adapter.

The Discord test sends nothing at all, which is a real constraint rather than a
stylistic one. Enqueuing a genuine webhook URL would eventually be posted by the
drain loop, so the only URL it touches is the `CHANGE-ME` placeholder — and the
property under test is precisely that the adapter refuses it.

### 4.6 `SKIP` is not `FAIL`

A target that is not installed reports `SKIP`. A server without `qs-inventory` is
not broken, and printing a `FAIL` line for it would bury the one result the
operator came for under a wall of noise they have to read past. The tally
reports skipped checks separately so the operator knows how much of the run
actually executed.

### 4.7 The client half

`Cis.target.*` is a **client** surface. On the server `Cis.target` is `nil` and
every call raises "attempt to call field `add` (a nil value)", which is why the
server marks those slots `SKIP` and asks every connected client to run its own
half. It exists for one specific reason: a target resource can be started on the
server and still be broken on a client. `ox_target` registers on both sides, and
a client that cannot create a zone produces a door that does not respond — which
looks exactly like a server-side permission problem and is not one.

The server and client capability registries are **independent**, so a provider
can pass the server's checks and fail the client's.

A client answers with a table of results. An untrusted client can send anything,
so the server prints and counts, never treats a client's `PASS` as proof of
anything it did not check itself, bounds the payload at 64 rows, truncates every
field before printing it, and **rate limits the handler itself** — see §7.

It also runs on demand from the client console with `cis_bridge_client`.

### 4.8 Programmatic access

```lua
exports['cis_bridge']:RunConformance('oxmysql')   --> boolean
exports['cis_bridge']:GetConformanceResults()     --> { { target, name, ok, skipped, detail }, ... }
```

The results are the answer to "is this a broken adapter or an incompatible
target?", which is the first half of every support thread about a bridge.

### 4.9 What each target is actually checked for

| Target | Checks |
|---|---|
| `ox_target` (client) | serves the whole slot contract, names itself, creates a sphere, creates a box from a vector3 **and** from an array, creates a target on a **real spawned ped**, removes, forgets a removed zone, refuses an unknown name and an unknown zone type without being fatal |
| `qb-target` (client) | the same set, through `qb-target`'s three-number box zone |
| `oxmysql` | query, single, scalar, insert, DDL, the inserted row is visible, **a transaction binds the key the contract documents** and the row is actually there, refuses a malformed entry and names its index, refuses an empty transaction, drops the table, and asks the catalogue |
| `mysql-connector` | query, single, scalar, routed through `Cis.db`, **refuses a transaction**, and the refusal names `oxmysql` |
| `ghmattimysql` | query, scalar, **`update` returns a number of rows and not a result object**, refuses a transaction |
| all four inventories | serves the slot contract, names itself, reports itself available, a missing item counts **zero not nil**, and a nil source or item is `nil` rather than zero |
| `mongodb` | **says it is not a SQL driver**, explains why, and every method refuses rather than raising |
| `discord` | answers `log` and `depth`, refuses a placeholder, nil, and empty webhook, **queues nothing** for any of them, and the queue is bounded with drops counted |

---

## §4.10 — Threads, loops and the frame budget

The project rule is that nothing runs per-frame unless it is drawing, and the
budget is 0.00–0.02 ms idle. This resource has **four loops**, and every one is
accounted for:

| Where | What | Cost |
|---|---|---|
| `shared/bridge.lua` | the start-order wait | one thread per adapter slot at boot, 500 ms poll, 60 s deadline, then it exits |
| `adapters/discord/webhooks.lua` | the webhook drain | one thread, 1000 ms idle, the send interval otherwise |
| `client/conformance.lua` | the model probe | on demand only, 50 ms poll, 5 s deadline |
| `server/report.lua` | the boot printout | one thread, a single `Wait` then it returns |

`test/perf.lua` enforces that account: no `Wait(0)` in shipped code, every loop
waits, and a loop in a file that is not in the account above is a failure. That
last rule is the one that matters — it is what makes the account mean something
rather than being a description of today.

**The model probe used to be `Wait(0)`.** It is the shape everybody writes:

```lua
while not HasModelLoaded(hash) and GetGameTimer() < timeout do
    RequestModel(hash)
    Wait(0)
end
```

`RequestModel` is idempotent, so every call after the first is an identical
native doing nothing, and the frame loop is 250 scheduler wakeups checking a flag
a streamer sets on its own schedule. The request is made once and polled at 50 ms
now — a quarter of the load time even on a bad asset, and far below what a person
notices.

There is no drawing in this resource: no `DrawMarker`, `DrawText3D` or
`DrawRect`, no NUI, no spatial queries. `test/perf.lua` asserts that too, so
adding one becomes a decision rather than a paste.

---

## §5 — The boot report

Printed once at boot, and on demand with `cis_bridge report`.

Support is roughly seventy percent of this company's cost base. The cheapest
thing that moves it is an answer that arrives without a ticket, so every row
carries three things: the outcome, the sentence that explains it, and the next
step.

```
  state    slot            target
  -------  --------------  ---------------------------------------------
  OK       target          ox_target         registered
  OK       database        oxmysql           registered
  DOWN     inventory       -                 qs-inventory is stopped and did not start within 60000ms
  OK       discord         cis_bridge        registered

  capabilities cis_libs can see:
    database           cis_bridge
    inventoryProvider  cis_bridge

  3 of 4 adapter slot(s) registered.

  what to do about the rows above:
    inventory          check the start order in server.cfg: put `ensure qs-inventory` BEFORE `ensure cis_bridge`

  Next: run `cis_bridge test` to exercise every adapter that registered.
```

Five refusals are told apart, because they are five different problems with five
different fixes:

| State | Means | The fix it names |
|---|---|---|
| `MISSING` | not on this server at all | the resources to install and start |
| `DOWN` | installed, never came up | the start order in `server.cfg` |
| `OTHER` | the configuration names a different resource | that resource, by name |
| `NO API` | started, without the exports this adapter needs | the missing export, by name |
| `REFUSED` | another resource already holds the slot | only one provider may hold a slot |

`UNKNOWN` means the adapter never reached its registration call at all — usually
`cis_libs` never becoming ready. It never claims a resource is absent, because it
did not check.

The report also asks cis_libs what **it** can see, which is how a provider that
registered but cannot serve the methods a slot declares becomes visible: healthy
from in here, raising on first real call.

```lua
exports['cis_bridge']:GetBridgeReport()
--> { { slot, label, target, detail, fix }, ... }
```

---

## §6 — Extending

Adding a target is one file plus one test.

1. Create `adapters/<kind>/<target>.lua`.
2. Implement the slot's methods, matching the contract in §3 exactly.
3. `exports('CisBridge<Slot><Target>', function() return Adapter end)` — **a
   unique name**.
4. In a `CreateThread`: `WaitReady(15000)`, then `Bridge.register(...)`, then
   `Bridge.publish(slot, Adapter)` on success.
5. Add a case to the `tests` table in `server/conformance.lua`, keyed by **slot**.
   The runner looks the test up by slot first and by target name second, because
   the discord slot registers against this resource rather than a third party. A
   slot with no test is reported as a **failure**, not silently skipped.
6. Declare the export in `api.lua` or `npm run test:api` fails.
7. Add it to `Bridge.SLOTS` in `shared/bridge.lua` so the boot report has a row.

**Never vendor, never modify, never copy.** Read the target's source if you need
to understand it; the one-file rule is the whole mitigation and copying breaks
it silently.

Verify the export signatures against the target's own source, not against a
remembered API. Every third-party shape this resource adapts was checked against
the upstream repository, and the two that had been written from memory were both
wrong.

---

## §6.5 — Configuration this resource reads

**cis_bridge has no config file of its own.** That is a decision, not an
omission: two config files describing one server is two places to be wrong, and
the disagreement between them is invisible until an adapter silently refuses to
register.

It asks `cis_libs` instead, which asks whichever resource owns the config file —
`cis_core` on a stock install. So a server has exactly **one** place where these
are set, and it is the place the rest of the platform already reads.

Three keys are read. Every value is a **resource name to look for**, never a
connection string and never a database name.

| Key (in `Config.Framework`) | Read as | Accepted values | Default |
|---|---|---|---|
| `Database.Type` | the database slot | `AUTO`, `oxmysql`, `mysql-connector`, `ghmattimysql`, `mongodb` | `AUTO` |
| `Inventory` | the `inventoryProvider` slot | `ox_inventory`, `qb-inventory`, `qs-inventory`, `codem-inventory` | `ox_inventory` |
| `Target.Type` | the `target` slot | `ox_target`, `qb-target` | `ox_target` |

### `AUTO` and `NONE` mean "no opinion", and that is load-bearing

Both are **answers, not rival resource names**, and treating either as a rival is
what stopped a stock install from registering anything at all:

- `AUTO` is the default for `Database.Type`. It means "work it out from what is
  started", which is exactly what the presence path did anyway. Reading it as a
  name made every database adapter compare itself against the string `AUTO`,
  find a mismatch, and refuse — on a server where `oxmysql` was running, with
  nothing wrong anywhere.
- `NONE` is what the config summary reports for a slot nobody configured. Same
  shape of mistake, from the other direction.

A **configured name that is not running** is a different answer from both, and it
is reported as `OTHER`: the operator asked for something and did not get it.

### `Security.AuthorizedResources` is also yours to set

Since cis_libs 2.2.0, an **empty** allow-list refuses every resource. That
includes this one, on all four slots, until it is named:

```lua
Security.AuthorizedResources = { 'cis_core', 'cis_bridge' }
```

The boot report calls this `NO AUTH` and prints the line to add. It is the single
most common first-boot problem and it has a one-line fix that the report prints
for you.

### What this resource does NOT read

- No webhook URLs. Those belong to cis_libs, and it does not re-export them —
  a URL printed into another resource's console is how a secret ends up in a
  support ticket. The consequence is that the Discord adapter has **no cosmetics**
  to render, and an embed with an empty `footer` is a 400. See §3.4.
- No database credentials, no connection strings, no ACE groups.
- No operator feature switches. The only thing that gates outbound logging is
  cis_libs's own `Config.Printing.UseDiscordLogs`, checked before the capability
  is ever called.

---

## §7 — Security notes

| Control | What it does |
|---|---|
| No vendoring | GPL isolation for `ox_inventory` is a file boundary, and a file boundary is only real if nothing crosses it |
| No outbound except Discord | One auditable place for every request this platform makes |
| `UseDiscordLogs` off by default | A placeholder webhook URL is inert no matter what it contains |
| Bounded queue | A dead webhook drops entries rather than growing without limit |
| Bounded client payload | The conformance-results handler is reachable by any connected player; the table is capped at 64 rows and every field is truncated before printing |
| **Rate limit on the client handler** | That same handler prints to the console on every accepted call. Five seconds per source, refusals counted rather than logged, `playerDropped` cleanup |
| **Validate before announcing** | A payload with no valid rows prints **nothing** — not a header, not a summary, not a name. The previous version printed a report header before looking at a single row, so junk produced a block of console that reads exactly like a report arrived |
| **Rows counted before they are shown** | Junk rows do not consume the 64-row budget, so 10,000 of them cannot displace the one real result |
| **Client command cooldown** | Ten seconds. It allocates a ped and four zones per run and is reachable by any player |
| **Webhook host allow-list** | The platform's only outbound request can only reach Discord. Not a filter for the placeholder string — an allow-list of four hosts plus a webhook-shaped path |
| Clock failure falls **closed** | If the clock is absent, nil, a string, or raises, the cooldown refuses rather than opening |
| Conformance sends nothing | A test that mutates a customer's data is a support ticket |
| Console-only command | `cis_bridge` is `restricted`. It prints the `add_ace` line and lets the owner decide rather than granting itself access to somebody's server |
| No secrets in the report | Names of third-party resources only. No webhook URLs, no credentials, no player identifiers |

### 7.1 The one player-reachable surface

This resource has exactly **one** net event handler a player can reach:

```
cis_bridge:server:conformanceResults   (client -> server)
```

Everything else a player can do to it, they can do to a resource that owns no
data: it registers capabilities it has already proved it needs, creates and drops
one conformance-prefixed database table on request, and draws one diagnostic.

Even so, that handler has three defences, because it is the only place where an
attacker with a Lua executor can make the **server** do something:

| Defence | Against |
|---|---|
| Payload must be a table, ≤ 64 rows | A malformed or enormous packet reaching the printing loop |
| Every string truncated (46 / 120 chars) | Terminal escape sequences and log-line injection |
| **Per-source cooldown, 5s** | A flood that does not crash anything but scrolls the operator's only window past the report they asked for |

The cooldown lives in `server/ratelimit.lua` and has its own suite. Three
properties of it are asserted rather than assumed, because each is a way for a
guard to quietly stop guarding:

- **per source, not global** — a global guard lets one player lock everyone else
  out of the report, which turns a flood control into a denial of the feature;
- **forget on `playerDropped`** — FiveM recycles server ids, so without cleanup
  the next player to receive a used id has their first request refused;
- **clock failure falls closed** — an absent, nil, string-valued or raising
  clock refuses rather than opening.

`server/ratelimit.lua` is `require`d rather than listed in `fxmanifest`, so it can
be loaded and tested without the engine. `tools/luacheck.js` resolves every
`require` path against the tree, because a typo there fails nothing until the
resource is started on a customer's server with a green build behind it.

### 7.2 What was audited and found

A full static pass over all sixteen shipped Lua files. Four findings, all fixed
in 1.1.0:

| # | Severity | Finding |
|---|---|---|
| 1 | HIGH | The client-results handler had **no rate limit**. A cheat menu could fire it thousands of times a second; each accepted call printed up to 64 lines into the operator's console. |
| 2 | MEDIUM | The boot report told an **unauthorised** registration to "stop the other resource". Since cis_libs 2.2.0 an empty allow-list refuses everything, so this is what a stock install hits — and it pointed at a resource that does not exist. |
| 3 | MEDIUM | The Discord URL check rejected only the literal string `CHANGE-ME`, making an arbitrary caller-supplied URL a live server-side request target. |
| 4 | LOW | `cis_bridge_client` was unrestricted and allocates a ped and four zones per run, with no cooldown. |

**What is deliberately not defended against:** anything in your `server.cfg`
already has every permission you have. These are guards against accidents.

---

## §8 — Tests

```
npm install
npm test          # 570 assertions, no FiveM server required
npm run test:all  # + syntax check + the api contract self-test
                  # + lint + the generated-docs check + the count check
```

**The count is checked, not trusted.** It appears in four files — this one, the
README, the changelog and a comment in the workflow — and it was wrong in three
of them at least once while `test:all` stayed green. `npm run check:counts` runs
the suites, sums what they reported, and fails when any file that quotes the
number disagrees. It checks the suite count too, which is a separate claim and
drifts separately.

Ten suites, each in a **fresh Lua state** so one cannot read another's globals:

| Suite | What it covers |
|---|---|
| `test/bridge.lua` | the registration helper: the four conditions, `AUTO`/`NONE`, the probe list, the start-order wait, and the failure shapes of `GetConfigSummary` |
| `test/adapters.lua` | the adapters: transaction bind-key normalisation, the ox_inventory count decision, the Discord embed, the webhook allow-list, the queue's refusals and its bound |
| `test/report.lua` | the boot report: every registration outcome produces a row with a cause and a fix |
| `test/ratelimit.lua` | the cooldown: ten thousand calls in one instant, per-source isolation, `playerDropped` cleanup, a recycled source id, a clock that goes backwards, a clock that is nil or raises, and malformed sources |
| `test/contract.lua` | **compliance with cis_libs**, read from the source on disk: the two manifest requirements, no deprecated API, every `cis_libs` export called actually existing, realm boundaries, `Cis.*` namespaces cis_libs defines, and no internal cis_libs files included |
| `test/globals.lua` | every shipped file loaded against a stubbed engine with a `_G` watcher on `__newindex`: no file writes an undeclared global, and each of the four declared globals is created only by the file that owns it |
| `test/runner.lua` | **the conformance runner itself** — the command an operator actually runs. PASS/FAIL/SKIP counted separately, a raised test counted once, client-only slots SKIPped rather than failed, not-installed distinguished from failed, and the client half asked on a full run but not on a single-target one |
| `test/adapters-matrix.lua` | **every adapter method against every return shape.** qb-inventory's *string* refusal, codem's `nil`, ox_target's own record, mongodb's six refusals, the array-size arithmetic, a provider that raises |
| `test/perf.lua` | **`Wait()` discipline**, checked against the source: no `Wait(0)` anywhere, every loop waits, every loop is in a written account of the four that exist, and no draw calls |
| `test/handler.lua` | **the player-reachable surface, attacked.** Every payload category against `cis_bridge:server:conformanceResults`: wrong types, 10,000 rows, a megabyte-long string, 10,000-deep nesting, terminal escape sequences, format specifiers, and a 5,000-call flood. Plus both commands' ACLs |

`test/adapters-matrix.lua` is the suite that makes the conformance suite
trustworthy offline. The interesting differences between these targets are
entirely in their **return shapes**, and a live run can only test the one shape
the install happens to produce. qb-inventory reports a failure as a **string**,
which is truthy in Lua, so every failed add reads as a success and a caller
writing `if inventory.add(...) then give the item end` hands out the item. That
is invisible on a server where nothing is being added.

The technique worth knowing: the fakes **record the exact table they were
handed**, because the interesting question is almost never "what did it answer"
— it is "what did it ask for". The transaction bug above is invisible to a fake
that only returns a value.

**`test/globals.lua` watches what RUNS, and that is not enough.** A missing
`local` inside a function no suite ever calls is invisible to it — which was
verified rather than assumed, by applying exactly that mutation and watching
nothing fail. So it is not a substitute for a static analyser: **luacheck is the
authority on undeclared names and CI installs it**, while this runs everywhere,
including on a machine with no Lua toolchain at all, and catches the writes that
actually happen. Both run; neither is described as the other.

`test/contract.lua` is the odd one out: fengari has no filesystem, so the
harness reads the source and hands it over in two forms — comments stripped, and
comments *and string contents* stripped. The second exists because a compliance
rule that matches `Cis.target.` also matches it inside the sentence written to
explain that `Cis.target` is a client surface, and a rule that fires on prose
grows an exemption list until nobody trusts it.

Every fix in this resource ships with an assertion that was **observed failing
first**. The ones that matter have been mutation-checked by hand: removing the
bind-key normalisation, restoring the empty footer, collapsing `nil` to zero,
removing the start-order wait, or dropping the report's `fix` field each produce
failures.

The rest is tested where it can actually fail: on a live server, by
`cis_bridge test`.

---

## §9 — Layout

```
fxmanifest.lua        depends on cis_libs
api.lua               data. the contract. not loaded at runtime
API.md                generated from api.lua + the source. checked
types/cis_bridge.lua  generated LuaCATS annotations. never loaded
shared/bridge.lua     the registration helper and the outcome table
adapters/
  target/       ox_target.lua, qb_target.lua            (client)
  inventory/    ox, qb, qs, codem                        (server only)
  database/     oxmysql, mysql_connector, ghmattimysql, mongodb
  discord/      webhooks.lua, embed.lua
server/
  report.lua        the boot report
  conformance.lua   the runner and the server half
  ratelimit.lua     the per-source cooldown
client/conformance.lua
test/  tools/
```

**Two files are `require`d rather than listed in `fxmanifest`**, because both have
to be loadable without the FiveM engine so a unit suite can exercise them:

| Module | Required by | What the suite proves about it |
|---|---|---|
| `adapters/discord/embed.lua` | the Discord adapter | that the payload contains no empty table, which is the 400 |
| `server/ratelimit.lua` | the conformance runner | that the guard closes, per source, and survives a recycled id |

The cost is a path that only fails at resource load, so `tools/luacheck.js`
resolves every `require` against the tree on every run.

---

## §10 — Licence

MIT. See `LICENSE.md`. The attribution notice must be retained in every copy.
Third-party resources are not vendored, modified or relicensed here, and remain
under their own licences.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko>