-- =============================================================================
-- FS25_ForestryPhysicsExperimental - main: update loop, input, menu
-- =============================================================================

local FP = ForestryPhysics

FP.MENU_ACTION = "FORESTRY_PHYSICS_MENU"

function FP.getText(key)
    local env = g_i18n.modEnvironments ~= nil and g_i18n.modEnvironments[FP.MOD_NAME] or nil
    if env ~= nil then
        return env:getText(key)
    end
    return g_i18n:getText(key)
end

-- -----------------------------------------------------------------------------
-- menu
-- -----------------------------------------------------------------------------

function FP.loadGui()
    if FP.gui ~= nil then
        return
    end
    g_gui:loadProfiles(Utils.getFilename("gui/guiProfiles.xml", FP.MOD_DIR))
    FP.gui = ForestryPhysicsGui.new()
    g_gui:loadGui(Utils.getFilename("gui/ForestryPhysicsGui.xml", FP.MOD_DIR), ForestryPhysicsGui.NAME, FP.gui)
end

function FP.openMenu()
    if FP.gui == nil then
        local ok, err = pcall(FP.loadGui)
        if not ok then
            FP.logError("Menu could not be loaded: %s", tostring(err))
            return
        end
    end
    g_gui:showDialog(ForestryPhysicsGui.NAME)
end

function FP.onMenuAction()
    local ok, err = pcall(FP.openMenu)
    if not ok then
        FP.logError("Menu could not be opened: %s", tostring(err))
    end
end

-- in forestry vehicles (all LogGrab / WoodHarvester vehicles have Cylindered)
local function registerVehicleMenuAction(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
    if not vehicle.isClient or not isActiveForInputIgnoreSelection then
        return
    end
    if vehicle.spec_logGrab == nil and vehicle.spec_woodHarvester == nil then
        return
    end
    local spec = vehicle.spec_cylindered
    local _, eventId = vehicle:addActionEvent(spec.actionEvents, InputAction[FP.MENU_ACTION] or FP.MENU_ACTION, vehicle,
        FP.onMenuAction, false, true, false, true, nil)
    if eventId ~= nil and g_inputBinding.setActionEventTextPriority ~= nil then
        g_inputBinding:setActionEventTextPriority(eventId, GS_PRIO_VERY_LOW or GS_PRIO_LOW or 0)
    end
end

if Cylindered ~= nil and Cylindered.onRegisterActionEvents ~= nil then
    Cylindered.onRegisterActionEvents = Utils.appendedFunction(Cylindered.onRegisterActionEvents,
        function(vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
            local ok, err = pcall(registerVehicleMenuAction, vehicle, isActiveForInput, isActiveForInputIgnoreSelection)
            if not ok then
                FP.logError("Menu key could not be registered: %s", tostring(err))
            end
        end)
end

-- on foot
if PlayerInputComponent ~= nil and PlayerInputComponent.registerGlobalPlayerActionEvents ~= nil then
    PlayerInputComponent.registerGlobalPlayerActionEvents = Utils.appendedFunction(
        PlayerInputComponent.registerGlobalPlayerActionEvents, function(component)
            local ok, err = pcall(function()
                g_inputBinding:registerActionEvent(InputAction[FP.MENU_ACTION] or FP.MENU_ACTION, FP, FP.onMenuAction,
                    false, true, false, true, nil, true)
            end)
            if not ok then
                FP.logError("Menu key (on foot) could not be registered: %s", tostring(err))
            end
        end)
end

-- -----------------------------------------------------------------------------
-- mod event listener
-- -----------------------------------------------------------------------------

function FP:loadMap(filename)
    self.cleanupTimer = 0
    self.subscribed = false
    if g_currentMission ~= nil and g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.TREE_SHAPE_CUT, FP.onTreeShapeCut, FP)
        self.subscribed = true
    end

    local ok, err = pcall(FP.loadGui)
    if not ok then
        FP.logError("Menu could not be loaded: %s", tostring(err))
    end

    if addConsoleCommand ~= nil then
        addConsoleCommand("fpMenu", "Opens the forestry physics settings", "onConsoleMenu", FP)
    end

    local s = FP.s
    FP.logInfo("Loaded. Log weight %s (x%.2f), grapples %s (claws x%g, mount x%g, max %g°).",
        tostring(s.logWeightEnabled), s.logWeightScale, tostring(s.grabEnabled), s.clawStrength, s.mountStiffness,
        s.maxWobbleDeg)
end

function FP:onConsoleMenu()
    FP.onMenuAction()
    return "Forestry physics menu opened"
end

function FP:deleteMap()
    if self.subscribed then
        g_messageCenter:unsubscribe(MessageType.TREE_SHAPE_CUT, FP)
        self.subscribed = false
    end
    if removeConsoleCommand ~= nil then
        removeConsoleCommand("fpMenu")
    end
    FP.massApplied = {}
    FP.pendingShapes = {}
    FP.gui = nil
end

function FP:update(dt)
    if self.disabled then
        return
    end
    local ok, err = pcall(FP.updateInternal, self, dt)
    if not ok then
        self.disabled = true
        FP.logError("Runtime error, mod update disabled for this session: %s", tostring(err))
    end
end

function FP:updateInternal(dt)
    FP.processPendingShapes()
    FP.processClawUpdates()

    self.cleanupTimer = (self.cleanupTimer or 0) + dt
    if self.cleanupTimer > FP.CLEANUP_INTERVAL then
        self.cleanupTimer = 0
        FP.cleanupAppliedShapes()
    end
end

addModEventListener(ForestryPhysics)
