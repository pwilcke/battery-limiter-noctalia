import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("The Luau executable path is required.")

folder = Path(__file__).with_name("framework-charge")
source = r"""
local rendered
local ticks = false
local capacity = "50\n"
local batteryStatus = "Not charging\n"
local chargerOnline = "1\n"
local now = 0
local store, watchers = {}, {}
ui = {}
for _, kind in ipairs({"box", "column", "row", "label", "glyph"}) do
    ui[kind] = function(props, children) return { kind = kind, props = props, children = children or {} } end
end
panel = {
    render = function(tree) rendered = tree end,
    setNeedsFrameTick = function(value) ticks = value end,
    setWantsSecondTicks = function() end,
}
noctalia = {
    fileExists = function() return true end,
    readFile = function(path)
        if path:find("capacity$") then return capacity end
        if path:find("status$") then return batteryStatus end
        if path:find("online$") then return chargerOnline end
        error("unexpected read " .. path)
    end,
    nowMs = function() return now end,
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    state = {
        set = function(key, value)
            store[key] = value
            for _, watcher in watchers[key] or {} do watcher(value) end
        end,
        get = function(key) return store[key] end,
        watch = function(key, watcher)
            watchers[key] = watchers[key] or {}
            table.insert(watchers[key], watcher)
        end,
    },
}
local function find(kind, property, expected, tree)
    tree = tree or rendered
    if tree.kind == kind and (property == nil or tree.props[property] == expected) then return tree end
    for _, child in ipairs(tree.children) do
        local found = find(kind, property, expected, child)
        if found then return found end
    end
    return nil
end
local function clickNode(key)
    find("row", "key", key).props.onClick("", "")
end
local function hoverNode(key, entered)
    find("row", "key", key).props.onHover(entered, key)
end
local function value()
    return find("label", "fontSize", 25).props.text
end
-- What the service answers to the panel's last request.
local function answer(status, limit, extra)
    local controller = { status = status, limit = limit, drains = true, ack = store.request.id }
    for key, field in extra or {} do controller[key] = field end
    noctalia.state.set("controller", controller)
end
"""
modules = {"./planner.luau": "planner.luau", "./power.luau": "power.luau"}
source += "local modules = {}\n"
for name, file in modules.items():
    source += (
        f"modules[{name!r}] = (function()\n"
        + folder.joinpath(file).read_text().replace("--!strict", "")
        + "\nend)()\n"
    )
source += "require = function(path) return modules[path] end\n"
source += folder.joinpath("panel.luau").read_text()
source += r"""
for _, case in { {40, -55}, {50, 0}, {60, 55}, {70, 110}, {80, 165}, {90, 193}, {100, 220} } do
    assert(px(case[1]) == case[2], "px(" .. case[1] .. ") is " .. px(case[1]))
end

-- Opening asks the service for a fresh read.
onOpen()
assert(store.request.kind == "read" and value() == "")
answer("ready", 50)
assert(value() == "50%" and find("box", "width", 1.75))

-- Hover previews without touching the header; the line glides; leaving waits a frame.
hoverNode("zone4", "true")
assert(value() == "50%" and find("label", "text", "80%").props.color == "primary")
assert(not find("box", "fill", "primary/0.15") and ticks)
now += 200
onFrameTick()
assert(find("box", "fill", "primary/0.15") and not ticks)
hoverNode("zone4", "false")
hoverNode("label4", "true")
now += 16
onFrameTick()
assert(find("label", "text", "80%"))
hoverNode("label4", "false")
now += 16
onFrameTick()
assert(not find("label", "text", "80%") and find("label", "text", "80"))

-- A click sends one set; a second click waits; the answer is held until the spinner turned.
local reads = store.request.id
clickNode("zone4")
local set = store.request
assert(set.kind == "set" and set.limit == 80 and set.id ~= reads)
clickNode("zone5")
onKey("Right", true)
assert(store.request.id == set.id)
noctalia.state.set("controller", { status = "applying", limit = 50, drains = true, target = 80, ack = reads })
assert(find("box", "height", 3) and value() == "50%")
answer("ready", 80)
assert(find("box", "height", 3) and value() == "50%")
now += 700
onFrameTick()
assert(not find("box", "height", 3) and value() == "80%" and find("glyph", "name", "check"))
now += 800
onFrameTick()
assert(not find("glyph", "name", "check") and not ticks)

-- The status line, the drain preview, and an overshoot the firmware holds.
capacity = "63\n"
update()
assert(find("label", "text", "Battery 63% · ") and find("label", "text", "holding"))
batteryStatus = "Discharging\n"
update()
assert(find("label", "text", "draining").props.color == "error")
chargerOnline = "0\n"
update()
assert(find("label", "text", "on battery"))
batteryStatus, chargerOnline = "Charging\n", "1\n"
update()
assert(find("label", "text", "charging").props.color == "primary" and value() == "80%")
batteryStatus = "Not charging\n"
update()
hoverNode("zone2", "true")
assert(find("label", "text", "60%").props.color == "error")
now += 200
onFrameTick()
assert(find("row", "fill", "error"))
hoverNode("zone2", "false")
now += 16
onFrameTick()
assert(not find("label", "text", "60%"))
now += 200
onFrameTick()
assert(not find("row", "fill", "error") and not find("box", "fill", "error"))
capacity = "85\n"
update()
assert(not find("box", "fill", "error"))
batteryStatus = "Discharging\n"
update()
assert(find("box", "fill", "error"))
capacity, batteryStatus = "63\n", "Not charging\n"
update()

-- A failed write shows the alert; the service's own re-read then arrives without an ack.
onKey("Right", true)
assert(store.request.kind == "set" and store.request.limit == 100)
answer("failed", nil, { message = "Controller request failed." })
now += 700
onFrameTick()
assert(find("glyph", "name", "alert-circle"))
noctalia.state.set("controller", { status = "ready", limit = 80, drains = true, ack = store.request.id })
assert(value() == "80%" and not find("glyph", "name", "alert-circle"))

-- A fast failure held for the spinner yields to the newer read that follows it.
clickNode("zone5")
answer("failed", nil, { message = "Busy." })
noctalia.state.set("controller", { status = "ready", limit = 80, drains = true, ack = store.request.id })
now += 700
onFrameTick()
assert(value() == "80%" and not find("glyph", "name", "alert-circle"))

-- "Charge by": the editor offers only presets above the limit and sends one target.
clickNode("charge-by")
assert(find("row", "key", "target").children[1].props.text == "100%")
clickNode("target")
assert(find("row", "key", "target").children[1].props.text == "100%")
clickNode("later")
clickNode("start")
local target = store.request
assert(target.kind == "target" and target.limit == 100 and target.deadline % 1800 == 0)
answer("ready", 80)
noctalia.state.set("plan", { note = "100% by 13:00 · from 12:02", target = { limit = 100, deadline = target.deadline } })
assert(find("label", "text", "100% by 13:00 · from 12:02"))
clickNode("cancel")
assert(store.request.kind == "cancel")
answer("ready", 80)

-- When the limit reaches the top, an open editor has nothing left to offer and closes.
noctalia.state.set("plan", {})
clickNode("charge-by")
assert(find("row", "key", "target"))
noctalia.state.set("controller", { status = "ready", limit = 100, drains = true, ack = store.request.id })
assert(not find("row", "key", "target") and not find("row", "key", "start"))
noctalia.state.set("controller", { status = "ready", limit = 80, drains = true, ack = store.request.id })

-- With working hours on, a manual choice can be undone, and the current limit still counts.
noctalia.state.set("plan", { note = "Your 80% until midnight", scheduling = true, overridden = true })
clickNode("schedule")
assert(store.request.kind == "schedule")
answer("ready", 80)
clickNode("zone4")
assert(store.request.kind == "set" and store.request.limit == 80)
answer("ready", 80)
now += 700
onFrameTick()
onClose()

-- Reopening without a running service ends in a message, not a spinner forever.
onOpen()
assert(store.request.kind == "read")
now += 5001
update()
assert(find("glyph", "name", "alert-circle"))
onClose()
assert(not ticks)
print("Hover, glide, spinner hold, duplicate guard, status line, drain preview, keyboard, charge-by, back on schedule, and missing-service flows passed.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "panel.luau"
    test.write_text(source)
    subprocess.run([sys.argv[1], str(test)], check=True)
