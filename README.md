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

**Start order does not matter.** An adapter waits up to 60 seconds for its
target to start, so listing `cis_bridge` first is fine.

## Supported targets

| Kind | Targets |
|---|---|
| Target | `ox_target`, `qb-target` |
| Inventory | `ox_inventory`, `qb-inventory`, `qs-inventory`, `codem-inventory` |
| Database | `oxmysql`, `mysql-connector`, `ghmattimysql` (deprecated), `mongodb` (unsupported — says so) |
| Outbound | Discord webhooks — **the only outbound request in the platform** |

An adapter registers only when its target is actually started, the configured
name matches, and **every** export it calls exists. Each of those has a failure
behind it, and an adapter that registered without them would raise on every
call.

`mysql-async` is **not** supported. It exports a different set from
`mysql-connector` and the bridge does not pretend otherwise.

## What it tells you at boot

```
  state    slot            target
  -------  --------------  ---------------------------------------------
  OK       target          ox_target         registered
  OK       database        oxmysql           registered
  DOWN     inventory       -                 qs-inventory is stopped and did not start within 60000ms
  OK       discord         cis_bridge        registered

  3 of 4 adapter slot(s) registered.

  what to do about the rows above:
    inventory          check the start order in server.cfg: put `ensure qs-inventory` BEFORE `ensure cis_bridge`
```

"Not registered" with no next step is a support ticket. Every refusal names its
cause and its fix, and five refusals are told apart — not installed, installed
but down, configured for something else, started without the right exports, and
held by another resource — because they are five different problems.

## Conformance

```
cis_bridge                # everything
cis_bridge test database  # one target
cis_bridge report         # what is wired up, and what to do about it
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
one exception is the `oxmysql` test, which creates and drops a table with a
conformance prefix and then asks `information_schema` whether it is gone — a
conformance test that leaves a table on a customer's database is litter.

The client runs its half on request, because a target resource can be broken on
a client and healthy on the server, and the two registries are independent.

## Security

The Discord webhook is the only outbound request this platform makes, so its
destination is an **allow-list**: HTTPS only, one of four Discord hosts, and a
webhook-shaped path. A caller who can reach the capability cannot point the
server anywhere else — the worst they can do is drop a log line, which is what a
log line is worth to a caller who should not have had one.

There is exactly one net event a player can reach. Its payload is bounded, every
field is truncated before it is printed, and the handler is rate limited per
source — because a console that scrolls at thousands of lines a second is a
console nobody is reading, and the report an operator asked for is somewhere
underneath it.

## Tests

```
npm install
npm test          # 630 assertions, no FiveM server required
npm run test:all  # + syntax check + the api contract self-test
```

Every fix in this resource ships with an assertion that was observed failing
first. The important ones have been mutation-checked by hand.

## Docs

**[DOCUMENTATION.md](DOCUMENTATION.md)** — the registration rules, every adapter
contract, the conformance suite, and the boot report.

**[API.md](API.md)** — every export, its signature, realm, stability and the
file that declares it. **Generated** from `api.lua` and from a scan of what the
resource actually registers; `npm run docs:check` fails if it is not current, so
it cannot describe an export that was renamed or omit one that was added.

---

**Author:** Cisoko · **Docs:** <https://docs.cisoko.net> · **Discord:** <https://discord.gg/cisoko>