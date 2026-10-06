local config = {}
config.defaults = {hideCompass = false, hideParty = false, hideAlliance = false, hideTarget = false, hideSolo = false, hideStatus = false, hideChatChannel = false, chatTransparency = 0, chatTextOpacity = 127/255}
local function fraction(value, default)
    if type(value) ~= 'number' or value ~= value then return default end
    return math.max(0,math.min(1,value))
end
function config.load()
    local manager = AshitaCore:GetConfigurationManager()
    local loaded = manager:Load('hudbegone', 'hudbegone.ini')
    local settings = {}
    for key, default in pairs(config.defaults) do
        local value = default
        if key == 'chatTransparency' or key == 'chatTextOpacity' then
            value = loaded and manager:GetFloat('hudbegone','default',key,default) or default
            value = fraction(value,default)
        else
            value = loaded and manager:GetBool('hudbegone', 'default', key, default) or default
            if type(value) ~= 'boolean' then value = default end
        end
        settings[key] = value
    end
    if not loaded and manager:Load('hidecompass', 'hidecompass.ini') then
        local value = manager:GetBool('hidecompass', 'default', 'hideCompass', false)
        if type(value) == 'boolean' then settings.hideCompass = value end
    end
    return settings
end
function config.save(settings)
    local manager = AshitaCore:GetConfigurationManager()
    manager:Delete('hudbegone', 'hudbegone.ini')
    for key, default in pairs(config.defaults) do
        local value
        if type(default) == 'number' then value = fraction(settings[key],default)
        else value = settings[key] == true end
        manager:SetValue('hudbegone', 'default', key, tostring(value))
    end
    manager:Save('hudbegone', 'hudbegone.ini')
end
return config
