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
local present = true
ui = {}
for _, kind in ipairs({"button", "column", "row", "label", "glyph", "slider"}) do
    ui[kind] = function(props, children) return { kind = kind, props = props, children = children or {} } end
end
panel = {
    render = function(tree) rendered = tree end,
    close = function() end,
    setNeedsFrameTick = function(value) ticks = value end,
}
noctalia = {
    fileExists = function() return present end,
    string = { trim = function(s) return s:match("^%s*(.-)%s*$") end },
    json = { decode = function(s) if s == "bad" then return nil end return { limit = tonumber(s) } end },
    notifyError = function(title, message) table.insert(notifications, message) end,
    runAsync = function(argv, cb) table.insert(requests, {args=argv, finish=cb}); return true end,
}
local function find(kind, text, tree)
    tree = tree or rendered
    if tree.kind == kind and (text == nil or tree.props.text == text) then return tree end
    for _, child in ipairs(tree.children) do
        local found = find(kind, text, child)
        if found then return found end
    end
    return nil
end
local function reply(limit)
    requests[#requests].finish({exitCode=0, timedOut=false, stdout=tostring(limit), stderr=""})
end
"""
source += (
    Path(__file__).with_name("framework-charge").joinpath("panel.luau").read_text()
)
source += r"""
onOpen()
assert(#requests == 1 and requests[1].args[3] == "read")
reply(50)
assert(not find("button", "Apply"))
assert(find("slider").props.value == 0)
previewLimit("0.4")
previewLimit("1.3")
assert(#requests == 1)
commitLimit()
assert(#requests == 2 and requests[2].args[4] == "60")
commitLimit()
choose3()
assert(#requests == 2)
reply(60)
onFrameTick("140")
assert(find("slider").props.value == 1)
onFrameTick("800")
assert(not ticks)
commitLimit()
assert(#requests == 2)
previewLimit("2.2")
onClose()
onOpen()
assert(#requests == 3 and requests[3].args[3] == "read")
reply(60)
assert(find("slider").props.value == 1)
onKey("Right", false)
assert(#requests == 3)
onKey("Right", true)
assert(#requests == 4 and requests[4].args[4] == "70")
requests[4].finish({exitCode=1,timedOut=false,stdout="",stderr="Controller request failed."})
assert(#notifications == 1)
assert(#requests == 5 and requests[5].args[3] == "read")
assert(not find("slider").props.enabled)
reply(70)
assert(find("slider").props.enabled and find("slider").props.value == 2)
choose5()
assert(#requests == 6 and requests[6].args[4] == "100")
requests[6].finish({exitCode=0,timedOut=false,stdout="80",stderr=""})
assert(#notifications == 2 and #requests == 7 and requests[7].args[3] == "read")
reply(80)
onFrameTick("800")
assert(find("slider").props.value == 3)
assert(not ticks)
choose5()
assert(#requests == 8 and requests[8].args[4] == "100")
onClose()
onOpen()
assert(#requests == 8)
reply(100)
assert(find("slider").props.value == 4)
onFrameTick("800")
local sliderKey = find("slider").props.key
previewLimit("2.2")
assert(find("slider").props.key == sliderKey)
commitLimit()
assert(#requests == 9 and requests[9].args[4] == "70")
assert(find("slider").props.key ~= sliderKey)
reply(70)
previewLimit("1.8")
commitLimit()
assert(#requests == 9 and find("slider").props.value == 2)
onClose()
assert(not ticks and #requests == 9)
print("Preview, release, duplicate guard, cancellation, keyboard, and recovery flows passed.")
"""

with tempfile.TemporaryDirectory() as directory:
    test = Path(directory) / "slider.luau"
    test.write_text(source)
    subprocess.run([sys.argv[1], str(test)], check=True)
