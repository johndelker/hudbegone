addon.name = 'hudbegone'
addon.author = 'SlowCircuit, atom0s'
addon.version = '1.5.7'
addon.desc = 'Independent controls for native compass, party, alliance, target, solo gauges, status effects and chat HUD visibility.'
require('common')
local imgui = require('imgui')
local directory = debug.getinfo(1, 'S').source:sub(2):match('(.*[\\/])') or './'
local config = dofile(directory .. 'config.lua')
local hud = dofile(directory .. 'hud.lua')
local settings, supported
local loaded, ready = false, false
local menu_open = {false}
local groups = {
    {'Player Frames (top left)', {{'Show Player Frame', 'hideSolo'}, {'Show Player Status Effects', 'hideStatus'}}},
    {'Party Frames (bottom right)', {{'Show Party Frame', 'hideParty'}, {'Show Alliance Frames', 'hideAlliance'}, {'Show Target Frame', 'hideTarget'}}},
    {'Chat Frames (bottom left)', {{'Show Compass', 'hideCompass'}, {'Show Channel Name', 'hideChatChannel'}, {'Chat Background Opacity', 'chatTransparency', 'opacity'}, {'Chat Text Opacity', 'chatTextOpacity', 'slider'}}},
}
local command_keys = {compass = 'hideCompass', party = 'hideParty', alliance = 'hideAlliance', target = 'hideTarget', solo = 'hideSolo', status = 'hideStatus', channel = 'hideChatChannel'}
local function help()
    print('[hudbegone] /hudbegone: configuration; /hudbegone compass|party|alliance|target|solo|status|channel hide|show|toggle; help')
end
ashita.events.register('load', 'hudbegone_load', function()
    settings = config.load()
    supported = hud.initialize()
    loaded, ready = true, true
end)
ashita.events.register('command', 'hudbegone_command', function(e)
    local args = e.command:args()
    if #args == 0 or args[1]:lower() ~= '/hudbegone' then return end
    e.blocked = true
    if #args == 1 then menu_open[1] = not menu_open[1]; return end
    if #args == 2 and args[2]:lower() == 'help' then help(); return end
    if loaded and #args == 3 then
        local key, action = command_keys[args[2]:lower()], args[3]:lower()
        if key and supported[key] then
            if action == 'hide' then settings[key] = true
            elseif action == 'show' then settings[key] = false
            elseif action == 'toggle' then settings[key] = not settings[key]
            else help(); return end
            config.save(settings); return
        end
    end
    help()
end)
-- Apply visibility before every scene, including later offscreen passes.
-- Present is too late to affect pixels already drawn by the game.
ashita.events.register('d3d_beginscene', 'hudbegone_beginscene', function()
    if loaded and ready and GetPlayerEntity() ~= nil then hud.apply(settings) end
end)
ashita.events.register('d3d_present', 'hudbegone_present', function()
    if not loaded then return end
    if menu_open[1] then
        imgui.SetNextWindowSize({420, 390}, ImGuiCond_Once)
        if imgui.Begin('HUD Begone', menu_open) then
            for index, group in ipairs(groups) do
                if index > 1 then imgui.Separator() end
                imgui.Text(group[1])
                for _, option in ipairs(group[2]) do
                    local label, key = option[1], option[2]
                    if supported[key] then
                        if option[3] == 'slider' or option[3] == 'opacity' then
                            -- Preserve the saved legacy transparency while displaying opacity.
                            local inverse = option[3] == 'opacity'
                            local value = {inverse and (1-settings[key]) or settings[key]}
                            imgui.SetNextItemWidth(200)
                            if imgui.SliderFloat(label,value,0,1,'%.2f',ImGuiSliderFlags_AlwaysClamp) then
                                local fraction = math.max(0,math.min(1,value[1]))
                                settings[key] = inverse and (1-fraction) or fraction
                            end
                            if imgui.IsItemDeactivatedAfterEdit() then config.save(settings) end
                        else
                        -- Retain legacy hide keys so saved behavior remains unchanged.
                        local value = {not settings[key]}
                        if imgui.Checkbox(label, value) then settings[key] = not value[1]; config.save(settings) end
                        end
                    else imgui.TextDisabled(label .. ' (unavailable on this client)') end
                end
            end
        end
        imgui.End()
    end
end)
ashita.events.register('packet_in', 'hudbegone_packet_in', function(e)
    if e.id == 0x00A then ready = loaded
    elseif e.id == 0x00B then ready = false end -- Zone Out; 0x04B is Delivery Box.
end)
ashita.events.register('unload', 'hudbegone_unload', function()
    loaded, ready = false, false
    hud.restore()
    if settings then config.save(settings) end
end)
