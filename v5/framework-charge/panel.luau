--!strict
type State =
	{ kind: "idle" }
	| { kind: "reading" }
	-- drains: whether the laptop drains charge above the limit, even on AC.
	| { kind: "ready", limit: number, drains: boolean }
	| { kind: "applying", limit: number, drains: boolean, target: number }
	| { kind: "failed", message: string }
type Glide = { from: number, to: number, startMs: number }
-- What the service publishes about its plan, for the footer.
type Plan = { note: string?, scheduling: boolean?, overridden: boolean?, target: { limit: number, deadline: number }? }
type Pending = { id: string, kind: string, sentMs: number }

local planner = require("./planner.luau")
local power = require("./power.luau")
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
local stepWidth = 60
local barWidth = 4 * stepWidth
local fillHeight = 24
local shellHeight = 30
local leadWidth = 19 -- the open end left of 50 %; half a label wide, so 50 can centre
local markerWidth = 2
local labelWidth = 38
local gaugeWidth = leadWidth + barWidth + 8 -- the battery with its nub; the header ends there too
-- Noctalia's label boxes are far taller than their text and centre the capitals, so the
-- header needs three offsets, measured with the default font: titleDrop moves the title
-- down onto the limit's baseline, sublineRise tucks the status line under the limit's
-- box, and headerTrim pulls the header up by the empty top of that box.
local titleDrop = 8
local sublineRise = -6
local headerTrim = 8
local glideMs = 180
local spinPeriodMs = 800
local minimumSpinMs = 700
local serviceWaitMs = 5000 -- an unanswered request after this means the service is not running
local clear = "#00000000" -- Noctalia keeps a box's previous fill when the prop is absent.
local state: State = { kind = "idle" }
local hovered: number? = nil
local leaving = false
local charge: number? = nil
local activity: power.Activity? = nil
local plan: Plan = noctalia.state.get("plan") or {}
local pending: Pending? = nil
local sent = 0
local editing: { limit: number, deadline: number }? = nil
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

-- The service owns the controller. A request goes out only once the last one has been answered,
-- so none replaces another; the answer arrives as the controller's ack.
local function send(kind: string, limit: number?, deadline: number?): boolean
	if pending then
		return false
	end
	sent += 1
	local id = `{noctalia.nowMs()}-{sent}`
	pending = { id = id, kind = kind, sentMs = noctalia.nowMs() }
	noctalia.state.set("request", { id = id, kind = kind, limit = limit, deadline = deadline })
	return true
end

local function adopt(controller)
	if controller.status == "ready" then
		state = { kind = "ready", limit = controller.limit, drains = controller.drains }
	elseif controller.status == "applying" then
		local limit = controller.limit or controller.target
		state = { kind = "applying", limit = limit, drains = controller.drains == true, target = controller.target }
		spunFromMs = noctalia.nowMs()
	elseif controller.status == "failed" then
		state = { kind = "failed", message = controller.message }
	else
		state = { kind = "reading" }
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
	-- With a schedule or a target running, a click on the current limit still counts: it is a
	-- manual choice.
	if state.kind == "ready" and (limit ~= state.limit or plan.scheduling or plan.target) and send("set", limit) then
		state = { kind = "applying", limit = state.limit, drains = state.drains, target = limit }
		spunFromMs = noctalia.nowMs()
		confirmedAtMs = nil
		render()
	end
end

local held: any = nil -- the newest controller state while the spinner finishes its turn

noctalia.state.watch("controller", function(controller)
	if pending and controller.ack ~= pending.id then
		return -- the answer to our own request is still coming; the panel already shows it
	elseif finish then
		held = controller -- a newer state replaces the one the spinner holds
		pending = nil
		return
	end
	local ours = pending
	pending = nil
	held = controller
	local function settle()
		adopt(held)
		if ours and ours.kind == "set" and held.status == "ready" then
			confirmedAtMs = noctalia.nowMs()
		end
		held = nil
		render()
	end
	-- Writes return in about 0.1 s; holding the answer lets the spinner finish a turn instead of
	-- flashing. Closing the panel releases it at once.
	if ours and ours.kind == "set" and isOpen and noctalia.nowMs() - spunFromMs < minimumSpinMs then
		finish = settle
		panel.setNeedsFrameTick(true)
	else
		settle()
	end
end)

noctalia.state.watch("plan", function(value)
	plan = value or {}
	render()
end)

-- The presets a "charge by" target can use: only above the current limit, so it never drains.
local function targetChoices(): { number }
	local choices = {}
	for _, preset in presets do
		if state.kind == "ready" and preset.limit > state.limit then
			table.insert(choices, preset.limit)
		end
	end
	return choices
end

-- Deadlines sit on half hours: from the first one at least 15 minutes away to 24 hours ahead.
local function halfHourFrom(time: number): number
	return time + (1800 - time % 1800) % 1800
end

local function deadlineRange(): (number, number)
	local now = os.time()
	return halfHourFrom(now + 15 * 60), halfHourFrom(now + 24 * 3600) - 1800
end

local function openEditor()
	local choices = targetChoices()
	if #choices == 0 then
		return
	end
	editing = {
		limit = if table.find(choices, 80) then 80 else choices[1],
		deadline = halfHourFrom(os.time() + 2 * 3600),
	}
	render()
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
		return ui.row({ height = 2, gap = 0 }, { ui.box({ width = leadWidth + 1, height = 2, fill = "outline" }) })
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
				{ width = shellWidth - 2, height = shellHeight, radius = 9, border = "outline", borderWidth = 2 },
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
	table.insert(gauge, ui.box({ width = 3, height = 14, radius = 1.5, fill = "outline" }))

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
				height = 22,
				justify = "center",
				align = "center",
				radius = 7,
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
					fontSize = 13.5,
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
			return ui.box({ width = 3.3, height = 3.3, radius = 1.65, fill = "primary", opacity = opacity })
		end
		table.insert(
			status,
			ui.column({ align = "center" }, {
				ui.row({ gap = 2.5 }, { dot(7), dot(0) }),
				space(1, 0.8),
				ui.row({ gap = 10.7 }, { dot(6), dot(1) }),
				space(1, 2.5),
				ui.row({ gap = 10.7 }, { dot(5), dot(2) }),
				space(1, 0.8),
				ui.row({ gap = 2.5 }, { dot(4), dot(3) }),
			})
		)
	elseif state.kind == "failed" then
		table.insert(
			status,
			ui.row({
				onClick = function()
					if send("read") then
						state = { kind = "reading" }
						render()
					end
				end,
				tooltip = state.message,
			}, {
				ui.glyph({ name = "alert-circle", size = 20, color = "error" }),
			})
		)
	elseif checkMs < 800 then
		table.insert(
			status,
			ui.glyph({
				name = "check",
				size = 20,
				color = "primary",
				opacity = math.min(1, checkMs / 120, (800 - checkMs) / 250),
			})
		)
	end
	-- The footer: the service's plan with its controls, or the editor for "charge by".
	local function button(key: string, glyph: string, tooltip: string, action: () -> (), color: string?)
		return ui.row({
			key = key,
			width = 22,
			height = 22,
			justify = "center",
			align = "center",
			tooltip = tooltip,
			onClick = action,
		}, { ui.glyph({ name = glyph, size = 16, color = color or "on_surface_variant" }) })
	end
	local function text(value: string, color: string?, grow: number?)
		return ui.label({
			text = value,
			fontSize = 13.5,
			fontWeight = "medium",
			color = color or "on_surface_variant",
			maxLines = 1,
			flexGrow = grow,
		})
	end
	local choices = targetChoices()
	local footer = {}
	-- The limit may have moved since the editor opened: keep its target above it, or close it.
	if editing and not table.find(choices, editing.limit) then
		editing = if #choices > 0 then { limit = choices[1], deadline = editing.deadline } else nil
	end
	local edit = editing
	if edit then
		local function move(minutes: number)
			local earliest, latest = deadlineRange()
			edit.deadline = math.clamp(edit.deadline + minutes * 60, earliest, latest)
			render()
		end
		footer = {
			ui.glyph({ name = "clock", size = 16, color = "primary" }),
			ui.row({
				key = "target",
				tooltip = "Change the target",
				onClick = function()
					local at = table.find(choices, edit.limit) or 0
					edit.limit = choices[at % #choices + 1]
					render()
				end,
			}, { text(`{edit.limit}%`, "on_surface") }),
			text("by"),
			button("earlier", "chevron-left", "30 minutes earlier", function()
				move(-30)
			end),
			text(planner.clock(edit.deadline, os.time()), "on_surface"),
			button("later", "chevron-right", "30 minutes later", function()
				move(30)
			end),
			ui.row({ flexGrow = 1 }, {}),
			button("start", "check", "Start", function()
				if send("target", edit.limit, edit.deadline) then
					editing = nil
					render()
				end
			end, "primary"),
			button("close", "x", "Close", function()
				editing = nil
				render()
			end),
		}
	elseif plan.target then
		footer = {
			ui.glyph({ name = "clock", size = 16, color = "primary" }),
			text(plan.note or "", "on_surface", 1),
			button("cancel", "x", "Cancel", function()
				send("cancel")
			end),
		}
	elseif plan.note then
		footer = { ui.glyph({ name = "briefcase", size = 16, color = "on_surface_variant" }), text(plan.note, nil, 1) }
		if plan.overridden then
			table.insert(
				footer,
				button("schedule", "arrow-back-up", "Back on schedule", function()
					send("schedule")
				end)
			)
		end
		if #choices > 0 then
			table.insert(footer, button("charge-by", "clock", "Charge by a time", openEditor))
		end
	elseif #choices > 0 then
		footer = {
			ui.row({ key = "charge-by", gap = 7, align = "center", onClick = openEditor }, {
				ui.glyph({ name = "clock", size = 16, color = "on_surface_variant" }),
				text("Charge by a time"),
			}),
		}
	end

	panel.render(ui.column({ gap = 7, padding = 1 }, {
		ui.column({ gap = -headerTrim }, {
			space(1, 0.01),
			ui.row({ gap = 10, align = "center", width = gaugeWidth }, {
				ui.label({ text = "🌿", fontSize = 23, baseline = "pictographic" }),
				ui.column({ gap = sublineRise, flexGrow = 1 }, {
					ui.row({ gap = 8, align = "center" }, {
						ui.column({ flexGrow = 1 }, {
							space(1, titleDrop),
							ui.label({ text = "Charge limit", fontSize = 19, fontWeight = "semibold" }),
						}),
						ui.row({ width = 20, justify = "center", align = "center" }, status),
						ui.label({
							text = if limit then tostring(limit) .. "%" else "",
							fontSize = 28,
							fontWeight = "bold",
						}),
					}),
					ui.row({ gap = 0 }, {
						ui.label({
							text = if charge
								then "Battery " .. tostring(charge) .. "%" .. (if activity then " · " else "")
								else "",
							fontSize = 13.5,
							fontWeight = "medium",
							color = "on_surface_variant",
						}),
						ui.label({
							text = activity or "",
							fontSize = 13.5,
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
		ui.row({ gap = 6, align = "center", width = gaugeWidth, height = 24 }, footer),
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
	if pending and noctalia.nowMs() - pending.sentMs > serviceWaitMs then
		pending = nil
		state = { kind = "failed", message = "The charge planner service is not running." }
		render()
	end
	local nextCharge, nextActivity = power.charge(), power.activity()
	if nextCharge ~= charge or nextActivity ~= activity then
		charge, activity = nextCharge, nextActivity
		render()
	end
end

function onOpen()
	isOpen = true
	charge, activity = power.charge(), power.activity()
	panel.setWantsSecondTicks(true)
	if pending and noctalia.nowMs() - pending.sentMs > serviceWaitMs then
		pending = nil
	end
	-- A fresh read also proves the service is running: old state outlives it.
	if send("read") then
		state = { kind = "reading" }
	end
	render()
end

function onClose()
	isOpen = false
	hovered = nil
	leaving = false
	glide = nil
	editing = nil
	releaseFinish()
	confirmedAtMs = nil
	panel.setNeedsFrameTick(false)
end
