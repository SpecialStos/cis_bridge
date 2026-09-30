-- Broken on purpose: GetConformanceResults is registered by
-- server/conformance.lua and is not in api.lua.
--
-- E031 -- the other half of drift. E030 catches a declaration for something
-- that does not exist; this catches a real, working, reachable export nobody
-- has taken responsibility for.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.GetConformanceResults = nil
return real
