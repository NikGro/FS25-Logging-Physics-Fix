#!/usr/bin/env python3
"""Offline tests for FS25_ForestryPhysicsExperimental with a mocked GIANTS engine.
Run: python3 -I tools/test_mod.py"""
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET
from lupa import lua51, luajit21

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'FS25_ForestryPhysicsExperimental')
SCRIPTS = ['FPSettings.lua', 'ForestryPhysics.lua', 'LoadMomentLimiter.lua', 'FPGui.lua', 'FPMain.lua']

# ---------------------------------------------------------------- syntax
for name in SCRIPTS:
    src = open(os.path.join(ROOT, 'scripts', name), encoding='utf-8').read()
    for mod, label in ((lua51, 'Lua 5.1'), (luajit21, 'LuaJIT')):
        L = mod.LuaRuntime()
        r = L.eval('function(s,n) local f,e=loadstring(s,n) if f then return "OK" end return e end')(src, name)
        assert r == 'OK', f'{label} {name}: {r}'
print('syntax OK (5 files, Lua 5.1 + LuaJIT)')

# ---------------------------------------------------------------- xml backend for getXML*/setXML*
docs = {}


class Doc:
    def __init__(self, path=None, root=None):
        self.path = path
        self.root = ET.parse(path).getroot() if root is None else ET.Element(root)


def resolve(doc, path, create=False):
    p, _, attr = path.partition('#')
    parts = p.split('.')
    if parts[0] != doc.root.tag:
        return None, None
    node = doc.root
    for part in parts[1:]:
        m = re.match(r'(\w+)(?:\((\d+)\))?$', part)
        kids = [c for c in node if c.tag == m.group(1)]
        i = int(m.group(2) or 0)
        if i >= len(kids):
            if not create:
                return None, None
            child = ET.SubElement(node, m.group(1))
            kids.append(child)
        node = kids[i]
    return node, attr


def x_load(_, path):
    if not os.path.exists(path):
        return 0
    docs[len(docs) + 1] = Doc(path)
    return len(docs)


def x_create(_, path, root):
    docs[len(docs) + 1] = Doc(path, root)
    return len(docs)


def x_get(i, key):
    n, a = resolve(docs[i], key)
    if n is None:
        return None
    return n.get(a) if a else n.text


def x_set(i, key, val):
    n, a = resolve(docs[i], key, True)
    if a:
        n.set(a, str(val))
    else:
        n.text = str(val)


def x_save(i):
    d = docs[i]
    ET.ElementTree(d.root).write(d.path)


tmp = tempfile.mkdtemp()
L = lua51.LuaRuntime()
g = L.globals()
g.py_load, g.py_create, g.py_get, g.py_set, g.py_save = x_load, x_create, x_get, x_set, x_save
g.py_has = lambda i, k: resolve(docs[i], k)[0] is not None
g.MOD_DIR = ROOT + '/'
g.SETTINGS_DIR = tmp + '/'

L.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mock_engine.lua')).read())
for name in SCRIPTS:
    L.execute(open(os.path.join(ROOT, 'scripts', name), encoding='utf-8').read())
L.execute(open(os.path.join(os.path.dirname(os.path.abspath(__file__)), 'test_cases.lua')).read())

# settings file written by the test
saved = os.path.join(tmp, 'FS25_ForestryPhysicsExperimental.xml')
assert os.path.exists(saved), 'settings file not written'
print('settings file:', open(saved).read()[:160].replace('\n', ' '), '...')
print('ALL TESTS OK')
