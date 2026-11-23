local chromatic = dofile("mod/HaloPhotoMode/Scripts/chromatic.lua")

local function fixture(intensity, override)
    local state = {
        values = {SceneFringeIntensity = intensity, bOverride_SceneFringeIntensity = override,
            ChromaticAberrationStartOffset = 0.31, DepthOfFieldFocalDistance = 500, BloomIntensity = 2},
        writes = 0, valid = true,
    }
    local pp = setmetatable({}, {
        __index = state.values,
        __newindex = function(_, key, value)
            assert(key == "SceneFringeIntensity" or key == "bOverride_SceneFringeIntensity")
            state.writes = state.writes + 1
            if key == state.ignore then return end
            state.values[key] = value
            if key == state.failOnce then
                state.failOnce = nil
                error("setter failed after mutation")
            end
        end,
    })
    local lens = {PostProcessSettings = pp, PostProcessBlendWeight = 1, IsValid = function() return state.valid end}
    return {lens = lens}, state
end

for _, original in ipairs({{0, false}, {2.5, false}, {2.5, true}, {0, true}}) do
    local s, t = fixture(table.unpack(original))
    assert(chromatic.get(s) == "Game" and chromatic.set(s, "Game") and t.writes == 0)
    assert(chromatic.set(s, "Off") and chromatic.get(s) == "Off")
    assert(t.values.SceneFringeIntensity == 0 and t.values.bOverride_SceneFringeIntensity)
    local count = t.writes
    assert(chromatic.set(s, "Off") and t.writes == count)
    assert(chromatic.close(s) and chromatic.close(s) and chromatic.get(s) == "Game")
    assert(t.values.SceneFringeIntensity == original[1] and t.values.bOverride_SceneFringeIntensity == original[2])
end

local s, t = fixture(4, false)
t.failOnce = "bOverride_SceneFringeIntensity"
assert(not chromatic.set(s, "Off") and chromatic.get(s) == "Game")
assert(t.values.SceneFringeIntensity == 4 and t.values.bOverride_SceneFringeIntensity == false)
t.ignore = "SceneFringeIntensity"
assert(not chromatic.set(s, "Off") and chromatic.get(s) == "Game")
t.ignore = nil
assert(chromatic.set(s, "Off"))
t.values.SceneFringeIntensity = 3.2 -- External edit also expects to keep its active override.
assert(chromatic.set(s, "Game") and t.values.SceneFringeIntensity == 3.2 and t.values.bOverride_SceneFringeIntensity)
assert(not chromatic.set(s, "Unknown"))

s, t = fixture(4, false)
assert(chromatic.set(s, "Off"))
t.failOnce = "bOverride_SceneFringeIntensity"
assert(not chromatic.close(s))
assert(chromatic.close(s) and t.values.SceneFringeIntensity == 4 and not t.values.bOverride_SceneFringeIntensity)
s.lens.PostProcessBlendWeight = 0.5
assert(not chromatic.set(s, "Off") and s.lens.PostProcessBlendWeight == 0.5)
s.lens.PostProcessBlendWeight = 1
assert(chromatic.set(s, "Off"))
t.valid = false
assert(chromatic.close(s) and chromatic.get(s) == "Game" and not chromatic.set(s, "Off"))
print("Chromatic aberration override, rollback and restoration passed")
