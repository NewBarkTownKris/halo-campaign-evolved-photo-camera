-- Adapted from Denshattack! Photo Camera, copyright (c) 2026 NewBarkTownKris (MIT).
local function near(a, b)
    assert(math.abs(a - b) <= 1e-6 * math.max(1, math.abs(b)), ("%g != %g"):format(a, b))
end

local camera, world, pawn = {}, {}, {}
local trace = {calls = 0}
function trace:IsValid() return true end
function trace:LineTraceSingle(context, start, finish, channel, complex, ignore, draw, hit, ignoreSelf, _, _, duration)
    self.calls = self.calls + 1
    assert(context == camera and context ~= pawn and ignoreSelf)
    self.lastIgnored = ignore
    assert(channel == 0 and complex and draw == 0 and duration == 0)
    -- Shipping FNames are case preserving. Use mixed-case keys like a reflected call.
    assert(start.x == -203000 and start.Y == 40 and start.z == 120)
    near(finish.x, start.x)
    near(finish.Y - start.Y, 1000000 * math.cos(math.rad(30)))
    near(finish.z - start.z, 500000)
    if self.unavailable then error("trace unavailable") end
    if self.layers then
        for _, layer in ipairs(self.layers) do
            local ignored = false
            for _, actor in ipairs(ignore) do if actor == layer.actor then ignored = true end end
            if not ignored then
                hit.distance, hit.Component = layer.distance, layer.component
                return true
            end
        end
        return false
    end
    hit.distance = self.distance
    hit.Component = self.component
    return self.distance ~= nil
end
local messages = {}
local env = setmetatable({print = function(message) messages[#messages + 1] = message end, StaticFindObject = function(path)
    assert(path == "/Script/Engine.Default__KismetSystemLibrary")
    return trace
end}, {__index = _G})
local focus = assert(loadfile("mod/HaloPhotoMode/Scripts/focus.lua", "t", env))()

local properties = {
    DepthOfFieldSensorWidth = 24.576, bOverride_DepthOfFieldSensorWidth = true,
    DepthOfFieldFocalDistance = 73, bOverride_DepthOfFieldFocalDistance = false,
    DepthOfFieldFstop = 4, CameraISO = 250, AutoExposureBias = -1,
}
local failNextDistance = false
local pp = setmetatable({}, {__index = properties, __newindex = function(_, key, value)
    assert(key:match("DepthOfFieldSensorWidth$") or key:match("DepthOfFieldFocalDistance$"),
        "unexpected change to " .. key)
    if key == "DepthOfFieldFocalDistance" and failNextDistance then
        failNextDistance = false
        error("rejected reflected write")
    end
    properties[key] = value
end})
local s = {camera = camera, world = world, pawn = pawn, lens = {PostProcessSettings = pp},
    positionKeys = {x = "x", y = "Y", z = "z"},
    pose = {x = -203000, y = 40, z = 120, pitch = 30, yaw = 90, roll = 70, fov = 45}}

assert(focus.status(s) == nil)
focus.track(s, 0)
assert(trace.calls == 0 and s.focus == nil, "idle camera touched focus before first use")
assert(focus.autofocus(s):find("no focusable surface"))
assert(not s.focus.enabled and properties.DepthOfFieldFocalDistance == 73)
trace.distance = 123.45
assert(focus.autofocus(s):find("AF lock"))
assert(pp.DepthOfFieldFocalDistance == 123.45 and pp.bOverride_DepthOfFieldFocalDistance)

-- Compare the sensor-normalized blur circle at infinity for the renderer and the
-- equivalent 36 mm aperture. The same factor also applies at finite subject depths.
local function blurCircle(width, fstop, fov, distanceCm)
    local focalMm = width / (2 * math.tan(math.rad(fov) / 2))
    return focalMm ^ 2 / (width * fstop * (distanceCm * 10 - focalMm))
end
local function checkBlur(expected)
    near(blurCircle(pp.DepthOfFieldSensorWidth, pp.DepthOfFieldFstop, s.pose.fov, pp.DepthOfFieldFocalDistance),
        blurCircle(36, expected, s.pose.fov, pp.DepthOfFieldFocalDistance))
end
checkBlur(2.8)
local distance = pp.DepthOfFieldFocalDistance
trace.distance = 0
assert(focus.autofocus(s):find("no focusable surface") and pp.DepthOfFieldFocalDistance == distance)
trace.distance = nil
assert(focus.autofocus(s):find("AF lock") and pp.DepthOfFieldFocalDistance == distance)

assert(focus.manual(s, -1):find("Manual"))
near(pp.DepthOfFieldFocalDistance, distance / 1.20)
assert(focus.fineStep(s):find("1% step", 1, true))
focus.manual(s, 1)
near(pp.DepthOfFieldFocalDistance, distance / 1.20 * 1.01)
assert(focus.aperture(s, 1):find("f/3.2", 1, true))
checkBlur(3.2)
for _, multiplier in ipairs({2, 4, 8, 1}) do
    assert(focus.strength(s):find(multiplier .. "x DOF", 1, true))
    checkBlur(3.2 / multiplier)
end
s.pose.fov = 3
focus.refresh(s)
checkBlur(3.2)
assert(trace.calls == 4, "changing lenses or dials triggered another focus trace")

local beforeText, beforeWidth = focus.status(s), pp.DepthOfFieldSensorWidth
failNextDistance = true
assert(not pcall(focus.aperture, s, 1))
assert(focus.status(s) == beforeText and pp.DepthOfFieldSensorWidth == beforeWidth)
assert(focus.toggle(s):find("Photo DOF off"))
assert(pp.DepthOfFieldFocalDistance == 73 and not pp.bOverride_DepthOfFieldFocalDistance)
assert(pp.DepthOfFieldSensorWidth == 24.576 and pp.bOverride_DepthOfFieldSensorWidth)
focus.aperture(s, -1)
focus.refresh(s)
assert(pp.DepthOfFieldFocalDistance == 73)

trace.distance = 1
focus.autofocus(s)
assert(pp.DepthOfFieldFocalDistance > 36 / (20 * math.tan(math.rad(s.pose.fov) / 2)))
assert(pp.DepthOfFieldFstop == 4 and pp.CameraISO == 250 and pp.AutoExposureBias == -1)

assert(focus.toggleTracking(s):find("AF%-C"))
trace.distance = 500
focus.track(s, 1)
near(pp.DepthOfFieldFocalDistance, 500)
assert(focus.status(s):find("Subject 5.00 m | Aligned", 1, true))
trace.distance = 700
local calls = trace.calls
focus.track(s, 1.10)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 500)
focus.track(s, 1.125)
near(pp.DepthOfFieldFocalDistance, 700)
trace.distance = nil
focus.track(s, 1.25)
assert(focus.status(s):find("No center target") and pp.DepthOfFieldFocalDistance == 700)

-- Refocus at the shutter even if the previous sample is very recent;
-- once capture is pending, every camera pose uses that same plane.
trace.distance = 900
focus.track(s, 1.26, true)
near(pp.DepthOfFieldFocalDistance, 900)
s.pending = {timed=true}
trace.distance = 1100
calls = trace.calls
focus.track(s, 2)
focus.track(s, 2, true)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 900)
s.pending = nil
assert(focus.toggleTracking(s):find("AF lock"))
focus.track(s, 2)
assert(focus.status(s):find("Focus farther") and pp.DepthOfFieldFocalDistance == 900)
trace.distance = 800
focus.track(s, 2.15)
assert(focus.status(s):find("Focus nearer") and pp.DepthOfFieldFocalDistance == 900)

-- The same focus error is sharp on a wide-angle lens and visibly blurred
-- on the telephoto. A stronger DOF effect also narrows the aligned region.
s.pose.fov = 60
focus.refresh(s)
assert(focus.status(s):find("Aligned"))
trace.distance = 520
focus.track(s, 2.30)
assert(focus.status(s):find("Aligned"))
assert(focus.setStrength(s,4):find("Focus nearer"))
assert(focus.setStrength(s,1):find("Aligned"))
assert(not pcall(focus.setStrength, s, 0))

focus.toggleTracking(s)
focus.manual(s, 1)
trace.distance = 450
focus.track(s, 2.50)
near(pp.DepthOfFieldFocalDistance, 909)
assert(s.focus.mode == "Manual" and s.focus.subject == 450)
focus.toggleTracking(s)
assert(focus.autofocus(s):find("AF lock"))
trace.distance = 300
focus.track(s, 2.75)
near(pp.DepthOfFieldFocalDistance, 450)

-- A transient trace or reflected lens write failure cannot close photo mode.
focus.toggleTracking(s)
trace.unavailable = true
focus.track(s, 3)
assert(focus.status(s):find("Focus range unavailable"))
trace.unavailable = false
calls = trace.calls
focus.track(s, 4.90)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 450)
failNextDistance = true
focus.track(s, 5)
assert(focus.status(s):find("Focus adjustment unavailable") and pp.DepthOfFieldFocalDistance == 450)
focus.track(s, 7)
assert(focus.status(s):find("Aligned") and pp.DepthOfFieldFocalDistance == 300)
focus.toggle(s)
calls = trace.calls
focus.track(s, 8)
assert(trace.calls == calls and pp.DepthOfFieldFocalDistance == 73)
assert(focus.fineStep(s):find("20% step", 1, true))
for i = 1, 30 do focus.aperture(s, -1) end
assert(focus.status(s):find("f/1 equiv.", 1, true))
for i = 1, 30 do focus.aperture(s, 1) end
assert(focus.status(s):find("f/16 equiv.", 1, true))
-- Only still-hidden models from this session are skipped, for both N and AF-C.
assert(#trace.lastIgnored == 0)
local valid = function() return true end
pawn.IsValid, pawn.bHidden = valid, true
world.IsValid, world.GetAddress = valid, function() return 17 end
local otherWorld = {IsValid = valid, GetAddress = function() return 18 end}
local backingWorld = world
local backing = {IsValid = valid, GetWorld = function() return backingWorld end}
local backingQueries = 0
function pawn:GetBlamObjectActor()
    backingQueries = backingQueries + 1
    return backing
end
local weapon = {IsValid = valid, bHidden = true}
local visibleWeapon = {IsValid = valid, bHidden = false}
local expired = setmetatable({IsValid = function() return false end}, {
    __index = function() error("inspected an invalid actor") end})
s.body = {hidden = {pawn, expired, weapon, visibleWeapon}}
local owner = {IsValid = valid, GetFullName = function() return "Level.SnowSurface" end}
local component = setmetatable({IsValid = valid, GetOwner = function() return owner end},
    {__index = function(_, key) error("absent component member " .. key) end})
local weak = {Get = function() return component end}
trace.distance, trace.component = 31, component
local startMessages = #messages
focus.autofocus(s)
assert(#trace.lastIgnored == 3 and trace.lastIgnored[1] == pawn and trace.lastIgnored[2] == weapon
    and trace.lastIgnored[3] == backing)
assert(messages[#messages]:find("0.31 m, component owner Level.SnowSurface", 1, true))
trace.component = weak
focus.toggleTracking(s)
focus.track(s, 9)
assert(#trace.lastIgnored == 3 and trace.lastIgnored[3] == backing)
assert(#messages == startMessages + 2 and messages[#messages]:find("component owner Level.SnowSurface", 1, true))
backingWorld = otherWorld
focus.track(s, 9.125)
assert(#trace.lastIgnored == 2 and #messages == startMessages + 2)
backing = expired
focus.autofocus(s)
assert(#trace.lastIgnored == 2 and #messages == startMessages + 2)
s.body.hidden, pawn.bHidden, weapon.bHidden = {}, false, false
local previousQueries = backingQueries
focus.track(s, 9.25)
assert(#trace.lastIgnored == 0 and backingQueries == previousQueries)

local function layer(class, distance, actorHidden, visible, ownerActor, parent)
    local actor = {IsValid = valid, bHidden = actorHidden, GetFullName = function() return "Level." .. class end,
        GetClass = function() return {IsValid = valid, GetFullName = function() return class end} end,
        GetOwner = function() return ownerActor end, GetAttachParentActor = function() return parent end}
    local primitive = {IsValid = valid, GetOwner = function() return actor end, IsVisible = function() return visible end}
    return {actor = actor, component = primitive, distance = distance}
end
s.body.hidden, pawn.bHidden = {pawn}, true
backing = {IsValid = valid, GetWorld = function() return world end}
local heldWeapon = layer("SniperRifle_WeaponActor_C", 31, false, true, pawn)
local attached = layer("Attachment_C", 32, false, true, nil, backing)
local invisibleWeapon = layer("Stowed_WeaponActor_C", 35, false, false)
local nearScenery = layer("SnowBank_C", 39, false, false) -- visible mesh with a separate collision primitive
local far = layer("Mountain_C", 4012, false, true)
trace.layers = {heldWeapon, attached, invisibleWeapon, nearScenery, far}
calls = trace.calls
focus.autofocus(s)
assert(trace.calls == calls + 4 and s.focus.subject == 39)
local hidden = layer("HiddenActor_C", 40, true, true)
local visiblePickup = layer("SniperRifle_WeaponActor_C", 41, false, true)
trace.layers = {hidden, visiblePickup, far}
focus.autofocus(s)
assert(s.focus.subject == 41)
trace.layers = {hidden, heldWeapon, attached, invisibleWeapon, far}
calls = trace.calls
local locked = pp.DepthOfFieldFocalDistance
focus.autofocus(s)
assert(trace.calls == calls + 4 and s.focus.subject == nil and pp.DepthOfFieldFocalDistance == locked)
trace.layers = {heldWeapon, far}
calls = trace.calls
s.body.hidden, pawn.bHidden = {}, false
focus.autofocus(s)
assert(trace.calls == calls + 1 and s.focus.subject == 31)
print("Photo focus checks passed")
