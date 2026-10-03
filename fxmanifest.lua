-- =============================================================================
--  CIsoko Bridge -- the integrator SDK
--
--  WHAT THIS IS: one adapter, and one conformance test, per third-party target.
--  Everything on this server that is not us -- ox_target, qb-target,
--  ox_inventory, qb-inventory, qs-inventory, codem-inventory, oxmysql,
--  mysql-connector, ghmattimysql, mongodb, Discord -- has exactly one file
--  here, and nothing outside this resource knows any of their names.
--
--  WHY IT IS A SEPARATE RESOURCE AND NOT A FOLDER
--
--  Because `ox_inventory` is GPL-3.0. That is not a formality: it is on roughly
--  half of all servers, it is actively maintained, and it is a hard dependency
--  of Qbox. Vendoring it, wrapping it in a way that is hard to separate, or
--  modifying it puts our licence and our customers' servers in a position
--  nobody wants to be in. One adapter FILE, optional, never vendored, never
--  modified, is the entire mitigation and it costs about four lines.
--
--  The same reason, less sharply, applies to everything else here. A target we
--  do not support is a target a customer cannot use, and the cost of that is
--  paid by them. One file per target is the unit of support, and the conformance
--  test is the unit of proof.
--
--  WHAT A CONFORMANCE TEST IS FOR
--
--  Third-party resources change under us. ox_target changed how it handles
--  zones; qb-target returns nothing from a removal; oxmysql grew a `single`
--  export and did not always have one. Each of those produced a bug here that
--  looked like a bug in somebody's server. So every adapter ships with a test
--  that exercises the CONTRACT rather than the implementation, and
--  `/cis_bridge test <target>` runs them on a live server and prints PASS or
--  FAIL per check.
--
--      ensure cis_libs
--      ensure cis_core
--      ensure cis_bridge
--
--  Adapters register capabilities. An adapter whose target is not started
--  registers nothing and says so once in the console -- which is a different
--  message from "started and broken", and the difference is the first thing a
--  support thread needs.
-- =============================================================================

fx_version 'cerulean'
game 'gta5'

name "Cisoko - Bridge - Integrator SDK"
description "One adapter and one conformance test per third-party target."
author "Cisoko"
version "1.1.0"
lua54 'yes'

dependencies {
    'cis_libs',
}

-- NO `fxmeta { cis_requires = ... }`, AND THAT IS DELIBERATE.
--
-- cis_libs reads that key and reports any slot it names that has no provider:
--
--     fxmeta {
--         cis_requires = 'database, target'
--     }
--
-- which reads exactly like the thing this resource should declare. It is not.
-- `cis_requires` means "this resource CANNOT WORK WITHOUT these slots", and cis_bridge
-- can work with any subset of them -- a server with only ox_target and no
-- database still gets a working target adapter, and a server with nothing at all
-- gets a boot report that says exactly that.
--
-- Declaring it would put four "[x] requires capability X and no provider is
-- registered" lines on every server that does not happen to run all four targets,
-- which is most of them. A diagnostic that fires on the normal case is not a
-- diagnostic.
--
-- What this resource offers instead is `cis_bridge report`, which covers the
-- same ground and states the fix for each row -- see server/report.lua.

shared_scripts {
    -- The `Cis` facade, the same one line a consumer's own resource uses.
    -- cis_bridge calls it in the conformance suites, and it was not loaded:
    -- `Cis` was nil, so every server conformance test reported "the test ran
    -- to completion -- attempt to index global 'Cis'" on a perfectly healthy
    -- install, and the client half died inside its thread before printing a
    -- single line. A test harness that cannot run is worse than no harness,
    -- because it looks like a product failure.
    --
    -- init.lua is the one shared file that is safe to load into a consumer: it
    -- holds no state of its own, it captures this resource's exports table, and
    -- the rest of the twelve stateful shared files stay where they are.
    '@cis_libs/init.lua',
    'shared/bridge.lua',
}

client_scripts {
    'adapters/target/ox_target.lua',
    'adapters/target/qb_target.lua',
    'client/conformance.lua',
}

server_scripts {
    -- LOAD ORDER IS A CORRECTNESS PROPERTY, NOT A STYLE CHOICE.
    --
    -- Two modules publish themselves as globals for the file that reads them,
    -- and the manifest is what guarantees the consumer loads after the producer:
    --
    --   adapters/discord/embed.lua  ->  CisBridgeEmbed      ->  webhooks.lua
    --   server/ratelimit.lua        ->  CisBridgeRateLimit  ->  conformance.lua
    --
    -- Both were `require`d by dotted path until now. That was a load-time
    -- mechanism NOTHING IN THIS PLATFORM PROVES -- every sibling resource loads
    -- shared code through explicit fxmanifest entries, and there is not one
    -- dotted `require` between cis_libs, cis_core, cis_keys, cis_admin,
    -- phylax_ac and cis_inventory. If FiveM's `require` does not resolve
    -- resource-relative dotted paths, the resource does not START: no partial
    -- failure, no diagnostic, a customer with a dead resource.
    --
    -- They stay modules rather than code inlined into their consumers, because
    -- that is what lets the unit suite load them without the engine -- and the
    -- empty-footer 400 and the cooldown guard are exactly the two things that
    -- must not be verified only on a live server. Being listed in the manifest
    -- costs that nothing: `dofile` reads a file the same way whether the
    -- manifest mentions it or not.
    --
    -- Every check that walks the filesystem still sees them, so the syntax
    -- check, the api validator, the conformance suite and the GPL-isolation
    -- grep all cover both files.
    'adapters/database/oxmysql.lua',
    'adapters/database/mysql_connector.lua',
    'adapters/database/ghmattimysql.lua',
    'adapters/database/mongodb.lua',
    'adapters/inventory/ox_inventory.lua',
    'adapters/inventory/qb_inventory.lua',
    'adapters/inventory/qs_inventory.lua',
    'adapters/inventory/codem_inventory.lua',
    'adapters/discord/embed.lua',
    'adapters/discord/webhooks.lua',
    'server/report.lua',
    'server/ratelimit.lua',
    'server/conformance.lua',
}
