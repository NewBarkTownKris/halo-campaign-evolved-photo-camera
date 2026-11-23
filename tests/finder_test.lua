local optics = dofile("mod/HaloPhotoMode/Scripts/optics.lua")
local methods = {}
local function widget()
    return setmetatable({}, {__index = methods})
end

function methods:IsValid() return true end
function methods:AddChildToCanvas(child)
    local slot = widget()
    slot.child = child
    return slot
end
function methods:SetPosition(p) self.pos = p end
function methods:SetSize(s) self.size = s end
function methods:SetBrushColor(color) self.color = color end
function methods:SetVisibility(value) self.visibility = value end
function methods:SetText(value) self.text = value; self.writes = (self.writes or 0) + 1 end
function methods:SetDesiredSizeInViewport(s) self.desired = s end
function methods:SetPositionInViewport(p, removeDpi) assert(p.X == 0 and p.Y == 0 and removeDpi == false) end
for _, name in ipairs({"SetClipping", "SetPadding", "SetContent", "SetAutoSize", "SetAlignment",
                        "SetColorAndOpacity", "SetAutoWrapText", "SetFont", "SetWidthOverride"}) do
    methods[name] = function() end
end

local pc, widgets, viewport = widget(), widget(), widget()
local host, rejectAttach
function widgets:Create(context, class, owner)
    assert(context == pc and owner == pc and class.path == "/Script/LevelSequence.LevelSequenceBurnIn")
    host = widget()
    host.WidgetTree = widget()
    function host:AddToViewport() self.attached = true end
    function host:IsInViewport() return self.attached and not rejectAttach end
    function host:RemoveFromParent() self.attached = false; self.removes = (self.removes or 0) + 1 end
    return host
end
function viewport:GetViewportScale(context) assert(context == pc); return self.dpi end
local env = setmetatable({
    StaticFindObject = function(path)
        if path == "/Script/UMG.Default__WidgetBlueprintLibrary" then return widgets end
        if path == "/Script/UMG.Default__WidgetLayoutLibrary" then return viewport end
        local class = widget()
        class.path = path
        return class
    end,
    StaticConstructObject = function(_, outer) assert(outer == host.WidgetTree); return widget() end,
    FText = function(s) return s end,
    FName = function(s) return s end,
}, {__index = _G})

local finder = assert(loadfile("mod/HaloPhotoMode/Scripts/finder.lua", "t", env))()
local handle = assert(finder.open(pc))
assert(host.attached and host.visibility == 2)
local function near(a, b) assert(math.abs(a - b) < 1e-8, ("%f != %f"):format(a, b)) end
local function pixelRect(slot, x, y, w, h)
    near(slot.pos.X * viewport.dpi, x)
    near(slot.pos.Y * viewport.dpi, y)
    near(slot.size.X * viewport.dpi, w)
    near(slot.size.Y * viewport.dpi, h)
end
for _, dpi in ipairs({1, 1.25, 2}) do
    viewport.dpi = dpi
    local width, height = 3840, 2160
    for index = 1, #optics.frames do
        for _, portrait in ipairs({false, true}) do
            local crop = optics.crop(width, height, index, portrait)
            local x, y, w, h = crop.x, crop.y, crop.w, crop.h
            assert(finder.update(handle, width, height, crop, "85 mm", true))
            assert(host.visibility == 2 and handle.grid.visibility == 3)
            near(host.desired.X * dpi, width)
            near(host.desired.Y * dpi, height)
            pixelRect(handle.masks.top, 0, 0, width, y)
            pixelRect(handle.masks.bottom, 0, y + h, width, height - y - h)
            pixelRect(handle.masks.left, 0, y, x, h)
            pixelRect(handle.masks.right, x + w, y, width - x - w, h)
            pixelRect(handle.gridSlot, x, y, w, h)
            for third = 1, 2 do
                pixelRect(handle.guides[third], w * third / 3 - 0.5, 0, 1, h)
                pixelRect(handle.guides[third + 2], 0, h * third / 3 - 0.5, w, 1)
            end
        end
    end
end
assert(handle.label.text == "85 mm" and handle.label.writes == 1)
for _, slot in pairs(handle.masks) do
    local color = slot.child.color
    assert(color.R == 0 and color.G == 0 and color.B == 0 and color.A == 1)
end
assert(finder.visible(handle, true) and host.visibility == 3)
assert(finder.visible(handle, false) and host.visibility == 2)
assert(finder.update(handle, 1921, 1081, optics.crop(1921, 1081), "Saved PNG", false))
assert(host.visibility == 2 and handle.grid.visibility == 2 and handle.label.text == "Saved PNG")
viewport.dpi = 0
assert(not finder.update(handle, 1921, 1081, optics.crop(1921, 1081), "Miss", false))
assert(finder.close(handle) and not host.attached)
assert(finder.close(handle) and host.removes == 1)
assert(not finder.visible(handle, true))

rejectAttach = true
local failed, failure = finder.open(pc)
assert(not failed and failure:match("attach") and not host.attached and host.removes == 1)
print("Finder tests passed")
