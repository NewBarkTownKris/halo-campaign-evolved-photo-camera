-- UMG host and DPI handling adapted from Denshattack! Photo Camera.
-- Copyright (c) 2026 NewBarkTownKris. Distributed under the MIT license.
local finder = {}
local hidden, hitTestInvisible = 2, 3

local function valid(value, name)
    assert(value and value:IsValid(), "Missing " .. name)
    return value
end

local function object(path)
    return valid(StaticFindObject(path), path)
end

local function build(handle, pc)
    local widgets = object("/Script/UMG.Default__WidgetBlueprintLibrary")
    local burnIn = object("/Script/LevelSequence.LevelSequenceBurnIn")
    local host = valid(widgets:Create(pc, burnIn, pc), "viewfinder host")
    handle.host = host
    local tree = valid(host.WidgetTree, "viewfinder widget tree")
    local classes = {}
    local function make(kind)
        classes[kind] = classes[kind] or object("/Script/UMG." .. kind)
        return valid(StaticConstructObject(classes[kind], tree), kind)
    end

    local canvas = make("CanvasPanel")
    tree.RootWidget = canvas
    local function border(parent, color)
        local widget = make("Border")
        widget:SetBrushColor(color)
        return valid(parent:AddChildToCanvas(widget), "border slot")
    end
    local black = {R = 0, G = 0, B = 0, A = 1}
    handle.masks = {}
    for _, edge in ipairs({"top", "bottom", "left", "right"}) do
        handle.masks[edge] = border(canvas, black)
    end
    handle.grid = make("CanvasPanel")
    handle.grid:SetClipping(1)
    handle.grid:SetVisibility(hidden)
    handle.gridSlot = valid(canvas:AddChildToCanvas(handle.grid), "grid slot")
    handle.guides = {}
    for i = 1, 4 do
        handle.guides[i] = border(handle.grid, {R = 1, G = 1, B = 1, A = 0.48})
    end

    local card = make("Border")
    card:SetBrushColor({R = 0.014, G = 0.022, B = 0.028, A = 0.86})
    card:SetPadding({Top = 6, Right = 10, Bottom = 6, Left = 10})
    handle.bounds = make("SizeBox")
    handle.label = make("TextBlock")
    handle.font = StaticFindObject("/Engine/EngineFonts/Roboto.Roboto")
    handle.label:SetColorAndOpacity({SpecifiedColor = {R = 1, G = 1, B = 1, A = 1}, ColorUseRule = 0})
    handle.label:SetAutoWrapText(true)
    handle.bounds:SetContent(handle.label)
    card:SetContent(handle.bounds)
    handle.card = valid(canvas:AddChildToCanvas(card), "readout slot")
    handle.card:SetAutoSize(true)
    handle.card:SetAlignment({X = 0, Y = 1})
    handle.layout = object("/Script/UMG.Default__WidgetLayoutLibrary")
    host:SetVisibility(hidden)
    host:AddToViewport(100)
    assert(host:IsInViewport(), "Could not attach the viewfinder to the viewport")
end

function finder.close(handle)
    return pcall(function()
        if handle and handle.host and handle.host:IsValid() then
            handle.host:RemoveFromParent()
        end
        if handle then handle.host = nil end
    end)
end

function finder.open(pc)
    local handle = {pc = pc}
    local ok, reason = pcall(build, handle, pc)
    if ok then return handle end
    finder.close(handle)
    return nil, reason
end

function finder.visible(handle, show)
    return pcall(function()
        valid(handle.host, "viewfinder host"):SetVisibility(show and hitTestInvisible or hidden)
    end)
end

local function layout(handle, width, height, crop, dpi)
    -- All offsets and lengths enter in capture pixels. Grid slots are local
    -- to the crop, while the four masks and grid panel are viewport-local.
    local function rect(slot, x, y, w, h)
        slot:SetPosition({X = x / dpi, Y = y / dpi})
        slot:SetSize({X = w / dpi, Y = h / dpi})
    end
    local x, y, w, h = crop.x, crop.y, crop.w, crop.h
    local right, bottom = x + w, y + h
    handle.host:SetDesiredSizeInViewport({X = width / dpi, Y = height / dpi})
    handle.host:SetPositionInViewport({X = 0, Y = 0}, false)
    rect(handle.masks.top, 0, 0, width, y)
    rect(handle.masks.bottom, 0, bottom, width, height - bottom)
    rect(handle.masks.left, 0, y, x, h)
    rect(handle.masks.right, right, y, width - right, h)
    rect(handle.gridSlot, x, y, w, h)
    for i = 1, 2 do
        rect(handle.guides[i], w * i / 3 - 0.5, 0, 1, h)
        rect(handle.guides[i + 2], 0, h * i / 3 - 0.5, w, 1)
    end
    local sw, sh = width / dpi, height / dpi
    local textSize = math.max(13, math.min(28, math.floor(sh / 72 + 0.5)))
    if handle.font and handle.font:IsValid() and handle.textSize ~= textSize then
        handle.label:SetFont({FontObject = handle.font, TypefaceFontName = FName("Regular"), Size = textSize})
        handle.textSize = textSize
    end
    local margin = math.min(14, sw / 16, sh / 16)
    handle.card:SetPosition({X = margin, Y = sh - margin})
    handle.bounds:SetWidthOverride(math.max(1, math.min(40 * textSize, sw - 2 * margin - 20)))
end

function finder.update(handle, width, height, crop, lensText, grid)
    return pcall(function()
        valid(handle.host, "viewfinder host")
        assert(crop.w > 0 and crop.h > 0 and crop.x >= 0 and crop.y >= 0
            and crop.x + crop.w <= width and crop.y + crop.h <= height, "Invalid viewfinder crop")
        local dpi = handle.layout:GetViewportScale(handle.pc)
        assert(dpi > 0 and dpi < math.huge, "Invalid viewport scale")
        if width ~= handle.width or height ~= handle.height or dpi ~= handle.dpi
            or crop.x ~= handle.x or crop.y ~= handle.y or crop.w ~= handle.w or crop.h ~= handle.h then
            layout(handle, width, height, crop, dpi)
            handle.width, handle.height, handle.dpi = width, height, dpi
            handle.x, handle.y, handle.w, handle.h = crop.x, crop.y, crop.w, crop.h
        end
        if grid ~= handle.gridShown then
            handle.grid:SetVisibility(grid and hitTestInvisible or hidden)
            handle.gridShown = grid
        end
        if lensText ~= handle.text then
            handle.label:SetText(FText(lensText or ""))
            handle.text = lensText
        end
    end)
end

return finder
