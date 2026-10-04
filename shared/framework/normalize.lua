-- Player normalisation.
--
-- Four frameworks, one shape. `Cis.framework.player(src)` returns the same table
-- whichever framework is underneath, because a consumer that has to know which
-- one it got has not been abstracted from anything.
--
-- The shapes, as they actually arrive:
--
--   QBox / QBCore   PlayerData.job = { name, label, grade = { level, label } }
--                   PlayerData.charinfo = { firstname, lastname }
--                   PlayerData.money is an OBJECT keyed by account name
--   ESX Legacy      xPlayer.getName() / getJob() / getMoney() / getIdentifier()
--                   getJob() returns { label, grade, grade_level } -- note it has
--                   NO `name`, so the LABEL is the job name for ESX
--   standalone      nothing; there is no player and the answer is nil
--
-- EVERY accessor is called under pcall. That is not defensiveness for its own
-- sake: a framework raising inside `GetPlayer` is a thing that happens on real
-- servers, and cis_libs' registry runs provider methods under pcall and answers
-- `false, reason` -- so an adapter that lets the raise escape turns a framework
-- bug into a failed capability call that reads as cis_libs being broken.

local Normalize = {}

--- Concatenate a first and last name without inventing a separator for a
--- missing half. `"Ada" .. " " .. nil` is `"Ada "` and reads as a typo in every
--- consumer that prints it.
local function personName(first, last)
    first = type(first) == 'string' and first or nil
    last = type(last) == 'string' and last or nil
    if first and last then return (first .. ' ' .. last) end
    return first or last
end

--- A job, whichever shape it arrived in.
---
--- `grade` comes back as a NUMBER wherever the framework has one, because that
--- is what a consumer compares against. ESX gives `grade_level`; QBox gives
--- `grade.level`.
function Normalize.job(raw)
    if type(raw) ~= 'table' then return nil, nil end

    -- ESX: { label, grade, grade_level }. No `name` key at all.
    local name = raw.name
    if type(name) ~= 'string' then name = raw.label end

    local grade = raw.grade_level
    if type(grade) ~= 'number' and type(raw.grade) == 'table' then
        grade = raw.grade.level
    end
    if type(grade) ~= 'number' and type(raw.grade) == 'number' then
        grade = raw.grade
    end
    if type(grade) ~= 'number' and type(raw.grade) == 'string' then
        grade = tonumber(raw.grade)
    end

    local label = raw.label
    if type(label) ~= 'string' then label = raw.name end

    return name, grade, label
end

--- Money as a NUMBER, or nil.
---
--- QBox keeps `PlayerData.money` as an OBJECT keyed by account name; ESX keeps it
--- behind `getMoney()`. Returning the object where a consumer expects a number
--- is the failure this avoids: arithmetic on a table, or a `%d` in a string
--- format that quietly prints a table address.
function Normalize.money(raw, get)
    -- ESX first: it is a CALL, and calling it is how the real value arrives.
    if type(get) == 'function' then
        local ok, value = pcall(get)
        if ok and type(value) == 'number' then return value end
    end
    local pd = type(raw) == 'table' and raw.PlayerData or nil
    if type(pd) == 'table' and type(pd.money) == 'number' then return pd.money end
    if type(pd) == 'table' and type(pd.money) == 'table' then
        -- Sum the accounts. A consumer asking "how much money does this player
        -- have" means total, and returning one arbitrary account is a number
        -- that is wrong without being obviously wrong.
        local total = 0
        for _, amount in pairs(pd.money) do
            if type(amount) == 'number' then total = total + amount end
        end
        return total
    end
    return nil
end

--- The identifier, whichever framework has one.
function Normalize.identifier(raw)
    if type(raw) ~= 'table' then return nil end
    if type(raw.getIdentifier) == 'function' then
        local ok, value = pcall(raw.getIdentifier)
        if ok and type(value) == 'string' and value ~= '' then return value end
    end
    local pd = raw.PlayerData
    if type(pd) == 'table' then
        if type(pd.citizenid) == 'string' and pd.citizenid ~= '' then return pd.citizenid end
        if type(pd.license) == 'string' and pd.license ~= '' then return pd.license end
        local license = pd.license
        if type(license) == 'table' then
            for _, value in pairs(license) do
                if type(value) == 'string' and value ~= '' then return value end
            end
        end
    end
    if type(raw.identifier) == 'string' and raw.identifier ~= '' then return raw.identifier end
    return nil
end

--- Normalise a raw framework player object.
---
--- `ctx` carries what only the caller can supply -- the server id and, on a
--- standalone server, the identifier list, because there is no framework object
--- to read one from.
---
--- @return table|nil `{ id, name, job, grade, identifier, money }`, or nil when
---   there is no player at all. Never a table of nils standing in for one.
function Normalize.player(raw, ctx)
    ctx = ctx or {}
    if type(raw) ~= 'table' then
        return nil
    end

    local name
    if type(raw.getName) == 'function' then
        local ok, value = pcall(raw.getName)
        if ok and type(value) == 'string' then name = value end
    end
    local pd = type(raw.PlayerData) == 'table' and raw.PlayerData or nil
    if not name and type(pd) == 'table' and type(pd.charinfo) == 'table' then
        name = personName(pd.charinfo.firstname, pd.charinfo.lastname)
    end

    local jobRaw
    if type(raw.getJob) == 'function' then
        local ok, value = pcall(raw.getJob)
        if ok then jobRaw = value end
    end
    if type(jobRaw) ~= 'table' and type(pd) == 'table' then jobRaw = pd.job end

    local job, grade, label = Normalize.job(jobRaw)

    return {
        id = ctx.id,
        name = name,
        job = job,
        grade = grade,
        label = label,
        identifier = Normalize.identifier(raw) or ctx.identifier,
        money = Normalize.money(raw, raw.getMoney),
        onDuty = ctx.onDuty,
    }
end

return Normalize