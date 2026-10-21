import subprocess
import sys
import tempfile
from pathlib import Path

if len(sys.argv) != 2:
    raise SystemExit("The Luau executable path is required.")

source = r"""
local rendered
local requests = {}
local notifications = {}
local ticks = false
local capacity = "50\n"
local batteryStatus = "Not charging\n"
local chargerOnline = "1\n"
local now = 0
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
    json = { decode = function(s)
        local limit, rest = s:match("^(%d+)(.*)$")
        if not limit then return nil end
        return { limit = tonumber(limit), drains = rest ~= " keeps" }
    end },
    notifyError = function(title, message) table.insert(notifications, message) end,
    runAsync = function(argv, cb) table.insert(requests, {args=argv, finish=cb}); return true end,
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
local function reply(limit)
    requests[#requests].finish({exitCode=0, timedOut=false, stdout=tostring(limit), stderr=""})
end
"""
source += (
    Path(__file__).with_name("framework-charge").joinpath("panel.luau").read_text()
)
source += r"""
for _, case in { {40, -55}, {50, 0}, {60, 55}, {70, 110}, {80, 165}, {90, 193}, {100, 220} } do
    assert(px(case[1]) == case[2], "px(" .. case[1] .. ") is " .. px(case[1]))
end
onOpen()
assert(#requests == 1 and requests[1].args[3] == "read")
assert(value() == "")
reply(50)
assert(value() == "50%" and find("box", "width", 1.75))

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
assert(find("label", "text", "80%"))
now += 16
onFrameTick()
assert(not find("label", "text", "80%") and find("label", "text", "80"))
hoverNode("zone4", "true")
assert(#requests == 1)
clickNode("zone4")
assert(#requests == 2 and requests[2].args[4] == "80")
clickNode("zone5")
onKey("Right", true)
assert(#requests == 2)
assert(find("box", "height", 3) and value() == "50%")
reply(80)
assert(find("box", "height", 3) and value() == "50%")
now += 700
onFrameTick()
assert(not find("box", "height", 3) and value() == "80%" and find("glyph", "name", "check"))
now += 800
onFrameTick()
assert(not find("glyph", "name", "check") and not ticks)

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
batteryStatus = "Full\n"
update()
assert(find("label", "text", "holding"))
batteryStatus = nil
update()
assert(find("label", "text", "Battery 63%") and find("label", "text", "").props.color == "on_surface_variant")
batteryStatus = "Not charging\n"
hoverNode("zone2", "true")
assert(value() == "80%" and find("label", "text", "60%").props.color == "error")
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
assert(not find("row", "fill", "error") and not find("box", "fill", "error"))
batteryStatus = "Discharging\n"
update()
assert(find("box", "fill", "error"))
capacity, batteryStatus = "63\n", "Not charging\n"
update()

onKey("Right", false)
assert(#requests == 2)
onKey("Right", true)
assert(#requests == 3 and requests[3].args[4] == "100")
requests[3].finish({exitCode=1,timedOut=false,stdout="",stderr="Controller request failed."})
assert(#notifications == 0)
now += 700
onFrameTick()
assert(#notifications == 1)
assert(#requests == 4 and requests[4].args[3] == "read")
clickNode("zone1")
assert(#requests == 4)
reply(80)
clickNode("zone5")
assert(#requests == 5 and requests[5].args[4] == "100")
reply(70)
now += 700
onFrameTick()
assert(#notifications == 2 and #requests == 6 and requests[6].args[3] == "read")
reply(55)
onKey("Right", true)
assert(#requests == 7 and requests[7].args[4] == "60")
onClose()
now += 1000
onOpen()
assert(#requests == 7)
reply(60)
assert(value() == "60%" and not find("box", "height", 3))
onClose()
assert(not ticks)
onOpen()
assert(#requests == 8)
reply(60)
assert(value() == "60%" and not find("glyph", "name", "check"))
onKey("Home", true)
assert(#requests == 9 and requests[9].args[4] == "50")
reply(60)
onClose()
assert(#notifications == 3 and #requests == 9)
onOpen()
assert(#requests == 10)
requests[10].finish({exitCode=0,timedOut=false,stdout="bad",stderr=""})
assert(find("glyph", "name", "alert-circle") and #requests == 10)
find("row", "tooltip", "The charge-limit helper returned an invalid response.").props.onClick("", "")
assert(#requests == 11)
reply(60)
assert(not find("glyph", "name", "alert-circle"))

onClose()
onOpen()
assert(#requests == 12)
requests[12].finish({exitCode=0,timedOut=false,stdout="80 keeps",stderr=""})
hoverNode("zone2", "true")
assert(find("label", "text", "60%").props.color == "primary")
now += 200
onFrameTick()
assert(not find("row", "fill", "error") and not find("box", "fill", "error"))
hoverNode("zone2", "false")
now += 16
onFrameTick()

capacity = nil
update()
assert(not find("box", "fill", "primary"))
onClose()
assert(not ticks and #requests == 12)
print("Hover preview, leave debounce, click, spinner hold, duplicate guard, drain preview, no-drain preview, keyboard, and recovery flows passed, with the line gliding.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "panel.luau"
    test.write_text(source)
    subprocess.run([sys.argv[1], str(test)], check=True)
