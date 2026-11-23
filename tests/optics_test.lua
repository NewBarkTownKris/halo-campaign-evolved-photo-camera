local optics = dofile("mod/HaloPhotoMode/Scripts/optics.lua")

local function near(actual, expected)
    assert(math.abs(actual - expected) < 1e-8, ("Expected %.9f, got %.9f"):format(expected, actual))
end

local function frameIndex(name)
    for i, frame in ipairs(optics.frames) do
        if frame == name then return i end
    end
    error("Missing frame " .. name)
end

local function rectangle(rect, x, y, w, h)
    assert(rect.x == x and rect.y == y and rect.w == w and rect.h == h,
        ("Unexpected crop %d, %d, %d × %d"):format(rect.x, rect.y, rect.w, rect.h))
end

near(optics.lensFov(18), 90)
near(optics.lensFov(50), 39.59775270904986)
for _, mm in ipairs(optics.lenses) do
    near(optics.focalLength(optics.lensFov(mm)), mm)
end
assert(not pcall(optics.lensFov, 0))
assert(not pcall(optics.focalLength, 180))

rectangle(optics.crop(1921, 1081), 0, 0, 1921, 1081)
rectangle(optics.crop(1921, 1081, 1, true), 0, 0, 1921, 1081)
rectangle(optics.crop(3840, 2160, frameIndex("65:24")), 2, 372, 3835, 1416)
rectangle(optics.crop(3840, 2160, frameIndex("65:24"), true), 1524, 7, 792, 2145)
rectangle(optics.crop(13, 12, frameIndex("1:1")), 0, 0, 12, 12)
rectangle(optics.crop(14, 6, frameIndex("21:9")), 0, 0, 14, 6)
assert(not pcall(optics.crop, 10, 10, frameIndex("89:35")))
assert(not pcall(optics.crop, 12, 0))
assert(not pcall(optics.crop, 12.5, 12))
assert(not pcall(optics.crop, 12, 12, 100))

local pose = {x = 1, y = 2, z = 3, yaw = 0, pitch = 0, roll = 0, fov = 90}
assert(optics.move(pose, 0.1, {}) == nil)
local p = optics.move(pose, 0.1, {forward = 1, right = 1, up = 1})
near(p.x - 1, 8 / math.sqrt(3))
near(p.y - 2, 8 / math.sqrt(3))
near(p.z - 3, 8 / math.sqrt(3))
near(pose.x, 1)
p = optics.move(pose, 0.05, {right = 0.5, speed = 4})
near(p.y - 2, 8)
p = optics.move(pose, 1, {forward = 1})
near(p.x - 1, 8)
local mid = optics.move(pose, 0.05, {forward = 1})
p = optics.move(mid, 0.05, {forward = 1})
near(p.x - 1, 8)

pose.pitch, pose.yaw, pose.roll = 30, 90, 90
p = optics.move(pose, 0.1, {forward = 1})
near(p.x - 1, 0)
near(p.y - 2, 8 * math.cos(math.rad(30)))
near(p.z - 3, 4)
p = optics.move(pose, 0.1, {up = 1})
near(p.x, pose.x)
near(p.y, pose.y)
near(p.z - 3, 8)

pose.fov = optics.lensFov(600)
p = optics.move(pose, 0, {mouseYaw = 9})
near(p.yaw - pose.yaw, 9 * 18 / 600)
p = optics.move(pose, 0.1, {yaw = 1, roll = -1, zoom = -1})
near(p.yaw - pose.yaw, 8)
near(p.roll - pose.roll, -5.5)
near(p.fov, 2)
print("Optics tests passed")
