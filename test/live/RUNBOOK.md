# cis_bridge — live verification runbook

**Everything else in this repository runs without a game.** 570 assertions under
fengari, a syntax check, a real luacheck, an API-contract validator with its own
fixtures, a generated documentation check, a `bash -n` over the workflow, and a
GPL-isolation grep.

None of that can tell you whether `ox_target` answers on *your* server. This file
is what is left, and it is short on purpose: a runbook nobody finishes is worse
than no runbook, because the person who needs it is already out of time.

**Tracked project documentation. It goes in the repository on purpose** — it is
how a support thread becomes an answer, and an answer that lives only in one
person's head stops existing when they stop working here.

---

## 0. Before you start

You need a FiveM server, this resource, `cis_libs`, and **at least one** of the
targets below actually started.

```cfg
ensure cis_libs
ensure cis_bridge
ensure oxmysql          # or whichever database you use
ensure ox_target         # or qb-target
ensure ox_inventory      # or whichever inventory you use
```

Start order does not matter — adapters wait up to 60 seconds — but a target
that is not installed at all is reported immediately rather than waited on, so
do not read "MISSING" as "slow to start".

**Nothing here writes to a player, and nothing is sent.** Every check either
reads or creates and removes its own name. The single exception is the database
check, which creates and drops a table with the prefix `cis_bridge_conformance`.

---

## 1. The boot report

The first thing to look at, because it answers the question that opens almost
every support thread: *is this installed, and what is it doing?*

```
  state    slot            target
  -------  --------------  ---------------------------------------------
  OK       target          ox_target         registered
  OK       database        oxmysql           registered
  MISSING  inventory       -                 qs-inventory is not installed
  OK       discord         cis_bridge        registered
```

**What to do with it:**

| State | What it means | What to do |
|---|---|---|
| `OK` | registered and serving | nothing |
| `MISSING` | the resource is not on this server | start it, or point the config at the one you use |
| `DOWN` | installed, but not started within 60s | fix the start order in `server.cfg` |
| `OTHER` | the configuration names a different resource | start that one, or change the config |
| `NO API` | started, but without the exports the adapter needs | update it, or switch targets |
| `NO AUTH` | cis_libs will not let this resource fill a slot | add it to `Security.AuthorizedResources` |
| `REFUSED` | another resource already provides that capability | stop the other one |
| `UNKNOWN` | the adapter never ran at all | cis_libs did not become ready — look above for the error |

`NO AUTH` is the one people miss. **Since cis_libs 2.2.0 an empty
`AuthorizedResources` refuses every resource**, so a stock install that never
added `cis_bridge` to the allow-list gets it on all four slots. The fix is one
line:

```lua
Security.AuthorizedResources = { 'cis_core', 'cis_bridge', ... }
```

Re-run it on demand at any time:

```
cis_bridge report
```

## 2. The conformance suite

```
cis_bridge test              # everything that registered
cis_bridge test database     # one slot or one target
```

Read the **tally** at the bottom, not the rows:

```
cis_bridge: 4 target(s) tested, 7 not installed, 1 skipped, 0 failure(s)
```

- `FAIL` — an adapter is genuinely incompatible. The detail says which check and
  why.
- `SKIP` — a check did not run. The tally counts these separately, so you always
  know how much of the suite actually executed.
- `not installed` — targets this resource *could* adapt and you do not run. Not a
  failure.

**The target adapters report SKIP on the server.** `Cis.target` is a client
surface; the server and client capability registries are independent. So:

```
cis_bridge test
```

asks every connected client to run its own half and prints their answers when
they come back. If nothing comes back, no client is running the resource — check
that the client scripts loaded. A developer can also run the client half alone:

```
cis_bridge_client
```

## 3. What the database check writes

One table, created and dropped, twice at most:

```sql
CREATE TABLE cis_bridge_conformance (id INT)
INSERT INTO cis_bridge_conformance (id) VALUES (1)
-- the transaction check, which must bind its value
DROP TABLE IF EXISTS cis_bridge_conformance
```

Then it asks `information_schema` whether the table is gone. **A database user
with no read access to `information_schema` gets a SKIP on that check**, not a
FAIL — that has told us nothing about the adapter, and reporting it as a failure
is the wrong answer rather than the pessimistic one.

If the table survives a run, that is a finding worth reporting: the adapter
dropped nothing.

## 4. The Discord check

Nothing is posted. The only URL it touches is the `CHANGE-ME` placeholder, and
the property under test is precisely that the adapter **refuses** it.

A real-looking URL is also refused, and so is one on a host that is not Discord.
That is not a formality: `log(webhookUrl, ...)` takes its destination as an
argument, and without the allow-list any resource that can call the capability
could point your server at an address of its choosing.

So:

```
cis_bridge test
...
[discord] refuses an unconfigured placeholder webhook          PASS
[discord] refuses a webhook on a host that is not Discord     PASS
[discord] queues nothing for either                           PASS
```

If you want to verify the adapter actually sends, enable
`Config.Printing.UseDiscordLogs` with a real webhook and restart cis_libs, then
run the platform and look for a line in the channel. That is a platform
setting, not a bridge one — the bridge deliberately never sends on its own.

## 5. Reading the results from another resource

```lua
local ok = exports['cis_bridge']:RunConformance('oxmysql')
local rows = exports['cis_bridge']:GetConformanceResults()
-- { { target, name, ok, skipped, detail }, ... }

for _, row in ipairs(export_rows) do
    if not row.ok and not row.skipped then
        print(('%s: %s -- %s'):format(row.target, row.name, row.detail))
    end
end
```

A client's `PASS` is not proof of anything the server did not check itself. It is
an observation from a machine you do not control, reported as such.

---

## 6. What is deliberately NOT covered here

| Not covered | Why |
|---|---|
| Whether a third-party resource works at all | Not our code. If `ox_target` is broken, the adapter says so. |
| Performance under load | There is nothing per-frame in this resource; `npm test` asserts that structurally. |
| Whether `cis_libs` itself is healthy | It ships `cis_doctor` and `cis_debug`. Start there. |
| Anything escrow-protected | Nothing in this resource is escrowed; every file here is readable. |

## 7. If something is wrong and the report does not say why

1. `cis_libs:cis_doctor` — cis_libs's own health check, with fixes.
2. `cis_libs:cis_debug` — the capability table with a verdict per slot.
3. `cis_bridge report` — what this resource registered and what it was waiting
   for.
4. `npm run test:all` — if this is a fresh checkout rather than a live server,
   that is the fastest way to find out whether the problem is here at all.

Step 4 first when you have a clone, step 1 first when you have a server. That
ordering is not a preference: a report that names the cause is worth more than a
test that passes.