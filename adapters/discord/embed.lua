-- The Discord embed builder, on its own so it can be tested without a server.
--
-- It is a separate file for one reason and not for tidiness: the bug it is
-- extracted to make testable took out the entire outbound logging feature, and
-- nothing in CI could see it, because the builder was a local function inside a
-- 200-line adapter that also owns a queue and a polling thread. It cannot be
-- loaded without FiveM. THIS can.
--
-- THE BUG, because it is worth stating and worth a test.
--
-- The embed used to be built like this:
--
--     thumbnail = cfg.Thumbnail and { url = cfg.Thumbnail } or nil,
--     footer    = { text = cfg.FooterText, icon_url = cfg.FooterIcon },
--
-- `cfg` was a config table that was ALWAYS EMPTY -- read first as a global in
-- cis_core's Lua state, then through cis_libs, which hands a foreign caller an
-- empty table by design and will not re-export webhook configuration across a
-- resource boundary. So the footer object was built with both fields nil,
-- `json.encode` dropped both keys, and the payload carried `"footer":{}`.
--
-- Discord validates embeds and rejects one whose `footer` carries neither text
-- nor an icon -- with a 400 for the WHOLE request. Every message this platform
-- has ever sent to Discord was therefore a 400. The adapter counted that as an
-- unhappy endpoint, backed off to sixty seconds, and an operator saw a webhook
-- that "stopped working some time ago" and no error naming the cause.
--
-- A missing decoration cost the whole feature. The rule below is therefore
-- "omit an optional section entirely rather than include it empty", and the test
-- that keeps it is `test/adapters.lua`, which builds a payload and asserts that
-- no key of it is an empty table.

local M = {}

-- The colours cis_libs asks for by name. A name that is not here falls back to
-- `default`, which is Discord's own "no colour specified" -- it renders the
-- embed with a grey sidebar rather than rejecting it.
local colors = {
    default = 0,
    white = 16777215,
    black = 0,
    red = 16711680,
    green = 65280,
    blue = 255,
    orange = 16753920,
    yellow = 16776960,
    lightblue = 8900331,
}

M.colors = colors

--- Build the webhook payload for one log line.
---
--- `version` is passed in rather than read here: `GetResourceMetadata` is a
--- FiveM global, and a builder that cannot be loaded outside the engine is a
--- builder that cannot be tested. The caller reads it, once per batch, because
--- it does not change while the process runs.
---
--- @param title string
--- @param message string
--- @param color string|nil  one of M.colors, by name
--- @param version string|nil  the cis_libs version, for the author line
--- @return table
function M.build(title, message, color, version)
    return {
        username = 'cis_libs',
        embeds = {
            {
                author = { name = 'cis_libs  -  Version: ' .. tostring(version) },
                color = colors[color] or colors.default,
                title = '**' .. tostring(title) .. '**',
                description = tostring(message),
                -- No thumbnail, no footer, no fields, no icon. Deliberately.
                -- Discord rejects an embed whose `footer` or `author` object
                -- carries neither a text nor an icon, so an optional section
                -- that is included-but-empty is strictly worse than one that is
                -- absent. An operator who wants cosmetics has this one function
                -- to edit, which is the right place: it is the only place that
                -- cannot contradict cis_libs about what is actually configured.
            },
        },
    }
end

-- PUBLISHED AS WELL AS RETURNED.
--
-- A global, not only a return value, because the consumer is a DIFFERENT FILE
-- in the same resource and the manifest is what guarantees the order they load
-- in. `return` alone would mean `require`, and `require` is a load-time
-- mechanism nothing in this platform proves: every sibling resource loads shared
-- code through explicit fxmanifest entries, not one dotted `require` between
-- them. If that assumption is wrong the resource does not start, which is the
-- one failure a customer cannot work around.
--
-- The global is namespaced for the same reason every other global here is --
-- `test/globals.lua` asserts that exactly one file may create it, so an
-- accidental second writer is a test failure rather than a mystery six months
-- later.
CisBridgeEmbed = M

return M
