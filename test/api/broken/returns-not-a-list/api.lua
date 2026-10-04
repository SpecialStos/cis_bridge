-- Broken on purpose: `returns` is a string rather than a list of names.
--
-- `returns` exists so the shape can be CHECKED rather than read. `npm run docs`
-- renders it and test/adapters-matrix.lua compares it against the table an
-- adapter actually returns -- and neither can do anything with a string, so a
-- string here means the check silently stops covering that export while still
-- reporting clean.
local real = assert(loadfile(CIS_API_REAL))()
real.exports.CisBridgeDiscord.returns = 'log, depth'
return real
