local base = "mod/HaloPhotoMode/Scripts/"
local studio, focus, optics = dofile(base.."studio.lua"), dofile(base.."focus.lua"), dofile(base.."optics.lua")
local path = os.tmpname()
os.remove(path)
local chromaticCalls = 0
local rejectChromatic = false
local chromatic = {
    get = function(s) return s.chromaticMode or "Game" end,
    set = function(s, mode)
        chromaticCalls = chromaticCalls + 1
        if rejectChromatic then return false, "fixture refused" end
        s.chromaticMode = mode
        return true, mode
    end,
}
local function open(fov)
    local s = {pose={fov=fov}, frame=1, portrait=false, lensIndex=0, grid=false, showFinder=true}
    s.lens = {PostProcessSettings={DepthOfFieldFstop=4, DepthOfFieldSensorWidth=36,
        DepthOfFieldFocalDistance=0, bOverride_DepthOfFieldSensorWidth=false, bOverride_DepthOfFieldFocalDistance=false}}
    assert(studio.open(s, optics, focus, function(session, key, value)
        session.pose[key] = value
    end, path, chromatic))
    return s
end
local function select(s, label)
    for i=1,#studio.model(s).rows do
        local model = studio.model(s)
        if model.rows[model.selected].label == label then return model.rows[model.selected].value end
        studio.navigate(s, 1)
    end
    error("Missing " .. label)
end
local function change(s, field, delta)
    select(s, field)
    studio.adjust(s, delta)
    return select(s, field)
end
local s = open(90)
assert(not studio.model(s) and not s.focus and chromaticCalls == 0)
studio.navigate(s, 1); studio.adjust(s, 1)
assert(not s.captureEXR and not s.focus)
assert(studio.toggle(s) and studio.model(s).selected == 1 and studio.model(s).detail:find("LogC3"))
assert(select(s, "F9 output") == "PNG" and change(s, "F9 output", 1) == "PNG + linear EXR")
assert(change(s, "Orientation", 1) == "Viewport")
assert(studio.model(s).notice:find("frame ratio"))
assert(change(s, "Frame", 1) == "3:2" and change(s,"Orientation",1) == "Portrait")
assert(change(s, "Lens", 1) == "24.0 mm" and change(s, "Lens",-1) == "16.0 mm")
assert(change(s, "Aperture", 1) == "f/3.2" and change(s,"DOF strength",-1) == "8×")
assert(change(s, "Focus step",1) == "1%" and change(s, "Focus distance",1) == "3.03 m")
assert(select(s, "Depth of field") == "On" and select(s, "Focus mode") == "Manual")
assert(change(s, "Focus mode", -1) == "AF-C")
assert(change(s, "Thirds grid",1) == "On" and change(s,"Viewfinder",1) == "Off")
assert(change(s, "Chromatic aberration",1) == "Off" and chromaticCalls == 1)
assert(not studio.toggle(s) and not studio.model(s))
local nextSession = open(72)
assert(nextSession.captureEXR and nextSession.frame == s.frame and nextSession.portrait)
assert(nextSession.grid and not nextSession.showFinder and nextSession.pose.fov == s.pose.fov)
assert(chromatic.get(nextSession) == "Off" and chromaticCalls == 2)
local nextFocus = focus.values(nextSession)
assert(nextFocus.fine and nextFocus.aperture == 3.2 and nextFocus.strength == 8)
assert(nextFocus.mode == "Manual" and nextFocus.distance == 300 and not nextFocus.enabled)
assert(studio.toggle(nextSession) and change(nextSession, "Chromatic aberration",-1) == "Game")
local calls = chromaticCalls
local recovered = open(86)
assert(chromaticCalls == calls and chromatic.get(recovered) == "Game")
-- Edits to the same dials through camera shortcuts survive the save at exit.
recovered.frame = 4
assert(studio.save(recovered) and open(86).frame == 4)
os.remove(path..".bak")
assert(os.rename(path, path..".bak"))
local bad = assert(io.open(path, "wb")); bad:write("version=1\nframe=999\n"); bad:close()
assert(open(70).frame == 4)
os.remove(path..".bak")
local corrupted = open(70)
assert(corrupted.frame == 1 and corrupted.pose.fov == 70 and not corrupted.focus)
studio.toggle(corrupted)
rejectChromatic = true
assert(change(corrupted, "Chromatic aberration",1) == "Game")
assert(studio.model(corrupted).notice == "Chromatic control unavailable")
-- An unsupported optional focus operation keeps the menu usable.
corrupted.lens.PostProcessSettings = {}
assert(change(corrupted, "Depth of field",1) == "Off" and studio.model(corrupted).notice:find("unavailable"))
assert(change(corrupted, "Frame",-1) == optics.frames[#optics.frames])
os.remove(path)
os.remove(path..".bak")
print("Studio menu and preferences tests passed")
