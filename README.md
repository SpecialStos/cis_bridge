# cis_bridge

**The integrator SDK.** One adapter, and one conformance test, per third-party
target. Free with purchase.

Everything on your server that is not us has exactly one file here, and nothing
outside this resource knows any of their names.

| Resource | What it is | Price |
|---|---|---|
| `cis_libs` | The shared boundary. Owns no table, no config, no framework. | Free, always |
| `cis_core` | Framework abstraction, state, config, migrations. | Free with purchase |
| **`cis_bridge`** | **This.** Adapters and conformance tests. | Free with purchase |
| `cis_keys` | Doors, keys, PINs, guest passes, access ledger. | Paid, private |

## Why it is a separate resource

Because `ox_inventory` is GPL-3.0. That is not a formality: it is on roughly
half of all servers, actively maintained, and a hard dependency of Qbox.
Vendoring it, or modifying it, puts our licence and our customers' servers in a
position nobody wants to be in. One adapter **file**, optional, never vendored,
never modified, is the entire mitigation — and the isolation is only real if
nothing outside that file names ox_inventory.

The same reason, less sharply, applies to everything else here. A target we do
not support is a target a customer cannot use, and the cost of that is paid by
them. One file per target is the unit of support, and the conformance test is
the unit of proof.

## Install

```cfg
ensure cis_libs
ensure cis_core
ensure cis_bridge
```

## Supported targets

| Kind | Targets |
|---|---|
| Target | `ox_target`, `qb-target` |
| Inventory | `ox_inventory`, `qb-inventory`, `qs-inventory`, `codem-inventory` |
| Database | `oxmysql`, `mysql-connector` / `mysql-async`, `ghmattimysql` (deprecated), `mongodb` (unsupported — says so) |
| Outbound | Discord webhooks — **the only outbound request in the platform** |

An adapter registers only when its target is actually started, the configured
name matches, and the export it needs exists. Each of those three checks has a
failure behind it, and an adapter that registered without them would raise on
every call.

## Conformance

```
cis_bridge                # everything
cis_bridge test database  # one target
```

Third-party resources change under us. ox_target changed how it handles zones;
qb-target returns nothing from a removal, so a truthiness test on the result
reports failure for a removal that worked; oxmysql grew a `single` export and
calling it on an older build *raises* rather than returning nil. Each of those
was a real incident, and each looked like a bug in somebody's server.

So every adapter ships with a test that exercises the **contract** rather than
the implementation, and the runner prints `PASS`, `FAIL` or `SKIP` per check.
`SKIP` is not `FAIL`: a server without `qs-inventory` is not broken.

**Nothing is sent and nothing is written to a player.** The tests create and
remove their own names, use obviously-synthetic ids, and touch no inventory. The
one exception is the oxmysql test, which creates and drops a table with a
conformance prefix — a conformance test that leaves a table on a customer's
database is litter.

## Tests

```
npm install
npm test          # 15 assertions, no FiveM server required
npm run test:all
```

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>
