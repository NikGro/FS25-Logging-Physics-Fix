-- =============================================================================
-- FS25_ForestryPhysicsExperimental - settings
--
-- Defaults come from xml/forestryPhysics.xml (inside the mod).
-- Changes made in the in-game menu are stored in
--   <user profile>/modSettings/FS25_ForestryPhysicsExperimental.xml
-- and override the defaults. Physics runs on the server, so in multiplayer
-- the host's settings are the ones that count.
-- =============================================================================

ForestryPhysics = ForestryPhysics or {}
local FP = ForestryPhysics

FP.MOD_NAME = g_currentModName
FP.MOD_DIR = g_currentModDirectory
FP.CONFIG_FILE = "xml/forestryPhysics.xml"
FP.USER_SETTINGS_FILE = "FS25_ForestryPhysicsExperimental.xml"
FP.LOG_PREFIX = "[ForestryPhysics] "

function FP.logInfo(fmt, ...)
    print(FP.LOG_PREFIX .. string.format(fmt, ...))
end

function FP.logWarning(fmt, ...)
    Logging.warning("%s", FP.LOG_PREFIX .. string.format(fmt, ...))
end

function FP.logError(fmt, ...)
    Logging.error("%s", FP.LOG_PREFIX .. string.format(fmt, ...))
end

local function range(from, to, step)
    local t = {}
    local n = math.floor((to - from) / step + 0.5)
    for i = 0, n do
        t[#t + 1] = math.floor((from + i * step) * 1000 + 0.5) / 1000
    end
    return t
end

local function fmtPercent(v) return string.format("%d %%", math.floor(v * 100 + 0.5)) end
local function fmtFactor(v) return string.format("x%.2f", v) end
local function fmtScale(v) return string.format("x%g", v) end
local function fmtDegree(v) return string.format("%g°", v) end
local function fmtKnm(v) return string.format("%g kNm/t", v) end

-- settings shown in the in-game menu, in display order
FP.SETTINGS = {
    { section = "logWeight" },
    { key = "logWeightEnabled",   type = "bool" },
    { key = "logWeightScale",     type = "list", values = range(0.5, 1.5, 0.1),   format = fmtPercent },
    { key = "logWeightMaxFactor", type = "list", values = range(1.25, 3.0, 0.25), format = fmtFactor },

    { section = "grab" },
    { key = "grabEnabled",        type = "bool" },
    { key = "clawStrength",       type = "list", values = {1, 2, 3, 4, 5, 6, 8, 10, 15}, format = fmtScale },
    { key = "mountStiffness",     type = "list", values = {1, 2, 3, 4, 5, 6, 8, 10, 15}, format = fmtScale },
    { key = "maxWobbleDeg",       type = "list", values = {1, 2, 3, 5, 8, 10, 15, 25, 45}, format = fmtDegree },
    { key = "lockTranslation",    type = "bool" },

    { section = "lml" },
    { key = "lmlEnabled",         type = "bool" },
    { key = "lmlHydraulic",       type = "bool" },
    { key = "lmlKnmPerTonne",     type = "list", values = range(5, 20, 1), format = fmtKnm },
    { key = "lmlStability",       type = "bool" },
    { key = "lmlStabilitySafety", type = "list", values = range(0.5, 0.95, 0.05), format = fmtPercent },
    { key = "lmlSlowdownStart",   type = "list", values = range(0.6, 0.95, 0.05), format = fmtPercent },
    { key = "lmlSagging",         type = "bool" },
    { key = "lmlSagSpeed",        type = "list", values = range(0.1, 1.0, 0.1), format = fmtPercent },
    { key = "lmlShowInfo",        type = "bool" },
}

FP.SETTINGS_BY_KEY = {}
for _, s in ipairs(FP.SETTINGS) do
    if s.key ~= nil then
        FP.SETTINGS_BY_KEY[s.key] = s
    end
end

function FP.getHardDefaults()
    return {
        logWeightEnabled = true,
        logWeightScale = 1.0,
        logWeightMaxFactor = 2.0,
        defaultDensity = 0.85,
        logResult = true,
        densities = {},

        grabEnabled = true,
        clawStrength = 5,
        mountStiffness = 5,
        maxWobbleDeg = 5,
        lockTranslation = true,
        translationRange = 0.03,
        massReference = 1.0,

        lmlEnabled = true,
        lmlHydraulic = true,
        lmlKnmPerTonne = 10,
        lmlStability = true,
        lmlStabilitySafety = 0.8,
        lmlSlowdownStart = 0.85,
        lmlSagging = true,
        lmlSagSpeed = 0.3,
        lmlShowInfo = true,
    }
end

-- -----------------------------------------------------------------------------
-- defaults from the mod's xml
-- -----------------------------------------------------------------------------

local function readFloat(xmlFile, key, current, minValue)
    local v = getXMLFloat(xmlFile, key)
    if v == nil then
        return current
    end
    if minValue ~= nil then
        v = math.max(minValue, v)
    end
    return v
end

local function readBool(xmlFile, key, current)
    local v = getXMLBool(xmlFile, key)
    if v == nil then
        return current
    end
    return v
end

function FP.loadDefaults()
    local s = FP.getHardDefaults()
    local path = Utils.getFilename(FP.CONFIG_FILE, FP.MOD_DIR)
    local xmlFile = loadXMLFile("forestryPhysicsConfig", path)
    if xmlFile == nil or xmlFile == 0 then
        FP.logWarning("Config '%s' could not be loaded, using built-in defaults.", tostring(path))
        return s
    end

    local k = "forestryPhysics.logWeight"
    s.logWeightEnabled = readBool(xmlFile, k .. "#enabled", s.logWeightEnabled)
    s.logWeightScale = readFloat(xmlFile, k .. "#scale", s.logWeightScale, 0.1)
    s.logWeightMaxFactor = readFloat(xmlFile, k .. "#maxFactor", s.logWeightMaxFactor, 1.0)
    s.defaultDensity = readFloat(xmlFile, k .. "#defaultDensity", s.defaultDensity, 0.1)
    s.logResult = readBool(xmlFile, k .. "#logResult", s.logResult)
    local i = 0
    while true do
        local sk = string.format("%s.species(%d)", k, i)
        if not hasXMLProperty(xmlFile, sk) then
            break
        end
        local name = getXMLString(xmlFile, sk .. "#name")
        local density = getXMLFloat(xmlFile, sk .. "#density")
        if name ~= nil and density ~= nil and density > 0 then
            s.densities[string.upper(name)] = density
        end
        i = i + 1
    end

    k = "forestryPhysics.grab"
    s.grabEnabled = readBool(xmlFile, k .. "#enabled", s.grabEnabled)
    s.clawStrength = readFloat(xmlFile, k .. "#clawStrengthScale", s.clawStrength, 1.0)
    s.mountStiffness = readFloat(xmlFile, k .. "#mountSpringScale", s.mountStiffness, 1.0)
    s.massReference = readFloat(xmlFile, k .. "#massReference", s.massReference, 0.05)
    s.maxWobbleDeg = readFloat(xmlFile, k .. "#maxRotLimit", s.maxWobbleDeg, 0)
    s.lockTranslation = readBool(xmlFile, k .. "#lockTranslation", s.lockTranslation)
    s.translationRange = readFloat(xmlFile, k .. "#translationRange", s.translationRange, 0)

    k = "forestryPhysics.loadMomentLimiter"
    s.lmlEnabled = readBool(xmlFile, k .. "#enabled", s.lmlEnabled)
    s.lmlHydraulic = readBool(xmlFile, k .. "#hydraulicLimit", s.lmlHydraulic)
    s.lmlKnmPerTonne = readFloat(xmlFile, k .. "#kNmPerTonne", s.lmlKnmPerTonne, 1)
    s.lmlStability = readBool(xmlFile, k .. "#stabilityLimit", s.lmlStability)
    s.lmlStabilitySafety = readFloat(xmlFile, k .. "#stabilitySafety", s.lmlStabilitySafety, 0.1)
    s.lmlSlowdownStart = readFloat(xmlFile, k .. "#slowdownStart", s.lmlSlowdownStart, 0.1)
    s.lmlSagging = readBool(xmlFile, k .. "#sagging", s.lmlSagging)
    s.lmlSagSpeed = readFloat(xmlFile, k .. "#sagSpeed", s.lmlSagSpeed, 0.01)
    s.lmlShowInfo = readBool(xmlFile, k .. "#showInfo", s.lmlShowInfo)

    delete(xmlFile)
    return s
end

-- -----------------------------------------------------------------------------
-- user settings (modSettings folder)
-- -----------------------------------------------------------------------------

function FP.getUserSettingsPath()
    local dir = g_modSettingsDirectory
    if dir == nil and getUserProfileAppPath ~= nil then
        dir = getUserProfileAppPath() .. "modSettings/"
    end
    if dir == nil then
        return nil
    end
    if string.sub(dir, -1) ~= "/" and string.sub(dir, -1) ~= "\\" then
        dir = dir .. "/"
    end
    return dir, dir .. FP.USER_SETTINGS_FILE
end

function FP.loadUserSettings(s)
    local _, path = FP.getUserSettingsPath()
    if path == nil then
        return false
    end
    if fileExists ~= nil and not fileExists(path) then
        return false
    end
    local xmlFile = loadXMLFile("forestryPhysicsUser", path)
    if xmlFile == nil or xmlFile == 0 then
        return false
    end
    for _, d in ipairs(FP.SETTINGS) do
        if d.key ~= nil then
            local key = "forestryPhysicsSettings." .. d.key
            if d.type == "bool" then
                local v = getXMLBool(xmlFile, key)
                if v ~= nil then
                    s[d.key] = v
                end
            else
                local v = getXMLFloat(xmlFile, key)
                if v ~= nil then
                    s[d.key] = v
                end
            end
        end
    end
    delete(xmlFile)
    return true
end

function FP.saveUserSettings()
    local dir, path = FP.getUserSettingsPath()
    if path == nil then
        FP.logWarning("No modSettings folder available, settings are kept for this session only.")
        return false
    end
    if createFolder ~= nil then
        createFolder(dir)
    end
    local xmlFile = createXMLFile("forestryPhysicsUser", path, "forestryPhysicsSettings")
    if xmlFile == nil or xmlFile == 0 then
        FP.logWarning("Could not write '%s'.", tostring(path))
        return false
    end
    for _, d in ipairs(FP.SETTINGS) do
        if d.key ~= nil then
            local key = "forestryPhysicsSettings." .. d.key
            if d.type == "bool" then
                setXMLBool(xmlFile, key, FP.s[d.key] == true)
            else
                setXMLFloat(xmlFile, key, FP.s[d.key])
            end
        end
    end
    saveXMLFile(xmlFile)
    delete(xmlFile)
    return true
end

-- -----------------------------------------------------------------------------
-- init + applying changes
-- -----------------------------------------------------------------------------

do
    local ok, result = pcall(FP.loadDefaults)
    if ok then
        FP.defaults = result
    else
        FP.defaults = FP.getHardDefaults()
        FP.logError("Config error, using built-in defaults: %s", tostring(result))
    end

    FP.s = {}
    for k, v in pairs(FP.defaults) do
        FP.s[k] = v
    end
    local okUser, errUser = pcall(FP.loadUserSettings, FP.s)
    if not okUser then
        FP.logWarning("User settings could not be read: %s", tostring(errUser))
    end
end

FP.settingsListeners = {}

function FP.addSettingsListener(func)
    table.insert(FP.settingsListeners, func)
end

-- newValues: table key -> value for the menu settings
function FP.applySettings(newValues, save)
    local old = {}
    for k, v in pairs(FP.s) do
        old[k] = v
    end
    for key, value in pairs(newValues) do
        if FP.SETTINGS_BY_KEY[key] ~= nil then
            FP.s[key] = value
        end
    end
    for _, func in ipairs(FP.settingsListeners) do
        local ok, err = pcall(func, old, FP.s)
        if not ok then
            FP.logError("Applying settings failed: %s", tostring(err))
        end
    end
    if save then
        FP.saveUserSettings()
    end
end

function FP.resetToDefaults(save)
    local values = {}
    for _, d in ipairs(FP.SETTINGS) do
        if d.key ~= nil then
            values[d.key] = FP.defaults[d.key]
        end
    end
    FP.applySettings(values, save)
end
