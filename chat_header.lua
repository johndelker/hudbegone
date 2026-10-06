-- The channel name and backing strip are a graphic drawn after chat messages.
-- Skip its argument setup and draw call; retain the native message renderer.
local header = {}
local ffi = require('ffi')
ffi.cdef[[int __stdcall FlushInstructionCache(void* process, const void* address, size_t size);]]
local kernel32 = ffi.load('kernel32')
local pattern = '0FBF4C240E6A006A000FBFD0688080808051528BCDE8????????5F5D83C40CC3'
local original = {0x0F,0xBF,0x4C,0x24,0x0E}
-- Jump over the 26-byte draw block, before any arguments are pushed.
local patch = {0xE9,0x15,0,0,0}
local site, enabled = nil, false
local function same(address, expected)
    local actual = ashita.memory.read_array(address,#expected)
    if not actual then return false end
    for i,v in ipairs(expected)do if actual[i]~=v then return false end end
    return true
end
local function write(bytes)
    local ok, protection = ashita.memory.unprotect(site,#bytes)
    if not ok then return false end
    ashita.memory.write_array(site,bytes)
    local flushed=kernel32.FlushInstructionCache(ffi.cast('void*',-1),ffi.cast('const void*',site),#bytes)
    local protected=ashita.memory.protect(site,#bytes,protection)
    return flushed~=0 and protected and same(site,bytes)
end
function header.initialize()
    local match=ashita.memory.find('FFXiMain.dll',0,pattern,0,0)
    local duplicate=ashita.memory.find('FFXiMain.dll',0,pattern,0,1)
    if not match or match==0 or (duplicate and duplicate~=0)
        or not same(match,original) or not same(match+26,{0x5F,0x5D,0x83,0xC4,0x0C,0xC3}) then return false end
    site=match
    return true
end
function header.set_hidden(hidden)
    if not site then return false end
    hidden=hidden==true
    if not same(site,enabled and patch or original) then return false end
    if hidden==enabled then return true end
    if not write(hidden and patch or original) then
        -- Track an installed jump even if cache/protection verification fails.
        enabled=same(site,patch)
        return false
    end
    enabled=hidden
    return true
end
function header.shutdown()
    if enabled and not header.set_hidden(false) then return end
    site=nil
end
return header
