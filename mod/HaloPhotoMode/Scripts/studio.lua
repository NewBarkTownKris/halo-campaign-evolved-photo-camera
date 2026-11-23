-- Photo Studio controls and settings, adapted from Denshattack! Photo Camera (MIT).
local studio = {}

local controls = {
    {"output", "F9 output"}, {"frame", "Frame"}, {"orientation", "Orientation"}, {"lens", "Lens"},
    {"dof", "Depth of field"}, {"aperture", "Aperture"}, {"strength", "DOF strength"},
    {"mode", "Focus mode"}, {"distance", "Focus distance"}, {"step", "Focus step"},
    {"grid", "Thirds grid"}, {"finder", "Viewfinder"}, {"chromatic", "Chromatic aberration"},
}
local modes = {"Manual", "AF lock", "AF-C"}

local function cycle(index, delta, count)
    return (index - 1 + delta) % count + 1
end

local function onOff(on)
    return on and "On" or "Off"
end

local function settingsPath()
    local dir = os.getenv("LOCALAPPDATA")
    if dir and dir ~= "" then return dir .. "/Meteorite/Saved/HaloPhotoStudio.ini" end
end

local function readSettings(path)
    local file = io.open(path, "rb")
    if not file then return end
    local data = file:read(4097)
    file:close()
    if not data or #data > 4096 then return end
    data = data:gsub("\r\n", "\n")
    if not data:match("^version=1\n") or not data:match("\nend=1\n$") then return end
    local values = {}
    for key, value in data:gmatch("([%a]+)=([^\n]+)\n") do
        if value == "true" then values[key] = true
        elseif value == "false" then values[key] = false
        elseif key == "chromatic" and (value == "Game" or value == "Off") then values.chromatic = value
        else values[key] = tonumber(value) end
    end
    return values
end

local function restore(s, prefs)
    local st = s.studio
    local frame = math.tointeger(prefs.frame)
    if frame and st.optics.frames[frame] then s.frame = frame end
    for _, field in ipairs({"captureEXR", "portrait", "grid", "showFinder"}) do
        if type(prefs[field]) == "boolean" then s[field] = prefs[field] end
    end
    if type(prefs.fov) == "number" and prefs.fov >= 2 and prefs.fov <= 155 then
        st.changePose(s, "fov", prefs.fov)
        s.lensIndex = 0
        for index, mm in ipairs(st.optics.lenses) do
            if math.abs(prefs.fov - st.optics.lensFov(mm)) < 0.00001 then s.lensIndex = index end
        end
        st.savedLens = true
    end
    st.focus.restoreDials(s, prefs.aperture, prefs.strength, prefs.fine)
    if prefs.chromatic == "Off" and st.chromatic then
        st.chromaticChoice = "Off"
        local ok, reason = st.chromatic.set(s, "Off")
        if not ok then
            st.chromaticError = "Chromatic control unavailable"
            print("[HaloPhotoMode] " .. st.chromaticError .. ": " .. tostring(reason) .. "\n")
        end
    end
end

local function serialize(s)
    local st = s.studio
    local focus = st.focus.values(s)
    local lines = {"version=1", "captureEXR=" .. tostring(s.captureEXR == true), "frame=" .. s.frame,
        "portrait=" .. tostring(s.portrait), "grid=" .. tostring(s.grid),
        "showFinder=" .. tostring(s.showFinder), "aperture=" .. tostring(focus.aperture),
        "strength=" .. tostring(focus.strength), "fine=" .. tostring(focus.fine),
        "chromatic=" .. st.chromaticChoice}
    -- Keep the gameplay FOV at entry until a lens preset or camera zoom is used.
    if st.savedLens or s.lensIndex > 0 or math.abs(s.pose.fov - st.entryFov) > 0.00001 then
        lines[#lines + 1] = ("fov=%.17g"):format(s.pose.fov)
    end
    return table.concat(lines, "\n") .. "\nend=1\n"
end

function studio.open(s, optics, focus, changePose, path, chromatic)
    if path == nil then path = settingsPath() end
    local st = {visible = false, selected = 1, path = path, optics = optics, focus = focus,
        changePose = changePose, entryFov = s.pose.fov, chromatic = chromatic, chromaticChoice = "Game"}
    s.studio = st
    s.captureEXR = false
    if path then
        local prefs = readSettings(path) or readSettings(path .. ".bak")
        if prefs then restore(s, prefs) end
    end
    st.persisted = serialize(s)
    return true
end

local function writeSettings(path, data)
    local temp = path .. "." .. tostring({}):gsub("[^%w]", "") .. ".tmp"
    local file, err = io.open(temp, "wb")
    if not file then return nil, err end
    local written, writeErr = file:write(data)
    local closed, closeErr = file:close()
    if not written or not closed then os.remove(temp); return nil, writeErr or closeErr end
    local ok, reason = os.rename(temp, path)
    if ok then return true end
    -- Windows rename cannot replace an existing file. Reading the backup
    -- on startup also covers an exit between these two renames.
    local existing = io.open(path, "rb")
    if not existing then os.remove(temp); return nil, reason end
    existing:close()
    local backup = path .. ".bak"
    os.remove(backup)
    ok, reason = os.rename(path, backup)
    if ok then
        ok, reason = os.rename(temp, path)
        if not ok then os.rename(backup, path) end
    end
    if not ok then os.remove(temp) end
    return ok, reason
end

function studio.save(s)
    local st = s.studio
    local data = serialize(s)
    if data == st.persisted then return true end
    if not st.path then return nil, "Studio settings folder unavailable" end
    local saved, reason = writeSettings(st.path, data)
    if saved then st.persisted = data end
    return saved, reason
end

function studio.toggle(s)
    s.studio.visible = not s.studio.visible
    s.studio.notice = nil
    return s.studio.visible
end

function studio.navigate(s, delta)
    if not s.studio.visible then return end
    s.studio.selected = cycle(s.studio.selected, delta, #controls)
    s.studio.notice = nil
end

local function adjustFocus(s, field, delta)
    local focus = s.studio.focus
    if field == "dof" then return focus.toggle(s) end
    if field == "aperture" then return focus.aperture(s, delta) end
    if field == "step" then return focus.fineStep(s) end
    if field == "distance" then return focus.manual(s, delta) end
    if field == "strength" then return focus.strength(s, delta) end
    if field == "mode" then
        local current = focus.values(s).mode
        for i, name in ipairs(modes) do
            if name == current then return focus.setMode(s, modes[cycle(i, delta, #modes)]) end
        end
    end
end

function studio.adjust(s, delta)
    local st = s.studio
    if not st.visible then return end
    local field = controls[st.selected][1]
    st.notice = nil
    if field == "output" then s.captureEXR = not s.captureEXR
    elseif field == "frame" then s.frame = cycle(s.frame, delta, #st.optics.frames)
    elseif field == "orientation" then
        if s.frame == 1 then st.notice = "Select a frame ratio to rotate it."
        else s.portrait = not s.portrait end
    elseif field == "lens" then
        local lenses = st.optics.lenses
        local mm = st.optics.focalLength(s.pose.fov)
        local index = delta > 0 and 1 or #lenses
        for i = 1, #lenses do
            local j = delta > 0 and i or #lenses - i + 1
            if (lenses[j] - mm) * delta > 0.001 then index = j; break end
        end
        st.changePose(s, "fov", st.optics.lensFov(lenses[index]))
        s.lensIndex = index
    elseif field == "grid" then s.grid = not s.grid
    elseif field == "finder" then s.showFinder = not s.showFinder
    elseif field == "chromatic" then
        local wanted = st.chromaticChoice == "Game" and "Off" or "Game"
        local ok, reason
        if st.chromatic then ok, reason = st.chromatic.set(s, wanted) end
        if ok then
            st.chromaticChoice, st.chromaticError = wanted, nil
        else
            st.chromaticError = "Chromatic control unavailable"
            print("[HaloPhotoMode] " .. st.chromaticError .. ": " .. tostring(reason) .. "\n")
        end
    else
        local ok, reason = pcall(adjustFocus, s, field, delta)
        if not ok then
            st.notice = "Focus control unavailable"
            st.focus.warn(s, st.notice, reason)
        elseif field == "mode" and reason and reason:match("^AF found no") then
            st.notice = "No center target"
        end
    end
    local saved, reason = studio.save(s)
    if not saved then
        if not st.writeError then print("[HaloPhotoMode] Could not save Studio settings: " .. tostring(reason) .. "\n") end
        st.writeError = true
    else st.writeError = nil end
end

function studio.model(s)
    local st = s.studio
    if not st or not st.visible then return end
    local f = st.focus.values(s)
    local values = {
        output = s.captureEXR and "PNG + linear EXR" or "PNG",
        frame = st.optics.frames[s.frame],
        orientation = s.frame == 1 and "Viewport" or (s.portrait and "Portrait" or "Landscape"),
        lens = ("%.1f mm"):format(st.optics.focalLength(s.pose.fov)),
        dof = onOff(f.enabled), aperture = ("f/%g"):format(f.aperture),
        strength = ("%d×"):format(f.strength), mode = f.mode,
        distance = ("%.2f m"):format(f.distance / 100), step = f.fine and "1%" or "20%",
        grid = onOff(s.grid), finder = onOff(s.showFinder),
        chromatic = st.chromatic and st.chromatic.get(s) or "Game",
    }
    local model = {selected = st.selected, rows = {}, notice = st.notice}
    if controls[st.selected][1] == "chromatic" then model.notice = st.chromaticError end
    if controls[st.selected][1] == "output" then model.detail = "Develop EXRs to LogC3 or F-Log TIFF." end
    if not model.notice and st.writeError then model.notice = "Changes apply to this session only." end
    for i, control in ipairs(controls) do model.rows[i] = {label = control[2], value = values[control[1]]} end
    return model
end

return studio
