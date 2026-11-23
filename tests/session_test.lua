local adapterPath = "mod/HaloPhotoMode/Scripts/session.lua"

local function object(properties)
    local value = properties or {}
    function value:IsValid() return not self.destroyed end
    function value:GetAddress() return self end
    return value
end

local function widget(visibility, root, world)
    local view = object({visibility = visibility})
    function view:GetWorld() return world end
    function view:IsInViewport() return root end
    function view:GetVisibility() return self.visibility end
    function view:SetVisibility(v) self.visibility = v end
    return view
end

local function fixture()
    local f = {standalone = true, gameplay = true, calls = {}, now = 42}
    f.world = object({paused = false})
    f.pawn, f.original, f.viewport = object(), object(), object()
    f.engine = object({GameViewport = f.viewport})
    f.hud = object({bShowHUD = true})
    f.visible, f.nested, f.collapsed = widget(3, true, f.world), widget(0, false, f.world), widget(1, true, f.world)
    local pc = object({world = f.world, pawn = f.pawn, view = f.original,
        PrimaryActorTick = {bTickEvenWhenPaused = false}, bShouldPerformFullTickWhenPaused = false})
    f.pc = pc
    local objects = {}
    for _, path in ipairs({
        "/Script/Meteorite.MeteoritePlayerController", "/Script/Engine.CameraActor",
        "/Script/Engine.CameraComponent", "/Script/BlamEngine.BlamPawn", "/Script/BlamEngine.BlamEngineAudioGameSubsystem",
        "/Script/BlamEngine.BlamCinematicSubsystem",
    }) do objects[path] = object({path = path}) end

    function pc:IsA(class)
        return class == objects["/Script/Meteorite.MeteoritePlayerController"] and not f.wrongController
    end
    function pc:K2_GetPawn() return self.pawn end
    function pc:GetWorld() return self.world end
    function pc:GetHUD() return f.hud end
    function pc:GetViewTarget() return self.view end
    function pc:SetTickableWhenPaused(v) self.PrimaryActorTick.bTickEvenWhenPaused = v end
    function pc:SetGameAndBlamPaused(world, paused)
        assert(world == self.world, "attempted to alter pause through a stale controller")
        f.calls[#f.calls + 1] = paused and "Blam pause" or "Blam resume"
        f.blamPaused = paused and not f.rejectBlamPause
        if f.pairedWorld and (paused or not f.stickyWorld) then world.paused = paused end
        if paused and f.errorAfterPause then error("title setter failed after changing state") end
    end
    function pc:SetViewTargetWithBlend(actor)
        if actor == f.original and f.rejectViewRestore then return end
        if actor == f.camera then
            assert(actor.location.X == -400 and actor.angle.pitch == -7.5,
                "camera must match the evaluated transform before switching the rendered view")
            assert(actor.lens.FieldOfView == 100)
        end
        self.view = actor
    end
    pc.PlayerCameraManager = object({
        GetCameraLocation = function() return {X = -400, Y = 0, Z = 75} end,
        GetCameraRotation = function() return {pitch = -7.5, Yaw = 34, Roll = -12} end,
        GetFOVAngle = function() return 100 end,
    })

    function f.world:SpawnActor(class, xyz, rot)
        assert(class == objects["/Script/Engine.CameraActor"] and xyz.X == -400 and rot.Pitch == -7.5)
        local camera = object({lens = object({FieldOfView = 90})})
        function camera:GetWorld() return self.world end
        camera.world = f.world
        function camera:GetComponentByClass(component)
            assert(component == objects["/Script/Engine.CameraComponent"])
            return self.lens
        end
        function camera.lens:SetFieldOfView(v) self.FieldOfView = v end
        function camera.lens:SetConstraintAspectRatio(v) self.constrain = v end
        function camera:K2_SetActorLocationAndRotation(location, angle)
            self.location, self.angle = location, angle
            return not f.rejectTransform
        end
        function camera:EnableInput(controller)
            assert(controller == pc and self.bBlockInput and self.InputPriority > 0)
            self.input = true
        end
        function camera:DisableInput(controller) assert(controller == pc); self.input = false end
        function camera:K2_DestroyActor() self.destroyed = true end
        f.camera = camera
        return camera
    end

    local audio = object({
        GetIsPaused = function() return not not f.blamPaused end,
        IsNetworkCoop = function() return not not f.coop end,
    })
    local cinematic = object({IsCinematicInProgress = function() return not not f.cinematic end})
    objects["/Script/Engine.Default__GameplayStatics"] = object({
        GetPlayerController = function(_, viewport, index)
            assert(viewport == f.viewport and index == 0)
            return pc
        end,
        IsGamePaused = function(_, world) return world.paused end,
        SetGamePaused = function(_, world, paused)
            assert(world == pc.world, "attempted to change pause on an unrelated world")
            assert(paused == false, "CU4 entry must leave the Unreal render world running")
            f.calls[#f.calls + 1] = "world resume"
            world.paused = paused
            return true
        end,
        GetRealTimeSeconds = function(_, world) assert(world == f.world); return f.now end,
    })
    objects["/Script/Meteorite.Default__MeteoriteUIStatics"] = object({
        IsInGameplayState = function(_, world) assert(world == f.world); return f.gameplay end,
    })
    objects["/Script/Engine.Default__KismetSystemLibrary"] = object({
        IsStandalone = function(_, world) assert(world == f.world); return f.standalone end,
        IsSplitScreen = function(_, world) assert(world == f.world); return not not f.split end,
    })
    objects["/Script/Engine.Default__SubsystemBlueprintLibrary"] = object({
        GetGameInstanceSubsystem = function(_, world, class)
            assert(world == f.world)
            if class == objects["/Script/BlamEngine.BlamEngineAudioGameSubsystem"] then return audio end
            assert(class == objects["/Script/BlamEngine.BlamCinematicSubsystem"])
            return cinematic
        end,
    })
    objects["/Script/UMG.Default__WidgetLayoutLibrary"] = object({
        GetViewportSize = function() return {X = 1920, Y = 1080} end,
    })
    local env = setmetatable({
        FindFirstOf = function(name) assert(name == "GameEngine"); return f.engine end,
        FindAllOf = function(name) assert(name == "UserWidget"); return {f.visible, f.nested, f.collapsed} end,
        StaticFindObject = function(path) return assert(objects[path], "Unexpected object " .. path) end,
    }, {__index = _G})
    f.adapter = assert(loadfile(adapterPath, "t", env))()
    return f
end

local function bodyFixture()
    local f = fixture()
    local pawn = f.pawn
    f.pc.view = pawn
    pawn.bHidden, pawn.CurrentBlamCameraPerspective = false, 1
    pawn.location, pawn.world, pawn.changes = {X = -400, Y = 0, Z = 0}, f.world, {}
    function pawn:IsA(class) return class.path == "/Script/BlamEngine.BlamPawn" end
    function pawn:K2_GetActorLocation() return self.location end
    function pawn:GetWorld() return self.world end
    function pawn:SetActorHiddenInGame(value)
        self.changes[#self.changes + 1] = value and "hide" or "show"
        self.bHidden = value
        if f.brokenHide and value then error("optional setter failed after hiding") end
    end
    local function weapon()
        local actor = object({bHidden = false, changes = 0, world = f.world})
        function actor:GetWorld() return self.world end
        function actor:SetActorHiddenInGame(value)
            self.bHidden, self.changes = value, self.changes + 1
        end
        return actor
    end
    f.firstWeapon, f.thirdWeapon = weapon(), weapon()
    function pawn:GetPawnViewModeAndWeaponActors(mode, third, first)
        mode.OutViewMode = 1
        third.ThirdPersonWeapon = f.thirdWeapon
        first.FirstPersonWeapon = f.firstWeapon
    end
    return f
end

do
    local f = bodyFixture()
    local s = assert(f.adapter.open())
    assert(f.pawn.bHidden and f.firstWeapon.bHidden and f.thirdWeapon.bHidden)
    s.pose.x = s.pose.x + 60
    f.adapter.apply(s, s.pose)
    assert(not f.pawn.bHidden and not f.firstWeapon.bHidden and not f.thirdWeapon.bHidden)
    s.pose.x = s.pose.x - 60
    f.adapter.apply(s, s.pose)
    assert(f.pawn.bHidden and f.firstWeapon.bHidden and f.thirdWeapon.bHidden)
    assert(f.adapter.close(s) and not f.pawn.bHidden and not f.firstWeapon.bHidden and not f.thirdWeapon.bHidden)
    assert(table.concat(f.pawn.changes, ",") == "hide,show,hide,show")
end

do
    local f = bodyFixture()
    f.firstWeapon.bHidden = true
    f.thirdWeapon.world = object()
    local s = assert(f.adapter.open())
    assert(f.pawn.bHidden and f.adapter.close(s))
    assert(f.firstWeapon.bHidden and f.firstWeapon.changes == 0 and f.thirdWeapon.changes == 0)
end

do
    local f = bodyFixture()
    local previous = f.firstWeapon
    f.thirdWeapon = previous -- both views refer to the same actor
    local s = assert(f.adapter.open())
    assert(previous.bHidden and previous.changes == 1)
    s.pose.x = s.pose.x + 60
    f.adapter.apply(s, s.pose)
    f.firstWeapon, f.thirdWeapon = nil, nil -- unequipped while clear of the pawn
    s.pose.x = s.pose.x - 60
    f.adapter.apply(s, s.pose)
    assert(f.pawn.bHidden and not previous.bHidden and previous.changes == 2)
    assert(f.adapter.close(s) and previous.changes == 2)
end

for _, prepare in ipairs({
    function(f) f.pawn.CurrentBlamCameraPerspective = 2 end,
    function(f) f.pawn.bHidden = true end,
    function(f) f.pawn.location.X = -700 end,
    function(f) f.pc.view = f.original end,
    function(f) f.pawn.K2_GetActorLocation = nil end,
}) do
    local f = bodyFixture()
    prepare(f)
    local original = f.pawn.bHidden
    local s = assert(f.adapter.open())
    assert(f.pawn.bHidden == original and f.adapter.close(s) and #f.pawn.changes == 0)
    assert(f.firstWeapon.changes == 0 and f.thirdWeapon.changes == 0)
end

do
    local f = bodyFixture()
    f.brokenHide = true
    local s = assert(f.adapter.open())
    assert(not f.pawn.bHidden and f.adapter.close(s) and table.concat(f.pawn.changes, ",") == "hide,show")
end

do
    local f = bodyFixture()
    local s = assert(f.adapter.open())
    local replacement = object({bHidden = true})
    f.pc.pawn = replacement
    assert(not f.adapter.alive(s))
    assert(f.adapter.close(s) and not f.pawn.bHidden and replacement.bHidden)
end

local titlePause = "Blam pause,Blam resume"
do
    local f = fixture()
    local s = assert(f.adapter.open())
    assert(f.adapter.alive(s))
    assert(not f.world.paused and f.blamPaused and f.pc.view == f.camera and f.camera.input)
    assert(not f.hud.bShowHUD and f.visible.visibility == 2 and f.nested.visibility == 0 and f.collapsed.visibility == 1)
    local w, h = f.adapter.viewport(s)
    assert(w == 1920 and h == 1080 and f.adapter.time(s) == 42)
    s.pose.pitch, s.pose.z, s.pose.fov = 10, 300, 30
    f.adapter.apply(s, s.pose)
    assert(f.camera.angle.pitch == 10 and f.camera.location.Z == 300 and f.camera.lens.FieldOfView == 30)
    assert(f.adapter.close(s))
    assert(table.concat(f.calls, ",") == titlePause and not f.world.paused and not f.blamPaused)
    assert(f.pc.view == f.original and f.camera.destroyed and not f.camera.input)
    assert(f.hud.bShowHUD and f.visible.visibility == 3 and f.nested.visibility == 0 and f.collapsed.visibility == 1)
    assert(not f.pc.PrimaryActorTick.bTickEvenWhenPaused and not f.pc.bShouldPerformFullTickWhenPaused)
    assert(f.adapter.close(s) and #f.calls == 2)
end

for _, sticky in ipairs({false, true}) do
    local f = fixture()
    f.pairedWorld, f.stickyWorld = true, sticky
    local s = assert(f.adapter.open())
    assert(f.world.paused and f.blamPaused and f.adapter.close(s))
    local expected = sticky and titlePause .. ",world resume" or titlePause
    assert(table.concat(f.calls, ",") == expected and not f.world.paused and not f.blamPaused)
end

do
    local f = fixture()
    f.pairedWorld, f.stickyWorld = true, true
    local s = assert(f.adapter.open())
    f.world.paused = false -- Unreal clears its flag while Blam remains paused.
    assert(f.adapter.alive(s))
    f.world.paused = true -- Independent menu pause after ownership was released.
    f.blamPaused = false
    assert(not f.adapter.alive(s))
    assert(f.adapter.close(s) and f.world.paused and table.concat(f.calls, ",") == titlePause)
end

for _, prepare in ipairs({
    function(f) f.coop = true end,
    function(f) f.standalone = false end,
    function(f) f.split = true end,
    function(f) f.cinematic = true end,
    function(f) f.gameplay = false end,
    function(f) f.wrongController = true end,
    function(f) f.world.paused = true end,
    function(f) f.blamPaused = true end,
}) do
    local f = fixture()
    prepare(f)
    local s, err = f.adapter.open()
    assert(not s and type(err) == "string")
    assert(#f.calls == 0 and not f.camera and f.pc.view == f.original)
end

for _, fail in ipairs({"rejectBlamPause", "errorAfterPause", "rejectTransform"}) do
    local f = fixture()
    f.pairedWorld, f.stickyWorld = true, true
    f[fail] = true
    local s, err = f.adapter.open()
    assert(not s and type(err) == "string")
    assert(table.concat(f.calls, ",") == titlePause .. ",world resume" and not f.world.paused and not f.blamPaused)
    if fail ~= "rejectTransform" then assert(not f.camera, "camera must wait for Blam acknowledgment") end
    assert(f.pc.view == f.original and f.hud.bShowHUD and f.visible.visibility == 3)
    assert(not f.camera or f.camera.destroyed)
end

do
    local f = fixture()
    f.hud.bShowHUD = false
    f.pc.PrimaryActorTick.bTickEvenWhenPaused, f.pc.bShouldPerformFullTickWhenPaused = true, true
    local s = assert(f.adapter.open())
    f.visible.visibility = 1 -- The game collapsed a root independently during the session.
    assert(f.adapter.close(s))
    assert(not f.hud.bShowHUD and f.visible.visibility == 1)
    assert(f.pc.PrimaryActorTick.bTickEvenWhenPaused and f.pc.bShouldPerformFullTickWhenPaused)
end

do
    local f = fixture()
    local s = assert(f.adapter.open())
    f.rejectViewRestore = true
    local ok, reason = f.adapter.close(s)
    assert(not ok and type(reason) == "string" and f.camera:IsValid() and f.pc.view == f.camera)
    f.rejectViewRestore = false
    assert(f.adapter.close(s))
    assert(f.pc.view == f.original and f.camera.destroyed and not f.world.paused)
end

do
    local f = fixture()
    local s = assert(f.adapter.open())
    local nextWorld, nextView = object({paused = true}), object()
    f.pc.world, f.pc.view, f.pc.pawn = nextWorld, nextView, object()
    assert(not f.adapter.alive(s))
    assert(f.adapter.close(s))
    assert(nextWorld.paused and f.pc.view == nextView and table.concat(f.calls, ",") == "Blam pause")
end

print("Session adapter tests passed")
