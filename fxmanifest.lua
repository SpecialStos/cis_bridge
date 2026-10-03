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
    -- TWO files are deliberately NOT listed here, and both are `require`d by the
    -- file that needs them:
    --
    --   adapters/discord/embed.lua  -- the webhook payload builder
    --   server/ratelimit.lua        -- the per-source cooldown
    --
    -- Listing them as well would run each twice: once as a script and once as a
    -- module. Being invisible to the manifest is the price of being loadable
    -- without the engine, which is what lets the unit suite exercise both -- and
    -- the empty-footer 400 and the cooldown are exactly the two things that must
    -- not be verified only on a live server.
    --
    -- Both are still found by every check that walks the filesystem, so the
    -- syntax check, the api validator and the GPL-isolation grep all see them.
    'adapters/database/oxmysql.lua',
    'adapters/database/mysql_connector.lua',
    'adapters/database/ghmattimysql.lua',
    'adapters/database/mongodb.lua',
    'adapters/inventory/ox_inventory.lua',
    'adapters/inventory/qb_inventory.lua',
    'adapters/inventory/qs_inventory.lua',
    'adapters/inventory/codem_inventory.lua',
    'adapters/discord/webhooks.lua',
    -- After the adapters, so `Report` exists by the time a console command can
    -- reach it. The boot thread inside it waits for the slowest adapter anyway,
    -- so this ordering is about the command, not about the report.
    'server/report.lua',
    'server/conformance.lua',
}
