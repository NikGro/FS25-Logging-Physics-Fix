-- =============================================================================
-- FS25_ForestryPhysicsExperimental
-- ForestryPhysics.lua - fresh-cut log weight + stronger grapples
--
-- 1) Fresh-cut log weight: newly cut log pieces get a green-wood density.
-- 2) Stronger grapples (base game LogGrab):
--    - claw joints get a higher holding force / spring / damping
--    - the joint between grapple and log is stiffer, scaled with the log weight,
--      wobbles less and no longer lets the log slide freely
--
-- Physics is server side. Settings: FPSettings.lua / in-game menu.
-- =============================================================================

local FP = ForestryPhysics

-- base game values from LogGrab:mountSplitShape
FP.BASE_MOUNT_SPRING = 7500
FP.BASE_MOUNT_DAMPING = 1500
FP.CLEANUP_INTERVAL = 60000

-- -----------------------------------------------------------------------------
-- Log weight
-- -----------------------------------------------------------------------------

FP.massApplied = {}     -- shape -> mass (t) we set, to stay idempotent
FP.pendingShapes = {}   -- shapes cut this frame, processed in the next update
FP.loggedResults = 0
FP.unitsInvalid = false

function FP.getTargetDensity(shape)
    local s = FP.s
    local splitTypeIndex = getSplitType(shape)
    if splitTypeIndex == nil or splitTypeIndex == 0 then
        return nil, nil
    end
    local splitType = g_splitShapeManager:getSplitTypeByIndex(splitTypeIndex)
    local name = splitType ~= nil and splitType.name or nil
    local density = (name ~= nil and s.densities[name]) or s.defaultDensity
    return density * s.logWeightScale, name
end

function FP.isDynamicSplitShape(shape)
    return shape ~= nil and shape ~= 0 and entityExists(shape)
        and getHasClassId(shape, ClassIds.MESH_SPLIT_SHAPE)
        and getRigidBodyType(shape) == RigidBodyType.DYNAMIC
end

-- returns true if the mass was changed
function FP.applyLogMass(shape)
    local s = FP.s
    if not s.logWeightEnabled or FP.unitsInvalid then
        return false
    end
    if not FP.isDynamicSplitShape(shape) then
        return false -- standing trees and stumps stay untouched
    end

    local mass = getMass(shape)
    if mass == nil or mass <= 0 then
        return false
    end

    local applied = FP.massApplied[shape]
    if applied ~= nil and math.abs(applied - mass) < 0.0001 then
        return false -- already done
    end

    local volume = getVolume(shape)
    if volume == nil or volume <= 0.0001 then
        return false
    end

    local density = mass / volume
    if density < 0.05 or density > 3 then
        FP.unitsInvalid = true
        FP.logWarning("Unexpected log density %.3f (mass %.4f / volume %.4f), log weight disabled.", density, mass, volume)
        return false
    end

    local targetDensity, speciesName = FP.getTargetDensity(shape)
    if targetDensity == nil then
        return false
    end

    local factor = math.min(targetDensity / density, s.logWeightMaxFactor)
    if factor <= 1.01 then
        FP.massApplied[shape] = mass -- already heavy enough, remember it
        return false
    end

    local newMass = mass * factor
    setMass(shape, newMass)
    FP.massApplied[shape] = getMass(shape) or newMass

    if s.logResult and FP.loggedResults < 5 then
        FP.loggedResults = FP.loggedResults + 1
        FP.logInfo("Log %s: %.3f m³, %.0f kg -> %.0f kg (density %.2f -> %.2f t/m³)",
            tostring(speciesName), volume, mass * 1000, newMass * 1000, density, density * factor)
    end
    return true
end

-- MessageType.TREE_SHAPE_CUT(oldShape, shape), published for every new split shape
function FP:onTreeShapeCut(oldShape, shape)
    if shape ~= nil and shape ~= 0 then
        FP.pendingShapes[shape] = true
    end
end

function FP.processPendingShapes()
    if next(FP.pendingShapes) == nil then
        return
    end
    local shapes = FP.pendingShapes
    FP.pendingShapes = {}
    for shape, _ in pairs(shapes) do
        FP.applyLogMass(shape)
    end
end

function FP.cleanupAppliedShapes()
    for shape, _ in pairs(FP.massApplied) do
        if not entityExists(shape) then
            FP.massApplied[shape] = nil
        end
    end
end

-- -----------------------------------------------------------------------------
-- Grapples (LogGrab)
-- -----------------------------------------------------------------------------

FP.grabVehicles = setmetatable({}, {__mode = "k"}) -- vehicle -> true

function FP.getClawScale()
    if FP.s.grabEnabled then
        return FP.s.clawStrength
    end
    return 1
end

-- scales a claw joint relative to its original xml values
function FP.setClawJointScale(vehicle, jointDesc, scale)
    if jointDesc == nil or jointDesc.rotLimitSpring == nil or jointDesc.rotLimitDamping == nil
        or jointDesc.rotLimitForceLimit == nil then
        return false
    end

    if jointDesc.fpOriginal == nil then
        jointDesc.fpOriginal = {
            spring = {jointDesc.rotLimitSpring[1], jointDesc.rotLimitSpring[2], jointDesc.rotLimitSpring[3]},
            damping = {jointDesc.rotLimitDamping[1], jointDesc.rotLimitDamping[2], jointDesc.rotLimitDamping[3]},
            force = {jointDesc.rotLimitForceLimit[1], jointDesc.rotLimitForceLimit[2], jointDesc.rotLimitForceLimit[3]}
        }
        jointDesc.fpScale = 1
    end
    if jointDesc.fpScale == scale then
        return false
    end

    local o = jointDesc.fpOriginal
    for axis = 1, 3 do
        jointDesc.rotLimitSpring[axis] = o.spring[axis] > 0 and o.spring[axis] * scale or o.spring[axis]
        jointDesc.rotLimitDamping[axis] = o.damping[axis] > 0 and o.damping[axis] * scale or o.damping[axis]
        -- -1 means unlimited and stays unlimited
        jointDesc.rotLimitForceLimit[axis] = o.force[axis] > 0 and o.force[axis] * scale or o.force[axis]
    end
    jointDesc.fpScale = scale

    -- normally the joints are created later (addToPhysics); if they already exist, rebuild them
    if jointDesc.jointIndex ~= nil and jointDesc.jointIndex ~= 0 and vehicle.components ~= nil then
        local c1 = vehicle.components[jointDesc.componentIndices[1]]
        local c2 = vehicle.components[jointDesc.componentIndices[2]]
        if c1 ~= nil and c2 ~= nil then
            removeJoint(jointDesc.jointIndex)
            jointDesc.jointIndex = 0
            vehicle:createComponentJoint(c1, c2, jointDesc)
        end
    end
    return true
end

function FP.getGrabHasMountedLogs(vehicle)
    local spec = vehicle.spec_logGrab
    if spec == nil or spec.grabs == nil then
        return false
    end
    for _, grab in ipairs(spec.grabs) do
        if grab.dynamicMountedShapes ~= nil and next(grab.dynamicMountedShapes) ~= nil then
            return true
        end
    end
    return false
end

-- returns the number of changed claw joints, or nil if postponed (logs are held)
function FP.updateClawJoints(vehicle, allowWithLogs)
    local spec = vehicle.spec_logGrab
    if spec == nil or spec.grabs == nil or not vehicle.isServer or vehicle.componentJoints == nil then
        return 0
    end
    local scale = FP.getClawScale()
    local needsChange = false
    for _, grab in ipairs(spec.grabs) do
        for _, claw in ipairs(grab.claws or {}) do
            local jd = vehicle.componentJoints[claw.componentJoint]
            if jd ~= nil and (jd.fpScale or 1) ~= scale then
                needsChange = true
            end
        end
    end
    if not needsChange then
        return 0
    end
    -- rebuilding a claw joint while it holds a log would drop it for a moment
    if not allowWithLogs and FP.getGrabHasMountedLogs(vehicle) then
        return nil
    end
    local count = 0
    for _, grab in ipairs(spec.grabs) do
        for _, claw in ipairs(grab.claws or {}) do
            if FP.setClawJointScale(vehicle, vehicle.componentJoints[claw.componentJoint], scale) then
                count = count + 1
            end
        end
    end
    return count
end

-- appended to LogGrab.onPostLoad
function FP.onLogGrabPostLoad(vehicle, savegame)
    local spec = vehicle.spec_logGrab
    if spec == nil or spec.grabs == nil then
        return
    end

    FP.grabVehicles[vehicle] = true
    local numClaws = FP.updateClawJoints(vehicle, true) or 0

    -- instance level override, the type's function table stays untouched
    if vehicle.fpOriginalMountSplitShape == nil and vehicle.mountSplitShape ~= nil then
        vehicle.fpOriginalMountSplitShape = vehicle.mountSplitShape
        vehicle.mountSplitShape = FP.safeMountSplitShape
    end

    FP.logInfo("Grapple '%s': %d claw joint(s) adjusted.", tostring(vehicle.configFileName), numClaws)
end

-- settings changed: re-scale claws of all known grapples (postponed while logs are held)
FP.clawUpdatePending = false
FP.addSettingsListener(function(old, new)
    if old.clawStrength ~= new.clawStrength or old.grabEnabled ~= new.grabEnabled then
        FP.clawUpdatePending = true
    end
end)

function FP.processClawUpdates()
    if not FP.clawUpdatePending then
        return
    end
    local allDone = true
    for vehicle, _ in pairs(FP.grabVehicles) do
        if vehicle.isDeleted then
            FP.grabVehicles[vehicle] = nil
        else
            local result = FP.updateClawJoints(vehicle, false)
            if result == nil then
                allDone = false
            end
        end
    end
    FP.clawUpdatePending = not allDone
end

-- replacement for LogGrab:mountSplitShape(grab, shapeId), same structure as the base game
function FP.mountSplitShape(self, grab, shapeId)
    local s = FP.s
    if not s.grabEnabled or grab.jointRoot == nil or grab.jointNode == nil or grab.treeDetectionNode == nil then
        return self.fpOriginalMountSplitShape(self, grab, shapeId)
    end

    -- logs from the savegame get their fresh weight when picked up
    FP.applyLogMass(shapeId)

    local rotLimit = math.min(grab.rotLimit or math.rad(10), math.rad(s.maxWobbleDeg))

    local constr = JointConstructor.new()
    constr:setActors(grab.jointRoot, shapeId)

    local jointTransform = createTransformGroup("dynamicMountJoint")

    local cx, cy, cz = getWorldTranslation(grab.treeDetectionNode)
    local nx, ny, nz = localDirectionToWorld(grab.treeDetectionNode, 1, 0, 0)
    local yx, yy, yz = localDirectionToWorld(grab.treeDetectionNode, 0, 1, 0)
    local minY, maxY, minZ, maxZ = testSplitShape(shapeId, cx, cy, cz, nx, ny, nz, yx, yy, yz,
        grab.treeDetectionNodeSizeY, grab.treeDetectionNodeSizeZ)
    if minY ~= nil then
        link(grab.jointNode, jointTransform)
        local x, y, z = localToWorld(grab.treeDetectionNode, 0, (minY + maxY) * 0.5, (minZ + maxZ) * 0.5)
        setWorldTranslation(jointTransform, x, y, z)

        constr:setRotationLimit(0, -rotLimit, rotLimit)
        constr:setRotationLimit(1, -rotLimit, rotLimit)
        constr:setRotationLimit(2, -rotLimit, rotLimit)
    else
        link(grab.jointNode, jointTransform)
        setTranslation(jointTransform, 0, 0, 0)

        constr:setRotationLimit(0, 0, 0)
        constr:setRotationLimit(1, 0, 0)
        constr:setRotationLimit(2, 0, 0)
    end

    constr:setJointTransforms(jointTransform, jointTransform)

    if not grab.lockAllAxis then
        if s.lockTranslation then
            -- base game leaves these two axes completely free -> logs slide in the grapple
            local r = s.translationRange
            if grab.limitYAxis then
                constr:setTranslationLimit(1, true, -r, 2)
            else
                constr:setTranslationLimit(1, true, -r, r)
            end
            constr:setTranslationLimit(2, true, -r, r)
        else
            if grab.limitYAxis then
                constr:setTranslationLimit(1, true, -0.1, 2)
                constr:setTranslationLimit(2, false, 0, 0)
            else
                constr:setTranslationLimit(1, false, 0, 0)
                constr:setTranslationLimit(2, false, 0, 0)
            end
        end
        constr:setEnableCollision(true)
    end

    local mass = 0
    if entityExists(shapeId) then
        mass = getMass(shapeId) or 0
    end
    local massFactor = math.max(1, mass / s.massReference)
    local springForce = FP.BASE_MOUNT_SPRING * s.mountStiffness * massFactor
    local springDamping = FP.BASE_MOUNT_DAMPING * s.mountStiffness * massFactor
    constr:setRotationLimitSpring(springForce, springDamping, springForce, springDamping, springForce, springDamping)
    constr:setTranslationLimitSpring(springForce, springDamping, springForce, springDamping, springForce, springDamping)

    grab.componentLimitsDirty = true

    g_messageCenter:publish(MessageType.TREE_SHAPE_MOUNTED, shapeId, self)
    SpecializationUtil.raiseEvent(self, "onLogGrabMountedTreesChanged", grab)

    return constr:finalize(), jointTransform
end

-- an error in our version must never break the grapple: fall back to the base game function
function FP.safeMountSplitShape(self, grab, shapeId)
    if not FP.mountDisabled then
        local ok, jointIndex, jointTransform = pcall(FP.mountSplitShape, self, grab, shapeId)
        if ok then
            return jointIndex, jointTransform
        end
        FP.mountDisabled = true
        FP.logError("Grapple mount error, using base game grip for this session: %s", tostring(jointIndex))
    end
    return self.fpOriginalMountSplitShape(self, grab, shapeId)
end

if LogGrab ~= nil and LogGrab.onPostLoad ~= nil then
    LogGrab.onPostLoad = Utils.appendedFunction(LogGrab.onPostLoad, function(vehicle, savegame)
        local ok, err = pcall(FP.onLogGrabPostLoad, vehicle, savegame)
        if not ok then
            FP.logError("Could not adjust grapple '%s': %s", tostring(vehicle.configFileName), tostring(err))
        end
    end)
else
    FP.logError("LogGrab specialization not found, grapple part disabled.")
end
