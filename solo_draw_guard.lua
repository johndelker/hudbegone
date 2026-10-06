-- Native x86 guard for solo/target windows created after the scene-start callback.
-- FFXI's primitive update still runs; only the matching window's draw is skipped.
local guard = {}
local ffi = require('ffi')
ffi.cdef[[int __stdcall FlushInstructionCache(void* process, const void* address, size_t size);]]
local kernel32 = ffi.load('kernel32')
local entry_pattern = '83EC24535556578BE9E8????????668B455633FF663BC77E054866894556'
local exit_pattern = '8A859B00000084C0740F8A44241284C074078BCDE8????????5F5E5D5B83C424C3'
local stolen = {0x66, 0x8B, 0x45, 0x56, 0x33, 0xFF}
local site, finish, slot, target_slot, cave, patch, cave_mode
local enabled = 0
local function same(address, expected)
    local actual = ashita.memory.read_array(address, #expected)
    if not actual then return false end
    for i, value in ipairs(expected) do if actual[i] ~= value then return false end end
    return true
end
local function write(address, bytes, executable)
    local ok, protection = ashita.memory.unprotect(address, #bytes)
    if not ok then return false end
    ashita.memory.write_array(address, bytes)
    kernel32.FlushInstructionCache(ffi.cast('void*', -1), ffi.cast('const void*', address), #bytes)
    local protected = ashita.memory.protect(address, #bytes, executable and 0x40 or protection)
    if executable and not protected then return false end
    return same(address, bytes)
end
function guard.initialize(owner_slot, target_owner_slot)
    if (not owner_slot or owner_slot == 0) and (not target_owner_slot or target_owner_slot == 0) then return false end
    local entry = ashita.memory.find('FFXiMain.dll', 0, entry_pattern, 0, 0)
    local duplicate = ashita.memory.find('FFXiMain.dll', 0, entry_pattern, 0, 1)
    if not entry or entry == 0 or (duplicate and duplicate ~= 0) then return false end
    local ending = ashita.memory.find(entry, 0x1000, exit_pattern, 0, 0)
    local another = ashita.memory.find(entry, 0x1000, exit_pattern, 0, 1)
    if not ending or ending <= entry + 20 or ending + 33 > entry + 0x1000
        or (another and another ~= 0) or not same(entry + 14, stolen) then return false end
    site, finish, slot = entry + 14, ending + 25, owner_slot
    target_slot = target_owner_slot
    return true
end
local function make_cave(mode)
    local bytes, branches = {}, {}
    local function emit(...)
        for _, value in ipairs({...}) do bytes[#bytes + 1] = value end
    end
    local function uint32(value)
        value = value % 4294967296
        for _ = 1, 4 do emit(value % 256); value = math.floor(value / 256) end
    end
    local function mismatch(opcode)
        emit(opcode, 0); branches[#branches + 1] = #bytes
    end
    local function jump(destination)
        emit(0xE9); uint32(destination - (cave + #bytes + 4))
    end
    -- EBP is the live primitive. Preserve flags and scratch registers on both paths.
    emit(0x9C, 0x50, 0x52)                       -- pushfd; push eax; push edx
    local function check(owner_slot, chunks)
        branches = {}
        emit(0xA1); uint32(owner_slot)            -- read current owner at draw time
        emit(0x85, 0xC0); mismatch(0x74)          -- null owner -> next check
        emit(0x39, 0x45, 0x0C); mismatch(0x75)    -- primitive.owner == current owner
        emit(0x39, 0x68, 0x08); mismatch(0x75)    -- owner.primitive == this primitive
        emit(0x8B, 0x55, 0x04, 0x85, 0xD2); mismatch(0x74) -- nonnull resource descriptor
        for i, chunk in ipairs(chunks) do
            emit(0x81, 0x7A, 0x46 + (i - 1) * 4); uint32(chunk); mismatch(0x75)
        end
        emit(0x5A, 0x58, 0x9D)                   -- pop edx; pop eax; popfd
        jump(finish)                            -- matching window: native epilogue
        local next_check = #bytes
        for _, offset in ipairs(branches) do
            local distance = next_check - offset
            assert(distance >= 0 and distance < 128, 'window guard branch exceeds short jump')
            bytes[offset] = distance
        end
    end
    if mode%2==1 then check(slot,{0x756E656D,0x20202020,0x67756167,0x6E697765}) end
    if mode>=2 then check(target_slot,{0x756E656D,0x20202020,0x67726174,0x69777465}) end
    -- Unmatched windows retain native drawing, including cursor shapes.
    emit(0x5A, 0x58, 0x9D)
    for _, value in ipairs(stolen) do emit(value) end
    jump(site + #stolen)
    assert(#bytes<=256,'window guard exceeds allocation')
    return bytes
end
function guard.set_hidden(hidden, hide_target)
    if not site then return false end
    local mode=(hidden and slot and slot~=0 and 1 or 0)+(hide_target and target_slot and target_slot~=0 and 2 or 0)
    if mode == enabled then return true end
    if enabled~=0 then
        -- Detach before replacing the guard when independent settings change.
        if not same(site, patch) or not write(site, stolen) then return false end
        enabled=0
    end
    if mode~=0 then
        if not same(site, stolen) then return false end
        if cave and cave_mode~=mode then ashita.memory.dealloc(cave);cave=nil end
        if not cave then
            cave = ashita.memory.alloc(256)
            if not cave or cave == 0 then cave = nil; return false end
            if not write(cave, make_cave(mode), true) then
                ashita.memory.dealloc(cave); cave = nil; return false
            end
            local displacement = (cave - site - 5) % 4294967296
            patch = {0xE9}
            for _ = 1, 4 do
                patch[#patch + 1] = displacement % 256; displacement = math.floor(displacement / 256)
            end
            patch[#patch + 1] = 0x90
            cave_mode=mode
        end
        if not write(site, patch) then return false end
        enabled = mode
    end
    return true
end
function guard.shutdown()
    if enabled~=0 and not guard.set_hidden(false,false) then return end
    if cave then ashita.memory.dealloc(cave); cave = nil end
    site, finish, slot, target_slot, patch, cave_mode = nil, nil, nil, nil, nil, nil
end
return guard
