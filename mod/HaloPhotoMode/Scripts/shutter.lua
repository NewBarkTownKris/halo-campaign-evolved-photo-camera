-- Called on the game thread after the photo pose and HUD state have settled.
local shutter = {}
local active
local abandoned = {}
local nextCleanup = 0
local sequence = 0

local function library(name)
    local object = StaticFindObject("/Script/Engine.Default__" .. name)
    assert(object and object:IsValid(), "Unreal library unavailable: " .. name)
    return object
end

local function occupied(path)
    local file, _, code = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil or code ~= 2
end

local function integer(value)
    return type(value) == "number" and math.tointeger(value) and value >= 0 and value <= 0x7fffffff
end

local function prepare(s, crop, width, height)
    assert(s.world and s.world:IsValid() and s.pc and s.pc:IsValid(), "Photo world or player is unavailable")
    assert(integer(width) and integer(height) and crop and integer(crop.w) and integer(crop.h)
        and crop.w > 0 and crop.h > 0 and integer(crop.x) and integer(crop.y)
        and crop.x <= width - crop.w and crop.y <= height - crop.h, "Crop is outside the viewport")

    local paths = library("BlueprintPathsLibrary")
    local relative = paths:ScreenShotDir():ToString()
    assert(relative ~= "", "Unreal did not return a screenshots directory")
    local dir = paths:ConvertRelativePathToFull(relative, ""):ToString():gsub("\\", "/")
    assert((dir:match("^/") or dir:match("^%a:/")) and not dir:find('[%c"|;]'),
        "Unreal returned an unsupported screenshots directory")

    sequence = sequence + 1
    local basename = ("Halo_%s_%04d_%08x"):format(os.date("%Y%m%d_%H%M%S"), sequence, math.random(0, 0x7fffffff))
    dir = dir:gsub("/+$", "") .. "/"
    local final = dir .. basename .. ".png"
    local stageName = "." .. basename .. ".pending.png"
    local stage = dir .. stageName
    assert(not occupied(final) and not occupied(stage), "Screenshot name is occupied or inaccessible")
    local now = os.time()
    return {final = final, stage = stage, stageName = stageName, dir = dir,
        width = width, height = height, w = crop.w, h = crop.h,
        state = "pending", started = now, progress = now, size = 0}
end

local function helperReady(shot)
    local file = io.open(shot.dir .. "HaloPhotoHelper.ready", "rb")
    if not file then return false end
    local value = file:read(33)
    file:close()
    local seconds = value and #value <= 32 and value:match("^%s*(%d+)%s*$")
    local timestamp = tonumber(seconds or "")
    return timestamp and timestamp >= shot.started - 6 and timestamp <= shot.started
end

local function requestDisplay(shot, crop)
    local request = shot.stage .. ".request"
    local temp = request .. ".tmp"
    assert(not occupied(request) and not occupied(temp), "Display capture request name is occupied or inaccessible")
    local payload = ("HALO-PNG-1\n%s\n%d %d %d %d %d %d\n")
        :format(shot.stageName, shot.width, shot.height, crop.x, crop.y, crop.w, crop.h)
    local file = assert(io.open(temp, "wb"))
    shot.requestTemp = temp
    local written, writeError = file:write(payload)
    local closed, closeError = file:close()
    assert(written and closed, writeError or closeError)
    assert(os.rename(temp, request))
    shot.requestTemp, shot.request = nil, request
end

local function clearRequest(shot)
    local path = shot.request or shot.requestTemp
    if not path then return end
    local removed, _, code = os.remove(path)
    if not removed and code ~= 2 then abandoned[path] = os.time() + 120 end
end

-- Either producer may deliver a capture after cancellation. Retry cleanup of
-- the private staging filename while the photo session is closed.
function shutter.reap()
    if not next(abandoned) then return end
    local now = os.time()
    if now < nextCleanup then return end
    nextCleanup = now + 1
    for path, expires in pairs(abandoned) do
        local removed, why, code = os.remove(path)
        if removed or now >= expires then
            abandoned[path] = nil
            if not removed and code ~= 2 then print("[HaloPhotoMode] Staging cleanup: " .. tostring(why)) end
        end
    end
end

local function fail(shot, why)
    shot.state, shot.result = "failed", why
    active = nil
    clearRequest(shot)
    abandoned[shot.stage] = os.time() + 120
    os.remove(shot.stage)
    return shot.state, why
end

function shutter.begin(s, crop, width, height)
    if active then return nil, "A PNG capture is already pending" end
    local ready, shot = pcall(prepare, s, crop, width, height)
    if not ready then return nil, tostring(shot) end
    active = shot
    local sent, why = pcall(function()
        if helperReady(shot) then
            requestDisplay(shot, crop)
        else
            local command = ('HighResShot filename="%s" 1 %d %d %d %d 0 0 0 0')
                :format(shot.stage, crop.x, crop.y, crop.w, crop.h)
            library("KismetSystemLibrary"):ExecuteConsoleCommand(s.world, command, s.pc)
        end
    end)
    if not sent then
        fail(shot, tostring(why))
        return nil, shot.result
    end
    return shot
end

local pngHeader = "\137PNG\r\n\26\n\0\0\0\13IHDR"
local pngEnd = "\0\0\0\0IEND\174\66\96\130"

-- Seek past image data. Native captures can be large enough that reading the
-- whole PNG on the game thread would stall the game.
local function inspect(file, size, shot)
    if size < 57 then return "pending" end
    assert(file:seek("set", size - 12))
    if file:read(12) ~= pngEnd then return "pending" end
    assert(file:seek("set", 0))
    assert(file:read(16) == pngHeader, "Invalid PNG header")
    local w, h = string.unpack(">I4I4", assert(file:read(8)))
    assert(w == shot.w and h == shot.h, ("PNG is %dx%d, expected %dx%d"):format(w, h, shot.w, shot.h))
    local offset, imageBytes = 33, 0
    while offset < size - 12 do
        assert(file:seek("set", offset))
        local length, kind = string.unpack(">I4c4", assert(file:read(8)))
        assert(kind ~= "IEND" and kind ~= "IHDR", "Unexpected repeated PNG boundary")
        if kind == "IDAT" then imageBytes = imageBytes + length end
        offset = offset + length + 12
    end
    assert(offset == size - 12 and imageBytes > 0, "Incomplete PNG image data")
    return "complete"
end

function shutter.poll(shot, width, height)
    if shot.state ~= "pending" then return shot.state, shot.result end
    if width ~= shot.width or height ~= shot.height then return fail(shot, "Viewport changed during capture") end
    local now = os.time()
    local file, detail = io.open(shot.stage, "rb")
    if file then
        local size = file:seek("end")
        local ok, state = pcall(inspect, file, size, shot)
        file:close()
        if not ok then return fail(shot, tostring(state)) end
        if size > shot.size then shot.progress, shot.size = now, size end
        if state == "complete" then
            if occupied(shot.final) then return fail(shot, "PNG destination is occupied or inaccessible") end
            -- Windows may hold the writer open briefly after the IEND appears.
            local published
            published, detail = os.rename(shot.stage, shot.final)
            if published then
                active = nil
                clearRequest(shot)
                shot.state, shot.result = "saved", shot.final
                return shot.state, shot.result
            end
        end
    end
    if now - shot.progress >= 30 or now - shot.started >= 120 then
        return fail(shot, "PNG capture timed out" .. (detail and " (" .. detail .. ")" or ""))
    end
    return "pending"
end

function shutter.cancel(shot)
    if shot and shot == active then fail(shot, "PNG capture canceled") end
end

return shutter
