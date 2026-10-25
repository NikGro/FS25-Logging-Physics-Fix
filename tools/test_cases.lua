-- Test cases, executed after mock_engine.lua and the mod scripts.
local FP = ForestryPhysics
local LML = FP.LML
local s = FP.s

local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function check(cond, msg) if not cond then dumpLogs() error(msg, 2) end end

-- ---------------------------------------------------------------- settings
check(s.clawStrength == 5 and s.mountStiffness == 5 and s.maxWobbleDeg == 5, "grab defaults from xml")
check(s.lmlEnabled and s.lmlKnmPerTonne == 10 and approx(s.lmlStabilitySafety, 0.8), "lml defaults from xml")
local n = 0 for _ in pairs(s.densities) do n = n + 1 end
check(n == 22, "species " .. n)
for _, d in ipairs(FP.SETTINGS) do
    if d.key ~= nil then check(s[d.key] ~= nil, "default for " .. d.key) end
end
_print("settings OK")

-- ---------------------------------------------------------------- forwarder model
local comp1 = newNode("main", 0)
local comp2 = newNode("head", 0)
local wheels = {}
for _, p in ipairs({{1.3, 2.0}, {-1.3, 2.0}, {1.3, -2.0}, {-1.3, -2.0}}) do
    table.insert(wheels, {driveNode = newNode("wheel", comp1, p[1], 0.6, p[2])})
end
local slew = newNode("slew", comp1, 0, 2.5, 0.5)
local boom1 = newNode("boom1", slew, 0, 0, 0, -0.5, 0, 0)
local boom2 = newNode("boom2", boom1, 0, 0, 5, 0.9, 0, 0)
local tele = newNode("tele", boom2, 0, 0, 1)
local tip = newNode("tip", tele, 0, 0, 2)
local grabJoint = newNode("grabJoint", comp2, 0, 0, 0)
local clawNode = newNode("claw", comp2, 0.3, 0, 0)
local logNode = newNode("log", comp2, 0, -0.6, 0)

local function syncHead()
    local x, y, z = getWorldTranslation(tip)
    setTranslation(comp2, x, y - 1.0, z)
end
syncHead()

local function tool(node, kind, axis, speed, minV, maxV)
    local t = {node = node, move = 0, externalMove = 0}
    if kind == "rot" then
        t.rotSpeed, t.rotationAxis, t.rotMin, t.rotMax = speed, axis, minV, maxV
    else
        t.transSpeed, t.translationAxis, t.transMin, t.transMax = speed, axis, minV, maxV
    end
    return t
end
local slewTool = tool(slew, "rot", 2, 0.0006, -3, 3)
local boom1Tool = tool(boom1, "rot", 1, 0.0004, -1.2, 0.6)
local boom2Tool = tool(boom2, "rot", 1, 0.0005, -0.5, 2.4)
local teleTool = tool(tele, "trans", 3, 0.0008, 0, 3)
local clawTool = tool(clawNode, "rot", 1, 0.001, -1, 1)
local tools = {slewTool, boom1Tool, boom2Tool, teleTool, clawTool}

SHAPES[logNode] = {mass = 0.3, volume = 0.6, body = RigidBodyType.DYNAMIC, split = 1}

local veh = {
    configFileName = "testForwarder.xml", isServer = true, isClient = true, isAddedToPhysics = true,
    components = {{node = comp1, mass = 17}, {node = comp2, mass = 1}},
    componentJoints = {{componentIndices = {1, 2}, jointNode = tip, jointNodeActor1 = comp2}},
    spec_cylindered = {movingTools = tools, actionEvents = {}},
    spec_logGrab = {grabs = {{jointNode = grabJoint, jointRoot = grabJoint, treeDetectionNode = grabJoint,
        dynamicMountedShapes = {[logNode] = {}}, claws = {}, rotLimit = math.rad(10), lockAllAxis = true}}},
    spec_motorized = {}, spec_wheels = {wheels = wheels},
}
function veh:getParentComponent(node)
    while node ~= 0 do
        if node == comp1 or node == comp2 then return node end
        node = getParent(node)
    end
    return 0
end
function veh:getTotalMass() return 18 end
function veh:getComponentMass(c) return c.mass end
function veh:getOverallCenterOfMass()
    local hx, hy, hz = getWorldTranslation(comp2)
    return (0 * 17 + hx * 1) / 18, (1.2 * 17 + hy) / 18, (0 * 17 + hz * 1) / 18
end
function veh:getMovingToolMoveValue(t) return t.move + t.externalMove end
function veh:mountSplitShape() return 1, 2 end
function veh:getMovingToolByNode(node) for _, t in ipairs(tools) do if t.node == node then return t end end end
function veh:getIsActiveForInput() return true end
local addedActions = {}
function veh:addActionEvent(tbl, action) table.insert(addedActions, action) return true, 5 end

Cylindered.onPostLoad(veh, nil)
LogGrab.onPostLoad(veh, nil)
check(veh.fpLmlOrigGetMoveValue ~= nil and veh.fpOriginalMountSplitShape ~= nil, "hooks installed")

local function state()
    g_time = g_time + 1
    return LML.getState(veh, LML.getData(veh))
end

-- analysis
local data = LML.getData(veh)
check(data ~= nil and data.valid, "analysis valid")
check(#data.craneTools == 4 and data.isControlled[teleTool] and not data.isControlled[clawTool], "crane tools found, claw excluded")
check(data.slewTool == slewTool and data.baseNode == slew, "slewing column found")
check(#data.headComps == 1 and data.headComps[1] == 2, "head component")
_print("analysis OK")

local function moveResult(t, m)
    t.move = m
    g_time = g_time + 1
    local r = veh:getMovingToolMoveValue(t)
    t.move = 0
    return r
end

-- A: light log, small utilisation -> nothing limited
s.lmlStability = false
local st = state()
check(st.u < 0.85, "light load low utilisation " .. st.u)
check(moveResult(teleTool, 1) == 1 and moveResult(teleTool, -1) == -1, "free movement when light")

-- B: utilisation 0.92 -> outward slowed, inward free
local function setUtilisation(target)
    local stx = state()
    local bx, _, bz = getWorldTranslation(slew)
    local lx, _, lz = localToWorld(logNode, 0, 0, 0)
    local hx, _, hz = getWorldTranslation(comp2)
    local rLog = math.sqrt((lx - bx) ^ 2 + (lz - bz) ^ 2)
    local rHead = math.sqrt((hx - bx) ^ 2 + (hz - bz) ^ 2)
    local limit = s.lmlKnmPerTonne * 18
    SHAPES[logNode].mass = (target * limit / LML.G - 1 * rHead) / rLog
    return state()
end
st = setUtilisation(0.92)
check(approx(st.u, 0.92, 1e-6), "utilisation set " .. st.u)
local out = moveResult(teleTool, 1)
check(out > 0.4 and out < 0.65, "outward slowed " .. out)
check(moveResult(teleTool, -1) == -1, "inward free")
_print(string.format("B: u=%.2f tele out -> %.2f", st.u, out))

-- C: overload -> outward stopped, sagging lowers the load until below 100 %
st = setUtilisation(1.08)
check(moveResult(teleTool, 1) == 0, "outward blocked at overload")
check(moveResult(teleTool, -1) == -1, "inward allowed at overload")
local _, y0 = localToWorld(logNode, 0, 0, 0)
local sagFrames = 0
for i = 1, 2000 do
    g_time = g_time + 16
    LML.update(16)
    for _, t in ipairs(tools) do
        local m = veh:getMovingToolMoveValue(t)
        if m ~= 0 then
            if t.rotSpeed then
                local r = {getRotation(t.node)}
                r[t.rotationAxis] = math.max(t.rotMin, math.min(t.rotMax, r[t.rotationAxis] + m * t.rotSpeed * 16))
                setRotation(t.node, r[1], r[2], r[3])
            else
                local tr = {getTranslation(t.node)}
                tr[t.translationAxis] = math.max(t.transMin, math.min(t.transMax, tr[t.translationAxis] + m * t.transSpeed * 16))
                setTranslation(t.node, tr[1], tr[2], tr[3])
            end
            sagFrames = sagFrames + 1
        end
    end
    syncHead()
    if not LML.getData(veh).isSagging and i > 5 then break end
end
st = state()
local _, y1 = localToWorld(logNode, 0, 0, 0)
check(sagFrames > 0, "crane sagged")
check(st.u < 1.0, "sagged below limit " .. st.u)
check(y1 < y0, "load was lowered")
check(#WARNINGS > 0, "warning shown")
_print(string.format("C: sagged %d frames, u %.2f -> %.2f, load y %.2f -> %.2f, hint '%s'", sagFrames, 1.08, st.u, y0, y1, WARNINGS[1]))

-- D: stability: slewing to the side is more critical than to the front
s.lmlHydraulic = false
s.lmlStability = true
setRotation(boom1, -0.5, 0, 0) setRotation(boom2, 0.9, 0, 0) setTranslation(tele, 0, 0, 1)
setRotation(slew, 0, 0, 0)
syncHead()
SHAPES[logNode].mass = 1.0
local uFront = state().u
setRotation(slew, 0, math.pi / 2, 0)
syncHead()
local uSide = state().u
check(uSide > uFront, string.format("side more critical %.2f > %.2f", uSide, uFront))
-- find mass where the side is overloaded, then slewing further out is blocked, back is free
SHAPES[logNode].mass = 3.0
setRotation(slew, 0, math.pi / 2 - 0.4, 0) syncHead()
local uMid = state().u
local towardsSide = moveResult(slewTool, 1)
local towardsFront = moveResult(slewTool, -1)
_print(string.format("D: stability front %.2f side %.2f; at %.2f: slew to side -> %.2f, to front -> %.2f", uFront, uSide, uMid, towardsSide, towardsFront))
if uMid >= 1 then
    check(towardsSide == 0, "slew to side blocked when tipping limit reached")
end
check(towardsFront == -1, "slew back to the front always allowed")

-- E: log resting on the ground does not count
s.lmlHydraulic = true
setTranslation(comp2, 0, 0.2, 9)
setTranslation(logNode, 0, -0.1, 0)
st = state()
check(st.logMass == 0, "resting log ignored")
setTranslation(logNode, 0, -0.6, 0) syncHead()
_print("E: resting log ignored")

-- F: easy arm control targets
local root = newNode("eacRoot", slew, 0, 0, 0)
local targetZ = newNode("targetZ", root, 0, 0, 6)
local targetY = newNode("targetY", targetZ, 0, 0, 0)
local tY = tool(targetY, "trans", 2, nil, nil, nil)
local tZ = tool(targetZ, "trans", 3, nil, nil, nil)
table.insert(tools, tY) table.insert(tools, tZ)
veh.spec_cylindered.easyArmControl = {targetNodeY = targetY, targetNodeZ = targetZ, rootNode = root, moveSpeed = 0.001, state = true}
veh.fpLml = {needsAnalysis = true}
setRotation(slew, 0, 0, 0) setRotation(boom1, -0.5, 0, 0) setRotation(boom2, 0.9, 0, 0) syncHead()
s.lmlStability = false
data = LML.getData(veh)
check(data.targetTools[tY] == "y" and data.targetTools[tZ] == "z", "easy targets found")
setUtilisation(1.05)
check(moveResult(tZ, 1) == 0, "easy control: outward blocked")
check(moveResult(tZ, -1) == -1, "easy control: inward allowed")
LML.getData(veh).nextSagUpdate = nil
LML.update(16)
check(LML.getData(veh).sagTool == tY and LML.getData(veh).sagMove < 0, "easy control: sag lowers target Y")
_print("F: easy arm control OK")
s.lmlStability = true

-- G: claws, live change postponed while a log is held
local cj = {rotLimitSpring = {0, 0, 300}, rotLimitDamping = {0, 0, 30}, rotLimitForceLimit = {-1, -1, 30}, jointIndex = 0, componentIndices = {1, 2}}
local rebuilt = 0
local gv = {isServer = true, configFileName = "grapple.xml", components = veh.components, componentJoints = {cj},
    spec_logGrab = {grabs = {{claws = {{componentJoint = 1}}, dynamicMountedShapes = {}}}},
    mountSplitShape = function() return 1, 2 end, createComponentJoint = function() rebuilt = rebuilt + 1 end}
LogGrab.onPostLoad(gv, nil)
check(cj.rotLimitSpring[3] == 1500 and cj.rotLimitDamping[3] == 150 and cj.rotLimitForceLimit[3] == 150, "claws x5")
check(cj.rotLimitForceLimit[1] == -1, "unlimited stays unlimited")
cj.jointIndex = 9
gv.spec_logGrab.grabs[1].dynamicMountedShapes[logNode] = {}
FP.applySettings({clawStrength = 2}, false)
FP.processClawUpdates()
check(cj.rotLimitSpring[3] == 1500 and FP.clawUpdatePending, "postponed while holding a log")
gv.spec_logGrab.grabs[1].dynamicMountedShapes = {}
FP.processClawUpdates()
check(cj.rotLimitSpring[3] == 600 and cj.rotLimitForceLimit[3] == 60 and rebuilt == 1 and not FP.clawUpdatePending, "applied when empty")
FP.applySettings({grabEnabled = false}, false)
FP.processClawUpdates()
check(cj.rotLimitSpring[3] == 300, "grab off -> original claws")
local ji = gv.mountSplitShape(gv, gv.spec_logGrab.grabs[1], logNode)
check(ji == 1, "grab off -> base game mount")
FP.applySettings({grabEnabled = true, clawStrength = 5}, false)
FP.processClawUpdates()
_print("G: claws OK")

-- H: log weight via message
listener:loadMap("map")
check(SUBS.cut ~= nil, "subscribed to cuts")
local cutNode = newNode("cut", 0, 0, 3, 0)
SHAPES[cutNode] = {mass = 0.47, volume = 1.0, body = RigidBodyType.DYNAMIC, split = 1}
g_messageCenter:publish(MessageType.TREE_SHAPE_CUT, 1, cutNode)
listener:update(16)
check(approx(SHAPES[cutNode].mass, 0.80), "spruce green weight")
FP.applySettings({logWeightEnabled = false}, false)
local cut2 = newNode("cut2", 0, 0, 3, 0)
SHAPES[cut2] = {mass = 0.47, volume = 1.0, body = RigidBodyType.DYNAMIC, split = 1}
g_messageCenter:publish(MessageType.TREE_SHAPE_CUT, 1, cut2)
listener:update(16)
check(SHAPES[cut2].mass == 0.47, "log weight switch off works live")
FP.applySettings({logWeightEnabled = true}, false)
_print("H: log weight OK")

-- I: menu key + dialog
Cylindered.onRegisterActionEvents(veh, true, true)
check(addedActions[#addedActions] == "FORESTRY_PHYSICS_MENU", "menu action in vehicle")
local gui = FP.gui
check(gui ~= nil, "gui created")
local function binary() local e = {v = false} function e:setIsChecked(v) self.v = v end function e:getIsChecked() return self.v end return e end
local function multi() local e = {st = 1} function e:setTexts(t) self.texts = t end function e:setState(i) self.st = i end function e:getState() return self.st end return e end
for _, d in ipairs(FP.SETTINGS) do
    if d.key ~= nil then gui["opt_" .. d.key] = d.type == "bool" and binary() or multi() end
end
FP.onMenuAction()
check(GUI_CALLS[#GUI_CALLS] == "show:ForestryPhysicsGui", "dialog shown")
gui:onOpen()
check(gui.opt_lmlEnabled.v == true and gui.opt_clawStrength.texts[gui.opt_clawStrength.st] == "x5", "dialog filled")
gui.opt_lmlSagging:setIsChecked(false)
gui.opt_lmlKnmPerTonne:setState(3) -- 7 kNm/t
gui.opt_logWeightScale:setState(3) -- 70 %
gui:onClickOk()
check(s.lmlSagging == false and s.lmlKnmPerTonne == 7 and approx(s.logWeightScale, 0.7), "values applied")
check(GUI_CALLS[#GUI_CALLS] == "close:ForestryPhysicsGui", "dialog closed")
gui:onClickReset()
check(gui.opt_lmlSagging.v == true and gui.opt_lmlKnmPerTonne.texts[gui.opt_lmlKnmPerTonne.st] == "10 kNm/t", "reset shows defaults")
_print("I: menu OK")

-- J: saved settings load again
local fresh = FP.getHardDefaults()
FP.loadUserSettings(fresh)
check(fresh.lmlSagging == false and fresh.lmlKnmPerTonne == 7 and approx(fresh.logWeightScale, 0.7), "settings reloaded from file")
_print("J: persistence OK")

for _, l in ipairs(LOGS) do
    if string.find(l, "ERROR") then dumpLogs() error("unexpected error log: " .. l) end
end
