-- Halo CU4's reflected gameplay interfaces, with camera/UMG handling adapted
-- from Denshattack! Photo Camera (see ../LICENSE). Call on the game thread.
local session = {}
local restoring

local function valid(o)
    return o ~= nil and o:IsValid()
end

local function need(o, message)
    assert(valid(o), message)
    return o
end

local function object(path)
    return need(StaticFindObject(path), "Missing reflected object " .. path)
end

local function same(a, b)
    return valid(a) and valid(b) and a:GetAddress() == b:GetAddress()
end

local function ownsWorld(s)
    return valid(s.pc) and same(s.pc:GetWorld(), s.world)
        and valid(s.viewportClient) and same(s.api:GetPlayerController(s.viewportClient, 0), s.pc)
end

local function undo(s, description, callback)
    table.insert(s.undos, {name = description, run = callback})
end

function session.close(s)
    if not s then return true end
    local errors = {}
    s.closed = true
    for i = #s.undos, 1, -1 do
        local step = s.undos[i]
        local ok, reason = pcall(step.run)
        if ok then table.remove(s.undos, i)
        else table.insert(errors, step.name .. ": " .. tostring(reason)) end
    end
    if #errors > 0 then
        restoring = s
        return false, table.concat(errors, ", ")
    end
    if restoring == s then restoring = nil end
    return true
end

-- Reflected struct fields can retain the shipping build's FName casing.
local function vector(value, names)
    local result, keys = {}, {}
    if type(value) == "table" then
        for key in pairs(value) do
            if type(key) == "string" then keys[key:lower()] = key end
        end
    end
    for _, name in ipairs(names) do
        local lower = name:lower()
        local key = keys[lower] or name
        local n = value and value[key]
        assert(type(n) == "number" and n == n and math.abs(n) < math.huge, "Missing camera field " .. name)
        result[lower], keys[lower] = n, key
    end
    return result, keys
end

local function restoreBody(s, body)
    -- Keep failed restorations for close() to retry; other actors still release.
    local errors = {}
    for i = #body.hidden, 1, -1 do
        local actor = body.hidden[i]
        local ok, reason = pcall(function()
            if valid(actor) and same(actor:GetWorld(), s.world) and actor.bHidden then
                actor:SetActorHiddenInGame(false)
                assert(actor.bHidden == false, "Actor visibility was not restored")
            end
        end)
        if ok then table.remove(body.hidden, i) else table.insert(errors, tostring(reason)) end
    end
    assert(#errors == 0, table.concat(errors, ", "))
end

local function hideNearActor(s, body, actor)
    if not valid(actor) or not same(actor:GetWorld(), s.world) or actor.bHidden ~= false then return false end
    -- Record before mutation so rollback also covers a partially failed setter.
    table.insert(body.hidden, actor)
    actor:SetActorHiddenInGame(true)
    assert(actor.bHidden == true, "Actor did not accept the visibility change")
    return true
end

local function localWeapons(pawn)
    -- UE4SS puts UObject out parameters in the caller's tables under the
    -- reflected property name. Resolve again when the lens returns to the pawn.
    local mode, third, first = {}, {}, {}
    pawn:GetPawnViewModeAndWeaponActors(mode, third, first)
    return first.FirstPersonWeapon, third.ThirdPersonWeapon
end

local function updateBody(s, pose)
    local body = s.body
    if not body or body.disabled then return end
    local dx, dy, dz = pose.x - body.x, pose.y - body.y, pose.z - body.z
    local near = dx * dx + dy * dy + dz * dz < 55 * 55 -- cm around the entry eye
    if near == body.near then return end
    body.near = near
    local ok, reason = pcall(function()
        if not near then
            restoreBody(s, body)
        elseif ownsWorld(s) and same(s.pc:K2_GetPawn(), s.pawn) and same(s.pawn:GetWorld(), s.world) then
            local found, first, third = pcall(localWeapons, s.pawn)
            hideNearActor(s, body, s.pawn)
            if found then
                local hiddenFirst = hideNearActor(s, body, first)
                local hiddenThird = hideNearActor(s, body, third)
                if not body.reported then
                    print(("[HaloPhotoMode] Near-eye weapon visibility changed (first %s, third %s)\n"):format(
                        tostring(hiddenFirst), tostring(hiddenThird)))
                end
            elseif not body.reported then
                print("[HaloPhotoMode] Local weapon lookup unavailable: " .. tostring(first) .. "\n")
            end
            body.reported = true
        end
    end)
    if not ok then
        body.disabled = true
        print("[HaloPhotoMode] Near-body hiding unavailable: " .. tostring(reason) .. "\n")
        restoreBody(s, body)
    end
end

local function enableBodyHiding(s)
    if not same(s.previous, s.pawn) then return end
    -- CU4's ABlamPawn enum is None=0, FirstPerson=1, ThirdPerson=2.
    if not s.pawn:IsA(object("/Script/BlamEngine.BlamPawn")) then return end
    local perspective = s.pawn.CurrentBlamCameraPerspective
    if s.pawn.bHidden ~= false or perspective ~= 1 then
        print(("[HaloPhotoMode] Body unchanged (perspective %s, hidden %s)\n"):format(
            tostring(perspective), tostring(s.pawn.bHidden)))
        return
    end
    local center = vector(s.pawn:K2_GetActorLocation(), {"X", "Y", "Z"})
    local eye = s.pose
    local dx, dy, dz = eye.x - center.x, eye.y - center.y, eye.z - center.z
    -- The actor origin can be at the feet or inside the capsule. A chase
    -- camera behind or above the Spartan should leave the subject visible.
    if dx * dx + dy * dy > 55 * 55 or math.abs(dz) > 225 then
        print(("[HaloPhotoMode] Body visible at entry (eye offset %.0f, %.0f, %.0f cm)\n"):format(dx, dy, dz))
        return
    end
    local body = {x = eye.x, y = eye.y, z = eye.z, hidden = {}}
    s.body = body
    undo(s, "restore local pawn visibility", function() restoreBody(s, body) end)
    updateBody(s, eye)
    if not body.disabled and s.pawn.bHidden then print("[HaloPhotoMode] First-person pawn hidden near the entry eye\n") end
end

function session.apply(s, pose)
    local k, r = s.positionKeys, s.rotationKeys
    local xyz = {[k.x] = pose.x, [k.y] = pose.y, [k.z] = pose.z}
    local pyr = {[r.pitch] = pose.pitch, [r.yaw] = pose.yaw, [r.roll] = pose.roll}
    assert(s.camera:K2_SetActorLocationAndRotation(xyz, pyr, false, {}, true), "Detached camera rejected its pose")
    if s.lens.FieldOfView ~= pose.fov then s.lens:SetFieldOfView(pose.fov) end
    s.pose = pose
    updateBody(s, pose)
end

local function hideHud(s)
    local hud = s.pc:GetHUD()
    if valid(hud) and hud.bShowHUD then
        undo(s, "HUD", function()
            if valid(hud) and not hud.bShowHUD then hud.bShowHUD = true end
        end)
        hud.bShowHUD = false
    end
    for _, widget in ipairs(FindAllOf("UserWidget") or {}) do
        if valid(widget) and widget:IsInViewport() and same(widget:GetWorld(), s.world) then
            local original = widget:GetVisibility()
            if original ~= 1 and original ~= 2 then
                undo(s, "viewport widget", function()
                    if valid(widget) and same(widget:GetWorld(), s.world) and widget:GetVisibility() == 2 then
                        widget:SetVisibility(original)
                    end
                end)
                widget:SetVisibility(2)
            end
        end
    end
end

local function enter(s)
    s.stage = "locate solo campaign"
    local engine = need(FindFirstOf("GameEngine"), "Game engine unavailable")
    s.viewportClient = need(engine.GameViewport, "Viewport unavailable")
    s.api = object("/Script/Engine.Default__GameplayStatics")
    s.pc = need(s.api:GetPlayerController(s.viewportClient, 0), "Local player unavailable")
    local pc = s.pc
    s.world = need(pc:GetWorld(), "World unavailable")
    local world = s.world
    local ui = object("/Script/Meteorite.Default__MeteoriteUIStatics")
    assert(ui:IsInGameplayState(world) == true, "Enter a campaign mission before pressing F8")
    assert(pc:IsA(object("/Script/Meteorite.MeteoritePlayerController")), "Campaign player controller unavailable")
    local kismet = object("/Script/Engine.Default__KismetSystemLibrary")
    assert(kismet:IsStandalone(world) and not kismet:IsSplitScreen(world), "A solo campaign is required")
    local subsystems = object("/Script/Engine.Default__SubsystemBlueprintLibrary")
    local function blamSubsystem(name)
        return need(subsystems:GetGameInstanceSubsystem(world, object("/Script/BlamEngine." .. name)),
            "Missing active " .. name)
    end
    s.blam = blamSubsystem("BlamEngineAudioGameSubsystem")
    assert(s.blam:IsNetworkCoop() == false, "Close co-op before entering photo mode")
    assert(not blamSubsystem("BlamCinematicSubsystem"):IsCinematicInProgress(), "Waiting for the cinematic to finish")
    assert(not s.api:IsGamePaused(world) and not s.blam:GetIsPaused(), "Resume gameplay before pressing F8")
    s.pawn = need(pc:K2_GetPawn(), "Local player has no pawn")
    s.previous = need(pc:GetViewTarget(), "Game view unavailable")
    s.stage = "sample camera"
    local manager = need(pc.PlayerCameraManager, "Player camera manager unavailable")
    local loc, locKeys = vector(manager:GetCameraLocation(), {"X", "Y", "Z"})
    local rot, rotKeys = vector(manager:GetCameraRotation(), {"Pitch", "Yaw", "Roll"})
    local fov = manager:GetFOVAngle()
    assert(type(fov) == "number" and fov > 0 and fov < 180, "Invalid rendered FOV")
    s.positionKeys, s.rotationKeys = locKeys, rotKeys
    local pose = {x=loc.x, y=loc.y, z=loc.z, pitch=rot.pitch, yaw=rot.yaw, roll=rot.roll, fov=fov}

    s.stage = "pause campaign simulation"
    -- CU4 broadcasts the requested Blam state to this subsystem on the game
    -- thread. Unreal can keep ticking and rendering with Blam paused.
    undo(s, "resume campaign", function()
        if ownsWorld(s) then
            -- If the entry setter threw, sample any partial change before
            -- undoing it. Both engines were running when entry started.
            if s.titlePausedWorld == nil then s.titlePausedWorld = s.api:IsGamePaused(world) end
            pc:SetGameAndBlamPaused(world, false)
            if s.titlePausedWorld and s.api:IsGamePaused(world) then
                s.api:SetGamePaused(world, false)
                assert(not s.api:IsGamePaused(world), "Could not release the title's Unreal pause")
            end
            assert(not valid(s.blam) or not s.blam:GetIsPaused(), "Blam still reports paused")
        end
    end)
    pc:SetGameAndBlamPaused(world, true)
    s.titlePausedWorld = s.api:IsGamePaused(world)
    assert(s.blam:GetIsPaused() == true, "Blam did not acknowledge the campaign pause")

    s.stage = "spawn camera"
    local camera = need(world:SpawnActor(object("/Script/Engine.CameraActor"),
        {X=loc.x, Y=loc.y, Z=loc.z}, {Pitch=rot.pitch, Yaw=rot.yaw, Roll=rot.roll}), "Camera spawn failed")
    s.camera = camera
    undo(s, "remove camera", function()
        if valid(camera) then
            assert(not (ownsWorld(s) and same(pc:GetViewTarget(), camera)), "Camera still owns the view")
            camera:K2_DestroyActor()
        end
    end)
    s.lens = need(camera:GetComponentByClass(object("/Script/Engine.CameraComponent")), "Camera lens unavailable")
    session.apply(s, pose)
    s.lens:SetConstraintAspectRatio(false)
    s.stage = "take input and view"
    camera.bBlockInput, camera.InputPriority = true, 100000
    undo(s, "release input", function()
        if valid(camera) and valid(pc) then camera:DisableInput(pc) end
    end)
    camera:EnableInput(pc)
    if not pc.PrimaryActorTick.bTickEvenWhenPaused then
        undo(s, "controller tick", function()
            if ownsWorld(s) then pc:SetTickableWhenPaused(false) end
        end)
        pc:SetTickableWhenPaused(true)
    end
    if not pc.bShouldPerformFullTickWhenPaused then
        undo(s, "paused view updates", function()
            if ownsWorld(s) then pc.bShouldPerformFullTickWhenPaused = false end
        end)
        pc.bShouldPerformFullTickWhenPaused = true
    end
    hideHud(s)
    undo(s, "restore game view", function()
        if ownsWorld(s) and same(pc:GetViewTarget(), camera) then
            local previous = valid(s.previous) and s.previous or pc:K2_GetPawn()
            need(previous, "Original view and pawn unavailable")
            pc:SetViewTargetWithBlend(previous, 0, 0, 0, false)
            assert(not same(pc:GetViewTarget(), camera), "View restoration rejected")
        end
    end)
    local ok, reason = pcall(enableBodyHiding, s)
    if not ok then print("[HaloPhotoMode] Could not evaluate first-person body: " .. tostring(reason) .. "\n") end
    pc:SetViewTargetWithBlend(camera, 0, 0, 0, false)
    assert(same(pc:GetViewTarget(), camera), "Halo retained the gameplay view")
end

function session.open()
    if restoring then
        local ok, reason = session.close(restoring)
        return nil, ok and "Gameplay restored. Press F8 again to enter." or reason
    end
    local s = {undos = {}}
    local ok, reason = pcall(enter, s)
    if ok then return s end
    local restored, err = session.close(s)
    return nil, s.stage .. ": " .. tostring(reason) .. (restored and "" or " (restoration pending: " .. err .. ")")
end

function session.alive(s)
    local ok, active, reason = pcall(function()
        if s.closed or not ownsWorld(s) then return false, "Campaign world or controller changed" end
        if not same(s.pc:K2_GetPawn(), s.pawn) then return false, "Campaign pawn changed" end
        if not valid(s.lens) then return false, "Detached lens expired" end
        if s.titlePausedWorld and not s.api:IsGamePaused(s.world) then s.titlePausedWorld = false end
        if not valid(s.blam) or not s.blam:GetIsPaused() then return false, "Campaign simulation resumed" end
        if not same(s.pc:GetViewTarget(), s.camera) then return false, "Halo replaced the detached view target" end
        return true
    end)
    if not ok then return false, tostring(active) end
    if not active then return false, reason end
    return true
end

function session.time(s)
    return s.api:GetRealTimeSeconds(s.world)
end

function session.viewport(s)
    local size = object("/Script/UMG.Default__WidgetLayoutLibrary"):GetViewportSize(s.pc)
    local xy = vector(size, {"X", "Y"})
    assert(xy.x >= 1 and xy.y >= 1, "Viewport has no pixels")
    return math.floor(xy.x), math.floor(xy.y)
end

return session
