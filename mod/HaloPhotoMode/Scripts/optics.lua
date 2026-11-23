-- Adapted from Denshattack! Photo Camera, copyright (c) 2026 NewBarkTownKris.
-- Distributed under the MIT license included with this project.
local optics = {}

optics.lenses = {16, 24, 35, 50, 85, 135, 200, 600}
optics.frames = {"Viewport", "3:2", "4:3", "1:1", "16:9", "5:4", "21:9", "65:24", "89:35"}

-- Lens equivalents use the horizontal field of view of a 36 mm wide gate.
function optics.lensFov(mm)
    assert(type(mm) == "number" and mm > 0 and mm < math.huge, "Expected a positive focal length")
    return math.deg(2 * math.atan(18 / mm))
end

function optics.focalLength(fov)
    assert(type(fov) == "number" and fov > 0 and fov < 180, "Expected a horizontal FOV between 0 and 180 degrees")
    return 18 / math.tan(math.rad(fov) / 2)
end

-- Coordinates are in original viewport pixels, with the origin at top left.
-- Odd leftover pixels go to the right and bottom, shared by finder and shutter.
function optics.crop(width, height, frameIndex, portrait)
    assert(math.tointeger(width) and math.tointeger(height) and width > 0 and height > 0,
        "Expected positive integer viewport dimensions")
    local frame = assert(optics.frames[frameIndex or 1], "Unknown photo frame")
    if frame == "Viewport" then
        return {x = 0, y = 0, w = width, h = height}
    end

    local a, b = frame:match("^(%d+):(%d+)$")
    a, b = tonumber(a), tonumber(b)
    -- Use the reduced ratio so a 21:9 gate can fill an exact 7:3 viewport.
    local divisor, remainder = a, b
    while remainder ~= 0 do
        divisor, remainder = remainder, divisor % remainder
    end
    a, b = a // divisor, b // divisor
    if portrait then a, b = b, a end
    local units = math.min(width // a, height // b)
    assert(units >= 1, "Viewport is too small for this frame")
    local w, h = a * units, b * units
    return {x = (width - w) // 2, y = (height - h) // 2, w = w, h = h}
end

local function clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

local function wrap(angle)
    return (angle + 180) % 360 - 180
end

-- X forward, Y right, Z up. Travel is 80 world units per real second at 1x.
-- Right stays level when banking and up follows the world vertical. Mouse
-- deltas arrive in degrees since the last sample. Stick/key axes are rates.
function optics.move(pose, dt, axes)
    dt = clamp(dt, 0, 0.1) -- Discard large pauses between input samples.
    local aimScale = math.min(1, math.tan(math.rad(pose.fov) / 2))
    local pitchRate = clamp((axes.pitch or 0) + (axes.stickPitch or 0) * aimScale, -1, 1)
    local yawRate = clamp((axes.yaw or 0) + (axes.stickYaw or 0) * aimScale, -1, 1)
    local pitchDelta = pitchRate * 65 * dt + (axes.mousePitch or 0) * aimScale
    local yawDelta = yawRate * 80 * dt + (axes.mouseYaw or 0) * aimScale
    local rollDelta = (axes.roll or 0) * 55 * dt
    local zoomDelta = (axes.zoom or 0) * 30 * dt
    local f, r, u = axes.forward or 0, axes.right or 0, axes.up or 0
    if pitchDelta == 0 and yawDelta == 0 and rollDelta == 0 and zoomDelta == 0
            and (dt == 0 or (f == 0 and r == 0 and u == 0)) then
        return nil
    end

    local pitch = pitchDelta == 0 and pose.pitch or clamp(pose.pitch + pitchDelta, -89.9, 89.9)
    local yaw = yawDelta == 0 and pose.yaw or wrap(pose.yaw + yawDelta)
    local roll = rollDelta == 0 and pose.roll or wrap(pose.roll + rollDelta)
    local fov = zoomDelta == 0 and pose.fov or clamp(pose.fov + zoomDelta, 2, 155)
    local p, y = math.rad(pitch), math.rad(yaw)
    local cp, sp, cy, sy = math.cos(p), math.sin(p), math.cos(y), math.sin(y)
    local dx, dy, dz = f * cp * cy - r * sy, f * cp * sy + r * cy, f * sp + u
    local length = math.sqrt(dx * dx + dy * dy + dz * dz)
    local step = 80 * (axes.speed or 1) * dt / math.max(1, length)
    return {
        x = pose.x + dx * step, y = pose.y + dy * step, z = pose.z + dz * step,
        pitch = pitch, yaw = yaw, roll = roll, fov = fov,
    }
end

return optics
