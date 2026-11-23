-- Run from the project root with lua5.4 tests/shutter_test.lua.
local shutter = dofile("mod/HaloPhotoMode/Scripts/shutter.lua")
local pngHex = "89504e470d0a1a0a0000000d49484452000000020000000108020000007b40e8dd"
    .. "0000000f49444154789c63546858c0c0c0000005ce0142d7c586730000000049454e44ae426082"
local png = pngHex:gsub("%x%x", function(pair) return string.char(tonumber(pair, 16)) end)
local function valid() return true end
local world, pc = {IsValid = valid}, {IsValid = valid}
local session = {world = world, pc = pc}
local crop = {x = 1, y = 2, w = 2, h = 1}
local tmp = (os.getenv("TMPDIR") or os.getenv("TEMP") or "/tmp"):gsub("\\", "/"):gsub("/+$", "")
local dir = tmp
local command, dispatchError
local function fstring(value)
    return {ToString = function() return value end}
end
local libraries = {
    BlueprintPathsLibrary = {IsValid = valid, ScreenShotDir = function() return fstring("screens") end,
        ConvertRelativePathToFull = function(_, relative, base)
            assert(relative == "screens" and base == "")
            return fstring(dir)
        end},
    KismetSystemLibrary = {IsValid = valid, ExecuteConsoleCommand = function(_, context, cmd, player)
        assert(context == world and player == pc)
        if dispatchError then error("simulated renderer failure") end
        command = cmd
    end}
}
function StaticFindObject(path)
    return libraries[path:match("^/Script/Engine%.Default__(.+)$")]
end

local function write(path, bytes)
    local file = assert(io.open(path, "wb"))
    assert(file:write(bytes))
    assert(file:close())
end
local function read(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local bytes = file:read("a")
    file:close()
    return bytes
end

-- Redirect the well-known heartbeat to this test's own file. Concurrent tests
-- and actual capture helpers own their own heartbeat and request directories.
local marker = os.tmpname()
os.remove(marker)
local open, rename = io.open, os.rename
io.open = function(path, mode)
    if path == tmp .. "/HaloPhotoHelper.ready" then return open(marker, mode) end
    return open(path, mode)
end
local files = {marker}
local clock, now = os.time, os.time()
os.time = function() return now end
local function begin(helper)
    command = nil
    local shot = assert(shutter.begin(session, crop, 4, 5))
    files[#files + 1] = shot.stage
    files[#files + 1] = shot.final
    local request = shot.stage .. ".request"
    files[#files + 1] = request
    files[#files + 1] = request .. ".tmp"
    if helper then
        assert(command == nil and shot.request == request and not read(request .. ".tmp"))
        local basename = assert(shot.stage:match("/(%.Halo_[%w_]+%.pending%.png)$"))
        assert(read(request) == "HALO-PNG-1\n" .. basename .. "\n4 5 1 2 2 1\n")
    else
        assert(command == ('HighResShot filename="%s" 1 1 2 2 1 0 0 0 0'):format(shot.stage))
        assert(not read(request))
    end
    return shot
end

local function check()
    local shot = begin()
    assert(not shutter.begin(session, crop, 4, 5))
    assert(shutter.poll(shot, 4, 5) == "pending")
    now = now + 29
    write(shot.stage, png:sub(1, -2))
    assert(shutter.poll(shot, 4, 5) == "pending")
    now = now + 10
    assert(shutter.poll(shot, 4, 5) == "pending")
    assert(not read(shot.final))
    write(shot.stage, png)
    local status, path = shutter.poll(shot, 4, 5)
    assert(status == "saved" and path == shot.final and read(path) == png and not read(shot.stage))
    shutter.cancel(shot)
    assert(shutter.poll(shot, 99, 99) == "saved")

    local resized = begin()
    assert(resized.stage ~= shot.stage and resized.final ~= shot.final)
    write(resized.stage, png)
    assert(shutter.poll(resized, 5, 4) == "failed")
    assert(not read(resized.stage) and not read(resized.final))

    local badSize = begin()
    write(badSize.stage, png:sub(1, 16) .. string.pack(">I4", 3) .. png:sub(21))
    assert(select(2, shutter.poll(badSize, 4, 5)):match("expected 2x1"))
    assert(not read(badSize.final))
    local damaged = begin()
    write(damaged.stage, png:sub(1, 33) .. string.pack(">I4", 999) .. png:sub(38))
    assert(shutter.poll(damaged, 4, 5) == "failed" and not read(damaged.final))

    local occupied = begin()
    write(occupied.stage, png)
    write(occupied.final, "older photograph")
    assert(shutter.poll(occupied, 4, 5) == "failed")
    assert(read(occupied.final) == "older photograph")

    local canceled = begin()
    shutter.cancel(canceled)
    write(canceled.stage, png) -- The engine delivered this after cancellation.
    assert(shutter.poll(canceled, 4, 5) == "failed" and not read(canceled.final))
    shutter.reap()
    assert(not read(canceled.stage))

    local timedOut = begin()
    now = now + 31
    assert(select(2, shutter.poll(timedOut, 4, 5)):match("timed out"))
    assert(not read(timedOut.final))
    dispatchError = true
    assert(not shutter.begin(session, crop, 4, 5))
    dispatchError = false
    assert(not shutter.begin(session, crop, 2, 2))
    assert(not shutter.begin({world = world}, crop, 4, 5))
    dir = tmp .. '/invalid"directory'
    assert(not shutter.begin(session, crop, 4, 5))
    dir = tmp
    shutter.cancel(begin())

    for _, invalid in ipairs({tostring(now - 7), tostring(now + 1), "1.7e9", now .. "\njunk"}) do
        write(marker, invalid)
        shutter.cancel(begin())
    end
    write(marker, tostring(now - 6) .. "\n")
    local fromHelper = begin(true)
    assert(shutter.poll(fromHelper, 4, 5) == "pending")
    write(fromHelper.stage, png)
    assert(shutter.poll(fromHelper, 4, 5) == "saved")
    assert(read(fromHelper.final) == png and not read(fromHelper.request))

    write(marker, tostring(now))
    local badHelperSize = begin(true)
    write(badHelperSize.stage, png:sub(1, 16) .. string.pack(">I4", 4) .. png:sub(21))
    assert(shutter.poll(badHelperSize, 4, 5) == "failed")
    assert(not read(badHelperSize.request) and not read(badHelperSize.final))

    local helperCanceled = begin(true)
    shutter.cancel(helperCanceled)
    assert(not read(helperCanceled.request))
    write(helperCanceled.stage, png) -- A host capture already in flight.
    now = now + 1
    shutter.reap()
    assert(not read(helperCanceled.stage) and not read(helperCanceled.final))

    local blocked = begin(true)
    now = now + 31
    assert(shutter.poll(blocked, 4, 5) == "failed")
    assert(not read(blocked.request) and not read(blocked.final))

    write(marker, tostring(now))
    local failedTemp
    os.rename = function(from, to)
        assert(from == to .. ".tmp" and read(from):match("^HALO%-PNG%-1\n") and not read(to))
        failedTemp = from
        return nil, "simulated request publication error"
    end
    assert(not shutter.begin(session, crop, 4, 5))
    os.rename = rename
    assert(failedTemp and not read(failedTemp))
    shutter.cancel(begin(true))
end

local ok, why = xpcall(check, debug.traceback)
os.time = clock
io.open, os.rename = open, rename
for _, path in ipairs(files) do os.remove(path) end
assert(ok, why)
print("PNG shutter tests passed")
