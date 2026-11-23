-- Adapted from Denshattack! Photo Camera (MIT). Only the detached lens owns
-- these overrides. SceneFringeIntensity of zero disables the built-in effect.
local chromatic = {}
local fields = {"SceneFringeIntensity", "bOverride_SceneFringeIntensity"}
local off = {SceneFringeIntensity = 0, bOverride_SceneFringeIntensity = true}

function chromatic.get(s)
    return s.chromaticOverride and s.chromaticOverride.applied and "Off" or "Game"
end

local function restore(s, state, rollback)
    if state.lens:IsValid() then
        local pp = state.lens.PostProcessSettings
        -- The value and its override flag act as a pair. A new edit from
        -- another camera tool takes ownership of that pair.
        if state.applied and (pp.SceneFringeIntensity ~= 0 or pp.bOverride_SceneFringeIntensity ~= true) then
            s.chromaticOverride = nil
            return
        end
        state.applied = false
        for i = #state.changed, 1, -1 do
            local field = state.changed[i]
            if pp[field] ~= state.original[field] and (rollback or pp[field] == off[field]) then
                pp[field] = state.original[field]
                assert(pp[field] == state.original[field], "Could not restore camera " .. field)
            end
            table.remove(state.changed, i)
        end
    end
    s.chromaticOverride = nil
end

function chromatic.set(s, mode)
    if mode ~= "Game" and mode ~= "Off" then return false, "Unknown chromatic aberration mode" end
    local ok, reason = pcall(function()
        local state = s.chromaticOverride
        if mode == "Game" then
            if state then restore(s, state, false) end
            return
        end
        if state and state.applied then return end
        if state then restore(s, state, false) end
        local lens = s.lens
        assert(lens and lens:IsValid(), "Detached lens unavailable")
        assert(lens.PostProcessBlendWeight == 1, "Chromatic control requires full camera post-process weight")
        local pp = lens.PostProcessSettings
        local original = {}
        for _, field in ipairs(fields) do
            original[field] = pp[field]
            assert(type(original[field]) == type(off[field]), "Missing camera property " .. field)
        end
        state = {lens = lens, original = original, changed = {}}
        s.chromaticOverride = state
        local applied, why = pcall(function()
            for _, field in ipairs(fields) do
                if original[field] ~= off[field] then
                    state.changed[#state.changed + 1] = field
                    pp[field] = off[field]
                    assert(pp[field] == off[field], "Camera rejected " .. field)
                end
            end
        end)
        if not applied then
            restore(s, state, true)
            error(why, 0)
        end
        state.applied = true
    end)
    if not ok then return false, tostring(reason) end
    return true, mode == "Off" and "Chromatic aberration off" or "Chromatic aberration follows the game"
end

function chromatic.close(s)
    return chromatic.set(s, "Game")
end

return chromatic
