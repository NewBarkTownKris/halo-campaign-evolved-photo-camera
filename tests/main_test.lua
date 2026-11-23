-- Exercise the UE4SS entry point with fake reflected session, finder and renderer.
local scriptRoot = "mod/HaloPhotoMode/Scripts/"
local now, wall, width, height = 10, 200, 1920, 1080
local flags, held, buttons, axes, log = {}, {}, {}, {}, {}
local s, widget, event, activeJob, inactiveReaper
local cameraComponent, camera = {}, {}
local targetDistance, traces = 1000, 0
local opened, closed, moves, captures, polls, cancels, reaps = 0, 0, 0, 0, 0, 0, 0
local stopped, scheduled = {}, {}
local session = {}
function session.open()
    if flags.entry then return nil, "No playable world" end
    opened = opened + 1
    s = {pose = {x = 0, y = 0, z = 2, pitch = 0, yaw = 0, roll = 8, fov = 90}, pc = {},
        lens = cameraComponent, camera = camera, positionKeys = {x = "X", y = "Y", z = "Z"}}
    cameraComponent.PostProcessSettings = {DepthOfFieldSensorWidth = 24, DepthOfFieldFocalDistance = 0,
        bOverride_DepthOfFieldSensorWidth = false, bOverride_DepthOfFieldFocalDistance = false, DepthOfFieldFstop = 4}
    function s.pc:IsInputKeyDown(k) return held[k.KeyName] == true end
    function s.pc:GetInputAnalogKeyState(k) return axes[k.KeyName] or 0 end
    return s
end
function session.close(active) assert(s == active); closed = closed + 1; return true end
function session.alive() return not flags.travel, "world changed" end
function session.viewport() return width, height end
function session.time() return now end
function session.apply(active, pose)
    assert(s == active and s.lens == cameraComponent)
    if flags.apply then error("Apply failed") end
    moves = moves + 1
    s.pose = pose
end
local finder = {}
function finder.open() widget = {visible = false}; return widget end
function finder.visible(f, visible) f.visible = visible; return true end
function finder.close(f) f.closed = true; return true end
function finder.update(f, w, h, crop, text, grid)
    assert(w == width and h == height)
    f.crop, f.text, f.grid = crop, text, grid
    return true
end
local shutter = {}
function shutter.reap() reaps = reaps + 1 end
function shutter.begin(active, crop, w, h)
    assert(active == s and not widget.visible and not activeJob)
    captures = captures + 1
    if flags.rejected then return nil, "Renderer refused PNG" end
    activeJob = {crop = crop, w = w, h = h}
    return activeJob
end
function shutter.poll(job)
    assert(job == activeJob and not widget.visible)
    polls = polls + 1
    if flags.saved then activeJob = nil; return "saved", "photos/shot.png" end
    return "pending"
end
function shutter.cancel(job) assert(job == activeJob); activeJob = nil; cancels = cancels + 1 end
local modules = {["session.lua"] = session, ["finder.lua"] = finder, ["shutter.lua"] = shutter}
local traceLibrary = {IsValid = function() return true end}
function traceLibrary:LineTraceSingle(context, _, _, _, _, _, _, hit)
    assert(context == camera)
    traces = traces + 1
    if flags.traceError then error("collision unavailable") end
    hit.Distance = targetDistance
    return targetDistance ~= nil
end
local focusEnv = setmetatable({StaticFindObject = function() return traceLibrary end,
    print = function(message) log[#log + 1] = message end}, {__index = _G})
modules["focus.lua"] = assert(loadfile(scriptRoot .. "focus.lua", "t", focusEnv))()
local env = setmetatable({
    dofile = function(path) return modules[path:match("[^/]+$")] or dofile(path) end,
    os = setmetatable({time = function() return wall end}, {__index = os}),
    EngineTickAvailable = true, ProcessEventAvailable = true, EGameThreadMethod = {EngineTick = 1},
    Key = setmetatable({}, {__index = function(_, name) return name end}),
    RegisterKeyBind = function(name, fn) buttons[name] = fn end,
    ExecuteInGameThread = function(fn, how) assert(how == 1); scheduled[#scheduled + 1] = fn end,
    LoopInGameThreadWithDelay = function(ms, fn) assert(ms == 1000); inactiveReaper = fn; return 1 end,
    LoopInGameThreadAfterFrames = function(frames, fn) assert(frames == 1); event = fn; return fn end,
    CancelDelayedAction = function(handle) stopped[handle] = true end,
    FName = function(name) return name end,
    print = function(message) log[#log + 1] = message end,
}, {__index = _G})
assert(loadfile(scriptRoot .. "main.lua", "t", env))()
local function press(key)
    buttons[key]()
    while #scheduled > 0 do table.remove(scheduled, 1)() end
end
local function frame(dt)
    now = now + (dt or 0.016)
    assert(event and not stopped[event])
    event()
end

inactiveReaper()
assert(reaps == 1)
press("F9")
assert(opened == 0 and captures == 0)
flags.entry = true
press("F8")
assert(closed == 0 and log[#log]:match("No playable world"))
flags.entry = false
press("F8")
assert(opened == 1 and widget.visible)
assert(not widget.text:find("DOF") and not s.focus)
flags.traceError = true
press("N"); frame()
assert(not widget.closed and widget.text:find("Focus control unavailable") and log[#log]:find("collision unavailable"))
flags.traceError = false
press("N"); frame()
assert(widget.text:find("AF lock") and widget.text:find("10.00 m", 1, true))
press("B"); frame()
assert(widget.text:find("Photo DOF off"))
press("J"); press("L"); press("K"); press("U"); press("I"); press("Y"); press("T"); frame()
assert(widget.text:find("AF%-C") and widget.text:find("1% step", 1, true) and widget.text:find("2x DOF", 1, true))
local previousSensorWidth = cameraComponent.PostProcessSettings.DepthOfFieldSensorWidth
held.W, held.LeftShift = true, true
axes.MouseX = 2
frame()
assert(s.pose.x > 0 and s.pose.yaw > 0)
held.W, held.LeftShift, axes.MouseX = false, false, 0
press("F5"); press("F6"); press("F7"); press("F10"); press("G"); frame()
assert(widget.text:match("16.0 mm") and widget.text:match("3:2 portrait") and widget.grid)
assert(s.pose.roll == 0)
assert(cameraComponent.PostProcessSettings.DepthOfFieldSensorWidth ~= previousSensorWidth)
local crop, lockedMoves = widget.crop, moves
targetDistance = 1250
press("F9")
assert(not widget.visible)
local lockedTraces = traces
targetDistance = 1850
press("J"); press("N"); press("I"); press("B"); press("T")
press("F9"); press("F7"); press("G"); press("H")
held.W = true
frame(0); frame(); frame(0)
assert(captures == 0 and moves == lockedMoves)
frame()
assert(captures == 1 and activeJob.crop.x == crop.x and activeJob.crop.h == crop.h)
assert(traces == lockedTraces and cameraComponent.PostProcessSettings.DepthOfFieldFocalDistance == 1250)
press("F8")
assert(closed == 0 and log[#log]:match("Waiting for PNG"))
frame()
assert(polls == 1 and closed == 0 and moves == lockedMoves)
flags.saved = true
frame()
assert(closed == 1 and widget.closed and stopped[event] and cancels == 0)
held.W, flags.saved = false, false

-- Retry after a pre-dispatch resize or renderer refusal without leaving the session.
press("F8"); press("F9")
width = 1919
frame()
assert(closed == 1 and widget.visible and widget.text:match("Viewport changed"))
press("H"); press("F9")
flags.rejected = true
frame(); frame()
assert(captures == 2 and not widget.visible and closed == 1)
flags.rejected = false
press("H"); press("F9")
wall = wall + 6
frame(0)
assert(widget.visible and widget.text:match("Timed out"))
press("F9"); frame(); frame()
assert(activeJob)
flags.travel = true
frame()
assert(cancels == 1 and closed == 2 and widget.closed and stopped[event])
flags.travel = false
press("F8")
held.W, flags.apply = true, true
frame()
assert(closed == 3 and widget.closed and stopped[event])
held.W, flags.apply = false, false
press("F8"); press("F9"); frame(); frame()
flags.saved = true
frame()
assert(widget.visible and widget.text:match("PNG saved") and closed == 3)
press("F8")
assert(closed == 4 and widget.closed and stopped[event])
print("Main entry point tests passed")
