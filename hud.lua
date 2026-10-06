--[[
* Addons - Copyright (c) 2025 Ashita Development Team
* Derived from Ashita's hideparty addon and the hidecompass extraction.
* Licensed under GNU GPL version 3 or (at your option) any later version.
* Distributed WITHOUT ANY WARRANTY; see LICENSE-GPLv3.md.
* Contact: https://www.ashitaxi.com/ ; https://discord.gg/Ashita
--]]
local hud = {}
local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*[\\/])') or './'
local solo_guard = dofile(directory .. 'solo_draw_guard.lua')
local chat_background = dofile(directory .. 'chat_background.lua')
local chat_header = dofile(directory .. 'chat_header.lua')
local chat_text = dofile(directory .. 'chat_text.lua')
local slots, original, compass, initialized = {}, {}, nil, false
local supported = {}
local groups = {party0 = 'hideParty', party1 = 'hideAlliance', party2 = 'hideAlliance', target = 'hideTarget', solo = 'hideSolo', status = 'hideStatus'}
local resources = {solo = 'menu    gaugewin', status = 'menu    buff    '}
local locators = {
    solo = '030C0000010210006D656E75202020206361737474696D65',
    status = '93000000150040006D656E75202020206775696465303020',
}
local function primitive(name)
    local slot = slots[name]
    if not slot or slot == 0 then return nil end
    local object = ashita.memory.read_uint32(slot)
    if not object or object == 0 then return nil end
    local address = ashita.memory.read_uint32(object + 0x08)
    if not address or address == 0 then return nil end
    if resources[name] then
        if ashita.memory.read_uint32(address + 0x0C) ~= object then return nil end
        local descriptor = ashita.memory.read_uint32(address + 0x04)
        if not descriptor or descriptor == 0 then return nil end
        if ashita.memory.read_string(descriptor + 0x46, 16) ~= resources[name] then return nil end
    end
    return address, object
end
function hud.initialize()
    local main = ashita.memory.find(0, 0, '66C78182000000????C7818C000000????????C781900000', 0, 0)
    local alliance = ashita.memory.find(0, 0, 'A1????????8B0D????????89442424A1????????33DB89', 0, 0)
    local signature = ashita.memory.find('FFXiMain.dll', 0, '33C0668B81????????483DE3000000', 0, 0)
    if main and main ~= 0 then
        slots.party0 = ashita.memory.read_uint32(main + 0x19)
        slots.target = ashita.memory.read_uint32(main + 0x23)
    end
    if alliance and alliance ~= 0 then
        slots.party1 = ashita.memory.read_uint32(alliance + 0x01)
        slots.party2 = ashita.memory.read_uint32(alliance + 0x07)
    end
    if signature and signature ~= 0 then compass = signature + 0x24 end
    for name, pattern in pairs(locators) do
        local match = ashita.memory.find('FFXiMain.dll', 0, pattern, 0, 0)
        local duplicate = ashita.memory.find('FFXiMain.dll', 0, pattern, 0, 1)
        if match and match > 4 and (not duplicate or duplicate == 0) then
            slots[name] = ashita.memory.read_uint32(match - 4)
        end
    end
    solo_guard.initialize(slots.solo, slots.target)
    local chat_supported = chat_background.initialize()
    local header_supported = chat_header.initialize()
    local text_supported = chat_text.initialize()
    initialized = true
    supported = {
        hideCompass = compass ~= nil,
        hideParty = slots.party0 ~= nil and slots.party0 ~= 0,
        hideAlliance = slots.party1 ~= nil and slots.party1 ~= 0 and slots.party2 ~= nil and slots.party2 ~= 0,
        hideTarget = slots.target ~= nil and slots.target ~= 0,
        hideSolo = slots.solo ~= nil and slots.solo ~= 0,
        hideStatus = slots.status ~= nil and slots.status ~= 0,
        chatTransparency = chat_supported,
        chatTextOpacity = text_supported,
        hideChatChannel = header_supported,
    }
    return supported
end
local function restore_frame(name, address, object)
    local saved = original[name]
    if saved and address and saved.address == address and saved.object == object then
        -- If the game already replaced our 0/0 flags, its current state wins.
        local native_changed = resources[name] and (ashita.memory.read_uint8(address + 0x69) ~= 0
            or ashita.memory.read_uint8(address + 0x6A) ~= 0)
        if not native_changed then
            ashita.memory.write_uint8(address + 0x69, saved.flag69)
            ashita.memory.write_uint8(address + 0x6A, saved.flag6A)
        end
    end
    original[name] = nil
end
function hud.apply(settings)
    if not initialized then return end
    if supported.chatTransparency then chat_background.apply(settings.chatTransparency or 0) end
    if supported.chatTextOpacity then chat_text.apply(settings.chatTextOpacity) end
    if supported.hideChatChannel then chat_header.set_hidden(settings.hideChatChannel == true) end
    -- Install independently of the primitive's combat lifetime. Native drawing
    -- can begin in the same scene that creates the solo window.
    solo_guard.set_hidden(supported.hideSolo and settings.hideSolo == true,
        supported.hideTarget and settings.hideTarget == true)
    for name, key in pairs(groups) do
        local address, object = primitive(name)
        local hide = supported[key] and settings[key]
        if hide and address then
            local flag69 = ashita.memory.read_uint8(address + 0x69)
            local flag6A = ashita.memory.read_uint8(address + 0x6A)
            -- Native nonzero flags mean the game refreshed/recreated the window,
            -- even if a null pointer was never observed between rendered frames.
            local refreshed = resources[name] and (flag69 ~= 0 or flag6A ~= 0)
            if not original[name] or original[name].address ~= address or original[name].object ~= object or refreshed then
                original[name] = {address = address, object = object, flag69 = flag69, flag6A = flag6A}
            end
            ashita.memory.write_uint8(address + 0x69, 0)
            ashita.memory.write_uint8(address + 0x6A, 0)
        elseif not hide then restore_frame(name, address, object)
        elseif resources[name] then
            -- Combat windows can disappear and reuse the same allocation later.
            original[name] = nil
        end
    end
    if compass then
        if settings.hideCompass then
            if original.compass == nil then original.compass = ashita.memory.read_uint8(compass) end
            ashita.memory.write_uint8(compass, 0)
        elseif original.compass ~= nil then
            ashita.memory.write_uint8(compass, original.compass); original.compass = nil
        end
    end
end
function hud.restore()
    if not initialized then return end
    solo_guard.shutdown()
    chat_background.shutdown()
    chat_header.shutdown()
    chat_text.shutdown()
    for name in pairs(groups) do restore_frame(name, primitive(name)) end
    if compass and original.compass ~= nil then ashita.memory.write_uint8(compass, original.compass) end
    original.compass = nil
    initialized = false
end
return hud
