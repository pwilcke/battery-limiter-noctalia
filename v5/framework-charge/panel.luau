--!strict
type State =
	{ kind: "idle" }
	| { kind: "reading" }
	-- drains: whether the laptop drains charge above the limit, even on AC.
	| { kind: "ready", limit: number, drains: boolean }
	| { kind: "applying", limit: number, drains: boolean, target: number }
	| { kind: "failed", message: string }
type Glide = { from: number, to: number, startMs: number }
type Activity = "charging" | "holding" | "draining" | "on battery"

local helper = "/usr/local/libexec/framework-charge-limit"
-- A Framework has only BAT1 and calls its charger ACAD; a ThinkPad has BAT0 and AC.
local batteryPath = if noctalia.fileExists("/sys/class/power_supply/BAT0/capacity")
	then "/sys/class/power_supply/BAT0/"
	else "/sys/class/power_supply/BAT1/"
local chargerPath = if noctalia.fileExists("/sys/class/power_supply/AC/online")
	then "/sys/class/power_supply/AC/online"
	else "/sys/class/power_supply/ACAD/online"
-- Each preset owns the part of the gauge that is closer to it than to its neighbours.
local presets = {
	{ limit = 50, from = 50, to = 55 },
	{ limit = 60, from = 55, to = 65 },
	{ limit = 70, from = 65, to = 75 },
	{ limit = 80, from = 75, to = 90 },
	{ limit = 100, from = 90, to = 100 },
}
-- The presets sit at even steps. 80 to 100 is one step too, so above 80 a point is half
-- as wide.
local stepWidth = 55
local barWidth = 4 * stepWidth
local fillHeight = 22
local shellHeight = 28
local leadWidth = 17 -- the open end left of 50 %; half a label wide, so 50 can centre
local markerWidth = 1.75
local labelWidth = 34
local gaugeWidth = leadWidth + barWidth + 8 -- the battery with its nub; the header ends there too
-- Noctalia's label boxes are far taller than their text and centre the capitals, so the
-- header needs three offsets, measured with the default font: titleDrop moves the title
-- down onto the limit's baseline, sublineRise tucks the status line under the limit's
-- box, and headerTrim pulls the header up by the empty top of that box.
local titleDrop = 6
local sublineRise = -6
local headerTrim = 8
local glideMs = 180
local spinPeriodMs = 800
local minimumSpinMs = 700
local clear = "#00000000" -- Noctalia keeps a box's previous fill when the prop is absent.
local state: State = { kind = "idle" }
local hovered: number? = nil
local leaving = false
local charge: number? = nil
local activity: Activity? = nil
local glide: Glide? = nil
local spunFromMs = 0
local confirmedAtMs: number? = nil
local finish: (() -> ())? = nil
local isOpen = false

local function px(percent: number): number
	-- Whole pixels, because Noctalia rounds positions and fractional edges would leave gaps.
	local steps = if percent <= 80 then (percent - 50) / 10 else 3 + (percent - 80) / 20
	return math.round(steps * stepWidth)
end

local function readCharge(): number?
	local text = noctalia.readFile(batteryPath .. "capacity")
	local percent = text and tonumber(noctalia.string.trim(text))
	return if percent and percent >= 0 and percent <= 100 then percent else nil
end

local function readActivity(): Activity?
	local status = noctalia.readFile(batteryPath .. "status")
	local online = noctalia.readFile(chargerPath)
	if status == nil or online == nil then
		return nil
	end
	status, online = noctalia.string.trim(status), noctalia.string.trim(online)
	if online == "0" then
		return "on battery"
	elseif status == "Charging" then
		return "charging"
	elseif status == "Discharging" then
		return "draining"
	elseif status == "Not charging" or status == "Full" then
		return "holding"
	end
	return nil
end

local function glidePosition(current: Glide, now: number): number
	local progress = math.clamp((now - current.startMs) / glideMs, 0, 1)
	return current.from + (current.to - current.from) * (1 - (1 - progress) ^ 3)
end

local function space(width: number, height: number)
	return ui.box({ width = width, height = height, fill = clear })
end

-- Noctalia has no stacking layout. A row with almost no width places its children
-- where it stands and lets them spill past it, so the next sibling is drawn over
-- them. (A width of exactly 0 means unbounded; 0.01 vanishes when positions round.)
local function overlay(children)
	return ui.row({ width = 0.01, gap = 0 }, children)
end

local render: () -> ()

local function request(maximum: number?)
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
		state = { kind = "applying", limit = state.limit, drains = state.drains, target = maximum }
	else
		state = { kind = "reading" }
	end
	spunFromMs = noctalia.nowMs()
	confirmedAtMs = nil
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
			or typeof(response.drains) ~= "boolean"
		then
			message = "The charge-limit helper returned an invalid response."
		elseif maximum and response.limit ~= maximum then
			message = "The controller returned a different charge limit."
		end
		if message then
			state = { kind = "failed", message = message }
			noctalia.notifyError("Charge limit", message)
			-- A failed write leaves the limit unknown; reopening reads it anyway.
			if maximum and isOpen then
				request(nil)
				return
			end
		else
			state = { kind = "ready", limit = response.limit, drains = response.drains }
			if maximum then
				confirmedAtMs = noctalia.nowMs()
			end
		end
		render()
	end
	local function received(result)
		-- Writes return in about 0.1 s; holding the result lets the spinner finish a turn
		-- instead of flashing. Closing the panel releases it at once.
		if maximum and isOpen and noctalia.nowMs() - spunFromMs < minimumSpinMs then
			finish = function()
				completed(result)
			end
		else
			completed(result)
		end
	end
	if not noctalia.runAsync(arguments, received) then
		completed({
			exitCode = -1,
			timedOut = false,
			stdout = "",
			stderr = "The charge-limit helper could not be started.",
		})
	end
end

local function releaseFinish()
	local run = finish
	finish = nil
	if run then
		run()
	end
end

local function choose(limit: number)
	if state.kind == "ready" and limit ~= state.limit then
		request(limit)
	end
end

local function hover(index: number, entered: string)
	if entered == "true" then
		leaving = false
		if hovered ~= index then
			hovered = index
			render()
		end
	elseif hovered == index then
		-- Moving between two zones reports a leave, then an enter. Clearing on the next
		-- frame instead of now keeps the gap between them from being drawn.
		leaving = true
		panel.setNeedsFrameTick(true)
	end
end

render = function()
	if not isOpen then
		panel.setNeedsFrameTick(false)
		return
	end
	local now = noctalia.nowMs()
	local spinMs = now - spunFromMs
	local checkMs = if confirmedAtMs then now - confirmedAtMs else math.huge
	local limit = if state.kind == "ready" or state.kind == "applying" then state.limit else nil
	local candidate = if state.kind == "applying"
		then state.target
		elseif state.kind == "ready" and hovered and presets[hovered].limit ~= state.limit then presets[hovered].limit
		else nil
	local ceiling = candidate or limit
	local drains = if state.kind == "ready" or state.kind == "applying" then state.drains else false
	-- Charge above the ceiling turns red when the firmware will drain it: in a preview of a
	-- lower limit, or while it drains now. It holds a small overshoot, which stays plain.
	local drainShown = drains and (candidate ~= nil or activity == "draining")
	local accent = if candidate == nil
		then "on_surface"
		elseif drains and charge and candidate < charge then "error"
		else "primary"

	-- The line and the fill behind it glide to a new ceiling instead of jumping.
	-- While a read hides the line, the glide keeps its place, so the line resumes from there.
	local target = ceiling and px(ceiling)
	if target and glide == nil then
		glide = { from = target, to = target, startMs = now }
	elseif target and glide and glide.to ~= target then
		glide = { from = glidePosition(glide, now), to = target, startMs = now }
	end
	local gliding = target ~= nil and glide ~= nil and now - glide.startMs < glideMs
	local ceilingX = if target and glide then math.round(glidePosition(glide, now)) else nil
	panel.setNeedsFrameTick(state.kind == "applying" or checkMs < 800 or leaving or gliding)

	-- The bar is one row of colour spans, cut where the colour changes.
	local chargeX = charge and px(charge)
	local limitX = limit and px(limit)
	local markerX = ceilingX and math.clamp(ceilingX - 1, 0, barWidth - 1)
	local cuts = { 0, barWidth }
	for _, x in { chargeX or 0, limitX or 0, markerX or 0 } do
		if x > 0 and x < barWidth then
			table.insert(cuts, x)
		end
	end
	table.sort(cuts)
	local function paint(x: number): string
		if chargeX and x < chargeX then
			return if drainShown and ceilingX and x >= ceilingX then "error" else "primary"
		elseif limitX and x < math.min(limitX, ceilingX or limitX) then
			return "primary/0.3"
		elseif limitX and ceilingX and x >= limitX and x < ceilingX then
			return "primary/0.15"
		end
		return clear
	end
	local spans: { { left: number, right: number, fill: string } } = {}
	for index = 1, #cuts - 1 do
		local left, right = cuts[index], cuts[index + 1]
		local fill = paint((left + right) / 2)
		local last = spans[#spans]
		if right > left and last and last.fill == fill and left ~= markerX then
			last.right = right
		elseif right > left then
			table.insert(spans, { left = left, right = right, fill = fill })
		end
	end
	local bar = {}
	for _, span in spans do
		local width, fill = span.right - span.left, span.fill
		if span.left == markerX then
			-- Positions round to whole pixels, so the line sits on the span to its right
			-- rather than between two spans, where rounding would open a gap.
			table.insert(
				bar,
				ui.row({ width = width, height = fillHeight, fill = fill }, {
					ui.box({ width = markerWidth, height = fillHeight, radius = markerWidth / 2, fill = accent }),
				})
			)
		else
			table.insert(bar, ui.box({ width = width, height = fillHeight, fill = fill }))
		end
	end

	-- Left of 50 % the battery is cut open with a straight edge: the panel-coloured block
	-- hides the outline's closed end, and the edges and fill stop flush at the cut. Each
	-- reaches one pixel past the lead, under the bar, so no seam shows there.
	local leadFill = if chargeX and chargeX >= 0 then "primary" else clear
	local function edge()
		return ui.row(
			{ height = 1.75, gap = 0 },
			{ ui.box({ width = leadWidth + 1, height = 1.75, fill = "outline" }) }
		)
	end
	local lead = ui.column({ width = leadWidth, height = shellHeight, fill = "surface", justify = "space_between" }, {
		edge(),
		ui.row(
			{ height = fillHeight, gap = 0 },
			{ ui.box({ width = leadWidth + 1, height = fillHeight, fill = leadFill }) }
		),
		edge(),
	})

	-- Layers, back to front: the outline, the bar, the open end, and invisible zones
	-- that take the pointer (the 50 % zone also covers the open end). The outline starts
	-- 2 px in so its anti-aliased left edge stays hidden under the open end.
	local shellWidth = leadWidth + barWidth + 3
	local gauge = {
		overlay({
			space(2, 1),
			ui.row(
				{ width = shellWidth - 2, height = shellHeight, radius = 8, border = "outline", borderWidth = 1.75 },
				{}
			),
		}),
		overlay({ space(leadWidth, 1), ui.row({ gap = 0 }, bar) }),
		overlay({ lead }),
	}
	for index, preset in presets do
		local width = px(preset.to) - px(preset.from)
		table.insert(
			gauge,
			ui.row({
				key = "zone" .. index,
				width = width + (if index == 1 then leadWidth elseif index == #presets then 3 else 0),
				height = shellHeight,
				onClick = function()
					choose(preset.limit)
				end,
				onHover = function(entered: string)
					hover(index, entered)
				end,
			}, {})
		)
	end
	table.insert(gauge, space(2, 1))
	table.insert(gauge, ui.box({ width = 3, height = 12, radius = 1.5, fill = "outline" }))

	-- Labels sit centred under their presets; the hovered one carries the preview.
	local labels = {}
	local cursor = -leadWidth
	for index, preset in presets do
		local center = px(preset.limit)
		local previewed = preset.limit == candidate
		table.insert(labels, space(center - labelWidth / 2 - cursor, 1))
		table.insert(
			labels,
			ui.row({
				key = "label" .. index,
				width = labelWidth,
				height = 20,
				justify = "center",
				align = "center",
				radius = 6,
				fill = if previewed then accent .. "/0.15" else clear,
				onClick = function()
					choose(preset.limit)
				end,
				onHover = function(entered: string)
					hover(index, entered)
				end,
			}, {
				ui.label({
					text = tostring(preset.limit) .. (if previewed then "%" else ""),
					fontSize = 12.5,
					fontWeight = if previewed or preset.limit == limit then "bold" else "medium",
					color = if previewed
						then accent
						elseif preset.limit == limit then "on_surface"
						else "on_surface_variant/0.6",
				}),
			})
		)
		cursor = center + labelWidth / 2
	end

	local status = {}
	if state.kind == "applying" then
		-- Eight dots on an octagon: a bright head goes round and the others fade behind it.
		local head = spinMs / spinPeriodMs * 8 % 8
		local function dot(order: number)
			local behind = (head - order) % 8
			-- The dot about to become the head brightens over the last step, so nothing jumps.
			local glow = if behind > 7 then behind - 7 else (1 - behind / 7) ^ 2
			local opacity = math.min(1, spinMs / 120) * (0.15 + 0.85 * glow)
			return ui.box({ width = 3, height = 3, radius = 1.5, fill = "primary", opacity = opacity })
		end
		table.insert(
			status,
			ui.column({ align = "center" }, {
				ui.row({ gap = 2.3 }, { dot(7), dot(0) }),
				space(1, 0.74),
				ui.row({ gap = 9.75 }, { dot(6), dot(1) }),
				space(1, 2.3),
				ui.row({ gap = 9.75 }, { dot(5), dot(2) }),
				space(1, 0.74),
				ui.row({ gap = 2.3 }, { dot(4), dot(3) }),
			})
		)
	elseif state.kind == "failed" then
		table.insert(
			status,
			ui.row({
				onClick = function()
					request(nil)
				end,
				tooltip = state.message,
			}, {
				ui.glyph({ name = "alert-circle", size = 18, color = "error" }),
			})
		)
	elseif checkMs < 800 then
		table.insert(
			status,
			ui.glyph({
				name = "check",
				size = 18,
				color = "primary",
				opacity = math.min(1, checkMs / 120, (800 - checkMs) / 250),
			})
		)
	end
	panel.render(ui.column({ gap = 6, padding = 1 }, {
		ui.column({ gap = -headerTrim }, {
			space(1, 0.01),
			ui.row({ gap = 9, align = "center", width = gaugeWidth }, {
				ui.label({ text = "🌿", fontSize = 21, baseline = "pictographic" }),
				ui.column({ gap = sublineRise, flexGrow = 1 }, {
					ui.row({ gap = 7, align = "center" }, {
						ui.column({ flexGrow = 1 }, {
							space(1, titleDrop),
							ui.label({ text = "Charge limit", fontSize = 17, fontWeight = "semibold" }),
						}),
						ui.row({ width = 18, justify = "center", align = "center" }, status),
						ui.label({
							text = if limit then tostring(limit) .. "%" else "",
							fontSize = 25,
							fontWeight = "bold",
						}),
					}),
					ui.row({ gap = 0 }, {
						ui.label({
							text = if charge
								then "Battery " .. tostring(charge) .. "%" .. (if activity then " · " else "")
								else "",
							fontSize = 12.5,
							fontWeight = "medium",
							color = "on_surface_variant",
						}),
						ui.label({
							text = activity or "",
							fontSize = 12.5,
							fontWeight = "medium",
							color = if activity == "draining"
								then "error"
								elseif activity == "charging" then "primary"
								else "on_surface_variant",
						}),
					}),
				}),
			}),
		}),
		ui.column({ gap = 3 }, {
			ui.row({ gap = 0, align = "center" }, gauge),
			ui.row({}, labels),
		}),
	}))
end

function onKey(chord: string, pressed: boolean)
	if not pressed or state.kind ~= "ready" then
		return
	end
	local limit = state.limit
	local target: number? = nil
	if chord == "Left" then
		for _, preset in presets do
			if preset.limit < limit then
				target = preset.limit
			end
		end
	elseif chord == "Right" then
		for _, preset in presets do
			if preset.limit > limit then
				target = preset.limit
				break
			end
		end
	elseif chord == "Home" or chord == "Page_Down" then
		target = presets[1].limit
	elseif chord == "End" or chord == "Page_Up" then
		target = presets[#presets].limit
	end
	if target then
		choose(target)
	end
end

-- Noctalia can merge frame callbacks, so animation time comes from the clock, not deltaMs.
function onFrameTick()
	if leaving then
		leaving = false
		hovered = nil
	end
	if finish and noctalia.nowMs() - spunFromMs >= minimumSpinMs then
		releaseFinish() -- completing renders
		return
	end
	render()
end

function update()
	local nextCharge, nextActivity = readCharge(), readActivity()
	if nextCharge ~= charge or nextActivity ~= activity then
		charge, activity = nextCharge, nextActivity
		render()
	end
end

function onOpen()
	isOpen = true
	charge, activity = readCharge(), readActivity()
	panel.setWantsSecondTicks(true)
	request(nil)
	render()
end

function onClose()
	isOpen = false
	hovered = nil
	leaving = false
	glide = nil
	releaseFinish()
	confirmedAtMs = nil
	panel.setNeedsFrameTick(false)
end
