-- =============================================================================
-- FS25_ForestryPhysicsExperimental - in-game settings dialog
-- Layout: gui/ForestryPhysicsGui.xml (element ids "opt_<settingKey>")
-- =============================================================================

local FP = ForestryPhysics

ForestryPhysicsGui = {}
local ForestryPhysicsGui_mt = Class(ForestryPhysicsGui, ScreenElement)

ForestryPhysicsGui.NAME = "ForestryPhysicsGui"

function ForestryPhysicsGui.new()
    local self = DialogElement.new(nil, ForestryPhysicsGui_mt)
    return self
end

function ForestryPhysicsGui:delete()
end

local function nearestIndex(values, value)
    local best, bestDiff = 1, math.huge
    for i, v in ipairs(values) do
        local d = math.abs(v - (value or 0))
        if d < bestDiff then
            best, bestDiff = i, d
        end
    end
    return best
end

function ForestryPhysicsGui:getElement(key)
    return self["opt_" .. key]
end

function ForestryPhysicsGui:onOpen()
    ForestryPhysicsGui:superClass().onOpen(self)
    self:updateRowColors()
    self:fillValues(FP.s)
end

-- The row containers (fs25_multiTextOptionContainer) are plain white bitmaps until they get the
-- alternating colors of the settings screen; without this the white text is unreadable.
function ForestryPhysicsGui:updateRowColors()
    local colors = SettingsScreen ~= nil and SettingsScreen.COLOR_ALTERNATING or nil
    if colors == nil or self.boxLayout == nil or self.boxLayout.elements == nil then
        return
    end
    local alternated = false
    for _, element in ipairs(self.boxLayout.elements) do
        if element.name ~= nil then
            alternated = false -- section header
        elseif element:getIsVisible() and element.setImageColor ~= nil then
            local c = colors[alternated]
            if c ~= nil then
                element:setImageColor(nil, c[1], c[2], c[3], c[4])
            end
            alternated = not alternated
        end
    end
end

function ForestryPhysicsGui:fillValues(values)
    for _, d in ipairs(FP.SETTINGS) do
        if d.key ~= nil then
            local element = self:getElement(d.key)
            if element ~= nil then
                if d.type == "bool" then
                    element:setIsChecked(values[d.key] == true)
                else
                    local texts = {}
                    for i, v in ipairs(d.values) do
                        texts[i] = d.format(v)
                    end
                    element:setTexts(texts)
                    element:setState(nearestIndex(d.values, values[d.key]))
                end
            end
        end
    end
end

function ForestryPhysicsGui:readValues()
    local values = {}
    for _, d in ipairs(FP.SETTINGS) do
        if d.key ~= nil then
            local element = self:getElement(d.key)
            if element ~= nil then
                if d.type == "bool" then
                    values[d.key] = element:getIsChecked()
                else
                    local index = element:getState()
                    values[d.key] = d.values[index] or FP.s[d.key]
                end
            end
        end
    end
    return values
end

function ForestryPhysicsGui:onClickOk()
    local values = self:readValues()
    FP.applySettings(values, true)
    g_gui:closeDialogByName(ForestryPhysicsGui.NAME)
end

function ForestryPhysicsGui:onClickBack()
    g_gui:closeDialogByName(ForestryPhysicsGui.NAME)
end

-- fills the dialog with the defaults; saved with OK
function ForestryPhysicsGui:onClickReset()
    self:fillValues(FP.defaults)
end
