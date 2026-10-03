# Changelog

All notable changes to `cis_bridge`. Keep a Changelog format; the version is
semantic; the **contract major** (`api = 1`) is separate from it and has not
moved.

---

## 1.1.0

The release where a stock install stopped being broken.

### Fixed

- **Transactions silently dropped their bind values.** `cis_libs` documents a
  transaction entry as `{ query = sql, params = { ... } }` and that is what every
  consumer writes. oxmysql's entry type is `{ query, parameters?, values? }` —
  there is no `params` — and its parser reads `parameters or values`, falling
  back to the transaction's outer parameter array. An entry written to the
  documented contract was not rejected, it was **ignored**: every `?` went
  unbound and the transaction reported success. The adapter normalises all three
  spellings into `values`, in oxmysql's own precedence order, and passes the
  `[sql, binds]` array form through untouched.
- **Every Discord message was a 400.** The embed built
  `footer = { text = nil, icon_url = nil }` from a config table that is always
  empty — `json.encode` dropped both keys and the payload carried `"footer":{}`,
  which Discord rejects for the whole request. The failure counter read that as
  an unhappy endpoint and backed off to sixty seconds, so an operator saw a
  webhook that "stopped working some time ago" with nothing naming the cause.
  Optional sections are now omitted rather than included empty.
- **No driver registered on a stock server.** `Framework.Database.Type` ships as
  `AUTO` and `GetConfigSummary` reports `NONE` for an unconfigured slot. Both
  are answers, not rival resource names, so every adapter compared itself
  against the string, found a mismatch and refused — on a server where oxmysql
  was running. Both now mean "no opinion".
- **Start order decided whether the platform worked.** An adapter checked its
  target once at boot and gave up if it was not up yet, so `ensure cis_bridge`
  above `ensure ox_target` — an extremely common `server.cfg` — meant the
  adapter never registered for the lifetime of the process. Adapters now wait,
  bounded at 60s, and answer `missing` immediately because no amount of waiting
  makes an uninstalled resource appear.
- **The inventory suite tested somebody else's code.** `Cis.inventory.*` routes
  to the `inventory` slot, which cis_core owns; cis_bridge fills the
  `inventoryProvider` slot underneath it. Four healthy adapters reported `FAIL`
  on a server without cis_core, and proved nothing on one with it.
- **`cis_bridge` in game was dead on every server.** The command checked
  `exports['cis_libs']:GetFramework().HasPermission(src, 'admin')`, which names
  cis_core's export from the one resource whose reason to exist is not to, reads
  a deprecated export, and cannot work — cis_libs documents the identical bug at
  length on its own `cis_debug` command. An admin with every right got silence.
- **`ox_inventory` counts went through the wrong export.** `Search(inv, 'count',
  item)` answers `false` for an inventory that does not exist yet, where
  `GetItemCount` answers `0`. `nil` reads as "I could not tell", so a player
  mid-spawn looked like an inventory outage — and that reading gates every dupe
  check in the platform. `Search` is kept as the fallback for old builds, and
  still keeps `false` as `nil`.
- **`ghmattimysql`'s `update` returned a result object, not a row count.** A
  caller writing `if affected > 0 then` compared a table with a number and
  raised.
- **The client conformance half never ran.** It executed on join and printed to
  a console the operator is not watching, and nothing ever collected the
  results, although the event it answers was declared as published API.
- **A missing tool could look like broken code.** A test suite calling
  `os.exit(1)` took the fengari state down with it, so a failure in one suite
  was reported against the previous one and the rest never ran.

### Security

Found by a full static pass over all sixteen shipped Lua files. Four findings,
all fixed and all unit tested.

- **[HIGH] The client-results handler had no rate limit.**
  `cis_bridge:server:conformanceResults` is a net event, so a cheat menu can fire
  it as fast as the executor likes with any payload. Each accepted call printed
  up to 64 lines into the server console — the operator's only window onto a
  running server. A player who fires it in a loop breaks nothing and buries
  everything. Now: a per-source cooldown, refusals counted rather than logged,
  and `playerDropped` cleanup so the table does not leak as FiveM recycles source
  ids.
- **[MEDIUM] The boot report diagnosed the wrong cause for an unauthorised
  registration.** One `REFUSED` row covered both "another resource holds this
  slot" and "cis_libs will not let this resource fill it", and every `REFUSED`
  row said "stop the other resource". Since cis_libs 2.2.0 an **empty**
  `AuthorizedResources` refuses every resource, so the second case is what a
  stock install hits — and the report was pointing at a resource that does not
  exist. The two are now `NO AUTH` and `REFUSED` with opposite fixes, and an
  unrecognised reason passes cis_libs' own sentence through rather than replacing
  it with a guess.
- **[MEDIUM] The Discord URL check was a filter, not a boundary.** It rejected
  the literal string `CHANGE-ME`, which makes every other URL a live request
  target for any resource that can call the capability — server-side request
  forgery built out of a logging adapter. Now an allow-list: HTTPS only, one of
  four Discord hosts, a webhook-shaped path. Nothing else reaches the queue.
- **[LOW] `cis_bridge_client` was unrestricted with no cooldown**, and allocates
  a ped and four target zones per run. Now ten seconds between runs.

The cooldown is a separate module so it can be tested without the engine, and its
suite asserts the three ways a guard quietly stops guarding: it is per source
rather than global, it forgets on `playerDropped` so a recycled id is not blocked,
and every clock failure — absent, nil, a string, or raising — refuses rather than
opens.

**A bug worth recording.** The URL allow-list was first written as a Lua pattern
using `(app)` for alternation. Lua patterns have no alternation, so that matched
nothing and the adapter silently stopped sending — the same failure the empty
footer had, arriving through a different door. It is now a table of hosts, and
the suite asserts that a well-formed webhook is **accepted**, not only that a bad
one is refused. A test that only proves refusal cannot tell a filter from a
boundary.

### Added

- **The boot report.** One row per adapter slot, with the outcome, the sentence
  that explains it and the next step. Five refusals are told apart: not
  installed, installed but down, configured for another resource, started
  without the required exports, and held by another resource. It also reports
  what cis_libs can see, which is how a provider that registered but cannot
  serve its slot's methods becomes visible.
- `cis_bridge report` — the same content on demand, for a server that has been
  up a week and has just changed its config. Separate from `cis_bridge test`:
  one says what is wired up, the other whether it works.
- `GetBridgeReport()` — the report as data, so another resource can render it.
- The start-order wait, bounded and instrumented.
- `probeExport` accepts a **list**, and the refusal names every missing export.
  One export cannot establish compatibility: an adapter that calls six of a
  target's exports has six ways to be wrong.
- `Bridge.publish` — adapters publish their method table so the conformance
  suite tests this resource's own code.
- `cis_bridge_client` — run the client half without being a server admin.
- Adapters unit suite. The fakes record the exact table they were handed,
  because the interesting question is "what did it ask for", not "what did it
  answer".

### Changed

- `cis_bridge` is **console-only** and prints the `add_ace` line rather than
  granting itself access to somebody's server. cis_libs never runs `add_ace` for
  the owner, and neither does this.
- Adapters wait for their target rather than checking once, and distinguish
  "not installed" from "not started" from "configured for something else".
- The conformance runner keys its tests by **slot** first and by target name
  second. The discord slot registers against this resource rather than a third
  party, so looking it up by name reported `FAIL` on every server that had the
  adapter working perfectly.
- `mysql-async` is no longer named as a mysql-connector alias. It exports
  `mysql_fetch_all` / `mysql_fetch_scalar` / `mysql_execute` and this adapter
  calls `mysql_query` / `mysql_scalar` / `mysql_insert` / `mysql_update`;
  pointing it at a mysql-async server would register and then raise on the first
  query. Naming it accurately is the difference between "not supported" and
  "supported, and broken".
- The Discord capability answers the slot's own method names, `log` and
  `depth`.
- The Discord embed builder moved to `adapters/discord/embed.lua` so it can be
  loaded and tested without the engine.

### Verification

128 assertions across three suites, each in a fresh Lua state so one cannot read
another's globals. Every fix above ships with an assertion that was observed
failing first; the five that matter most were mutation-checked by hand — removing
the bind-key normalisation, restoring the empty footer, collapsing `nil` to
zero, removing the start-order wait, and dropping the report's `fix` field each
produce failures.

---

## 1.0.0

First release. Eleven adapters, one conformance test per target, a server and a
client half, and an `api.lua` validated against the surface the code actually
registers.

---

**Contract:** `api = 1`, unchanged since 1.x. No `Cis.*` signature, argument
order or return shape has changed. Deprecations are logged once per calling
resource per boot and are removed in 3.0.0.