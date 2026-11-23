-- Adapted from Denshattack! Photo Camera, copyright (c) 2026 NewBarkTownKris (MIT).
local focus = {}

local apertures = {1, 1.1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5,
    4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16}
local strengths = {1, 2, 4, 8}
local sensorWidth = 36 -- mm, the horizontal gate used by the camera
local maxDistance = 1000000 -- cm
local traceInterval = 0.125 -- real seconds
local defaults = {enabled = false, distance = 300, aperture = 10, strength = 1, mode = "Manual"}

local function settings(session)
    if not session.focus then
        session.focus = {}
        for key, value in pairs(defaults) do session.focus[key] = value end
    end
    return session.focus
end

local function focalLength(session)
    return sensorWidth / (2 * math.tan(math.rad(session.pose.fov) / 2))
end

local function focusDistance(session, distance)
    -- A physical lens cannot form an image of a subject inside its focal length.
    local minimum = math.max(2, focalLength(session) * 1.05 / 10)
    return math.max(minimum, math.min(maxDistance, distance))
end

-- Values for the Studio are readable before the first focus command. Opening
-- the menu must leave the game camera's depth of field alone.
function focus.values(session)
    local s = session.focus or defaults
    return {enabled = s.enabled, mode = s.mode, distance = focusDistance(session, s.distance),
        fine = s.fine == true, aperture = apertures[s.aperture], strength = strengths[s.strength]}
end

function focus.status(session)
    local s = session.focus
    if not s then return end
    local mode = s.enabled and s.mode or "Photo DOF off"
    local focus = focusDistance(session, s.distance)
    local status = ("%s | %.2f m | f/%g equiv. | %dx DOF"):format(mode,
        focus / 100, apertures[s.aperture], strengths[s.strength])
    if s.fine ~= nil then status = status .. (s.fine and " | 1% step" or " | 20% step") end
    if s.focusIssue then return status .. " | " .. s.focusIssue end
    if not s.sampled then return status end
    if not s.subject then return status .. " | No center target" end
    if not s.enabled then return status end
    -- Compare the subject's circle of confusion with the conventional
    -- 0.03 mm limit on a 35 mm frame. The same equivalent aperture drives DOF.
    local focal = focalLength(session)
    local fStop = apertures[s.aperture] / strengths[s.strength]
    local blur = focal^2 * math.abs(1 - focus / s.subject) / (fStop * (10 * focus - focal))
    local aid = "Aligned"
    if blur > 0.03 then aid = s.subject < focus and "Focus nearer" or "Focus farther" end
    return ("%s | Subject %.2f m | %s"):format(status, s.subject / 100, aid)
end

function focus.warn(session, description, reason)
    local s = settings(session)
    if s.focusIssue ~= description then
        print("[HaloPhotoMode] " .. description .. ": " .. tostring(reason) .. "\n")
    end
    s.focusIssue = description
end

local function readOverrides(pp)
    local values = {
        DepthOfFieldSensorWidth = pp.DepthOfFieldSensorWidth,
        DepthOfFieldFocalDistance = pp.DepthOfFieldFocalDistance,
        bOverride_DepthOfFieldSensorWidth = pp.bOverride_DepthOfFieldSensorWidth,
        bOverride_DepthOfFieldFocalDistance = pp.bOverride_DepthOfFieldFocalDistance,
    }
    assert(type(values.DepthOfFieldSensorWidth) == "number" and type(values.DepthOfFieldFocalDistance) == "number"
        and type(values.bOverride_DepthOfFieldSensorWidth) == "boolean"
        and type(values.bOverride_DepthOfFieldFocalDistance) == "boolean", "Camera focus overrides unavailable")
    return values
end

local function writeOverrides(pp, values)
    pp.DepthOfFieldSensorWidth = values.DepthOfFieldSensorWidth
    pp.DepthOfFieldFocalDistance = values.DepthOfFieldFocalDistance
    pp.bOverride_DepthOfFieldSensorWidth = values.bOverride_DepthOfFieldSensorWidth
    pp.bOverride_DepthOfFieldFocalDistance = values.bOverride_DepthOfFieldFocalDistance
end

local function apply(session, changes)
    local old = settings(session)
    local s = {}
    for key, value in pairs(old) do s[key] = value end
    for key, value in pairs(changes) do s[key] = value end
    if s.enabled or old.enabled then
        local pp = session.lens.PostProcessSettings
        local previous = readOverrides(pp)
        if not old.enabled then s.baseline = previous end
        local wanted = s.baseline
        if s.enabled then
            local distance = focusDistance(session, s.distance)
            local focusMm = distance * 10
            local focalMm = focalLength(session)
            local engineFstop = pp.DepthOfFieldFstop
            assert(type(engineFstop) == "number" and engineFstop > 0, "No usable camera f-stop for DOF")
            local targetFstop = apertures[s.aperture] / strengths[s.strength]
            -- At a fixed FOV, focal length scales with the sensor width. Solve
            -- for a width giving the same normalized thin-lens circle of confusion
            -- as a 36 mm camera at targetFstop. Unreal also uses its f-stop for
            -- physical exposure, so leave that property and the exposure meter alone.
            local width = sensorWidth * engineFstop * focusMm /
                (targetFstop * (focusMm - focalMm) + engineFstop * focalMm)
            wanted = {
                DepthOfFieldSensorWidth = width, DepthOfFieldFocalDistance = distance,
                bOverride_DepthOfFieldSensorWidth = true, bOverride_DepthOfFieldFocalDistance = true,
            }
        else
            s.baseline = nil
        end
        local ok, err = pcall(writeOverrides, pp, wanted)
        if not ok then
            local restored, reason = pcall(writeOverrides, pp, previous)
            if not restored then error(tostring(err) .. " (could not restore focus settings: " .. tostring(reason) .. ")") end
            error(err)
        end
    end
    s.focusIssue = nil
    session.focus = s
    return focus.status(session)
end

function focus.toggle(session)
    return apply(session, {enabled = not settings(session).enabled})
end

-- Recalculate the optical model after a change to the horizontal field of view.
function focus.refresh(session)
    if session.focus and session.focus.enabled then apply(session, {}) end
end

function focus.fineStep(session)
    local s = settings(session)
    s.fine = not s.fine
    return focus.status(session)
end

function focus.manual(session, direction)
    local oldDistance = focusDistance(session, settings(session).distance)
    local factor = session.focus.fine and 1.01 or 1.20
    return apply(session, {enabled = true, mode = "Manual",
        distance = focusDistance(session, oldDistance * factor ^ direction)})
end

function focus.aperture(session, direction)
    local index = math.max(1, math.min(#apertures, settings(session).aperture + direction))
    return apply(session, {aperture = index})
end

function focus.setStrength(session, index)
    assert(strengths[index], "Unsupported depth-of-field strength")
    if settings(session).strength == index then return focus.status(session) end
    return apply(session, {strength = index})
end

function focus.strength(session, direction)
    return focus.setStrength(session, (settings(session).strength - 1 + (direction or 1)) % #strengths + 1)
end

local function backingBody(session)
    local actor = session.pawn:GetBlamObjectActor()
    if not actor or not actor:IsValid() then return end
    local world = actor:GetWorld()
    if world and world:IsValid() and world:GetAddress() == session.world:GetAddress() then return actor end
end

-- Optional metadata can be absent on older builds and in stripped hit results.
local function optional(read)
    local ok, value = pcall(read)
    if ok then return value end
end

local function valid(object)
    return object and object:IsValid() and object or nil
end

local function included(actors, actor)
    if not actor then return false end
    for _, item in ipairs(actors) do
        if item == actor then return true end
        local a = optional(function() return item:GetAddress() end)
        if a and a == optional(function() return actor:GetAddress() end) then return true end
    end
    return false
end

local function nearHitInfo(ref)
    local info = {}
    local component = optional(function()
        -- A weak pointer exposes Get(). A resolved UObject can reject this lookup.
        local get = optional(function() return ref.Get end)
        if type(get) == "function" then ref = get(ref) end
        return valid(ref)
    end)
    if not component then return info end
    info.visible = optional(function() return component:IsVisible() end)
    info.componentHidden = optional(function() return component.bHiddenInGame end)
    local actor = optional(function() return valid(component:GetOwner()) end)
    if not actor then return info end
    info.actor = actor
    info.hidden = optional(function() return actor.bHidden end)
    info.class = optional(function() return valid(actor:GetClass()):GetFullName() end)
    info.owner = optional(function() return valid(actor:GetOwner()) end)
    info.parent = optional(function() return valid(actor:GetAttachParentActor()) end)
    return info
end

local function reportNearHit(session, info, distance, ignored)
    local count = session.nearFocusReports or 0
    if count >= 2 then return end
    session.nearFocusReports = count + 1
    local function name(actor)
        return optional(function() return actor:GetFullName() end) or "unavailable"
    end
    local names = {}
    for _, actor in ipairs(ignored) do names[#names + 1] = name(actor) end
    print(("[HaloPhotoMode] Near focus hit %.2f m, component owner %s, class %s, bHidden %s, owner %s, "
        .. "attach parent %s, component visible %s, component hidden in game %s, trace exclusions [%s]\n")
        :format(distance / 100, name(info.actor), info.class or "unavailable", tostring(info.hidden),
            name(info.owner), name(info.parent), tostring(info.visible), tostring(info.componentHidden),
            table.concat(names, ", ")))
end

local function skipNearActor(info, localActors)
    if not info.actor then return false end
    if info.hidden == true or included(localActors, info.owner) or included(localActors, info.parent) then return true end
    -- Weapon collision can outlive the weapon mesh in first person. Ordinary
    -- scenery frequently uses invisible collision components for visible geometry.
    return info.class and info.class:lower():find("weapon", 1, true)
        and (info.componentHidden == true or info.visible == false)
end

local function centerDistance(session)
    local system = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    assert(system and system:IsValid(), "Unreal collision tracing is unavailable")
    local pose, keys = session.pose, session.positionKeys
    local pitch, yaw = math.rad(pose.pitch), math.rad(pose.yaw)
    local horizontal = maxDistance * math.cos(pitch)
    local start = {[keys.x] = pose.x, [keys.y] = pose.y, [keys.z] = pose.z}
    local finish = {
        [keys.x] = pose.x + horizontal * math.cos(yaw),
        [keys.y] = pose.y + horizontal * math.sin(yaw),
        [keys.z] = pose.z + maxDistance * math.sin(pitch),
    }
    local color = {R = 0, G = 0, B = 0, A = 0}
    -- Hidden local models retain their collision near the entry eye. Read the
    -- session's current list on each trace so the visible Spartan can be focused.
    local ignored, pawnHidden = {}, false
    if session.body then
        for _, actor in ipairs(session.body.hidden) do
            if actor:IsValid() and actor.bHidden then
                ignored[#ignored + 1] = actor
                if actor == session.pawn then pawnHidden = true end
            end
        end
    end
    if pawnHidden then
        local ok, backing = pcall(backingBody, session)
        if ok and backing then
            ignored[#ignored + 1] = backing
        elseif not ok and not session.backingFocusReported then
            session.backingFocusReported = true
            print("[HaloPhotoMode] Local Blam focus actor unavailable: " .. tostring(backing) .. "\n")
        end
    end
    -- Keep the origin fixed so each distance stays relative to the lens. At
    -- most three near actors can be skipped in one focus sample.
    local localActors = {table.unpack(ignored)}
    for attempt = 1, 4 do
        local hit = {}
        if not system:LineTraceSingle(session.camera, start, finish, 0, true, ignored, 0, hit, true, color, color, 0) then return end
        local distance, component
        for key, value in pairs(hit) do
            if type(key) == "string" then
                local field = key:lower()
                if field == "distance" then distance = value
                elseif field == "component" then component = value end
            end
        end
        if type(distance) ~= "number" or not (distance > 0 and distance <= maxDistance) then return end
        if not pawnHidden or distance >= 100 then return distance end
        local info = nearHitInfo(component)
        if not skipNearActor(info, localActors) then
            reportNearHit(session, info, distance, ignored)
            return distance
        end
        if attempt == 4 or included(ignored, info.actor) then
            reportNearHit(session, info, distance, ignored)
            return
        end
        ignored[#ignored + 1] = info.actor
    end
end

function focus.autofocus(session)
    local distance = centerDistance(session)
    local s = settings(session)
    s.sampled, s.subject, s.focusIssue = true, distance, nil
    if distance then
        return apply(session, {enabled = true, mode = "AF lock", distance = focusDistance(session, distance)})
    end
    return "AF found no focusable surface | " .. focus.status(session)
end

function focus.toggleTracking(session)
    local s = settings(session)
    if s.enabled and s.mode == "AF-C" then return apply(session, {mode = "AF lock"}) end
    return apply(session, {enabled = true, mode = "AF-C", nextTrace = 0})
end

function focus.setMode(session, mode)
    if mode == "AF lock" then return focus.autofocus(session) end
    assert(mode == "Manual" or mode == "AF-C", "Unknown focus mode")
    return apply(session, {enabled = true, mode = mode, nextTrace = 0})
end

-- Restore only the physical dials. Each photo session starts with its own
-- focus mode, distance and baseline on the new camera component.
function focus.restoreDials(session, aperture, strength, fine)
    local changes = {}
    for index, value in ipairs(apertures) do
        if value == aperture then changes.aperture = index end
    end
    for index, value in ipairs(strengths) do
        if value == strength then changes.strength = index end
    end
    if type(fine) == "boolean" then changes.fine = fine end
    if next(changes) then return apply(session, changes) end
end

-- A short exposure and every pose of a timed exposure retain the same
-- focus. The caller stops ticking once the shutter opens and may request
-- a final AF-C reading at the instant it opens.
function focus.track(session, now, shutter)
    local s = session.focus
    if not s or session.pending or not s.enabled or (shutter and s.mode ~= "AF-C") then return end
    if not shutter and now < (s.nextTrace or 0) then return end
    s.nextTrace = now + traceInterval
    local ok, distance = pcall(centerDistance, session)
    s.sampled = true
    if not ok then
        s.subject, s.nextTrace = nil, now + 2
        focus.warn(session, "Focus range unavailable", distance)
        return
    end
    s.subject = distance
    if s.mode == "AF-C" and distance then
        local target = focusDistance(session, distance)
        if math.abs(target - s.distance) > 0.001 then
            local moved, why = pcall(apply, session, {distance = target})
            if not moved then
                focus.warn(session, "Focus adjustment unavailable", why)
                s.nextTrace = now + 2
                return
            end
        end
    end
    session.focus.focusIssue = nil
end

return focus
