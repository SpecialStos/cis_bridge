# cis_bridge — documentation

**Version 1.0.0.** One adapter, and one conformance test, per third-party
target.

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
uses the shared helper rather than hand-rolling it — and why the helper's four
conditions are tested.

If you are integrating this, §2 (the registration rules) and §3 (the adapter
contracts) are what you need. §4 is the part that will save you a support
thread.

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

### 2.1 The four conditions

Every adapter calls the same helper, and each condition has a real failure
behind it:

```lua
Bridge.register(slot, target, configured, probeExport, exportName)
```

| # | Condition | The failure it prevents |
|---|---|---|
| 1 | `GetResourceState(target) == 'started'` | An adapter registering against a target nobody has, raising on every call, in a product that looks installed. |
| 2 | `configured` matches `target`, or is unset | A server with `ox_target` installed and `qb-target` configured would register the one that is present — working by accident on a server where the operator never tested the other one. |
| 3 | `exports[target][probeExport]` exists | Calling a missing export **raises**. Older `oxmysql` has no `single`; a renamed export is the same problem. Registering anyway means the capability exists and every call to it raises. |
| 4 | `RegisterCapability` was not refused | A bridge registering twice on a partial restart silently replacing a working provider. |

Each refusal prints **one line saying which condition failed** and by what
name. `SKIP` and `FAIL` are different sentences and an operator needs to be told
which one they have.

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

---

## §3 — The adapters

### 3.1 Targets (client)

Registered into `cis_libs` as the `target` capability.

| Export | Target | Registered when |
|---|---|---|
| `CisBridgeTargetOx` | `ox_target` | started, configured `ox_target`, exposes `addSphereZone` |
| `CisBridgeTargetQb` | `qb-target` | started, configured `qb-target`, exposes `AddBoxZone` |

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
| `CisBridgeInventoryCodem` | `codem-inventory` | The only one with **no boolean** in its contract: `HasItem`/`AddItem` answer counts and `nil` |

**None of these is registered on the client.** The client gets its counts from a
snapshot the server pushes. A client-side provider would be a second source of
truth about what a player is carrying.

Two hops on purpose: the service in `cis_core` is the `name -> amount`
normalisation every consumer depends on, and the provider here is the
third-party call underneath it. Either can be replaced alone.

### 3.3 Databases (server)

Registered into `cis_libs` as the `database` capability. All are **await-style**:
they yield and answer `nil` at their deadline.

| Export | Target | Notes |
|---|---|---|
| `CisBridgeDatabaseOxmysql` | `oxmysql` | **The only one that supports `Cis.db.transaction`** |
| `CisBridgeDatabaseMysqlConnector` | `mysql-connector`, `mysql-async` | Callback-first, bridged to await |
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

#### The oxmysql `single` fallback

`oxmysql` grew a `single` export. Builds before it do not have one, and calling
a missing export **raises** — so a server on an older build would get an error
on every `Cis.db.single` call, from a resource that looks like it supports it.

The adapter **probes at registration** and falls back to the first row of a
query. Both halves matter: probing without the fallback registers an adapter
that cannot serve a method it advertised.

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
Adapter.Log(webhookUrl, title, message, color, ping)
Adapter.QueueDepth()  --> depth, dropped
```

Bounded, rate-limited, and it never blocks the caller: a slow or dead webhook
drops entries rather than growing without limit.

**`QueueDepth` returns depth *and* cumulative drops.** Depth alone looks healthy
on a server that has been quietly truncating for an hour.

Registering is not sending. A server with this installed and
`Config.Printing.UseDiscordLogs = false` has a queue that never fills.

---

## §4 — Conformance

```
cis_bridge                # everything
cis_bridge test database  # one target
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

### 4.2 What a test checks

**The contract, not the implementation.** "Does `addSphereZone` exist" is worth
knowing and is not what breaks. What breaks is: *does a zone I create come back
when I ask whether it exists, and does removing one answer rather than raise.*

### 4.3 What a test does not do

**Nothing is sent and nothing is written to a player.** The tests create and
remove their own names, use obviously-synthetic ids, and touch no inventory — a
conformance test that gives a player an item to see whether the inventory works
is a test that can leave a player with an item.

The one exception is the `oxmysql` test, which creates and drops a table with a
conformance prefix. A test that leaves a table on a customer's database is
litter.

### 4.4 `SKIP` is not `FAIL`

A target that is not installed reports `SKIP`. A server without `qs-inventory` is
not broken, and printing a `FAIL` line for it would bury the one result the
operator came for under a wall of noise they have to read past.

The list of targets tested comes from **what actually registered**, not from a
static list of everything this resource can adapt.

### 4.5 Programmatic access

```lua
exports['cis_bridge']:RunConformance('oxmysql')   --> boolean
exports['cis_bridge']:GetConformanceResults()     --> { { target, name, ok, detail }, ... }
```

The results are the answer to "is this a broken adapter or an incompatible
target?", which is the first half of every support thread about a bridge.

The **client** runs the same contract on the client, and it exists for one
specific reason: a target resource can be started on the server and still be
broken on a client. `ox_target` registers on both sides, and a client that
cannot create a zone produces a door that does not respond — which looks exactly
like a server-side permission problem and is not one.

### 4.6 What each target is actually checked for

| Target | Checks |
|---|---|
| `ox_target` | creates a sphere, creates a box, reports a created zone as existing, removes without raising, forgets a removed zone, refuses an unknown name without being fatal |
| `qb-target` | creates a circle, creates a box from a vector3, accepts an array size, removes |
| `oxmysql` | query, single, scalar, insert, DDL, the inserted row is visible, **transaction succeeds**, cleans up after itself |
| `mysql-connector` | query, single, scalar, **refuses a transaction**, and the refusal names `oxmysql` |
| all four inventories | a missing item counts **zero, not nil** — the distinction a consumer's `if not count` depends on |
| `mongodb` | **says it is not a SQL driver** |

---

## §5 — Extending

Adding a target is one file plus one test.

1. Create `adapters/<kind>/<target>.lua`.
2. Implement the slot's methods, matching the contract in §3 exactly.
3. `exports('CisBridge<Slot><Target>', function() return Adapter end)` — **a
   unique name**.
4. `CreateThread(function() if not exports['cis_libs']:WaitReady(15000) then return end; Bridge.register(...) end)`.
5. Add an entry to `tests` in `server/conformance.lua`. A target with no test is
   reported as a **failure**, not silently skipped — "no conformance test is
   defined for it" is the finding.
6. Declare the export in `api.lua` or `npm run test:api` fails.

**Never vendor, never modify, never copy.** Read the target's source if you need
to understand it; the one-file rule is the whole mitigation and copying breaks
it silently.

---

## §6 — Diagnostics

```lua
exports['cis_libs']:GetCapabilities()
-- target -> owner: 'cis_bridge'
-- database -> owner: 'cis_bridge'
-- inventoryProvider -> owner: 'cis_bridge'
```

`cis_debug` in the server console prints the same table with a `resolved` /
`no provider installed` verdict per slot, and every target resource's raw state
— because the operator's next question after "no provider" is always "is my
framework even started?".

```
[cis_bridge] target: ox_target is started but exposes no "addSphereZone" export; not registered
[cis_bridge] database: not registered, the configuration names "ghmattimysql"
[cis_bridge] target: qb-target registered
```

Each of those three is a different problem with a different fix, which is why
they are three different sentences.

---

## §7 — Security notes

| Control | What it does |
|---|---|
| No vendoring | GPL isolation for `ox_inventory` is a file boundary, and a file boundary is only real if nothing crosses it |
| No outbound except Discord | One auditable place for every request this platform makes |
| `UseDiscordLogs` off by default | A placeholder webhook URL is inert no matter what it contains |
| Bounded queue | A dead webhook drops entries rather than growing without limit |
| Conformance sends nothing | A test that mutates a customer's data is a support ticket |
| Restricted command | `cis_bridge` and `cis_debug` both require admin in-game; the console is always allowed |

**What is deliberately not defended against:** anything in your `server.cfg`
already has every permission you have. These are guards against accidents.

---

## §8 — Tests

```
npm install
npm test          # 15 assertions, no FiveM server required
npm run test:all  # + syntax check + the api contract self-test
```

Every adapter is a thin wrapper around a third-party export, so there is very
little pure logic here — and testing it against a mock would be testing the
mock. What is tested without a server is `Bridge.register`, because its four
conditions are the difference between an adapter that works and one that raises
on every call.

The rest is tested where it can actually fail: on a live server, by
`cis_bridge test`.

---

## §9 — Layout

```
fxmanifest.lua        depends on cis_libs
api.lua               data. the contract. not loaded at runtime
shared/bridge.lua     the registration helper -- the four conditions
adapters/
  target/       ox_target.lua, qb_target.lua            (client)
  inventory/    ox, qb, qs, codem                        (server only)
  database/     oxmysql, mysql_connector, ghmattimysql, mongodb
  discord/      webhooks.lua
server/conformance.lua
client/conformance.lua
test/  tools/
```

---

## §10 — Licence

MIT. See `LICENSE.md`. The attribution notice must be retained in every copy.
Third-party resources are not vendored, modified or relicensed here, and remain
under their own licences.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> ·
**Discord:** <https://discord.gg/cisoko>
