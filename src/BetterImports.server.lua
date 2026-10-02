--[[
	BetterImports -- a Roblox Studio plugin that fixes freshly imported meshes.

	Every one of these checks exists because it cost somebody hours:

	  * imports arrive UNANCHORED. A 1,700-stud part falls the instant you press
	    Play and drags the physics solver down with it.
	  * every MeshPart gets a PivotOffset rotated 90 degrees about X, because
	    Blender is Z-up and Roblox is Y-up. Model:PivotTo then lays the thing on
	    its side and you spend an hour thinking your export is broken.
	  * Models arrive with no PrimaryPart, so PivotTo and GetPivot misbehave.
	  * scale is always wrong. Quaternius kits land ~50x too big, Kenney ~100x.
	  * CollisionFidelity defaults to Default, which builds a real mesh collider
	    for scenery nobody can touch.
	  * CastShadow on moving decor is the single largest avoidable render cost on
	    a phone.
	  * imports land LOOSE IN WORKSPACE, and it is genuinely easy to publish them
	    there by accident and ship a game full of falling buildings.

	Everything is wrapped in ChangeHistoryService, so Ctrl+Z undoes a whole fix.
]]

local ChangeHistoryService = game:GetService("ChangeHistoryService")
local Selection = game:GetService("Selection")
local ServerStorage = game:GetService("ServerStorage")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local TOOLBAR = "BetterImports"
local WIDGET_ID = "BetterImports_Main"

-- ============================================================ palette
local INK = Color3.fromRGB(24, 26, 31)
local PANEL = Color3.fromRGB(33, 36, 43)
local LINE = Color3.fromRGB(52, 57, 67)
local TEXT = Color3.fromRGB(232, 234, 238)
local MUTED = Color3.fromRGB(146, 152, 164)
local GOOD = Color3.fromRGB(104, 198, 130)
local WARN = Color3.fromRGB(232, 178, 86)
local ACCENT = Color3.fromRGB(96, 158, 232)

-- ============================================================ the checks
-- Each returns true when the instance HAS the problem.

-- Some parts are structure, not scenery, and turning off their collision looks
-- like a fixed problem while actually breaking the place. A SpawnLocation you
-- fall through and a Baseplate that is not a floor are the two obvious ones.
-- Learned the hard way: an early build happily did both.
local PROTECTED_NAMES = { Baseplate = true, Terrain = true, Ground = true, Floor = true }

local function isProtected(x)
	if x:IsA("Terrain") or x:IsA("SpawnLocation") or x:IsA("Seat") or x:IsA("VehicleSeat") then return true end
	if PROTECTED_NAMES[x.Name] then return true end
	-- NO size heuristic here. "Big part = floor" is exactly backwards for an import
	-- tool: a fresh Quaternius building is 1,700 studs and a Kenney car body is 150.
	-- An early version of this guard refused to fix 135 of 233 real meshes because
	-- of that rule. Hand-made floors are primitive Parts, and the scenery fixes are
	-- already scoped to MeshParts, so the rule earned nothing anyway.
	if x:FindFirstAncestorOfClass("Model") and x:FindFirstAncestorOfClass("Model"):FindFirstChildOfClass("Humanoid") then return true end
	return false
end

-- The scenery fixes only ever apply to actual imported geometry. A primitive
-- Part you placed by hand is not an import and this tool has no business
-- deciding whether it should collide.
local function isImport(x)
	return (x:IsA("MeshPart") or x:IsA("UnionOperation")) and not isProtected(x)
end

local CHECKS = {
	{
		key = "anchor",
		label = "Unanchored",
		detail = "Falls on Play and takes the physics solver with it",
		on = true,
		test = function(x) return x:IsA("BasePart") and not x.Anchored and not isProtected(x) end,
		fix = function(x) x.Anchored = true end,
	},
	{
		key = "pivot",
		label = "Rotated PivotOffset",
		detail = "Blender is Z-up, so PivotTo lays the mesh on its side",
		on = true,
		test = function(x)
			if not x:IsA("BasePart") then return false end
			local _, _, _, r00, _, _, _, r11 = x.PivotOffset:GetComponents()
			-- identity rotation has r00 and r11 both ~1
			return math.abs(r00 - 1) > 1e-4 or math.abs(r11 - 1) > 1e-4
		end,
		fix = function(x) x.PivotOffset = CFrame.identity end,
	},
	{
		key = "primary",
		label = "Model without a PrimaryPart",
		detail = "PivotTo and GetPivot misbehave without one",
		on = true,
		test = function(x) return x:IsA("Model") and x.PrimaryPart == nil and x:FindFirstChildWhichIsA("BasePart", true) ~= nil end,
		fix = function(x) x.PrimaryPart = x:FindFirstChildWhichIsA("BasePart", true) end,
	},
	{
		key = "collide",
		label = "Collidable imported mesh",
		detail = "Props the player should never snag on",
		on = false,
		test = function(x) return isImport(x) and x.CanCollide end,
		fix = function(x) x.CanCollide = false end,
	},
	{
		key = "query",
		label = "CanQuery on (imports)",
		detail = "Raycasts and the camera popper hit invisible scenery",
		on = false,
		test = function(x) return isImport(x) and x.CanQuery end,
		fix = function(x) x.CanQuery = false; x.CanTouch = false end,
	},
	{
		key = "shadow",
		label = "Imports casting shadows",
		detail = "The biggest avoidable render cost on a phone",
		on = false,
		test = function(x) return isImport(x) and x.CastShadow end,
		fix = function(x) x.CastShadow = false end,
	},
	{
		key = "fidelity",
		label = "Expensive CollisionFidelity",
		detail = "A full mesh collider for something nobody touches",
		on = false,
		test = function(x)
			return isImport(x) and x:IsA("MeshPart") and x.CollisionFidelity ~= Enum.CollisionFidelity.Box
		end,
		fix = function(x) x.CollisionFidelity = Enum.CollisionFidelity.Box end,
	},
}

-- ============================================================ gathering

-- An import batch is usually a flat pile in Workspace. We walk whatever is
-- selected, or all of Workspace, and look at every part inside.
local function gather(roots)
	local parts, models = {}, {}
	local function walk(x)
		if x:IsA("BasePart") then table.insert(parts, x) end
		if x:IsA("Model") then table.insert(models, x) end
		for _, c in ipairs(x:GetChildren()) do walk(c) end
	end
	for _, r in ipairs(roots) do walk(r) end
	return parts, models
end

local function scan(roots)
	local parts, models = gather(roots)
	local all = {}
	for _, p in ipairs(parts) do table.insert(all, p) end
	for _, m in ipairs(models) do table.insert(all, m) end

	local found = {}
	for _, c in ipairs(CHECKS) do
		local hits = {}
		for _, x in ipairs(all) do
			local ok, bad = pcall(c.test, x)
			if ok and bad then table.insert(hits, x) end
		end
		found[c.key] = hits
	end

	-- loose-in-Workspace is about the ROOTS, not every descendant
	local loose = {}
	for _, r in ipairs(roots) do
		if r.Parent == workspace then table.insert(loose, r) end
	end

	local guarded = 0
	for _, x in ipairs(all) do
		if x:IsA("BasePart") and isProtected(x) then guarded += 1 end
	end

	return found, loose, #parts, #models, guarded
end

-- ============================================================ ui helpers

local function corner(p, r)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, r or 6)
	c.Parent = p
	return c
end

local function label(parent, text, size, colour, props)
	local l = Instance.new("TextLabel")
	l.BackgroundTransparency = 1
	l.Font = Enum.Font.GothamMedium
	l.TextSize = size
	l.TextColor3 = colour
	l.Text = text
	l.TextXAlignment = Enum.TextXAlignment.Left
	for k, v in pairs(props or {}) do l[k] = v end
	l.Parent = parent
	return l
end

local function button(parent, text, colour, props)
	local b = Instance.new("TextButton")
	b.BackgroundColor3 = colour
	b.BorderSizePixel = 0
	b.Font = Enum.Font.GothamBold
	b.TextSize = 13
	b.TextColor3 = Color3.new(1, 1, 1)
	b.Text = text
	b.AutoButtonColor = true
	for k, v in pairs(props or {}) do b[k] = v end
	b.Parent = parent
	corner(b, 6)
	return b
end

-- ============================================================ the widget

local toolbar = plugin:CreateToolbar(TOOLBAR)
local btn = toolbar:CreateButton("BetterImportsOpen", "Fix freshly imported meshes", "rbxasset://textures/ui/common/robux.png", "Imports")
btn.ClickableWhenViewportHidden = true

local info = DockWidgetPluginGuiInfo.new(Enum.InitialDockState.Right, false, false, 340, 520, 300, 400)
local gui = plugin:CreateDockWidgetPluginGui(WIDGET_ID, info)
gui.Title = "BetterImports"
gui.Name = "BetterImports"

local root = Instance.new("Frame")
root.Size = UDim2.fromScale(1, 1)
root.Name = "Root"
root.BackgroundColor3 = INK
root.BorderSizePixel = 0
root.Parent = gui

local pad = Instance.new("UIPadding")
pad.PaddingTop = UDim.new(0, 10)
pad.PaddingLeft = UDim.new(0, 10)
pad.PaddingRight = UDim.new(0, 10)
pad.PaddingBottom = UDim.new(0, 10)
pad.Parent = root

local layout = Instance.new("UIListLayout")
layout.Padding = UDim.new(0, 8)
layout.SortOrder = Enum.SortOrder.LayoutOrder
layout.Parent = root

-- scope row -------------------------------------------------------------
local scopeRow = Instance.new("Frame")
scopeRow.Name = "ScopeRow"
scopeRow.BackgroundTransparency = 1
scopeRow.Size = UDim2.new(1, 0, 0, 30)
scopeRow.LayoutOrder = 1
scopeRow.Parent = root

local scanSel = button(scopeRow, "Scan selection", PANEL, { Name = "ScanSelection", Size = UDim2.new(0.5, -4, 1, 0), Position = UDim2.fromScale(0, 0) })
local scanAll = button(scopeRow, "Scan Workspace", PANEL, { Name = "ScanWorkspace", Size = UDim2.new(0.5, -4, 1, 0), Position = UDim2.new(0.5, 4, 0, 0) })

local summary = label(root, "Scan to begin.", 12, MUTED, {
	Name = "Summary", Size = UDim2.new(1, 0, 0, 16), LayoutOrder = 2, TextWrapped = true,
})

-- findings list ---------------------------------------------------------
local list = Instance.new("ScrollingFrame")
list.Name = "Findings"
list.Size = UDim2.new(1, 0, 1, -186)
list.BackgroundColor3 = PANEL
list.BorderSizePixel = 0
list.ScrollBarThickness = 4
list.CanvasSize = UDim2.new()
list.AutomaticCanvasSize = Enum.AutomaticSize.Y
list.LayoutOrder = 3
list.Parent = root
corner(list, 8)

local listPad = Instance.new("UIPadding")
listPad.PaddingTop = UDim.new(0, 6)
listPad.PaddingLeft = UDim.new(0, 6)
listPad.PaddingRight = UDim.new(0, 6)
listPad.PaddingBottom = UDim.new(0, 6)
listPad.Parent = list

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = list

-- scale row -------------------------------------------------------------
local scaleRow = Instance.new("Frame")
scaleRow.BackgroundTransparency = 1
scaleRow.Size = UDim2.new(1, 0, 0, 30)
scaleRow.LayoutOrder = 4
scaleRow.Parent = root

label(scaleRow, "Scale to height (studs)", 12, MUTED, { Size = UDim2.new(0.62, 0, 1, 0) })

local heightBox = Instance.new("TextBox")
heightBox.Name = "Height"
heightBox.Size = UDim2.new(0.38, 0, 1, 0)
heightBox.Position = UDim2.fromScale(0.62, 0)
heightBox.BackgroundColor3 = PANEL
heightBox.BorderSizePixel = 0
heightBox.Font = Enum.Font.Code
heightBox.TextSize = 13
heightBox.TextColor3 = TEXT
heightBox.PlaceholderText = "leave blank"
heightBox.Text = ""
heightBox.ClearTextOnFocus = false
heightBox.Parent = scaleRow
corner(heightBox, 6)

-- move row --------------------------------------------------------------
local moveRow = Instance.new("Frame")
moveRow.BackgroundTransparency = 1
moveRow.Size = UDim2.new(1, 0, 0, 30)
moveRow.LayoutOrder = 5
moveRow.Parent = root

local moveTo = "none"
local moveBtn = button(moveRow, "Leave in Workspace", PANEL, { Name = "MoveTarget", Size = UDim2.new(1, 0, 1, 0), TextSize = 12 })
local MOVE_ORDER = { "none", "ReplicatedStorage", "ServerStorage" }
local MOVE_TEXT = {
	none = "Leave in Workspace",
	ReplicatedStorage = "Move to ReplicatedStorage/Imports",
	ServerStorage = "Move to ServerStorage/Imports",
}
moveBtn.MouseButton1Click:Connect(function()
	local i = table.find(MOVE_ORDER, moveTo) or 1
	moveTo = MOVE_ORDER[(i % #MOVE_ORDER) + 1]
	moveBtn.Text = MOVE_TEXT[moveTo]
	moveBtn.BackgroundColor3 = moveTo == "none" and PANEL or ACCENT
end)

local fixBtn = button(root, "Fix selected problems", ACCENT, {
	Name = "Fix", Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 6, TextSize = 14,
})

local note = label(root, "", 11, MUTED, {
	Name = "Note", Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 7, TextWrapped = true,
})

-- ============================================================ state

local roots = {}
local lastUsedSelection = false   -- remember the scope; never infer it
local found = {}
local loose = {}
local rows = {}

local function setNote(text, colour)
	note.Text = text
	note.TextColor3 = colour or MUTED
end

local function render()
	for _, r in ipairs(rows) do r:Destroy() end
	table.clear(rows)

	local order = 0
	for _, c in ipairs(CHECKS) do
		local hits = found[c.key] or {}
		order += 1

		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 44)
		row.BackgroundColor3 = INK
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = list
		corner(row, 6)
		table.insert(rows, row)

		local tick = Instance.new("TextButton")
		tick.Size = UDim2.fromOffset(20, 20)
		tick.Position = UDim2.fromOffset(8, 12)
		tick.BackgroundColor3 = c.on and ACCENT or PANEL
		tick.BorderSizePixel = 0
		tick.Font = Enum.Font.GothamBold
		tick.TextSize = 13
		tick.TextColor3 = Color3.new(1, 1, 1)
		tick.Text = c.on and "x" or ""
		tick.AutoButtonColor = false
		tick.Parent = row
		corner(tick, 4)

		tick.MouseButton1Click:Connect(function()
			c.on = not c.on
			tick.BackgroundColor3 = c.on and ACCENT or PANEL
			tick.Text = c.on and "x" or ""
		end)

		local n = #hits
		label(row, string.format("%s  (%d)", c.label, n), 12,
			n > 0 and (c.on and TEXT or MUTED) or MUTED,
			{ Position = UDim2.fromOffset(36, 5), Size = UDim2.new(1, -44, 0, 16) })
		label(row, c.detail, 10, MUTED,
			{ Position = UDim2.fromOffset(36, 23), Size = UDim2.new(1, -44, 0, 14), TextWrapped = true })

		-- dim rows with nothing to do
		if n == 0 then row.BackgroundTransparency = 0.45 end
	end

	if #loose > 0 then
		order += 1
		local row = Instance.new("Frame")
		row.Size = UDim2.new(1, 0, 0, 34)
		row.BackgroundColor3 = INK
		row.BorderSizePixel = 0
		row.LayoutOrder = order
		row.Parent = list
		corner(row, 6)
		table.insert(rows, row)
		label(row, string.format("%d loose in Workspace", #loose), 12, WARN,
			{ Position = UDim2.fromOffset(10, 3), Size = UDim2.new(1, -16, 0, 15) })
		label(row, "Easy to publish by accident. Use the move button below.", 10, MUTED,
			{ Position = UDim2.fromOffset(10, 18), Size = UDim2.new(1, -16, 0, 14) })
	end
end

local function doScan(useSelection)
	lastUsedSelection = useSelection and true or false
	roots = {}
	if useSelection then
		roots = Selection:Get()
		if #roots == 0 then
			setNote("Nothing selected. Select your import batch, or scan Workspace.", WARN)
			return
		end
	else
		roots = workspace:GetChildren()
	end

	local parts, models, guarded
	found, loose, parts, models, guarded = scan(roots)

	local total = 0
	for _, c in ipairs(CHECKS) do total += #(found[c.key] or {}) end

	summary.Text = string.format("%d part%s, %d model%s  -  %d problem%s found",
		parts, parts == 1 and "" or "s", models, models == 1 and "" or "s",
		total, total == 1 and "" or "s")
	summary.TextColor3 = total > 0 and WARN or GOOD
	render()
	local guardNote = guarded > 0
		and string.format(" %d structural part%s left alone (spawns, floors, seats).", guarded, guarded == 1 and "" or "s")
		or ""
	setNote((total == 0 and "Nothing to fix." or "Tick what you want changed, then Fix.") .. guardNote)
end

scanSel.MouseButton1Click:Connect(function() doScan(true) end)
scanAll.MouseButton1Click:Connect(function() doScan(false) end)

-- ============================================================ fixing

local function folderIn(parent)
	local f = parent:FindFirstChild("Imports")
	if not f then
		f = Instance.new("Folder")
		f.Name = "Imports"
		f.Parent = parent
	end
	return f
end

-- Model:ScaleTo is ABSOLUTE, not relative. Multiplying by the current scale is
-- the difference between "make this 30 studs tall" and "make this 30x bigger".
local function scaleToHeight(x, target)
	if x:IsA("Model") then
		local _, size = x:GetBoundingBox()
		if size.Y <= 0 then return false end
		x:ScaleTo(x:GetScale() * (target / size.Y))
		return true
	elseif x:IsA("BasePart") then
		if x.Size.Y <= 0 then return false end
		local want = x.Size * (target / x.Size.Y)
		-- Roblox clamps a part to 0.05..2048 per axis. Scaling blindly would let the
		-- clamp change the proportions instead of the size, which looks like the tool
		-- mangled the mesh.
		if math.max(want.X, want.Y, want.Z) > 2048 or math.min(want.X, want.Y, want.Z) < 0.05 then
			return false
		end
		x.Size = want
		return true
	end
	return false
end

fixBtn.MouseButton1Click:Connect(function()
	if #roots == 0 then
		setNote("Scan first.", WARN)
		return
	end

	local target = tonumber(heightBox.Text)
	if heightBox.Text ~= "" and (not target or target <= 0) then
		setNote("Height must be a positive number, or blank.", WARN)
		return
	end

	local id = ChangeHistoryService:TryBeginRecording("BetterImports fix")
	if not id then
		setNote("Studio refused a history recording. Try again.", WARN)
		return
	end

	local counts, failed = {}, 0

	for _, c in ipairs(CHECKS) do
		if c.on then
			local n = 0
			for _, x in ipairs(found[c.key] or {}) do
				if x.Parent then
					local ok = pcall(c.fix, x)
					if ok then n += 1 else failed += 1 end
				end
			end
			if n > 0 then counts[c.label] = n end
		end
	end

	if target then
		local n = 0
		for _, r in ipairs(roots) do
			if r.Parent then
				local ok, did = pcall(scaleToHeight, r, target)
				if ok and did then n += 1 end
			end
		end
		if n > 0 then counts[string.format("Scaled to %.4gst", target)] = n end
	end

	if moveTo ~= "none" then
		local dest = folderIn(moveTo == "ServerStorage" and ServerStorage or ReplicatedStorage)
		local n = 0
		for _, r in ipairs(roots) do
			if r.Parent == workspace then
				r.Parent = dest
				n += 1
			end
		end
		if n > 0 then counts["Moved out of Workspace"] = n end
	end

	ChangeHistoryService:FinishRecording(id, Enum.FinishRecordingOperation.Commit)

	local parts = {}
	for k, v in pairs(counts) do table.insert(parts, string.format("%s %d", k, v)) end
	table.sort(parts)
	if #parts == 0 then
		setNote("Nothing matched the ticked checks.", MUTED)
	else
		setNote(table.concat(parts, "  -  ") .. (failed > 0 and string.format("  (%d failed)", failed) or "")
			.. "   Ctrl+Z undoes all of it.", GOOD)
	end

	-- Re-scan the SAME scope. This used to infer it by comparing roots[1] to
	-- workspace:GetChildren()[1], which flipped to the wrong scope the moment a
	-- fix moved things out of Workspace (and misfired on an empty Workspace).
	doScan(lastUsedSelection)
end)

btn.Click:Connect(function()
	gui.Enabled = not gui.Enabled
	if gui.Enabled and #roots == 0 then doScan(#Selection:Get() > 0) end
end)

gui:GetPropertyChangedSignal("Enabled"):Connect(function()
	btn:SetActive(gui.Enabled)
end)
