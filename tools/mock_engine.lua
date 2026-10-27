-- Minimal GIANTS engine mock: scene graph with Euler XYZ rotations, xml, physics bits.

g_currentModName = "FS25_ForestryPhysicsExperimental"
g_currentModDirectory = MOD_DIR
g_modSettingsDirectory = SETTINGS_DIR
g_time = 0

LOGS = {}
Logging = {
    warning = function(f, ...) local m = string.format(f, ...) table.insert(LOGS, "WARN " .. m) end,
    error = function(f, ...) local m = string.format(f, ...) table.insert(LOGS, "ERROR " .. m) print("ERROR " .. m) end
}
_print = print
print = function(s) table.insert(LOGS, s) end
function dumpLogs() for _, l in ipairs(LOGS) do _print(l) end end

Utils = {
    getFilename = function(a, b) return b .. a end,
    getNoNil = function(a, b) if a == nil then return b end return a end,
    appendedFunction = function(a, b) return function(...) a(...) b(...) end end
}

function Class(cls, base)
    local mt = {__index = cls}
    cls.superClass = function() return base end
    setmetatable(cls, {__index = base})
    return mt
end
ScreenElement = {onOpen = function() end}
DialogElement = {new = function(_, mt) return setmetatable({}, mt) end}

-- xml
loadXMLFile = function(_, path) return py_load(nil, path) end
createXMLFile = function(_, path, root) return py_create(nil, path, root) end
saveXMLFile = function(id) py_save(id) end
delete = function(id) end
getXMLString = function(id, k) return py_get(id, k) end
getXMLFloat = function(id, k) local v = py_get(id, k) return v and tonumber(v) end
getXMLInt = function(id, k) local v = py_get(id, k) return v and math.floor(tonumber(v)) end
getXMLBool = function(id, k) local v = py_get(id, k) if v == nil then return nil end return v == "true" end
hasXMLProperty = function(id, k) return py_has(id, k) end
setXMLFloat = function(id, k, v) py_set(id, k, string.format("%.4f", v)) end
setXMLBool = function(id, k, v) py_set(id, k, v and "true" or "false") end
setXMLInt = function(id, k, v) py_set(id, k, tostring(math.floor(v))) end
createFolder = function() end

-- ---------------------------------------------------------------- scene graph
NODES = {}
local nextId = 100
function newNode(name, parent, tx, ty, tz, rx, ry, rz)
    nextId = nextId + 1
    NODES[nextId] = {name = name, parent = parent or 0, t = {tx or 0, ty or 0, tz or 0}, r = {rx or 0, ry or 0, rz or 0}, children = {}}
    if parent and parent ~= 0 then table.insert(NODES[parent].children, nextId) end
    return nextId
end
function getParent(n) return NODES[n] and NODES[n].parent or 0 end
function getName(n) return NODES[n].name end
function getRotation(n) local r = NODES[n].r return r[1], r[2], r[3] end
function setRotation(n, x, y, z) NODES[n].r = {x, y, z} end
function getTranslation(n) local t = NODES[n].t return t[1], t[2], t[3] end
function setTranslation(n, x, y, z) NODES[n].t = {x, y, z} end

local function matMul(a, b)
    local c = {}
    for i = 1, 3 do c[i] = {} for j = 1, 3 do c[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] end end
    return c
end
local function rotMat(rx, ry, rz)
    local cx, sx, cy, sy, cz, sz = math.cos(rx), math.sin(rx), math.cos(ry), math.sin(ry), math.cos(rz), math.sin(rz)
    local X = {{1, 0, 0}, {0, cx, -sx}, {0, sx, cx}}
    local Y = {{cy, 0, sy}, {0, 1, 0}, {-sy, 0, cy}}
    local Z = {{cz, -sz, 0}, {sz, cz, 0}, {0, 0, 1}}
    return matMul(matMul(Y, X), Z)
end
local function world(n)
    if n == 0 or n == nil then return {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}}, {0, 0, 0} end
    local pr, pt = world(NODES[n].parent)
    local r = rotMat(NODES[n].r[1], NODES[n].r[2], NODES[n].r[3])
    local t = NODES[n].t
    local wt = {pt[1] + pr[1][1] * t[1] + pr[1][2] * t[2] + pr[1][3] * t[3],
                pt[2] + pr[2][1] * t[1] + pr[2][2] * t[2] + pr[2][3] * t[3],
                pt[3] + pr[3][1] * t[1] + pr[3][2] * t[2] + pr[3][3] * t[3]}
    return matMul(pr, r), wt
end
function getWorldTranslation(n) local _, t = world(n) return t[1], t[2], t[3] end
function localToWorld(n, x, y, z)
    local r, t = world(n)
    return t[1] + r[1][1] * x + r[1][2] * y + r[1][3] * z, t[2] + r[2][1] * x + r[2][2] * y + r[2][3] * z, t[3] + r[3][1] * x + r[3][2] * y + r[3][3] * z
end
function localDirectionToWorld(n, x, y, z)
    local r = world(n)
    return r[1][1] * x + r[1][2] * y + r[1][3] * z, r[2][1] * x + r[2][2] * y + r[2][3] * z, r[3][1] * x + r[3][2] * y + r[3][3] * z
end

-- ---------------------------------------------------------------- physics bits
SHAPES = {}
entityExists = function(n) return NODES[n] ~= nil or SHAPES[n] ~= nil end
ClassIds = {MESH_SPLIT_SHAPE = 7}
RigidBodyType = {NONE = 0, STATIC = 1, DYNAMIC = 2, KINEMATIC = 3}
getHasClassId = function(n) return SHAPES[n] ~= nil end
getRigidBodyType = function(n) return SHAPES[n] and SHAPES[n].body or RigidBodyType.DYNAMIC end
getMass = function(n) return SHAPES[n].mass end
setMass = function(n, m) SHAPES[n].mass = m end
getVolume = function(n) return SHAPES[n].volume end
getSplitType = function(n) return SHAPES[n].split end
getCenterOfMass = function(n) return 0, 0, 0 end
local splitNames = {[1] = "SPRUCE", [7] = "OAK"}
g_splitShapeManager = {getSplitTypeByIndex = function(_, i) return {name = splitNames[i]} end}
g_terrainNode = 1
getTerrainHeightAtWorldPos = function() return 0 end

SUBS = {}
g_messageCenter = {
    subscribe = function(_, t, cb, tgt) SUBS[t] = {cb = cb, tgt = tgt} end,
    unsubscribe = function(_, t) SUBS[t] = nil end,
    publish = function(_, t, ...) if SUBS[t] then SUBS[t].cb(SUBS[t].tgt, ...) end end
}
MessageType = {TREE_SHAPE_CUT = "cut", TREE_SHAPE_MOUNTED = "mounted"}
WARNINGS = {}
g_currentMission = {getIsServer = function() return true end, showBlinkingWarning = function(_, t) table.insert(WARNINGS, t) end}
g_i18n = {getText = function(_, k)
    local t = {fp_lmlLimit = "LM %d %% (%s) limited", fp_lmlSagging = "LM %d %% (%s) sagging", fp_lmlReasonHydraulic = "hyd", fp_lmlReasonStability = "stab"}
    return t[k] or k
end}

GUI_CALLS = {}
g_gui = {
    loadProfiles = function(_, p) table.insert(GUI_CALLS, "profiles") end,
    loadGui = function(_, p, name, inst) table.insert(GUI_CALLS, "load:" .. name) end,
    showDialog = function(_, name) table.insert(GUI_CALLS, "show:" .. name) end,
    closeDialogByName = function(_, name) table.insert(GUI_CALLS, "close:" .. name) end
}
InputAction = {FORESTRY_PHYSICS_MENU = "FORESTRY_PHYSICS_MENU"}
g_inputBinding = {registerActionEvent = function() return true, 1 end, setActionEventTextPriority = function() end}
listener = nil
addModEventListener = function(t) listener = t end

-- specialization tables that the mod appends to
LogGrab = {onPostLoad = function() end}
Cylindered = {onPostLoad = function() end, onRegisterActionEvents = function() end}
PlayerInputComponent = {registerGlobalPlayerActionEvents = function() end}
JointConstructor = {new = function()
    local o = {calls = {}}
    setmetatable(o, {__index = function(t, k) return function(self, ...) table.insert(self.calls, {k, ...}) if k == "finalize" then return 77 end end end})
    return o
end}
createTransformGroup = function(name) return newNode(name, 0) end
link = function(p, c) NODES[c].parent = p end
function worldToLocal(n, x, y, z)
    local r, t = world(n)
    x, y, z = x - t[1], y - t[2], z - t[3]
    return r[1][1] * x + r[2][1] * y + r[3][1] * z, r[1][2] * x + r[2][2] * y + r[3][2] * z, r[1][3] * x + r[2][3] * y + r[3][3] * z
end
setWorldTranslation = function(n, x, y, z)
    local p = NODES[n].parent
    if p == 0 then NODES[n].t = {x, y, z} else NODES[n].t = {worldToLocal(p, x, y, z)} end
end
getWorldRotation = function(n) return 0, 0, 0 end
setWorldRotation = function(n, x, y, z) NODES[n].r = {x, y, z} end
localRotationToLocal = function(a, b) return NODES[a].r[1], NODES[a].r[2], NODES[a].r[3] end
JOINT_FRAMES = {}
setJointFrame = function(j, actor, node) table.insert(JOINT_FRAMES, {j, actor, node}) end
testSplitShape = function() return -0.2, 0.2, -0.2, 0.2 end
SpecializationUtil = {raiseEvent = function() end}
removeJoint = function() end
