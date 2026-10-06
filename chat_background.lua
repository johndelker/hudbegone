-- Scale chat-background color and the opacity used to choose native blending.
local ffi = require('ffi')
ffi.cdef[[int __stdcall FlushInstructionCache(void* process, const void* address, size_t size);]]
local kernel32 = ffi.load('kernel32')
local background = {}
local pattern = 'D9460CD81D????????DFE0F6C4057A05B944000000'
local locators = {
    -- The pointer at p-4 belongs to the preceding native catalog record.
    -- These records resolve LOGWINDO and LOGWIN2, respectively.
    '93000000250100006D656E75202020206C6F6777696E3220',
    '93000000250100006D656E752020202066756C6C6C6F6720',
}
local site, original, allocation, patch
local slots, enabled = {}, false
local function unique(signature)
    local p = ashita.memory.find('FFXiMain.dll', 0, signature, 0, 0)
    local other = ashita.memory.find('FFXiMain.dll', 0, signature, 0, 1)
    return p and p > 4 and (not other or other == 0) and p or nil
end
local function same(p, expected)
    local actual = ashita.memory.read_array(p, #expected)
    if not actual then return false end
    for i,v in ipairs(expected) do if actual[i] ~= v then return false end end
    return true
end
local function write(p, bytes)
    local ok, protection = ashita.memory.unprotect(p, #bytes)
    if not ok then return false end
    ashita.memory.write_array(p, bytes)
    local flushed = kernel32.FlushInstructionCache(ffi.cast('void*', -1), ffi.cast('const void*', p), #bytes)
    local protected = ashita.memory.protect(p, #bytes, protection)
    return flushed ~= 0 and protected and same(p, bytes)
end
function background.initialize()
    site = unique(pattern)
    if not site then return false end
    original = ashita.memory.read_array(site, 9)
    if not original or original[1] ~= 0xD9 or original[4] ~= 0xD8 or original[5] ~= 0x1D then site = nil; return false end
    for _,locator in ipairs(locators) do
        local p = unique(locator)
        local slot = p and ashita.memory.read_uint32(p - 4)
        if slot and slot ~= 0 then slots[#slots + 1] = slot end
    end
    if #slots == 0 then site = nil; return false end
    return true
end
local function relative(from, destination)
    local bytes, value = {0xE9}, (destination - from - 5) % 4294967296
    for _=1,4 do bytes[#bytes+1]=value%256; value=math.floor(value/256) end
    return bytes
end
local function make_cave()
    local bytes = {}
    local function emit(...) for _,v in ipairs({...}) do bytes[#bytes+1]=v end end
    local function u32(v) for _=1,4 do emit(v%256);v=math.floor(v/256) end end
    -- Native EBX already contains ARGB; ST(0) will decide opaque vs. blended drawing.
    for i=1,3 do emit(original[i]) end
    emit(0x9C,0x50) -- preserve flags and EAX
    emit(0x66,0x83,0x3E,0,0x75,0) -- only textured background components (type 0)
    local wrong_type = #bytes
    local matches = {}
    for _,slot in ipairs(slots) do
        emit(0xA1);u32(slot)
        emit(0x85,0xC0,0x74,0) -- null owner skips this slot
        local null = #bytes
        emit(0x39,0x45,0x0C,0x75,0) -- primitive owner must be the live chat window
        local wrong_owner = #bytes
        emit(0x39,0x68,0x08,0x74,0) -- window must own this primitive
        matches[#matches+1] = #bytes
        local next_check = #bytes
        bytes[null],bytes[wrong_owner] = next_check-null,next_check-wrong_owner
    end
    emit(0xEB,0);local unmatched=#bytes
    local multiply=#bytes
    emit(0xD8,0x0D);u32(allocation+252) -- multiply existing ST(0), preserving native fades
    -- Scale only the alpha byte of the native color, leaving its RGB untouched.
    emit(0x8B,0xC3,0xC1,0xE8,0x18,0x50) -- EAX = EBX >> 24; push EAX
    emit(0xDB,0x04,0x24,0xD8,0x0D);u32(allocation+252) -- fild [esp]; fmul factor
    emit(0xDB,0x1C,0x24,0x58,0xC1,0xE0,0x18) -- fistp [esp]; pop EAX; shl EAX,24
    emit(0x81,0xE3,0xFF,0xFF,0xFF,0x00,0x09,0xC3) -- preserve RGB; insert adjusted alpha
    local finish=#bytes
    bytes[wrong_type],bytes[unmatched] = finish-wrong_type,finish-unmatched
    for _,offset in ipairs(matches) do bytes[offset]=multiply-offset end
    emit(0x58,0x9D)
    -- Compare adjusted opacity with 1.0, so the game enables its normal alpha blend.
    for i=4,9 do emit(original[i]) end
    for _,v in ipairs(relative(allocation+#bytes,site+9)) do emit(v) end
    assert(#bytes < 252, 'chat background bridge exceeds allocation')
    return bytes
end
function background.apply(transparency)
    if not site then return false end
    if type(transparency) ~= 'number' or transparency ~= transparency then transparency = 0 end
    transparency = math.max(0,math.min(1,transparency))
    if transparency == 0 then
        if enabled then
            if not same(site,patch) or not write(site,original) then return false end
            enabled = false
        end
        return true
    end
    if enabled and not same(site,patch) then return false end
    if not enabled and not same(site,original) then return false end
    if not allocation then
        allocation = ashita.memory.alloc(256)
        if not allocation or allocation == 0 then allocation = nil; return false end
        ashita.memory.write_float(allocation+252,1-transparency)
        local ok = ashita.memory.unprotect(allocation,256)
        if not ok then ashita.memory.dealloc(allocation); allocation=nil; return false end
        local written = write(allocation,make_cave())
        local protected = ashita.memory.protect(allocation,256,0x40)
        if not written or not protected then ashita.memory.dealloc(allocation); allocation=nil; return false end
        patch = relative(site,allocation)
        for _=6,9 do patch[#patch+1]=0x90 end
    else ashita.memory.write_float(allocation+252,1-transparency) end
    if not enabled then
        if not write(site,patch) then enabled=same(site,patch);return false end
        enabled = true
    end
    return true
end
function background.shutdown()
    if enabled and not background.apply(0) then return end
    if allocation and site and not same(site,original) then return end
    if allocation then ashita.memory.dealloc(allocation); allocation=nil end
    site,original,patch=nil,nil,nil
    slots={}
end
return background
