-- Exercise real EXR encoding and camera rays without a renderer.
local linear = dofile("mod/HaloPhotoMode/Scripts/linear.lua")
local stem = os.tmpname(); os.remove(stem)
local png = stem .. ".png"
local base = stem:match("[^/]+$")
local dir = stem:sub(1, #stem - #base)
local final, source, partial = stem..".exr", dir.."."..base..".source.exr", dir.."."..base..".exr.partial"
local function present(path)
    local f = io.open(path, "rb")
    if f then f:close(); return true end
    return false
end
local function read(path)
    local f <close> = assert(io.open(path,"rb"))
    return f:read("a")
end
local function write(path, content)
    local f <close> = assert(io.open(path,"wb"))
    assert(f:write(content))
end
write(png,"original display image")
local function valid() return true end
local function named(value) return {ToString=function() return value end} end
local now = 10
os.time = function() return now end
local activeSpace = "EWorkingColorSpace::sRGB"
local target, actor, camera, library, writer = {},{},{},{},{}
local objects = {
    ["Default__RendererSettings"] = {WorkingColorSpaceChoice=0}, EWorkingColorSpace = {
        GetNameByValue=function(_,n) assert(n==0); return named(activeSpace) end},
    ["Default__KismetRenderingLibrary"]=library, SceneCapture2D={}, SceneCaptureComponent2D={},
    ["Default__ImageWriteBlueprintLibrary"]=writer, ImageWriteOptions={ForEachProperty=function(_,cb)
        for _,key in ipairs({"Format","CompressionQuality","bOverwriteFile","bAsync","OnComplete"}) do
            cb({GetFName=function() return named(key) end})
        end
    end},
}
for _,o in pairs(objects) do o.IsValid=valid end
target.IsValid,actor.IsValid,camera.IsValid = valid,valid,valid
function StaticFindObject(path) return objects[path:match("%.([^%.]+)$")] end
local cropped = {x=2,y=1,w=5,h=3}
local pose = {x=9,y=-2,z=55,pitch=0,yaw=90,roll=90}
local session = {world={}, pc={}, pose=pose, positionKeys={x="x",y="Y",z="z"},rotationKeys={pitch="pitch",yaw="Yaw",roll="roll"}}
function session.world:SpawnActor(_, pos, rot)
    assert(pos.X==pose.x and pos.Z==pose.z and rot.Pitch==pose.pitch)
    actor.destroyed=nil
    return actor
end
function session.pc:DeprojectScreenPositionToWorld(x,y,_,out)
    -- At yaw 90, roll 90, forward is +Y, right is -Z, up is -X.
    out.x,out.Y,out.z = (y-3)/5,1,-(x-5)/5
    return true
end
function actor:GetComponentByClass() return camera end
function actor:K2_SetActorLocationAndRotation(pos, rot)
    assert(pos.x==pose.x and pos.z==pose.z and rot.roll==pose.roll)
    return true
end
function actor:K2_DestroyActor() self.destroyed=true end
function library:CreateRenderTarget2D(wld,w,h,fmt,_,mip,uav)
    assert(wld==session.world and w%32==0 and fmt==6 and not mip and not uav)
    target.SizeX,target.SizeY,target.released = w,h,nil
    return target
end
local close = function(a,b) return math.abs(a-b)<0.000001 end
function library:CalculateProjectionMatrix(info)
    local half=math.tan(math.rad(info.FOV)/2)
    local function slope(x,y)
        local offset=info.OffCenterProjectionOffset
        return half*(2*x/target.SizeX-1+offset.X),half/info.AspectRatio*(1-2*y/target.SizeY+offset.Y)
    end
    local left=(target.SizeX-cropped.w)//2
    local l,t=slope(left,0)
    local r,b=slope(left+cropped.w,cropped.h)
    assert(close(l,(cropped.x-5)/5) and close(t,(3-cropped.y)/5))
    assert(close(r,(cropped.x+cropped.w-5)/5) and close(b,(3-cropped.y-cropped.h)/5))
    return "projection"
end
function camera:CaptureScene()
    assert(self.bUseCustomProjectionMatrix and self.CustomProjectionMatrix=="projection")
    assert(self.CaptureSource==1 and self.TextureTarget==target and target.TargetGamma==1)
    assert(not self.bCaptureEveryFrame and not self.bCaptureOnMovement and not self.bAlwaysPersistRenderingState)
end
function library:ReleaseRenderTarget2D(rt) assert(rt==target); target.released=true end
function library:ReadRenderTargetRawPixel(wld,rt,x,y,norm)
    assert(wld==session.world and rt==target and x==0 and y==0 and norm==false)
end
function library:ReadRenderTargetRawPixelArea(wld,rt,x,y,w,h,norm)
    assert(wld==session.world and rt==target and x==(target.SizeX-w)//2 and norm==false)
    local colors={}
    for n=1,w*h do colors[n]={R=4,G=0.5,B=-0.25} end
    return colors
end
local function attr(n,t,v) return string.pack("<zzI4",n,t,#v)..v end
local function nativeBytes(w,h)
    local ch=""
    for _,c in ipairs({"A","B","G","R"}) do ch=ch..string.pack("<zI4I4i4i4",c,1,0,1,1) end
    local hdr=string.pack("<I4I4",20000630,2)..attr("channels","chlist",ch.."\0")..
        attr("dataWindow","box2i",string.pack("<i4i4i4i4",0,0,w-1,h-1))..attr("compression","compression","\0").."\0"
    local stride=8+w*8
    local index,rows={},{}
    for y=0,h-1 do
        index[#index+1]=string.pack("<I8",#hdr+h*8+y*stride)
        local left=(w-cropped.w)//2
        local function plane(bits) return ("xx"):rep(left)..string.pack("<I2",bits):rep(cropped.w)..("yy"):rep(w-left-cropped.w) end
        rows[#rows+1]=string.pack("<i4I4",y,w*8)..plane(0)..plane(0xb400)..plane(0x3800)..plane(0x4400)
    end
    return hdr..table.concat(index)..table.concat(rows)
end
local mode = "native"
function writer:ExportToDisk(rt, path, options)
    assert(rt==target and path==source and options.CompressionQuality==1 and options.Format==3 and not options.bOverwriteFile and not options.bAsync)
    if mode=="native" then write(path,nativeBytes(rt.SizeX,rt.SizeY))
    elseif mode=="invalid" then write(path,("oops"):rep(100)) end
end
local function begin()
    return assert(linear.begin(session,cropped,10,6,png))
end
local function finish(job)
    local state,detail
    for _=1,15 do
        state,detail=linear.poll(job,10,6)
        if state~="pending" then break end
        now=now+1
    end
    return state,detail
end
local native
for _,kind in ipairs({"native","raw"}) do
    mode=kind
    local job=begin()
    local state,message=finish(job)
    assert(state=="saved" and message==final,message)
    assert(actor.destroyed and target.released and not present(source) and not present(partial))
    local output=read(final)
    assert(output:find(attr("dataWindow","box2i",string.pack("<i4i4i4i4",0,0,4,2)),1,true))
    assert(output:find(attr("colorInteropID","string","lin_rec709_scene"),1,true))
    local row=string.pack("<i4I4",2,30)..string.pack("<I2",0xb400):rep(5)..string.pack("<I2",0x3800):rep(5)..string.pack("<I2",0x4400):rep(5)
    assert(output:sub(-#row)==row)
    if native then assert(output==native) else native=output end
    assert(not linear.begin(session,cropped,10,6,png))
    os.remove(final)
end
mode="invalid"
local state,detail=finish(begin())
assert(state=="failed" and detail:find("single%-part"),detail)
assert(actor.destroyed and target.released and not present(source) and not present(partial) and not present(final))
activeSpace="EWorkingColorSpace::ACESAP1"
assert(not linear.begin(session,cropped,10,6,png))
activeSpace="EWorkingColorSpace::sRGB"
local job=begin()
assert(linear.poll(job,9,6)=="failed" and actor.destroyed and target.released)
mode="silent"
job=begin()
assert(linear.poll(job,10,6)=="pending")
linear.cancel(job); linear.cancel(job)
write(source,"late native result")
linear.reap()
assert(not present(source) and not present(partial) and not present(final))
assert(read(png)=="original display image")
os.remove(png)
print("HDR projection, native and raw HALF pixels, metadata, collision and cleanup checks passed")
