-- Scene-linear shutter adapted from Denshattack! and Luna Abyss Photo Camera (MIT).
-- A separate nonpersistent scene capture renders once, before display tonemapping.
local linear = {}
local signature = "\118\047\049\001" .. string.pack("<I4", 2)
local abandoned = {}

local function object(path)
    local o = StaticFindObject(path)
    assert(o and o:IsValid(), "Missing Unreal object " .. path)
    return o
end

local function occupied(path)
    local file, _, code = io.open(path, "rb")
    if file then file:close() end
    return file ~= nil or code ~= 2
end

local function exact(file, count)
    local data = file:read(count)
    assert(data and #data == count, "Incomplete native EXR")
    return data
end

local function readName(file)
    local s = ""
    for _ = 1, 256 do
        local ch = exact(file, 1)
        if ch == "\0" then return s end
        s = s .. ch
    end
    error("Overlong EXR attribute name")
end

local function attribute(name, kind, data)
    return string.pack("<zzI4", name, kind, #data) .. data
end

local function rgbHeader(w, h)
    local entries = {}
    for _, key in ipairs({"B", "G", "R"}) do
        entries[#entries+1] = string.pack("<zI4I4i4i4", key, 1, 0, 1, 1)
    end
    local bounds = string.pack("<i4i4i4i4", 0, 0, w-1, h-1)
    return signature .. attribute("channels", "chlist", table.concat(entries) .. "\0")
        .. attribute("compression", "compression", "\0") .. attribute("dataWindow", "box2i", bounds)
        .. attribute("displayWindow", "box2i", bounds) .. attribute("lineOrder", "lineOrder", "\0")
        .. attribute("pixelAspectRatio", "float", string.pack("<f",1))
        .. attribute("screenWindowCenter", "v2f", string.pack("<ff",0,0))
        .. attribute("screenWindowWidth", "float", string.pack("<f",1))
        .. attribute("chromaticities", "chromaticities",
            string.pack("<ffffffff", 0.64,0.33,0.30,0.60,0.15,0.06,0.3127,0.3290))
        .. attribute("colorInteropID", "string", "lin_rec709_scene")
        .. attribute("comments", "string", "Halo Photo Mode. Unreal SceneColorHDRNoAlpha, independent view, relative exposure.")
        .. "\0"
end

local function startFile(job)
    assert(not occupied(job.partial), "EXR staging file already exists")
    local out <close> = assert(io.open(job.partial, "wb"))
    job.ownsPartial = true
    local header = rgbHeader(job.crop.w, job.crop.h)
    local first = #header + job.crop.h * 8
    job.stride = 8 + 6 * job.crop.w
    job.expectedSize = first + job.crop.h * job.stride
    assert(out:write(header))
    for y=0,job.crop.h-1 do assert(out:write(string.pack("<I8", first + y * job.stride))) end
    assert(out:flush())
end

-- Unreal's synchronous image writer can still submit a render-thread command.
-- Wait for all indexed rows to reach disk before trimming its alpha and padding.
local function sourceInfo(f, job, size)
    assert(exact(f, 8) == signature, "Expected a single-part scanline EXR")
    local fields = {}
    for i=1,100 do
        local key = readName(f)
        if key == "" then break end
        assert(i < 100 and not fields[key], "Unexpected native EXR header")
        readName(f)
        local length = string.unpack("<I4", exact(f, 4))
        assert(length < 65536, "Oversized native EXR attribute")
        fields[key] = exact(f, length)
    end
    assert(fields.compression == "\0" and fields.dataWindow == string.pack("<i4i4i4i4",0,0,job.renderW-1,job.crop.h-1),
        "Expected matching uncompressed EXR bounds")
    local channels, pos = {}, 1
    local data = assert(fields.channels, "Native EXR has no channels")
    while data:byte(pos) ~= 0 do
        local name, pixelType, _, subX, subY
        name, pixelType, _, subX, subY, pos = string.unpack("<zI4I4i4i4", data, pos)
        assert(pixelType == 1 and subX == 1 and subY == 1, "Expected full-resolution HALF channels")
        channels[#channels+1] = name
    end
    local list = table.concat(channels)
    assert(list == "ABGR" or list == "BGR", "Native EXR channel order is unsupported")
    local indices = exact(f, job.crop.h*8)
    local first = assert(f:seek())
    local stride = 8 + 2*#channels*job.renderW
    if size < first + job.crop.h*stride then return false end
    job.indices, job.channels, job.firstSource = indices, #channels, first
    return true
end

local function copyRows(job, f)
    local rowBytes = job.renderW*2
    local limit = math.min(job.crop.h, job.row + math.max(1, 1048576 // job.renderW))
    local out <close> = assert(io.open(job.partial, "ab"))
    for y=job.row,limit-1 do
        local offset = string.unpack("<I8", job.indices, y*8 + 1)
        assert(offset >= job.firstSource and f:seek("set", offset), "Invalid EXR row offset")
        local line, size = string.unpack("<i4I4", exact(f, 8))
        assert(line == y and size == job.channels*rowBytes, "Invalid native EXR scanline")
        if job.channels == 4 then assert(f:seek("cur", rowBytes)) end
        assert(out:write(string.pack("<i4I4", y, job.stride-8)))
        for _=1,3 do
            local plane = exact(f, rowBytes)
            assert(out:write(plane:sub(job.left*2 + 1, (job.left+job.crop.w)*2)))
        end
    end
    assert(out:flush())
    job.row = limit
end

-- Raw readback promotes RGBA16F to LinearColor; convert exactly back to HALF.
local function half(value)
    if value == 0 then return 1/value < 0 and "\0\128" or "\0\0" end
    local n = math.abs(value)
    assert(n <= 65504, "Non-finite HDR sample")
    local bits
    if n < 2^-14 then bits = assert(math.tointeger(n*2^24), "Invalid HALF subnormal")
    else
        local float = string.unpack("<I4", string.pack("<f", n))
        assert(float & 0x1fff == 0, "Scene color does not come from an RGBA16F target")
        bits = (float >> 13) - 0x1c000
    end
    return string.pack("<I2", value < 0 and (bits | 0x8000) or bits)
end

local function rawRows(job)
    local w = job.crop.w
    local rows = math.min(job.crop.h-job.row, math.max(1, 32768 // w))
    -- UE5.5 Kismet takes an origin and extents here despite MaxX/MaxY in the reflected name.
    local colors = job.lib:ReadRenderTargetRawPixelArea(job.world, job.target, job.left, job.row, w, rows, false)
    assert(#colors == w*rows, "Incomplete raw HDR readback rectangle")
    local out <close> = assert(io.open(job.partial, "ab"))
    local b, g, r, n = {}, {}, {}, 1
    for y=job.row, job.row+rows-1 do
        for x=1,w do
            local p = colors[n]
            if p.R == nil then p = p:get() end
            b[x], g[x], r[x] = half(p.B), half(p.G), half(p.R)
            n = n+1
        end
        assert(out:write(string.pack("<i4I4", y, job.stride-8), table.concat(b), table.concat(g), table.concat(r)))
    end
    assert(out:flush())
    job.row = job.row + rows
end

-- Use measured viewport rays, including roll and the asymmetric margins of odd crops.
local function projection(s, job)
    local pose, crop, k = s.pose, job.crop, s.positionKeys
    local p,y,r = math.rad(pose.pitch),math.rad(pose.yaw),math.rad(pose.roll)
    local cp,sp,cy,sy,cr,sr = math.cos(p),math.sin(p),math.cos(y),math.sin(y),math.cos(r),math.sin(r)
    local function slopes(x, y)
        local ray = {}
        assert(s.pc:DeprojectScreenPositionToWorld(x,y,{},ray), "Could not deproject the photo frame")
        local dx,dy,dz = ray[k.x],ray[k.y],ray[k.z]
        local level = cy*dx + sy*dy
        local forward, right, up = cp*level+sp*dz, -sy*dx+cy*dy, -sp*level+cp*dz
        assert(forward > 0, "Invalid photo frame ray")
        return (cr*right-sr*up)/forward,(sr*right+cr*up)/forward
    end
    local left,top = slopes(crop.x,crop.y)
    local right,bottom = slopes(crop.x+crop.w,crop.y+crop.h)
    assert(right>left and top>bottom, "Empty photo frame")
    local pixel = (right-left)/crop.w
    left = left - pixel*job.left
    right = left + pixel*job.renderW
    local halfX,halfY = (right-left)/2,(top-bottom)/2
    local centerX,centerY = (right+left)/2,(top+bottom)/2
    local view = {FOV=math.deg(2*math.atan(halfX)),AspectRatio=halfX/halfY,ProjectionMode=0,
        OffCenterProjectionOffset={X=centerX/halfX,Y=centerY/halfY}}
    local culling = math.max(math.abs(centerX)+halfX,(math.abs(centerY)+halfY)*math.max(1,job.renderW/crop.h))
    return job.lib:CalculateProjectionMatrix(view), math.min(179.99, math.deg(2*math.atan(culling)))
end

local function options()
    local result = {}
    local values = {format=3, compressionquality=1, boverwritefile=false, basync=false}
    local count = 0
    object("/Script/ImageWriteQueue.ImageWriteOptions"):ForEachProperty(function(prop)
        local key = prop:GetFName():ToString()
        if values[key:lower()] ~= nil then
            result[key],count = values[key:lower()],count+1
        end
    end)
    assert(count == 4, "Missing native EXR write options")
    return result
end

local function removeTemp(path)
    local ok, why, code = os.remove(path)
    assert(ok or code == 2, why)
end

function linear.reap()
    local now = os.time()
    for path, expiry in pairs(abandoned) do
        local ok = pcall(removeTemp, path)
        if now >= expiry then
            if not ok then print("[HaloPhotoMode] Could not clean EXR stage " .. path .. "\n") end
            abandoned[path] = nil
        end
    end
end

local function release(job)
    local errors = {}
    local function attempt(fn)
        local ok, why = pcall(fn)
        if not ok then errors[#errors+1] = tostring(why) end
    end
    attempt(function()
        if job.actor and job.actor:IsValid() then job.actor:K2_DestroyActor() end
        job.actor = nil
    end)
    attempt(function()
        if job.target and job.target:IsValid() then job.lib:ReleaseRenderTarget2D(job.target) end
        job.target = nil
    end)
    if job.ownsPartial then
        attempt(function() removeTemp(job.partial); job.ownsPartial = false end)
        if job.ownsPartial then abandoned[job.partial] = os.time()+120 end
    end
    if job.submitted then
        local removed = pcall(removeTemp, job.source)
        if not removed or not job.indices then abandoned[job.source] = os.time()+120 end
    end
    return table.concat(errors, " / ")
end

local function start(s, job)
    local settings = object("/Script/Engine.Default__RendererSettings")
    local enum = object("/Script/Engine.EWorkingColorSpace")
    local space = enum:GetNameByValue(settings.WorkingColorSpaceChoice):ToString()
    assert(space == "sRGB" or space:match("::sRGB$"), "Unsupported working color space for log development: " .. space)
    job.lib = object("/Script/Engine.Default__KismetRenderingLibrary")
    -- Some shipping builds strip the native writer; raw floating-point readback still works.
    local hasWriter, writer = pcall(object,"/Script/ImageWriteQueue.Default__ImageWriteBlueprintLibrary")
    if hasWriter then
        local hasOptions, opts = pcall(options)
        if hasOptions then job.writer,job.options = writer,opts end
    end
    local pose,k,r = s.pose,s.positionKeys,s.rotationKeys
    job.actor = s.world:SpawnActor(object("/Script/Engine.SceneCapture2D"), {X=pose.x,Y=pose.y,Z=pose.z},
        {Pitch=pose.pitch,Yaw=pose.yaw,Roll=pose.roll})
    assert(job.actor and job.actor:IsValid(),"Could not spawn the HDR camera")
    local component = job.actor:GetComponentByClass(object("/Script/Engine.SceneCaptureComponent2D"))
    assert(component and component:IsValid(),"Missing scene capture component")
    component.bCaptureEveryFrame,component.bCaptureOnMovement,component.bAlwaysPersistRenderingState = false,false,false
    assert(job.actor:K2_SetActorLocationAndRotation({[k.x]=pose.x,[k.y]=pose.y,[k.z]=pose.z},
        {[r.pitch]=pose.pitch,[r.yaw]=pose.yaw,[r.roll]=pose.roll},false,{},true),"Could not position the HDR camera")
    job.target = job.lib:CreateRenderTarget2D(s.world,job.renderW,job.crop.h,6,{R=0,G=0,B=0,A=0},false,false)
    assert(job.target and job.target:IsValid(),"Could not allocate the RGBA16F target")
    assert(job.target.SizeX == job.renderW and job.target.SizeY == job.crop.h,"Unreal resized the HDR target")
    job.target.TargetGamma = 1
    local matrix, fov = projection(s, job)
    component.bUseCustomProjectionMatrix,component.CustomProjectionMatrix,component.FOVAngle = true,matrix,fov
    component.CaptureSource,component.TextureTarget = 1,job.target -- SCS_SceneColorHDRNoAlpha
    component:CaptureScene()
end

function linear.begin(s, crop, width, height, png)
    if type(png) ~= "string" then return nil, "Expected a saved PNG path" end
    local dir,base = png:match("^(.*[/\\])([^/\\]+)%.png$")
    if not dir then return nil,"Expected a saved PNG path" end
    local job = {path=dir..base..".exr", source=dir.."."..base..".source.exr", partial=dir.."."..base..".exr.partial",
        viewportW=width, viewportH=height, world=s.world, status="pending", row=0, started=os.time()}
    if occupied(job.path) or occupied(job.source) or occupied(job.partial) then return nil,"EXR destination is occupied or inaccessible" end
    local ok, reason = pcall(function()
        local w,h,x,y = math.tointeger(crop.w),math.tointeger(crop.h),math.tointeger(crop.x),math.tointeger(crop.y)
        assert(w and h and x and y and w>0 and h>0 and x>=0 and y>=0 and w<=width-x and h<=height-y
            and w<=16384 and h<=16384 and w*h<=40000000, "EXR frame is outside the supported viewport")
        job.crop,job.renderW = {x=x,y=y,w=w,h=h},((w+31)//32)*32
        job.left = (job.renderW-w)//2
        start(s, job)
    end)
    if not ok then
        local detail = release(job)
        return nil,tostring(reason)..(detail~="" and " / "..detail or "")
    end
    return job
end

local function advance(job)
    local now = os.time()
    if now-job.started>180 then error("HDR capture timed out") end
    if job.writer and not job.submitted then
        job.submitted = now
        local ok, why = pcall(function()
            job.writer:ExportToDisk(job.target,job.source,job.options)
            job.lib:ReadRenderTargetRawPixel(job.world,job.target,0,0,false)
        end)
        if not ok then
            job.readRaw = true
            print("[HaloPhotoMode] Native EXR export unavailable. Reading scene pixels: "..tostring(why).."\n")
        end
        return
    end
    if job.writer and not job.readRaw then
        local file <close> = io.open(job.source, "rb")
        if file then
            local size = assert(file:seek("end"))
            if not job.indices then
                if size == 0 or size ~= job.size then job.size=size; return end
                assert(file:seek("set"))
                if not sourceInfo(file,job,size) then return end
            end
            if not job.ownsPartial then startFile(job) end
            copyRows(job,file)
        elseif now-job.submitted<2 then return
        else
            job.readRaw = true
            print("[HaloPhotoMode] Native EXR writer produced no file. Reading HDR pixels from the scene capture.\n")
        end
    end
    if not job.writer or job.readRaw then
        if not job.ownsPartial then startFile(job) end
        rawRows(job)
    end
    if job.row == job.crop.h then
        do
            local file <close> = assert(io.open(job.partial,"rb"))
            assert(file:seek("end")==job.expectedSize,"Incomplete RGB EXR")
        end
        assert(not occupied(job.path),"EXR destination is occupied or inaccessible")
        assert(os.rename(job.partial,job.path))
        job.ownsPartial,job.status,job.message = false,"saved",job.path
    end
end

function linear.cancel(job)
    if job and job.status == "pending" then
        job.status,job.message = "failed","HDR capture canceled"
        local detail = release(job)
        if detail ~= "" then job.message = job.message.." / "..detail end
    end
end

function linear.poll(job, width, height)
    if job.status ~= "pending" then return job.status,job.message end
    local ok, reason = pcall(function()
        assert(width==job.viewportW and height==job.viewportH,"Viewport changed during HDR capture")
        advance(job)
    end)
    if not ok then job.status,job.message="failed",tostring(reason) end
    if job.status ~= "pending" then
        local detail = release(job)
        if detail ~= "" then print("[HaloPhotoMode] HDR cleanup: "..detail.."\n") end
    end
    return job.status,job.message
end

return linear
