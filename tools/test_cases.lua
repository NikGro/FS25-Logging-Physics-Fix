-- Test cases, executed after mock_engine.lua and the mod scripts.
local FP = ForestryPhysics
local s = FP.s

local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local function check(cond, msg) if not cond then dumpLogs() error(msg, 2) end end

-- ---------------------------------------------------------------- settings
check(s.clawStrength == 3 and s.mountStiffness == 3 and s.maxWobbleDeg == 8, "grab defaults from xml")
check(approx(s.logWeightScale, 0.9), "log weight 90 %")
check(FP.LML == nil and s.lmlEnabled == nil, "load moment limiter removed")
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
check(veh.fpLmlOrigGetMoveValue == nil and veh.fpOriginalMountSplitShape ~= nil, "grab hook installed, no crane hook")

-- G: claws, live change postponed while a log is held
local cj = {rotLimitSpring = {0, 0, 300}, rotLimitDamping = {0, 0, 30}, rotLimitForceLimit = {-1, -1, 30}, jointIndex = 0, componentIndices = {1, 2}}
local rebuilt = 0
local gv = {isServer = true, configFileName = "grapple.xml", components = veh.components, componentJoints = {cj},
    spec_logGrab = {grabs = {{claws = {{componentJoint = 1}}, dynamicMountedShapes = {}}}},
    mountSplitShape = function() return 1, 2 end, createComponentJoint = function() rebuilt = rebuilt + 1 end}
LogGrab.onPostLoad(gv, nil)
check(cj.rotLimitSpring[3] == 900 and cj.rotLimitDamping[3] == 90 and cj.rotLimitForceLimit[3] == 90, "claws x3")
check(cj.rotLimitForceLimit[1] == -1, "unlimited stays unlimited")
cj.jointIndex = 9
gv.spec_logGrab.grabs[1].dynamicMountedShapes[logNode] = {}
FP.applySettings({clawStrength = 2}, false)
FP.processClawUpdates()
check(cj.rotLimitSpring[3] == 900 and FP.clawUpdatePending, "postponed while holding a log")
gv.spec_logGrab.grabs[1].dynamicMountedShapes = {}
FP.processClawUpdates()
check(cj.rotLimitSpring[3] == 600 and cj.rotLimitForceLimit[3] == 60 and rebuilt == 1 and not FP.clawUpdatePending, "applied when empty")
FP.applySettings({grabEnabled = false}, false)
FP.processClawUpdates()
check(cj.rotLimitSpring[3] == 300, "grab off -> original claws")
local ji = gv.mountSplitShape(gv, gv.spec_logGrab.grabs[1], logNode)
check(ji == 1, "grab off -> base game mount")
FP.applySettings({grabEnabled = true, clawStrength = 3}, false)
FP.processClawUpdates()
_print("G: claws OK")

-- H: log weight via message
listener:loadMap("map")
check(SUBS.cut ~= nil, "subscribed to cuts")
local cutNode = newNode("cut", 0, 0, 3, 0)
SHAPES[cutNode] = {mass = 0.47, volume = 1.0, body = RigidBodyType.DYNAMIC, split = 1}
g_messageCenter:publish(MessageType.TREE_SHAPE_CUT, 1, cutNode)
listener:update(16)
check(approx(SHAPES[cutNode].mass, 0.72), "spruce 90 % green weight")
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
check(gui.opt_grabEnabled.v == true and gui.opt_clawStrength.texts[gui.opt_clawStrength.st] == "x3", "dialog filled")
gui.opt_lockTranslation:setIsChecked(false)
gui.opt_logWeightScale:setState(3) -- 70 %
gui:onClickOk()
check(s.lockTranslation == false and approx(s.logWeightScale, 0.7), "values applied")
check(GUI_CALLS[#GUI_CALLS] == "close:ForestryPhysicsGui", "dialog closed")
gui:onClickReset()
check(gui.opt_lockTranslation.v == true and gui.opt_logWeightScale.texts[gui.opt_logWeightScale.st] == "90 %", "reset shows defaults")
_print("I: menu OK")

-- J: saved settings load again
local fresh = FP.getHardDefaults()
FP.loadUserSettings(fresh)
check(fresh.lockTranslation == false and approx(fresh.logWeightScale, 0.7), "settings reloaded from file")
_print("J: persistence OK")

for _, l in ipairs(LOGS) do
    if string.find(l, "ERROR") then dumpLogs() error("unexpected error log: " .. l) end
end

-- K: settings files from v0.2 (no version attribute) are ignored once
local _, path = FP.getUserSettingsPath()
local old = createXMLFile("old", path, "forestryPhysicsSettings")
setXMLFloat(old, "forestryPhysicsSettings.clawStrength", 5)
saveXMLFile(old)
local fresh2 = FP.getHardDefaults()
check(FP.loadUserSettings(fresh2) == false and fresh2.clawStrength == 3, "old settings file ignored")
_print("K: old settings ignored")

-- L: logs are fixed only when the claws stall + settle time
do
    local actor0 = newNode("clawTarget", comp2, 0, 0, 0)
    local actor1 = newNode("clawBody", comp2, 0, 0, 0)
    local grab = {dynamicMountedShapes = {}, pendingDynamicMountShapes = {[logNode] = true}}
    local claw = {jointActor0 = actor0, jointActor1 = actor1, axis = 3, fpGrab = grab}
    local base = true
    local cv = {fpOriginalClawState = function() return base end, getParentComponent = function() return comp2 end}
    s.mountAtStall, s.settleMs = true, 400
    local function step(moveRad)
        local r = NODES[actor1].r
        NODES[actor1].r = {r[1], r[2], r[3] + moveRad}
        return FP.safeClawState(cv, claw, 16, false, false)
    end
    -- claws still closing (2 deg per frame) -> not fixed although the game says "closed"
    for _ = 1, 30 do check(step(math.rad(2)) == false, "closing claws: not fixed yet") end
    -- claws stopped: fixed after 400 ms
    local fixedAt
    for i = 1, 60 do if step(0) and fixedAt == nil then fixedAt = i * 16 end end
    check(fixedAt ~= nil and fixedAt >= 400 and fixedAt <= 450, "fixed after settle time " .. tostring(fixedAt))
    -- already holding logs: game behaviour unchanged
    grab.dynamicMountedShapes[logNode] = {}
    check(step(math.rad(2)) == true, "holding logs: pass through")
    grab.dynamicMountedShapes = {}
    -- safety: never longer than 2 s, even if the claws keep creeping
    claw.fpDelay, claw.fpStill = 0, 0
    local n = 0
    while not step(math.rad(1)) do n = n + 1 if n > 500 then break end end
    check(n * 16 <= 2016, "max delay 2 s, was " .. n * 16)
    -- feature off
    s.mountAtStall = false
    check(step(math.rad(2)) == true, "mountAtStall off: game timing")
    s.mountAtStall = true
    _print("L: fix at stall OK")
end

-- M: axial slip joint: force limit on the log axis, re-anchor where the log was pushed to
do
    local jr = newNode("grabRoot", 0, 0, 0, 0)
    local jn = newNode("grabJointNode", jr, 0, 0, 0)
    local td = newNode("treeDetection", jr, 0, 0, 0)
    local shape = newNode("heavyLog", 0, 0, 0, 0)
    SHAPES[shape] = {mass = 0.8, volume = 1.0, body = RigidBodyType.DYNAMIC, split = 1, massSet = true}
    local grab = {jointRoot = jr, jointNode = jn, treeDetectionNode = td, treeDetectionNodeSizeY = 1, treeDetectionNodeSizeZ = 1,
        rotLimit = math.rad(10), lockAllAxis = true}
    local mv = {fpOriginalMountSplitShape = function() error("fallback used") end}
    s.axialSlip, s.slipForce = true, 2.5
    local lastConstr
    local origNew = JointConstructor.new
    JointConstructor.new = function() lastConstr = origNew() return lastConstr end
    local ji, jt = FP.safeMountSplitShape(mv, grab, shape)
    JointConstructor.new = origNew
    local forceLimit, transLimit0
    for _, c in ipairs(lastConstr.calls) do
        if c[1] == "setTranslationLimitForceLimit" then forceLimit = c[2] end
        if c[1] == "setTranslationLimit" and c[2] == 0 then transLimit0 = {c[3], c[4], c[5]} end
    end
    check(ji == 77 and FP.slipJoints[jt] ~= nil, "slip joint registered")
    check(transLimit0 ~= nil and transLimit0[1] == true and transLimit0[2] == 0 and transLimit0[3] == 0, "log axis locked with limit spring")
    check(forceLimit ~= nil and approx(forceLimit, 2.5 * 0.8 * 9.81, 1e-6), "force limit 2.5 x weight: " .. tostring(forceLimit))
    -- log pushed 20 cm along x (against a wall) -> joint re-anchored by 20 cm, frame of actor 0 updated
    local x0 = getWorldTranslation(jt)
    setTranslation(shape, 0.2, 0, 0)
    FP.slipTimer = 1000
    JOINT_FRAMES = {}
    FP.updateSlipJoints(16)
    local x1 = getWorldTranslation(jt)
    check(approx(x1 - x0, 0.2, 1e-6) and #JOINT_FRAMES == 1 and JOINT_FRAMES[1][1] == 77 and JOINT_FRAMES[1][2] == 0, "re-anchored")
    -- tiny movement below 5 mm: no update
    setTranslation(shape, 0.203, 0, 0)
    FP.slipTimer = 1000
    JOINT_FRAMES = {}
    FP.updateSlipJoints(16)
    check(#JOINT_FRAMES == 0, "no re-anchor below 5 mm")
    -- unmounted: record removed
    NODES[jt] = nil
    FP.slipTimer = 1000
    FP.updateSlipJoints(16)
    check(FP.slipJoints[jt] == nil, "record removed after unmount")
    -- switched off: no slip joint
    s.axialSlip = false
    JointConstructor.new = function() lastConstr = origNew() return lastConstr end
    local ji2, jt2 = FP.safeMountSplitShape(mv, grab, shape)
    JointConstructor.new = origNew
    check(FP.slipJoints[jt2] == nil, "axialSlip off: no slip joint")
    s.axialSlip = true
    _print("M: axial slip OK")
end
