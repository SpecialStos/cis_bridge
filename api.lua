-- =============================================================================
--  cis_bridge -- the machine-readable public contract
--
--  This file is DATA. It defines nothing, runs nothing, and is deliberately not
--  listed in fxmanifest.lua. Read it on demand, and run `npm run test:api`,
--  which validates it against what the code actually registers and fails on the
--  difference.
--
--  ONE EXPORT PER ADAPTER, NOT ONE PER SLOT
--
--  This is the shape decision the whole resource turns on, so it is worth
--  stating here as well as in the code. Two adapters registering the same export
--  name means the second silently replaces the first, so whichever file loaded
--  last answers for every capability -- and a server with ox_target and no
--  qb-target ends up served by whichever qb adapter ran last, which fails on
--  every call and names a resource that is not even installed.
--
--  `api = 1` is the CONTRACT MAJOR and is not the product version.
-- =============================================================================

return {
    name = 'cis_bridge',
    version = '1.2.0',
    api = 1,
    schema = 0,

    exports = {
        -- --------------------------------------------------------- targets
        -- Each is registered into cis_libs as the `target` capability. The
        -- provider receives a spec table and answers ok[, reason] -- see
        -- Cis.target.add for the shape, which is the abstraction's, not ours.
        CisBridgeTargetOx = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'ox_target. Registered only when ox_target is started AND the configured target is ox_target',
            realm = 'client',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'available', 'name', 'create', 'remove', 'exists' },
            signature = '()',
        },
        CisBridgeTargetQb = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'qb-target. Takes a box zone as three numbers where ox_target takes a vector3, which is why it cannot be a flag on the other one',
            realm = 'client',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'available', 'name', 'create', 'remove', 'exists' },
            signature = '()',
        },

        -- -------------------------------------------------------- database
        -- Registered into cis_libs as the `database` capability. All five are
        -- AWAIT-style: they yield and answer nil at their deadline, and a nil
        -- means "timed out or unavailable", never "no rows".
        CisBridgeDatabaseOxmysql = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'oxmysql. The only target that supports Cis.db.transaction. Probes for the single/query exports and falls back, so an older build still serves both',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'ready', 'query', 'single', 'scalar', 'insert', 'update', 'transaction' },
            signature = '()',
        },
        CisBridgeDatabaseMysqlConnector = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'mysql-connector. Callback-first, bridged to await with a hard deadline. Refuses a transaction rather than faking one. NOT mysql-async, which is a different export set',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'ready', 'query', 'single', 'scalar', 'insert', 'update', 'transaction' },
            signature = '()',
        },
        CisBridgeDatabaseGhmatti = {
            since = '1.0.0', ['until'] = '3.0.0', stable = false, deprecated = true,
            use = 'ghmattimysql, deprecated upstream. Present so installing the bridge does not break the last server still running it',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'ready', 'query', 'single', 'scalar', 'insert', 'update', 'transaction' },
            signature = '()',
        },
        CisBridgeDatabaseMongodb = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'mongodb. Registers so the platform can say it does not support MongoDB, rather than reporting a missing database capability',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'ready', 'query', 'single', 'scalar', 'insert', 'update', 'transaction' },
            signature = '()',
        },

        -- ------------------------------------------------------- inventory
        -- Registered into cis_libs as `inventoryProvider`, BEHIND the
        -- inventory service in cis_core. Two hops on purpose: the service is
        -- the name -> amount normalisation every consumer depends on, and the
        -- provider is the third-party call underneath it. Either can be
        -- replaced alone.
        --
        -- NONE of these is registered on the client. The client gets its counts
        -- from a snapshot the server pushes; a client-side provider would be a
        -- second source of truth about what a player is carrying.
        CisBridgeInventoryOx = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'ox_inventory. GPL-3.0: isolated in this one file, never vendored, never modified',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'available', 'count', 'add', 'remove', 'canCarry' },
            signature = '()',
        },
        CisBridgeInventoryQb = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'qb-inventory. Takes no metadata, and reports refusal as a STRING -- both differ from the others and neither can be a flag',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'available', 'count', 'add', 'remove' },
            signature = '()',
        },
        CisBridgeInventoryQs = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'qs-inventory',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'available', 'count', 'add', 'remove' },
            signature = '()',
        },
        CisBridgeInventoryCodem = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'codem-inventory. The only one with no boolean in its contract: HasItem and AddItem answer counts and nil',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'name', 'available', 'count', 'add', 'remove' },
            signature = '()',
        },

        -- --------------------------------------------------------- discord
        CisBridgeDiscord = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Discord webhooks. The ONLY outbound network request in the platform, which is why it is a file here rather than a function in a library',
            realm = 'server',
            -- The shape of the table this export ANSWERS, as data rather than as
            -- prose. It was English until 1.1.0 -- "Returns { log, depth }" in
            -- a sentence a reader has to parse -- and now `npm run docs`
            -- renders it and `test/adapters-matrix.lua` compares it against
            -- the table that is actually returned. A method added to an adapter
            -- without updating this is a test failure; one listed here that the
            -- adapter does not have is a test failure too.
            returns = { 'log', 'depth' },
            signature = '()',
        },

        -- ------------------------------------------------------ lib shims
        -- EXPORTS, NOT A GLOBAL, and the difference is the platform: each FiveM
        -- resource has its own Lua state, so a `lib` written here is a different
        -- variable from the `lib` a consumer reads. A shim that "installs lib"
        -- installs it for itself and nobody else -- which looks like a working
        -- drop-in on the machine it was tested on. A consumer takes it with one
        -- line, and that line SAYS cis_bridge is being used.
        GetLibShim = {
            since = '1.2.0', ['until'] = false, stable = true, deprecated = false,
            use = "ox_lib's lib.callback and lib.zones over cis_libs. A zone size is passed through UNCHANGED because CreateZone halves it itself",
            realm = 'server',
            signature = '()',
            returns = { 'callback', 'zones', 'zone' },
        },
        GetDbProxy = {
            since = '1.2.0', ['until'] = false, stable = true, deprecated = false,
            use = "The legacy MySQL / oxmysql surface over cis_libs' Db* exports, including the transaction bind-key normalisation",
            realm = 'server',
            signature = '()',
            returns = { 'query', 'single', 'scalar', 'insert', 'update', 'transaction' },
        },

        -- -------------------------------------------------------- framework
        -- Registered into cis_libs as the `framework` capability, BOTH realms.
        -- Two exports rather than one, because the client registry is separate
        -- and resolves only framework/target/doorsClient: a server registration
        -- says nothing about the client one.
        --
        -- It registers ONLY when nothing else holds the slot. The slot is
        -- first-registrant-wins, `cis_core` already provides `framework`
        -- properly, and two providers for one slot is a boot-order bug whose
        -- failure reproduces on one machine and not another.
        CisBridgeFrameworkServer = {
            since = '1.2.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Server framework capability: NormalizedPlayer, Notify, IsLoaded, HasPermission, GetPlayerJob. Falls back to it only when no other resource provides one',
            realm = 'server',
            signature = '()',
            returns = { 'NormalizedPlayer', 'Notify', 'IsLoaded', 'HasPermission', 'GetPlayerJob' },
        },
        CisBridgeFrameworkClient = {
            since = '1.2.0', ['until'] = false, stable = true, deprecated = false,
            use = 'Client framework capability: ShowNotification and IsLoaded only. No Notify -- a client cannot address a player',
            realm = 'client',
            signature = '()',
            returns = { 'ShowNotification', 'IsLoaded' },
        },

        -- ---------------------------------------------------- conformance
        RunConformance = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The same as the cis_bridge console command. Runs every registered target, or one named. Sends nothing and writes nothing to a player',
            realm = 'server',
            signature = '(target)',
        },
        GetConformanceResults = {
            since = '1.0.0', ['until'] = false, stable = true, deprecated = false,
            use = 'The last run, as an array of { target, name, ok, skipped, detail }. For a support thread',
            realm = 'server',
            signature = '()',
        },
        -- Added 1.1.0. The boot report, as data rather than as printed lines.
        GetBridgeReport = {
            since = '1.1.0', ['until'] = false, stable = true, deprecated = false,
            use = 'One row per adapter slot: { slot, label, target, detail, fix }. '
                .. 'The same content the boot printout shows, so another resource can render it',
            realm = 'server',
            signature = '()',
        },
    },

    -- cis_bridge publishes no net events.
    --
    -- It registers a net EVENT HANDLER for the client conformance results,
    -- which is not the same thing: a handler consumes, a publisher declares.
    -- The event belongs to this resource and is documented here as a
    -- dependency so the wire is visible in one place.
    events = {
        ['cis_bridge:client:conformance'] = {
            since = '1.0.0',
            payload = 'server to client: no arguments, asks the client to run its own conformance checks',
        },
        ['cis_bridge:server:conformanceResults'] = {
            since = '1.0.0',
            payload = 'client to server: (results) the client half of a conformance run',
        },
    },
}
