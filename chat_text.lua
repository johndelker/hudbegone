-- Use source-alpha blending for chat glyphs, preserving RGB and restoring
-- the prior device states immediately after each native glyph submission.
local ffi = require('ffi')
ffi.cdef[[int __stdcall FlushInstructionCache(void* process, const void* address, size_t size);]]
local kernel32 = ffi.load('kernel32')
local text = {}
local pattern = '6A7F5152B90F00000083EC3C8BFC55F3A5E8????????8B44246C8B942484000000'
local prologue = {0x8B,0x44,0x24,0x58,0x8B,0x4C,0x24,0x54,0x8B,0x54,0x24,0x50}
local quad_pattern = '6A1C566A026A05E8????????5F8BCD5E5D33C05B8B548400'
local hooks, allocation = {}, nil
local function same(address, expected)
    local actual = ashita.memory.read_array(address,#expected)
    if not actual then return false end
    for i,v in ipairs(expected) do if actual[i] ~= v then return false end end
    return true
end
local function write(address, bytes)
    local ok, protection = ashita.memory.unprotect(address,#bytes)
    if not ok then return false end
    ashita.memory.write_array(address,bytes)
    local flushed = kernel32.FlushInstructionCache(ffi.cast('void*',-1),ffi.cast('const void*',address),#bytes)
    local protected = ashita.memory.protect(address,#bytes,protection)
    return flushed ~= 0 and protected and same(address,bytes)
end
local function branch(opcode, from, target)
    local bytes, value = {opcode}, (target-from-5)%4294967296
    for _=1,4 do bytes[#bytes+1]=value%256;value=math.floor(value/256) end
    return bytes
end
function text.initialize()
    local match = ashita.memory.find('FFXiMain.dll',0,pattern,0,0)
    local duplicate = ashita.memory.find('FFXiMain.dll',0,pattern,0,1)
    if not match or match == 0 or (duplicate and duplicate ~= 0) then return false end
    local candidate = match+17
    local bytes = ashita.memory.read_array(candidate,5)
    if not bytes or bytes[1] ~= 0xE8 then return false end
    local target = (candidate+5+ashita.memory.read_uint32(candidate+1))%4294967296
    if target == 0 or not same(target,prologue)
        or not same(target+0x3D,{0x83,0xC4,0x24,0xC3}) then return false end
    local quad = ashita.memory.find('FFXiMain.dll',0,quad_pattern,0,0)
    local other = ashita.memory.find('FFXiMain.dll',0,quad_pattern,0,1)
    if not quad or quad == 0 or (other and other ~= 0) then return false end
    local quad_site = quad+7
    local quad_original = ashita.memory.read_array(quad_site,5)
    if not quad_original or quad_original[1] ~= 0xE8 then return false end
    local quad_target = (quad_site+5+ashita.memory.read_uint32(quad_site+1))%4294967296
    if not same(quad_target,{0x83,0xEC,0x08,0x8D,0x44,0x24,0,0x56,0x8B,0xF1}) then return false end
    -- Install the glyph hook first, so the row scope can never lack its consumer.
    hooks = {{site=quad_site,original=quad_original,destination=quad_target,offset=128},
        {site=candidate,original=bytes,destination=target,offset=0}}
    return true
end
local function make_cave()
    local bytes = {}
    local function emit(...) for _,v in ipairs({...}) do bytes[#bytes+1]=v end end
    local function u32(v) for _=1,4 do emit(v%256);v=math.floor(v/256) end end
    local function jump(opcode,destination)
        for _,v in ipairs(branch(opcode,allocation+#bytes,destination)) do emit(v) end
    end
    emit(0x9C,0x60,0x83,0x3D);u32(allocation+504);emit(0,0x75,3,0x61,0x9D,0xC3)
    emit(0xFF,0x05);u32(allocation+508) -- depth supports nested native row draws
    -- Copy 88 caller-owned argument bytes before calling the original row wrapper.
    emit(0x83,0xEC,0x58,0x8D,0xB4,0x24);u32(128)
    emit(0x8B,0xFC,0xB9);u32(22);emit(0xF3,0xA5)
    emit(0x8B,0x74,0x24,0x5C,0x8B,0x7C,0x24,0x58,0x8B,0x4C,0x24,0x70)
    jump(0xE8,hooks[2].destination)
    emit(0x83,0xC4,0x58,0xFF,0x0D);u32(allocation+508)
    emit(0x61,0x9D,0xC3)
    assert(#bytes <= 128,'chat row bridge exceeds its slot')
    while #bytes < 128 do emit(0x90) end
    emit(0x9C,0x60,0x83,0x3D);u32(allocation+508);emit(0,0x0F,0x84)
    local inactive = #bytes;u32(0)
    -- The native renderer in ECX owns an IDirect3DDevice8 at +0x0C.
    emit(0x8B,0x69,0x0C,0x85,0xED,0x0F,0x84)
    local null_device=#bytes;u32(0)
    emit(0x83,0xEC,12)
    local failures={}
    for i,state in ipairs({19,20}) do
        emit(0x8D,0x44,0x24,(i-1)*4,0x50,0x6A,state,0x55,0x8B,0x45,0,
            0xFF,0x90);u32(0xCC) -- GetRenderState (stdcall)
        emit(0x85,0xC0,0x0F,0x88);failures[#failures+1]=#bytes;u32(0)
    end
    emit(0x8D,0x44,0x24,8,0x50,0x6A,4,0x6A,0,0x55,0x8B,0x45,0,0xFF,0x90);u32(0xF8)
    emit(0x85,0xC0,0x0F,0x88);failures[#failures+1]=#bytes;u32(0)
    local function set_state(state,value,slot)
        if slot then emit(0x8B,0x44,0x24,slot,0x50) else emit(0x6A,value) end
        emit(0x6A,state,0x55,0x8B,0x45,0,0xFF,0x90);u32(0xC8)
    end
    set_state(19,5) -- SRCALPHA
    set_state(20,6) -- INVSRCALPHA
    -- Standard atlas alpha reaches 255; the high-resolution atlas encodes
    -- covered pixels as 128. Match the native font selector on every draw.
    -- Only that half-alpha atlas needs MODULATE2X to reach full opacity.
    local function set_alpha_op(slot)
        if slot then emit(0x8B,0x44,0x24,slot,0x50)
        else
            emit(0xB8);u32(4) -- MODULATE for the standard font
            emit(0x80,0xBE);u32(0x80);emit(1,0x75)
            local disabled=#bytes;emit(0)
            emit(0x8B,0x56,0x78,0x85,0xD2,0x74)
            local missing=#bytes;emit(0)
            emit(0x83,0x7A,8,0,0x74)
            local no_resource=#bytes;emit(0)
            emit(0x40) -- MODULATE2X for the native half-alpha font
            for _,offset in ipairs({disabled,missing,no_resource}) do
                bytes[offset+1]=#bytes-(offset+1)
            end
            emit(0x50)
        end
        emit(0x6A,4,0x6A,0,0x55,0x8B,0x45,0,0xFF,0x90);u32(0xFC)
    end
    set_alpha_op()
    emit(0xA1);u32(allocation+504)
    for _,offset in ipairs({0x13,0x2F,0x4B,0x67}) do emit(0x88,0x46,offset) end
    -- Copy the four native draw arguments; its RET 16 cleans this copy.
    emit(0x83,0xEC,0x10,0x8D,0x74,0x24,0x44,0x8B,0xFC,0xB9);u32(4)
    emit(0xF3,0xA5,0x8B,0x4C,0x24,0x34,0x8B,0x74,0x24,0x20,0x8B,0x7C,0x24,0x1C)
    jump(0xE8,hooks[1].destination)
    set_state(19,nil,0);set_state(20,nil,4)
    set_alpha_op(8)
    emit(0x83,0xC4,12,0x61,0x9D,0xC2,0x10,0)
    local failed=#bytes
    emit(0x83,0xC4,12)
    local finish = #bytes
    for _,offset in ipairs({inactive,null_device}) do
        local distance=finish-(offset+4)
        for i=1,4 do bytes[offset+i]=distance%256;distance=math.floor(distance/256) end
    end
    for _,offset in ipairs(failures) do
        local distance=failed-(offset+4)
        for i=1,4 do bytes[offset+i]=distance%256;distance=math.floor(distance/256) end
    end
    emit(0x61,0x9D)
    jump(0xE9,hooks[1].destination)
    assert(#bytes < 504,'chat glyph bridge exceeds allocation')
    return bytes
end
local function restore()
    -- Remove the producer first; restore only calls still owned by this addon.
    for i=#hooks,1,-1 do
        local hook=hooks[i]
        if hook.active then
            if not same(hook.site,hook.patch) or not write(hook.site,hook.original) then return false end
            hook.active=false
        end
    end
    return true
end
function text.apply(opacity)
    if #hooks == 0 then return false end
    if type(opacity) ~= 'number' or opacity ~= opacity then opacity = 127/255 end
    local alpha = math.floor(math.max(0,math.min(1,opacity))*255+0.5)
    for _,hook in ipairs(hooks) do
        if not same(hook.site,hook.active and hook.patch or hook.original) then return false end
    end
    if not allocation then
        allocation = ashita.memory.alloc(512)
        if not allocation or allocation == 0 then allocation=nil;return false end
        ashita.memory.write_uint32(allocation+504,alpha)
        ashita.memory.write_uint32(allocation+508,0)
        local ok = ashita.memory.unprotect(allocation,512)
        if not ok then ashita.memory.dealloc(allocation);allocation=nil;return false end
        local written = write(allocation,make_cave())
        local protected = ashita.memory.protect(allocation,512,0x40)
        if not written or not protected then ashita.memory.dealloc(allocation);allocation=nil;return false end
        for _,hook in ipairs(hooks) do hook.patch=branch(0xE8,hook.site,allocation+hook.offset) end
    else ashita.memory.write_uint32(allocation+504,alpha) end
    for _,hook in ipairs(hooks) do
        if not hook.active then
            local ok=write(hook.site,hook.patch)
            hook.active=same(hook.site,hook.patch)
            if not ok then restore();return false end
        end
    end
    return true
end
function text.shutdown()
    if not restore() then return end
    for _,hook in ipairs(hooks) do if not same(hook.site,hook.original) then return end end
    if allocation then ashita.memory.dealloc(allocation);allocation=nil end
    hooks={}
end
return text
