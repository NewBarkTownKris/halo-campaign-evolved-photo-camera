-- UMG host and DPI handling adapted from Denshattack! Photo Camera.
-- Copyright (c) 2026 NewBarkTownKris. Distributed under the MIT license.
local finder = {}
local hidden, hitTestInvisible = 2, 3
local collapsed = 1

local function place(slot, x, y, w, h)
    slot:SetPosition({X=x, Y=y})
    slot:SetSize({X=w, Y=h})
end

local function text(widget, value)
    widget:SetText(FText(value))
end

local function studioPanel(make, canvas)
    local panel, contents = make("Border"), make("CanvasPanel")
    panel:SetBrushColor({R=0.009, G=0.018, B=0.023, A=0.96})
    panel:SetPadding({Left=0, Right=0, Top=0, Bottom=0})
    panel:SetContent(contents)
    panel:SetClipping(1)
    panel:SetVisibility(collapsed)
    local s = {panel=panel, slot=canvas:AddChildToCanvas(panel), rows={}}
    local white = {R=0.95, G=0.98, B=1, A=1}
    local secondary = {R=0.66, G=0.81, B=0.84, A=1}
    local function label(tint)
        local widget = make("TextBlock")
        widget:SetColorAndOpacity({SpecifiedColor=tint, ColorUseRule=0})
        widget:SetAutoWrapText(false)
        return widget, contents:AddChildToCanvas(widget)
    end
    s.title, s.titleSlot = label(white)
    s.highlight = make("Border")
    s.highlight:SetBrushColor({R=0.045, G=0.20, B=0.24, A=1})
    s.highlightSlot = contents:AddChildToCanvas(s.highlight)
    for i=1,12 do
        local r = {}
        r.label, r.left = label(secondary)
        r.value, r.right = label(white)
        r.value:SetJustification(2)
        s.rows[i] = r
    end
    s.help, s.helpSlot = label(secondary)
    return s
end

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
    handle.readout = card
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
    handle.studio = studioPanel(make, canvas)
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
    local studio = handle.studio
    studio.size = math.min(23, textSize)
    studio.width = math.max(1, math.min(studio.size * 29, sw - 2 * margin))
    studio.margin = margin
    studio.rowHeight = math.ceil(studio.size * 1.8)
    studio.header = math.ceil(studio.rowHeight * 1.6)
    studio.footer = math.ceil(studio.rowHeight * 3.1)
    studio.capacity = math.max(1, math.min(#studio.rows,
        math.floor((sh - 2 * margin - studio.header - studio.footer) / studio.rowHeight)))
    if handle.font and handle.font:IsValid() and studio.fontSize ~= studio.size then
        local function font(widget, size, face)
            widget:SetFont({FontObject=handle.font, TypefaceFontName=FName(face), Size=size})
        end
        font(studio.title, studio.size + 2, "Medium")
        font(studio.help, math.max(10, studio.size - 2), "Regular")
        for _, row in ipairs(studio.rows) do
            font(row.label, studio.size, "Regular")
            font(row.value, studio.size, "Medium")
        end
        studio.fontSize = studio.size
    end
end

local function updateStudio(handle, model, resized)
    local s = handle.studio
    local visible = model ~= nil
    if visible ~= s.visible then
        s.panel:SetVisibility(visible and hitTestInvisible or collapsed)
        handle.readout:SetVisibility(visible and collapsed or hitTestInvisible)
        s.visible = visible
        resized = true
    end
    if not model then return end
    local count = math.min(#model.rows, s.capacity)
    local first = math.max(1, math.min(model.selected - math.floor(count / 2), #model.rows - count + 1))
    local w, rh, header = s.width, s.rowHeight, s.header
    if resized or count ~= s.count then
        place(s.slot, s.margin, s.margin, w, header + count * rh + s.footer)
        place(s.titleSlot, 10, 4, w - 20, header - 4)
        for i,r in ipairs(s.rows) do
            r.label:SetVisibility(i <= count and hitTestInvisible or collapsed)
            r.value:SetVisibility(i <= count and hitTestInvisible or collapsed)
            if i <= count then
                local y = header + (i-1) * rh
                local split = math.floor(w * .48)
                place(r.left, 10, y, math.max(1, split - 12), rh)
                place(r.right, split, y, math.max(1, w - split - 10), rh)
            end
        end
        place(s.helpSlot, 10, header + count * rh + 3, w - 20, s.footer - 3)
        s.count = count
    end
    if resized or model.selected ~= s.selected or first ~= s.first then
        place(s.highlightSlot, 4, header + (model.selected - first) * rh, w - 8, rh)
        text(s.title, ("Photo Studio    %d / %d"):format(model.selected, #model.rows))
        s.selected, s.first = model.selected, first
    end
    for i=1,count do
        local item, row = model.rows[first+i-1], s.rows[i]
        if row.caption ~= item.label then text(row.label, item.label); row.caption = item.label end
        if row.current ~= item.value then text(row.value, item.value); row.current = item.value end
    end
    local help = "Arrows / D-pad    ↑↓ Select    ←→ Adjust\nF4 / L3  Close    F9  Capture    F3  PNG + EXR"
    local hint = model.notice or model.detail
    if hint then help = hint .. "\n" .. help end
    if help ~= s.helpText then text(s.help, help); s.helpText = help end
end

function finder.update(handle, width, height, crop, lensText, grid, studio)
    return pcall(function()
        valid(handle.host, "viewfinder host")
        assert(crop.w > 0 and crop.h > 0 and crop.x >= 0 and crop.y >= 0
            and crop.x + crop.w <= width and crop.y + crop.h <= height, "Invalid viewfinder crop")
        local dpi = handle.layout:GetViewportScale(handle.pc)
        assert(dpi > 0 and dpi < math.huge, "Invalid viewport scale")
        local resized = width ~= handle.width or height ~= handle.height or dpi ~= handle.dpi
            or crop.x ~= handle.x or crop.y ~= handle.y or crop.w ~= handle.w or crop.h ~= handle.h
        if resized then
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
        updateStudio(handle, studio, resized)
    end)
end

return finder
