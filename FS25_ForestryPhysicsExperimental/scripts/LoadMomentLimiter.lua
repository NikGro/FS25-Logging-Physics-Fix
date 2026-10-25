-- =============================================================================
-- FS25_ForestryPhysicsExperimental
-- LoadMomentLimiter.lua - load moment limiter for forestry cranes
--
-- Base game cranes (Cylindered moving tools) move kinematically, the hydraulics
-- have no force limit. This adds what real cranes have:
--
--   load  = logs held by the grapple / harvester head + head/grapple components
--   reach = horizontal distance of the load to the crane's slewing column
--
--   hydraulic utilisation = sum(mass * g * reach) / (kNmPerTonne * machine mass)
--   stability utilisation = tipping moment about the critical wheel edge,
--                           relative to the stabilising moment, / safety factor
--
-- Above "slowdownStart" every crane movement that would increase the
-- utilisation is slowed down, at 100 % it is stopped. Above 100 % the crane
-- sags slowly (the movement that lowers the load and reduces the utilisation
-- most). Movements that reduce the utilisation always work.
--
-- Works through Cylindered:getMovingToolMoveValue, which the base game calls on
-- the server for every moving tool (incl. easy arm control targets) each frame.
-- =============================================================================

local FP = ForestryPhysics

local LML = {}
FP.LML = LML

LML.G = 9.81
LML.PROBE_TIME = 100         -- ms, size of the probe step for a movement
LML.SAG_HYSTERESIS = 0.03
LML.RESTING_HEIGHT = 0.5     -- m, log centre this close above terrain counts as resting
LML.INFO_INTERVAL = 1500     -- ms between warnings

LML.vehicles = setmetatable({}, {__mode = "k"})

-- -----------------------------------------------------------------------------
-- small vector helpers
-- -----------------------------------------------------------------------------

local function axisVector(axis)
    if axis == 2 then
        return 0, 1, 0
    elseif axis == 3 then
        return 0, 0, 1
    end
    return 1, 0, 0
end

local function cross(ax, ay, az, bx, by, bz)
    return ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
end

local function horizontalDistance(x1, z1, x2, z2)
    local dx, dz = x1 - x2, z1 - z2
    return math.sqrt(dx * dx + dz * dz)
end

-- convex hull (monotone chain) of points {x, z}
function LML.convexHull(points)
    if #points < 3 then
        return nil
    end
    local pts = {}
    for i, p in ipairs(points) do
        pts[i] = {p[1], p[2]}
    end
    table.sort(pts, function(a, b)
        if a[1] == b[1] then
            return a[2] < b[2]
        end
        return a[1] < b[1]
    end)
    local function crossO(o, a, b)
        return (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])
    end
    local lower = {}
    for _, p in ipairs(pts) do
        while #lower >= 2 and crossO(lower[#lower - 1], lower[#lower], p) <= 0 do
            table.remove(lower)
        end
        lower[#lower + 1] = p
    end
    local upper = {}
    for i = #pts, 1, -1 do
        local p = pts[i]
        while #upper >= 2 and crossO(upper[#upper - 1], upper[#upper], p) <= 0 do
            table.remove(upper)
        end
        upper[#upper + 1] = p
    end
    table.remove(lower)
    table.remove(upper)
    local hull = {}
    for _, p in ipairs(lower) do hull[#hull + 1] = p end
    for _, p in ipairs(upper) do hull[#hull + 1] = p end
    if #hull < 3 then
        return nil
    end
    return hull
end

-- signed distance of (x, z) to the edge a->b; positive = inside (hull is counter clockwise)
local function edgeDistance(a, b, x, z)
    local ex, ez = b[1] - a[1], b[2] - a[2]
    local len = math.sqrt(ex * ex + ez * ez)
    if len < 0.0001 then
        return 0
    end
    return (ex * (z - a[2]) - ez * (x - a[1])) / len
end

-- -----------------------------------------------------------------------------
-- crane analysis (once per vehicle, after it was added to physics)
-- -----------------------------------------------------------------------------

function LML.getComponentIndex(vehicle, node)
    local compNode = vehicle:getParentComponent(node)
    if compNode == nil or compNode == 0 then
        return nil
    end
    for i, component in ipairs(vehicle.components) do
        if component.node == compNode then
            return i
        end
    end
    return nil
end

function LML.analyze(vehicle)
    local data = {valid = false}
    local spec = vehicle.spec_cylindered
    if spec == nil or spec.movingTools == nil or vehicle.components == nil then
        return data
    end

    -- where the load hangs
    local loadNode = nil
    if vehicle.spec_logGrab ~= nil and vehicle.spec_logGrab.grabs ~= nil then
        for _, grab in ipairs(vehicle.spec_logGrab.grabs) do
            if grab.jointNode ~= nil then
                loadNode = grab.jointNode
                break
            end
        end
    end
    if loadNode == nil and vehicle.spec_woodHarvester ~= nil then
        loadNode = vehicle.spec_woodHarvester.cutNode
    end
    if loadNode == nil then
        return data
    end

    local loadComp = LML.getComponentIndex(vehicle, loadNode)
    if loadComp == nil then
        return data
    end

    -- component graph from the component joints
    local adjacency = {}
    for i = 1, #vehicle.components do
        adjacency[i] = {}
    end
    for _, jd in ipairs(vehicle.componentJoints or {}) do
        local a, b = jd.componentIndices[1], jd.componentIndices[2]
        if adjacency[a] ~= nil and adjacency[b] ~= nil then
            table.insert(adjacency[a], {other = b, node = jd.jointNode})
            table.insert(adjacency[b], {other = a, node = jd.jointNodeActor1 or jd.jointNode})
        end
    end

    -- BFS tree from the main component
    local parentOf, attachNodeInParent = {}, {}
    local visited = {[1] = true}
    local queue = {1}
    while #queue > 0 do
        local c = table.remove(queue, 1)
        for _, edge in ipairs(adjacency[c]) do
            if not visited[edge.other] then
                visited[edge.other] = true
                parentOf[edge.other] = c
                attachNodeInParent[edge.other] = edge.node
                table.insert(queue, edge.other)
            end
        end
    end

    -- head = load component and everything hanging below it
    data.headComps = {}
    if loadComp ~= 1 then
        for i = 1, #vehicle.components do
            local c = i
            while c ~= nil and c ~= loadComp do
                c = parentOf[c]
            end
            if c == loadComp then
                table.insert(data.headComps, i)
            end
        end
    end

    -- all nodes between load and vehicle root (scene graph + across joints)
    local craneNodes, craneOrder = {}, {}
    local function addAncestors(node, compIndex)
        local compNode = vehicle.components[compIndex].node
        while node ~= nil and node ~= 0 do
            if not craneNodes[node] then
                craneNodes[node] = true
                table.insert(craneOrder, node)
            end
            if node == compNode then
                break
            end
            node = getParent(node)
        end
    end
    addAncestors(loadNode, loadComp)
    local c = loadComp
    local guard = 0
    while c ~= 1 and parentOf[c] ~= nil and guard < 32 do
        local p = parentOf[c]
        if attachNodeInParent[c] ~= nil then
            addAncestors(attachNodeInParent[c], p)
        end
        c = p
        guard = guard + 1
    end

    local orderIndex = {}
    for i, node in ipairs(craneOrder) do
        orderIndex[node] = i
    end

    data.craneTools = {}
    data.isControlled = {}
    local slewTool, slewOrder = nil, -1
    local outermostOrder, baseTool = -1, nil
    for _, tool in ipairs(spec.movingTools) do
        if tool.node ~= nil and craneNodes[tool.node] and (tool.rotSpeed ~= nil or tool.transSpeed ~= nil) then
            table.insert(data.craneTools, tool)
            data.isControlled[tool] = true
            local idx = orderIndex[tool.node]
            if idx > outermostOrder then
                outermostOrder, baseTool = idx, tool
            end
            if tool.rotSpeed ~= nil then
                local _, ay, _ = localDirectionToWorld(tool.node, axisVector(tool.rotationAxis))
                if math.abs(ay) > 0.85 and idx > slewOrder then
                    slewTool, slewOrder = tool, idx
                end
            end
        end
    end

    if #data.craneTools == 0 then
        return data
    end

    data.baseNode = (slewTool or baseTool).node
    data.slewTool = slewTool

    -- easy arm control targets
    local eac = spec.easyArmControl
    if eac ~= nil and eac.targetNodeY ~= nil and eac.targetNodeZ ~= nil then
        data.eac = eac
        data.targetTools = {}
        local ty = vehicle:getMovingToolByNode(eac.targetNodeY)
        local tz = vehicle:getMovingToolByNode(eac.targetNodeZ)
        if ty ~= nil then
            data.isControlled[ty] = true
            data.targetTools[ty] = "y"
        end
        if tz ~= nil then
            data.isControlled[tz] = true
            data.targetTools[tz] = "z"
        end
    end

    -- wheels for the stability check (self propelled machines only, trailers lean on their tractor)
    data.wheelNodes = {}
    if vehicle.spec_motorized ~= nil and vehicle.spec_wheels ~= nil and vehicle.spec_wheels.wheels ~= nil then
        for _, wheel in ipairs(vehicle.spec_wheels.wheels) do
            local node = wheel.driveNode or wheel.repr
            if node ~= nil and node ~= 0 then
                table.insert(data.wheelNodes, node)
            end
        end
    end

    data.valid = true
    FP.logInfo("Load moment limiter '%s': %d crane tool(s), slewing column %s, %d head component(s), %d wheel(s).",
        tostring(vehicle.configFileName), #data.craneTools, slewTool ~= nil and "found" or "not found (fallback)",
        #data.headComps, #data.wheelNodes)
    return data
end

-- -----------------------------------------------------------------------------
-- load + utilisation
-- -----------------------------------------------------------------------------

local function isResting(x, y, z)
    if g_terrainNode == nil then
        return false
    end
    local h = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    return y - h < LML.RESTING_HEIGHT
end

function LML.collectLoads(vehicle, data)
    local loads = {}
    local logMass = 0

    local function addLog(shape)
        if FP.isDynamicSplitShape(shape) then
            local m = getMass(shape)
            if m ~= nil and m > 0 then
                local x, y, z
                local lx, ly, lz = getCenterOfMass(shape)
                if lx ~= nil then
                    x, y, z = localToWorld(shape, lx, ly, lz)
                else
                    x, y, z = getWorldTranslation(shape)
                end
                if not isResting(x, y, z) then
                    table.insert(loads, {m = m, x = x, y = y, z = z, isHead = false})
                    logMass = logMass + m
                end
            end
        end
    end

    if vehicle.spec_logGrab ~= nil and vehicle.spec_logGrab.grabs ~= nil then
        for _, grab in ipairs(vehicle.spec_logGrab.grabs) do
            for shape, _ in pairs(grab.dynamicMountedShapes or {}) do
                addLog(shape)
            end
        end
    end
    if vehicle.spec_woodHarvester ~= nil then
        addLog(vehicle.spec_woodHarvester.attachedSplitShape)
    end

    for _, index in ipairs(data.headComps) do
        local component = vehicle.components[index]
        local m = vehicle:getComponentMass(component)
        if m ~= nil and m > 0 then
            local x, y, z = localToWorld(component.node, getCenterOfMass(component.node))
            table.insert(loads, {m = m, x = x, y = y, z = z, isHead = true})
        end
    end

    return loads, logMass
end

-- returns total, hydraulic, stability utilisation (1.0 = limit)
function LML.evaluate(vehicle, data, loads, ox, oy, oz)
    local s = FP.s
    ox, oy, oz = ox or 0, oy or 0, oz or 0

    local uH, uS = 0, 0
    local bx, _, bz = getWorldTranslation(data.baseNode)
    local vehicleMass = vehicle:getTotalMass(true)

    if s.lmlHydraulic and vehicleMass > 0 then
        local moment = 0
        for _, l in ipairs(loads) do
            moment = moment + l.m * LML.G * horizontalDistance(l.x + ox, l.z + oz, bx, bz)
        end
        local limit = s.lmlKnmPerTonne * vehicleMass
        if limit > 0 then
            uH = moment / limit
        end
    end

    if s.lmlStability and #data.wheelNodes >= 3 and vehicleMass > 0 then
        local points = {}
        for _, node in ipairs(data.wheelNodes) do
            local x, _, z = getWorldTranslation(node)
            table.insert(points, {x, z})
        end
        local hull = LML.convexHull(points)
        if hull ~= nil then
            -- vehicle without the head components (they are part of the load)
            local cx, cy, cz = vehicle:getOverallCenterOfMass()
            local baseMass = vehicleMass
            local bmx, bmz = cx * vehicleMass, cz * vehicleMass
            for _, l in ipairs(loads) do
                if l.isHead then
                    baseMass = baseMass - l.m
                    bmx, bmz = bmx - l.m * l.x, bmz - l.m * l.z
                end
            end
            if baseMass > 0.01 then
                local baseX, baseZ = bmx / baseMass, bmz / baseMass

                -- combined centre of mass decides the critical edge
                local tm, tx, tz = baseMass, baseX * baseMass, baseZ * baseMass
                for _, l in ipairs(loads) do
                    tm = tm + l.m
                    tx, tz = tx + l.m * (l.x + ox), tz + l.m * (l.z + oz)
                end
                tx, tz = tx / tm, tz / tm

                local bestEdge, bestDist = nil, math.huge
                for i = 1, #hull do
                    local a, b = hull[i], hull[i % #hull + 1]
                    local d = edgeDistance(a, b, tx, tz)
                    if d < bestDist then
                        bestDist, bestEdge = d, {a, b}
                    end
                end

                local stabilising = baseMass * edgeDistance(bestEdge[1], bestEdge[2], baseX, baseZ)
                local overturning = 0
                for _, l in ipairs(loads) do
                    local d = edgeDistance(bestEdge[1], bestEdge[2], l.x + ox, l.z + oz)
                    if d >= 0 then
                        stabilising = stabilising + l.m * d
                    else
                        overturning = overturning - l.m * d
                    end
                end

                local tipping
                if stabilising <= 0.0001 then
                    tipping = 2
                else
                    tipping = overturning / stabilising
                end
                uS = tipping / math.max(0.05, s.lmlStabilitySafety)
            end
        end
    end

    return math.max(uH, uS), uH, uS
end

function LML.getState(vehicle, data)
    if data.stateTime == g_time and data.state ~= nil then
        return data.state
    end
    local loads, logMass = LML.collectLoads(vehicle, data)
    local u, uH, uS = LML.evaluate(vehicle, data, loads)

    local cm, cx, cy, cz = 0, 0, 0, 0
    for _, l in ipairs(loads) do
        cm = cm + l.m
        cx, cy, cz = cx + l.m * l.x, cy + l.m * l.y, cz + l.m * l.z
    end
    if cm > 0 then
        cx, cy, cz = cx / cm, cy / cm, cz / cm
    else
        cx, cy, cz = getWorldTranslation(data.baseNode)
    end

    data.state = {u = u, uH = uH, uS = uS, loads = loads, logMass = logMass, cx = cx, cy = cy, cz = cz}
    data.stateTime = g_time
    return data.state
end

-- -----------------------------------------------------------------------------
-- movement probing
-- -----------------------------------------------------------------------------

-- displacement of the load centre for a movement of 'move' during PROBE_TIME
function LML.probeOffset(data, tool, move, state)
    local target = data.targetTools ~= nil and data.targetTools[tool] or nil
    if target ~= nil then
        local eac = data.eac
        local dist = move * (eac.moveSpeed or 0.001) * LML.PROBE_TIME
        local dx, dy, dz
        if target == "y" then
            dx, dy, dz = localDirectionToWorld(eac.rootNode, 0, 1, 0)
        else
            dx, dy, dz = localDirectionToWorld(eac.rootNode, 0, 0, 1)
        end
        return dx * dist, dy * dist, dz * dist
    end

    if tool.rotSpeed ~= nil then
        local angle = move * tool.rotSpeed * LML.PROBE_TIME
        local ax, ay, az = localDirectionToWorld(tool.node, axisVector(tool.rotationAxis))
        local px, py, pz = getWorldTranslation(tool.node)
        local vx, vy, vz = cross(ax, ay, az, state.cx - px, state.cy - py, state.cz - pz)
        return vx * angle, vy * angle, vz * angle
    elseif tool.transSpeed ~= nil then
        local dist = move * tool.transSpeed * LML.PROBE_TIME
        local parent = getParent(tool.node)
        local dx, dy, dz = localDirectionToWorld(parent, axisVector(tool.translationAxis))
        return dx * dist, dy * dist, dz * dist
    end
    return 0, 0, 0
end

-- utilisation change caused by a movement
function LML.getMoveEffect(vehicle, data, tool, move, state)
    local ox, oy, oz = LML.probeOffset(data, tool, move, state)
    local u = LML.evaluate(vehicle, data, state.loads, ox, oy, oz)
    return u - state.u, oy
end

function LML.isToolAtLimit(tool, direction)
    if tool.rotSpeed ~= nil and tool.rotMin ~= nil and tool.rotMax ~= nil then
        local rot = select(tool.rotationAxis or 1, getRotation(tool.node))
        local increasing = direction * tool.rotSpeed > 0
        if increasing then
            return rot >= tool.rotMax - 0.001
        end
        return rot <= tool.rotMin + 0.001
    elseif tool.transSpeed ~= nil and tool.transMin ~= nil and tool.transMax ~= nil then
        local trans = select(tool.translationAxis or 3, getTranslation(tool.node))
        local increasing = direction * tool.transSpeed > 0
        if increasing then
            return trans >= tool.transMax - 0.001
        end
        return trans <= tool.transMin + 0.001
    end
    return false
end

-- -----------------------------------------------------------------------------
-- hooks
-- -----------------------------------------------------------------------------

function LML.getData(vehicle)
    local data = vehicle.fpLml
    if data == nil then
        return nil
    end
    if data.needsAnalysis then
        if not vehicle.isAddedToPhysics then
            return nil
        end
        local analysed = LML.analyze(vehicle)
        analysed.needsAnalysis = false
        vehicle.fpLml = analysed
        data = analysed
    end
    if not data.valid then
        return nil
    end
    return data
end

function LML.adjustMove(vehicle, tool, move)
    local data = LML.getData(vehicle)
    if data == nil or not data.isControlled[tool] then
        return move
    end

    local s = FP.s

    -- sagging: the chosen tool lowers the load, unless the driver actively reduces the load moment
    if data.sagTool == tool then
        if move ~= 0 then
            local du = LML.getMoveEffect(vehicle, data, tool, move, LML.getState(vehicle, data))
            if du < 0 then
                return move
            end
        end
        return data.sagMove
    end

    if move == 0 then
        return move
    end

    local state = LML.getState(vehicle, data)
    if state.u < s.lmlSlowdownStart then
        return move
    end

    local du = LML.getMoveEffect(vehicle, data, tool, move, state)
    if du <= 0.00001 then
        return move -- this movement does not increase the load moment
    end

    local start = math.min(s.lmlSlowdownStart, 0.99)
    local factor = math.max(0, math.min(1, (1 - state.u) / (1 - start)))
    if factor < 1 then
        data.limitedUntil = g_time + 500
    end
    return move * factor
end

function LML.getMovingToolMoveValue(vehicle, tool)
    local move = vehicle.fpLmlOrigGetMoveValue(vehicle, tool)
    if LML.disabled or not FP.s.lmlEnabled or not vehicle.isServer then
        return move
    end
    local ok, result = pcall(LML.adjustMove, vehicle, tool, move)
    if ok then
        return result
    end
    LML.disabled = true
    FP.logError("Load moment limiter error, disabled for this session: %s", tostring(result))
    return move
end

LML.SAG_UPDATE_INTERVAL = 100

function LML.updateSag(vehicle, data)
    local s = FP.s
    if not s.lmlSagging then
        data.sagTool, data.sagMove, data.isSagging = nil, 0, false
        return
    end
    if data.nextSagUpdate ~= nil and g_time < data.nextSagUpdate then
        return
    end
    data.nextSagUpdate = g_time + LML.SAG_UPDATE_INTERVAL
    data.sagTool, data.sagMove = nil, 0

    local state = LML.getState(vehicle, data)
    if state.u < 1.0 then
        data.isSagging = false
        return
    end
    if not data.isSagging and state.u < 1.0 + LML.SAG_HYSTERESIS then
        return
    end
    data.isSagging = true

    -- candidates: easy control targets while easy control is active, otherwise the crane tools
    local candidates = {}
    if data.eac ~= nil and data.eac.state and data.targetTools ~= nil then
        for tool, _ in pairs(data.targetTools) do
            table.insert(candidates, tool)
        end
    else
        for _, tool in ipairs(data.craneTools) do
            if tool ~= data.slewTool then
                table.insert(candidates, tool)
            end
        end
    end

    -- preferred: a movement that lowers the load and reduces the load moment;
    -- fallback: lower the load without increasing the moment (until it rests on the ground)
    local bestTool, bestMove, bestDu = nil, 0, -0.00001
    local fallTool, fallMove, fallDy = nil, 0, -0.0001
    for _, tool in ipairs(candidates) do
        for _, dir in ipairs({1, -1}) do
            local move = dir * s.lmlSagSpeed
            if not LML.isToolAtLimit(tool, dir) then
                local du, dy = LML.getMoveEffect(vehicle, data, tool, move, state)
                if dy < -0.0001 then
                    if du < bestDu then
                        bestTool, bestMove, bestDu = tool, move, du
                    elseif du <= 0.00001 and dy < fallDy then
                        fallTool, fallMove, fallDy = tool, move, dy
                    end
                end
            end
        end
    end
    if bestTool ~= nil then
        data.sagTool, data.sagMove = bestTool, bestMove
    else
        data.sagTool, data.sagMove = fallTool, fallMove
    end
end

function LML.updateInfo(vehicle, data)
    local s = FP.s
    if not s.lmlShowInfo or g_currentMission == nil then
        return
    end
    if vehicle.getIsActiveForInput == nil or not vehicle:getIsActiveForInput(true) then
        return
    end
    local state = data.state
    if state == nil or state.u < s.lmlSlowdownStart then
        return
    end
    if data.nextInfoTime ~= nil and g_time < data.nextInfoTime then
        return
    end
    data.nextInfoTime = g_time + LML.INFO_INTERVAL

    local reason = state.uS > state.uH and FP.getText("fp_lmlReasonStability") or FP.getText("fp_lmlReasonHydraulic")
    local key = data.isSagging and "fp_lmlSagging" or "fp_lmlLimit"
    local text = string.format(FP.getText(key), math.floor(state.u * 100 + 0.5), reason)
    g_currentMission:showBlinkingWarning(text, LML.INFO_INTERVAL)
end

function LML.update(dt)
    if LML.disabled or not FP.s.lmlEnabled then
        return
    end
    for vehicle, _ in pairs(LML.vehicles) do
        if vehicle.isDeleted then
            LML.vehicles[vehicle] = nil
        elseif vehicle.isServer then
            local data = LML.getData(vehicle)
            if data ~= nil then
                local ok, err = pcall(function()
                    LML.updateSag(vehicle, data)
                    LML.updateInfo(vehicle, data)
                end)
                if not ok then
                    LML.disabled = true
                    FP.logError("Load moment limiter error, disabled for this session: %s", tostring(err))
                    return
                end
            end
        end
    end
end

-- appended to Cylindered.onPostLoad
function LML.onCylinderedPostLoad(vehicle, savegame)
    if vehicle.spec_logGrab == nil and vehicle.spec_woodHarvester == nil then
        return
    end
    if vehicle.fpLmlOrigGetMoveValue ~= nil then
        return
    end
    vehicle.fpLml = {needsAnalysis = true}
    vehicle.fpLmlOrigGetMoveValue = vehicle.getMovingToolMoveValue
    vehicle.getMovingToolMoveValue = LML.getMovingToolMoveValue
    LML.vehicles[vehicle] = true
end

if Cylindered ~= nil and Cylindered.onPostLoad ~= nil then
    Cylindered.onPostLoad = Utils.appendedFunction(Cylindered.onPostLoad, function(vehicle, savegame)
        local ok, err = pcall(LML.onCylinderedPostLoad, vehicle, savegame)
        if not ok then
            FP.logError("Could not set up load moment limiter for '%s': %s", tostring(vehicle.configFileName), tostring(err))
        end
    end)
else
    FP.logError("Cylindered specialization not found, load moment limiter disabled.")
end
