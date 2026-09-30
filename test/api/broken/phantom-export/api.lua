-- Broken on purpose: CisBridgeDiscord is declared for the client realm, where
-- nothing registers it. It is a server-side webhook adapter.
--
-- E030 -- a declaration for a realm that does not exist. A consumer writing
-- against the client signature ships, and finds a nil index at runtime with
-- nothing in the contract to explain it.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.CisBridgeDiscord.realm = 'client'
return real
