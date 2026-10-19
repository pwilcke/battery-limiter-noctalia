--!strict
type State =
	{ kind: "idle" }
	| { kind: "reading" }
	| { kind: "ready", limit: number }
	| { kind: "applying", limit: number, target: number }
	| { kind: "failed", message: string }

local helper = "/usr/local/libexec/framework-charge-limit"
local presets = { 50, 60, 70, 80, 100 }
local spinner = { "◐", "◓", "◑", "◒" }
local state: State = { kind = "idle" }
local position = 0
local sliderRevision = 0
local feedbackMs = 0
local spinnerMs = 0
local isOpen = false

local function positionFor(limit: number): number
	for index = 2, #presets do
		if limit <= presets[index] then
			return math.clamp(index - 2 + (limit - presets[index - 1]) / (presets[index] - presets[index - 1]), 0, 4)
		end
	end
	return 4
end

local function render()
	panel.setNeedsFrameTick(isOpen and (state.kind == "reading" or state.kind == "applying" or feedbackMs > 0))
	if not isOpen then
		return
	end
	local busy = state.kind == "reading" or state.kind == "applying"
	local confirmed = if state.kind == "ready" or state.kind == "applying" then state.limit else nil
	local preview = presets[math.floor(position + 0.5) + 1]
	local anchors = {}
	for index, maximum in ipairs(presets) do
		table.insert(
			anchors,
			ui.column({ width = 60, gap = 0, align = "center" }, {
				ui.glyph({ name = "check", size = 12, color = "primary", opacity = confirmed == maximum and 1 or 0 }),
				ui.button({
					text = tostring(maximum) .. "%",
					variant = "ghost",
					fontSize = 12,
					width = 60,
					height = 28,
					selected = preview == maximum,
					enabled = state.kind == "ready",
					tooltip = confirmed and maximum < confirmed and "May discharge the battery while plugged in."
						or nil,
					onClick = "choose" .. tostring(index),
				}),
			})
		)
	end
	local status = {}
	if busy then
		table.insert(
			status,
			ui.label({ text = spinner[math.floor(spinnerMs / 100) % #spinner + 1], fontSize = 18, color = "primary" })
		)
	elseif feedbackMs > 0 then
		table.insert(
			status,
			ui.glyph({ name = "check", size = 18, color = "primary", opacity = math.min(1, feedbackMs / 250) })
		)
	end
	local failed = state.kind == "failed"
	panel.render(ui.column({ gap = 8, padding = 12, align = "center" }, {
		ui.row({ gap = 8, align = "center", width = 320 }, {
			ui.label({ text = "🌿", fontSize = 20, baseline = "pictographic" }),
			ui.label({ text = "Charge limit", fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
			ui.column({ width = 20, height = 24, align = "center", justify = "center" }, status),
			ui.button({
				glyph = failed and "alert-circle" or "refresh",
				variant = "ghost",
				controlSize = "sm",
				enabled = not busy,
				tooltip = if state.kind == "failed"
					then state.message
					else "Refresh\nThe BIOS may restore its saved limit at reboot.",
				onClick = "refresh",
			}),
			ui.button({ glyph = "close", variant = "ghost", controlSize = "sm", tooltip = "Close", onClick = "close" }),
		}),
		ui.column({ gap = 0, width = 320, align = "center" }, {
			ui.row({ width = 280, align = "center" }, {
				ui.slider({
					key = "charge-limit-slider-" .. tostring(sliderRevision),
					min = 0,
					max = 4,
					step = 0,
					value = position,
					flexGrow = 1,
					height = 24,
					enabled = state.kind == "ready",
					onChange = "previewLimit",
					onDragEnd = "commitLimit",
				}),
			}),
			ui.row({ width = 320, justify = "space_between" }, anchors),
		}),
	}))
end

local request: (number?) -> ()
request = function(maximum: number?)
	if state.kind == "reading" or state.kind == "applying" then
		return
	end
	if not noctalia.fileExists(helper) then
		state = { kind = "failed", message = "The charge-limit helper is not installed." }
		render()
		return
	end
	local arguments = { "/usr/bin/pkexec", helper, "read" }
	if maximum then
		assert(state.kind == "ready", "applying a charge limit requires a successful controller read")
		arguments = { "/usr/bin/pkexec", helper, "set", tostring(maximum) }
		state = { kind = "applying", limit = state.limit, target = maximum }
	else
		state = { kind = "reading" }
	end
	feedbackMs = 0
	render()
	local function completed(result)
		local message: string? = nil
		local response = if result.exitCode == 0 and not result.timedOut
			then noctalia.json.decode(result.stdout)
			else nil
		if result.timedOut then
			message = "The charge-limit request timed out."
		elseif result.exitCode ~= 0 then
			message = noctalia.string.trim(result.stderr)
			if message == "" then
				message = "The charge-limit request failed with exit code " .. tostring(result.exitCode) .. "."
			end
		elseif
			typeof(response) ~= "table"
			or typeof(response.limit) ~= "number"
			or response.limit % 1 ~= 0
			or response.limit < 25
			or response.limit > 100
		then
			message = "The charge-limit helper returned an invalid response."
		elseif maximum and response.limit ~= maximum then
			message = "The controller returned a different charge limit."
		end
		if message then
			state = { kind = "failed", message = message }
			noctalia.notifyError("Charge limit", message)
			if maximum then
				request(nil)
				return
			end
		else
			local limit = response.limit
			state = { kind = "ready", limit = limit }
			position = positionFor(limit)
			sliderRevision += 1
			if maximum then
				feedbackMs = 800
			end
		end
		render()
	end
	if not noctalia.runAsync(arguments, completed) then
		completed({
			exitCode = -1,
			timedOut = false,
			stdout = "",
			stderr = "The charge-limit helper could not be started.",
		})
	end
end

local function choose(index: number)
	if state.kind ~= "ready" then
		return
	end
	local maximum = presets[index]
	assert(maximum ~= nil, "a charge-limit anchor requires a supported preset")
	-- The slider key stays fixed during a gesture and resets after release.
	sliderRevision += 1
	position = index - 1
	if maximum ~= state.limit then
		request(maximum)
	else
		render()
	end
end

function previewLimit(value: string)
	if state.kind ~= "ready" then
		return
	end
	local nextPosition = tonumber(value)
	assert(nextPosition and nextPosition >= 0 and nextPosition <= 4, "the charge slider sent an invalid position")
	if math.abs(position - nextPosition) > 0.001 then
		position = nextPosition
		render()
	end
end

function commitLimit()
	choose(math.floor(position + 0.5) + 1)
end

function choose1()
	choose(1)
end
function choose2()
	choose(2)
end
function choose3()
	choose(3)
end
function choose4()
	choose(4)
end
function choose5()
	choose(5)
end
function refresh()
	request(nil)
end
function close()
	panel.close()
end

function onKey(chord: string, pressed: boolean)
	if not pressed or state.kind ~= "ready" then
		return
	end
	local index = math.floor(positionFor(state.limit) + 0.5) + 1
	if chord == "Left" then
		choose(math.max(1, index - 1))
	elseif chord == "Right" then
		choose(math.min(#presets, index + 1))
	elseif chord == "Home" or chord == "Page_Down" then
		choose(1)
	elseif chord == "End" or chord == "Page_Up" then
		choose(#presets)
	end
end

function onFrameTick(deltaMs: string)
	local elapsed = tonumber(deltaMs)
	assert(elapsed and elapsed >= 0, "the panel received an invalid frame duration")
	spinnerMs += elapsed
	feedbackMs = math.max(0, feedbackMs - elapsed)
	render()
end

function onOpen()
	isOpen = true
	request(nil)
	render()
end

function onClose()
	isOpen = false
	feedbackMs = 0
	if state.kind == "ready" then
		position = positionFor(state.limit)
	end
	panel.setNeedsFrameTick(false)
end
