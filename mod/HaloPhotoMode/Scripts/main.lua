-- Session and input scheduling adapted from Denshattack! Photo Camera (MIT).
local folder = assert(debug.getinfo(1, "S").source:match("^@(.+[/\\])"))
local session = dofile(folder .. "session.lua")
local optics = dofile(folder .. "optics.lua")
local focus = dofile(folder .. "focus.lua")
local finder = dofile(folder .. "finder.lua")
local shutter = dofile(folder .. "shutter.lua")
local gamepad = dofile(folder .. "gamepad.lua")
local mouselook = dofile(folder .. "mouselook.lua")
local current

local function log(message)
    print("[HaloPhotoMode] " .. tostring(message) .. "\n")
end

local keys = {}
local function key(name)
    if not keys[name] then keys[name] = {KeyName = FName(name)} end
    return keys[name]
end

local function analog(pc, name)
    return pc:GetInputAnalogKeyState(key(name))
end

local function readAxes(s, now)
    local function held(name) return s.pc:IsInputKeyDown(key(name)) end
    local function axis(positive, negative)
        return (held(positive) and 1 or 0) - (held(negative) and 1 or 0)
    end
    local axes = {
        forward = axis("W", "S"), right = axis("D", "A"), up = axis("E", "Q"),
        yaw = axis("Right", "Left"), pitch = axis("Up", "Down"), roll = axis("X", "Z"),
        zoom = axis("RightBracket", "LeftBracket"), speed = 1,
    }
    if held("LeftControl") or held("RightControl") then axes.speed = 0.2
    elseif held("LeftShift") or held("RightShift") then axes.speed = 4 end
    gamepad.apply(axes, analog, s.pc)
    axes.up = math.max(-1, math.min(1, axes.up + axis("Gamepad_RightShoulder", "Gamepad_LeftShoulder")))
    axes.mouseYaw, axes.mousePitch = s.mouse(now)
    return axes
end

-- A title build can expose the camera without exposing its DOF settings or
-- collision trace. Preserve the session and shutter if a focus call fails.
local function tryFocus(s, operation, ...)
    local ok, result = pcall(operation, s, ...)
    if ok then return result end
    focus.warn(s, "Focus control unavailable", result)
end

local function apply(s, pose)
    local previousFov = s.pose.fov
    local result, reason = session.apply(s, pose)
    assert(result ~= false, reason)
    if previousFov ~= pose.fov then tryFocus(s, focus.refresh) end
end

local function setVisible(s, show)
    if s.finder then assert(finder.visible(s.finder, show)) end
end

local function draw(s)
    if not s.showFinder or not s.finder then return end
    local width, height = session.viewport(s)
    local crop = optics.crop(width, height, s.frame, s.portrait)
    local name = optics.frames[s.frame]
    if s.portrait and s.frame ~= 1 then name = name .. " portrait" end
    local label = ("%.1f mm   %s   %d × %d\nF9  PNG     F5  Frame     F7  Lens     F8  Resume")
        :format(optics.focalLength(s.pose.fov), name, crop.w, crop.h)
    local focusText = focus.status(s)
    if focusText then label = label .. "\n" .. focusText end
    if s.status then label = label .. "\n" .. s.status end
    assert(finder.update(s.finder, width, height, crop, label, s.grid))
end

local function finish(s)
    if current ~= s then return end
    current = nil
    local function cleanup(fn, ...)
        local ok, result, why = pcall(fn, ...)
        if not ok or result == false then log(why or result or "Cleanup failed") end
    end
    if s.loop then cleanup(CancelDelayedAction, s.loop) end
    if s.pending and s.pending.shot then cleanup(shutter.cancel, s.pending.shot) end
    if s.finder then cleanup(finder.close, s.finder) end
    local ok, restored, reason = pcall(session.close, s)
    if ok and restored then log("Gameplay restored")
    else log("Gameplay restoration: " .. tostring(reason or restored)) end
end

local function shotDone(s, saved, detail)
    s.pending = nil
    log((saved and "PNG saved: " or "PNG failed: ") .. tostring(detail))
    if s.resumeRequested then finish(s); return end
    s.status = saved and "PNG saved" or ("PNG failed: " .. tostring(detail))
    draw(s)
    setVisible(s, s.showFinder)
end

local function advanceShot(s, now)
    local pending = s.pending
    local width, height = session.viewport(s)
    if width ~= pending.width or height ~= pending.height then
        if pending.shot then shutter.cancel(pending.shot) end
        shotDone(s, false, "Viewport changed during capture")
        return
    end
    if pending.shot then
        local state, detail = shutter.poll(pending.shot, width, height)
        if state ~= "pending" then shotDone(s, state == "saved", detail) end
        return
    end
    if os.time() - pending.started >= 5 then
        shotDone(s, false, "Timed out waiting for the hidden viewfinder frame")
        return
    end
    -- World real time advances once per engine frame even when the game is
    -- paused. ProcessEvent can dispatch twice in one frame. Two distinct
    -- advances leave an intervening frame to render the hidden overlay.
    if now <= pending.lastFrame then return end
    pending.lastFrame = now
    pending.frames = pending.frames + 1
    if pending.frames < 2 then return end
    local reason
    pending.shot, reason = shutter.begin(s, pending.crop, width, height)
    if not pending.shot then shotDone(s, false, reason) end
end

local function tick(s)
    local alive, reason = session.alive(s)
    assert(alive, reason or "Camera session expired")
    local now = session.time(s)
    local dt = math.max(0, now - s.previousTime)
    s.previousTime = now
    if s.pending then
        advanceShot(s, now)
    elseif dt > 0 then
        local nextPose = optics.move(s.pose, dt, readAxes(s, now))
        if nextPose then apply(s, nextPose) end
        tryFocus(s, focus.track, now)
        draw(s)
    end
end

local function guarded(action)
    local ok, reason = pcall(action)
    if not ok then
        log(reason)
        if current then finish(current) end
    end
end

local function enter()
    local s, reason = session.open()
    if not s then log("Entry failed: " .. tostring(reason)); return end
    current = s
    s.frame, s.lensIndex, s.portrait, s.grid, s.showFinder = 1, 0, false, false, true
    s.mouse = mouselook.reader(s.pc, analog)
    s.previousTime = session.time(s)
    s.mouse(s.previousTime)
    s.finder, reason = finder.open(s.pc)
    if not s.finder then log("Finder unavailable: " .. tostring(reason)) end
    draw(s)
    setVisible(s, true)
    local function update()
        if current == s then guarded(function() tick(s) end) end
    end
    if EngineTickAvailable then s.loop = LoopInGameThreadAfterFrames(1, update)
    else s.loop = LoopInGameThreadWithDelay(16, update) end
    assert(s.loop, "Could not start the photo update loop")
    log("Photo mode active. F9 saves PNG. F8 resumes gameplay.")
end

local function capture(s)
    local width, height = session.viewport(s)
    local crop = optics.crop(width, height, s.frame, s.portrait)
    local now = session.time(s)
    tryFocus(s, focus.track, now, true)
    setVisible(s, false)
    s.pending = {width = width, height = height, crop = crop, frames = 0,
        lastFrame = now, started = os.time()}
end

local function changePose(s, field, value)
    local pose = {}
    for name, old in pairs(s.pose) do pose[name] = old end
    pose[field] = value
    apply(s, pose)
end

local function focusAction(operation, direction)
    return function(s)
        local feedback = tryFocus(s, operation, direction)
        if feedback then log(feedback) end
    end
end

local actions = {
    F5 = function(s) s.frame = s.frame % #optics.frames + 1 end,
    F6 = function(s) s.portrait = not s.portrait end,
    F7 = function(s)
        s.lensIndex = s.lensIndex % #optics.lenses + 1
        changePose(s, "fov", optics.lensFov(optics.lenses[s.lensIndex]))
    end,
    F9 = capture,
    F10 = function(s) changePose(s, "roll", 0) end,
    B = focusAction(focus.toggle),
    N = focusAction(focus.autofocus),
    T = focusAction(focus.toggleTracking),
    J = focusAction(focus.manual, -1),
    K = focusAction(focus.manual, 1),
    L = focusAction(focus.fineStep),
    U = focusAction(focus.aperture, -1),
    I = focusAction(focus.aperture, 1),
    Y = focusAction(focus.strength),
    G = function(s) s.grid = not s.grid end,
    H = function(s)
        s.showFinder = not s.showFinder
        draw(s)
        setVisible(s, s.showFinder)
    end,
}

local function toggle()
    if not current then enter()
    elseif not current.pending then finish(current)
    elseif not current.resumeRequested then
        current.resumeRequested = true
        log("Resume requested. Waiting for PNG.")
    end
end

if not (EngineTickAvailable or ProcessEventAvailable) then
    log("Could not initialize: UE4SS has no game-thread scheduler")
    return
end
local method = EngineTickAvailable and EGameThreadMethod.EngineTick or EGameThreadMethod.ProcessEvent
RegisterKeyBind(Key.F8, function()
    ExecuteInGameThread(function() guarded(toggle) end, method)
end)
for name, action in pairs(actions) do
    RegisterKeyBind(Key[name], function()
        local s = current
        if s and not s.pending then
            ExecuteInGameThread(function()
                if current == s and not s.pending then
                    guarded(function()
                        local alive, reason = session.alive(s)
                        assert(alive, reason or "Camera session expired")
                        action(s)
                    end)
                end
            end, method)
        end
    end)
end
-- A canceled native screenshot can finish writing after the session closes.
-- The shutter returns immediately when no late staging file needs cleanup.
LoopInGameThreadWithDelay(1000, shutter.reap)
log("Loaded. F8 enters photo mode in a playable campaign.")
