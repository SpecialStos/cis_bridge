-- Broken on purpose: RunConformance has no `since`.
--
-- `since` is the one field with no safe default. Everything else in this file
-- can be inferred from the code; `since` is a claim about history, and a claim
-- with no value is a claim nobody can check.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.RunConformance.since = nil
return real
