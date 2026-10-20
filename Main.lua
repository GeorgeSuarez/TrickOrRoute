-- Main.lua - TrickOrRoute
-- A guided, efficient tour of every Hallow's End candy bucket.
--
-- The route is ordered by travel phase (portal hubs first), with each region
-- sequenced to avoid backtracking. Completion is tracked from the server
-- (each bucket is a one-time quest), so progress is per-character and exact.
--
-- Data source: RouteData.lua (see header comment there).

local ADDON_NAME, TR = ...

local C_QuestLog = _G.C_QuestLog
local C_Map = _G.C_Map
local C_SuperTrack = _G.C_SuperTrack
local C_Timer = _G.C_Timer
local HANDFUL_OF_TREATS_ITEM_ID = 37586 -- item granted by every candy bucket
local TRICKY_TREAT_ITEM_ID = 33226
local AUTO_ADVANCE_RADIUS = 40 -- yards

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

local function defaults()
	return {
		skips = {},        -- [questID] = true, manually skipped stops
		autoAdvance = true,
		useTomTom = false, -- prefer TomTom waypoints when available
		pointer = 1,
		minimapAngle = 220,
	}
end

local function EnsureDB()
	if type(TrickOrRouteCharDB) ~= "table" then
		TrickOrRouteCharDB = defaults()
	end
	local d = defaults()
	for k, v in pairs(d) do
		if TrickOrRouteCharDB[k] == nil then
			TrickOrRouteCharDB[k] = v
		end
	end
	if type(TrickOrRouteCharDB.skips) ~= "table" then
		TrickOrRouteCharDB.skips = {}
	end
	return TrickOrRouteCharDB
end

TR.db = EnsureDB()

--------------------------------------------------------------------------------
-- Route building
--------------------------------------------------------------------------------

function TR:MySide()
	local faction = UnitFactionGroup("player")
	if faction == "Alliance" then
		return 1
	elseif faction == "Horde" then
		return 2
	end
	return 3
end

-- Flatten region data into one ordered list, filtered by faction.
function TR:BuildRoute()
	local side = TR:MySide()
	local route = {}
	local regions = TrickOrRouteData and TrickOrRouteData.regions or {}
	for _, region in ipairs(regions) do
		for _, stop in ipairs(region.stops) do
			if stop.side == 3 or stop.side == side then
				local entry = {}
				for k, v in pairs(stop) do entry[k] = v end
				entry.regionKey = region.key
				entry.regionName = region.name
				entry.hint = region.hint
				route[#route + 1] = entry
			end
		end
	end
	TR.route = route
	TR.pointer = math.max(1, math.min(EnsureDB().pointer or 1, #route))
	TR:RefreshCurrent()
	return route
end

function TR:IsDone(stop)
	if not stop then return false end
	if TR.db.skips[stop.q] then return true end
	if C_QuestLog.IsQuestFlaggedCompleted then
		local ok, done = pcall(C_QuestLog.IsQuestFlaggedCompleted, stop.q)
		if ok and done then return true end
	end
	return false
end

-- First incomplete stop at or after index i (wraps around).
function TR:FirstIncomplete(i)
	local route = TR.route
	if #route == 0 then return nil end
	i = i or 1
	for step = 0, #route - 1 do
		local idx = ((i - 1 + step) % #route) + 1
		if not TR:IsDone(route[idx]) then
			return idx
		end
	end
	return nil -- all done!
end

function TR:CurrentStop()
	return TR.route and TR.route[TR.pointer] or nil
end

function TR:RefreshCurrent()
	if TR:IsDone(TR:CurrentStop()) then
		local idx = TR:FirstIncomplete(TR.pointer)
		if idx then TR.pointer = idx end
	end
end

function TR:Counts()
	local done, total = 0, #TR.route
	for _, stop in ipairs(TR.route) do
		if TR:IsDone(stop) then done = done + 1 end
	end
	return done, total
end

--------------------------------------------------------------------------------
-- Travel helpers
--------------------------------------------------------------------------------

local function GetStopWorldPos(map, x, y)
	local pos = C_Map.GetWorldPosFromMapPos(map, { x = x / 100, y = y / 100 })
	-- Some API revisions return (pos, mapID); be defensive.
	if type(pos) == "table" and pos.x and pos.y then
		return pos.x, pos.y
	end
	return nil
end

-- Distance in yards between the player and a stop, or nil if unknown.
function TR:Distance(stop)
	local bestMap = C_Map.GetBestMapForUnit("player")
	if not bestMap then return nil end
	local pPos = C_Map.GetPlayerMapPosition(bestMap, "player")
	if not pPos or (pPos.x == 0 and pPos.y == 0) then return nil end
	local px, py = GetStopWorldPos(bestMap, pPos.x * 100, pPos.y * 100)
	if not px then return nil end
	local sx, sy = GetStopWorldPos(stop.map, stop.x, stop.y)
	if not sx then return nil end
	local dx, dy = px - sx, py - sy
	return math.sqrt(dx * dx + dy * dy)
end

-- Set the game's waypoint (and TomTom's arrow if configured) on a stop.
function TR:SetWaypoint(stop, silent)
	if not stop then return end
	local title = string.format("%s (%s)", stop.label, stop.zone or "")
	local tomTom = _G.TomTom
	if tomTom and TR.db.useTomTom and tomTom.AddWaypoint then
		tomTom:AddWaypoint(stop.map, stop.x / 100, stop.y / 100, {
			title = title,
			from = ADDON_NAME,
			minimap = true,
			world = true,
			persistent = false,
		})
		if not silent then
			print(ADDON_NAME, "- TomTom waypoint set:", title)
		end
		return
	end
	if C_Map.CanSetUserWaypoint(stop.map) then
		C_Map.SetUserWaypoint({ uiMapID = stop.map, position = { x = stop.x / 100, y = stop.y / 100 } })
		C_SuperTrack.SetSuperTrackedUserWaypoint(true)
		if not silent then
			print(ADDON_NAME, "- Waypoint set:", title)
		end
	else
		print(ADDON_NAME, "- This area does not support user waypoints; opening the map instead.")
		TR:OpenMap(stop)
	end
end

function TR:OpenMap(stop)
	if not stop then return end
	if _G.WorldMapFrame then
		_G.WorldMapFrame:Show()
		_G.WorldMapFrame:SetMapID(stop.map)
	end
end

-- For the Aldor/Scryer stops the usable inn depends on Shattrath reputation.
function TR:StandingWith(factionID)
	local rep = C_Reputation and C_Reputation.GetFactionDataByID and C_Reputation.GetFactionDataByID(factionID)
	if rep and rep.standing then
		return rep.standing -- 1..8 (Hated..Exalted); 4 = Neutral
	end
	return nil
end

--------------------------------------------------------------------------------
-- Progressing the tour
--------------------------------------------------------------------------------

local function PlayDoneSound()
	pcall(PlaySound, SOUNDKIT and SOUNDKIT.IG_QUEST_LIST_COMPLETE or 895)
end

-- Mark the pointed stop complete and move on to the next incomplete stop.
function TR:CompleteCurrent()
	local stop = TR:CurrentStop()
	if not stop or TR:IsDone(stop) then return end
	PlayDoneSound()
	TR:AdvancePointer(1, true)
	TR:RefreshUI()
end

function TR:SkipCurrent()
	local stop = TR:CurrentStop()
	if not stop then return end
	TR.db.skips[stop.q] = true
	TR:AdvancePointer(1, true)
	TR:RefreshUI()
end

-- dir = 1 (next) or -1 (previous); snap = jump to the next incomplete stop.
function TR:AdvancePointer(dir, snap)
	local route = TR.route
	if #route == 0 then return end
	if snap then
		local target = nil
		local start = TR.pointer
		for step = 1, #route do
			local idx = ((start - 1 + step) % #route) + 1
			if not TR:IsDone(route[idx]) then
				target = idx
				break
			end
		end
		TR.pointer = target or TR.pointer
	else
		TR.pointer = ((TR.pointer - 1 + dir) % #route) + 1
	end
	TR.db.pointer = TR.pointer
	TR:RefreshUI()
end

function TR:JumpToRegion(regionKey)
	local route = TR.route
	for step = 0, #route - 1 do
		local idx = ((TR.pointer - 1 + step) % #route) + 1
		if route[idx].regionKey == regionKey and not TR:IsDone(route[idx]) then
			TR.pointer = idx
			TR.db.pointer = idx
			TR:RefreshUI()
			return
		end
	end
	-- region fully done: show its first stop anyway
	for idx, stop in ipairs(route) do
		if stop.regionKey == regionKey then
			TR.pointer = idx
			TR:RefreshUI()
			return
		end
	end
end

-- Auto-advance when the player loots a bucket or gets close.
function TR:OnLoot(msg)
	if not TR.db.autoAdvance then return end
	if not msg or not msg:find("item:" .. HANDFUL_OF_TREATS_ITEM_ID) then return end
	local stop = TR:CurrentStop()
	if not stop or TR:IsDone(stop) then return end
	local dist = TR:Distance(stop)
	if dist and dist < 60 then
		TR:CompleteCurrent()
	end
end

local ticker
local function StartTicker()
	if ticker then ticker:Cancel() end
	ticker = C_Timer.NewTicker(1.0, function()
		if not TR.db.autoAdvance then return end
		local stop = TR:CurrentStop()
		if not stop or TR:IsDone(stop) then return end
		local dist = TR:Distance(stop)
		if dist and dist < AUTO_ADVANCE_RADIUS then
			TR:CompleteCurrent()
		end
	end)
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

local function HandleCommand(msg)
	local cmd = (msg or ""):lower():gsub("^%s*(.-)%s*$", "%1")
	if cmd == "" or cmd == "toggle" then
		TR:ToggleUI()
	elseif cmd == "next" then
		TR:AdvancePointer(1, false)
	elseif cmd == "prev" or cmd == "back" then
		TR:AdvancePointer(-1, false)
	elseif cmd == "wp" or cmd == "waypoint" then
		TR:SetWaypoint(TR:CurrentStop())
	elseif cmd == "map" then
		TR:OpenMap(TR:CurrentStop())
	elseif cmd == "skip" then
		TR:SkipCurrent()
	elseif cmd == "auto" then
		TR.db.autoAdvance = not TR.db.autoAdvance
		print(ADDON_NAME, "- auto-advance:", TR.db.autoAdvance and "ON" or "OFF")
		TR:RefreshUI()
	elseif cmd == "tomtom" then
		TR.db.useTomTom = not TR.db.useTomTom
		print(ADDON_NAME, "- prefer TomTom:", TR.db.useTomTom and "ON" or "OFF")
		TR:RefreshUI()
	elseif cmd == "list" then
		TR:PrintRemaining()
	elseif cmd == "unskip" then
		wipe(TR.db.skips)
		print(ADDON_NAME, "- all manual skips cleared.")
		TR:RefreshUI()
	elseif cmd == "reset" then
		TrickOrRouteCharDB = nil
		TR.db = EnsureDB()
		TR:BuildRoute()
		TR:RefreshUI()
		print(ADDON_NAME, "- reset.")
	else
		print("|cffff9c1fTrickOrRoute|r commands: (no arg = toggle UI), next, prev, wp, map, skip, auto, tomtom, list, unskip, reset")
	end
end

SLASH_TRICKORROUTE1 = "/trickorroute"
SLASH_TRICKORROUTE2 = "/tor"
SlashCmdList["TRICKORROUTE"] = HandleCommand

function TR:PrintRemaining()
	print("|cffff9c1fTrickOrRoute|r - remaining stops as TomTom /way lines:")
	local n = 0
	for _, stop in ipairs(TR.route) do
		if not TR:IsDone(stop) then
			n = n + 1
			print(string.format("/way #%d %.2f %.2f %s", stop.map, stop.x, stop.y, stop.label))
		end
	end
	print(string.format("%d stops. Use the Paste addon to import into TomTom.", n))
end

--------------------------------------------------------------------------------
-- UI
--------------------------------------------------------------------------------

local ui          -- main frame (set by BuildUI)
local listRows = {} -- pooled row frames for the list view

local ORANGE = "|cffff9c1f%s|r"
local function Colored(text)
	return string.format(ORANGE, text)
end

local function CreateCheckbox(parent, labelText, get, set)
	local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
	local fs = rawget(cb, "Text") or cb.text
	if fs and fs.SetText then
		fs:SetText(labelText)
		fs:SetFontObject("GameFontHighlightSmall")
	end
	function cb:Refresh()
		self:SetChecked(get())
	end
	cb:SetScript("OnClick", function(self)
		set(self:GetChecked())
	end)
	return cb
end

local function RepositionMinimapButton(mb)
	local a = TR.db.minimapAngle or 220
	local x, y = math.cos(math.rad(a)), math.sin(math.rad(a))
	local r = (Minimap:GetWidth() / 2) + 8
	mb:ClearAllPoints()
	mb:SetPoint("CENTER", Minimap, "CENTER", x * r, y * r)
end

local function MakeMinimapButton()
	local mb = CreateFrame("Button", "TrickOrRouteMinimapButton", Minimap)
	mb:SetFrameStrata("MEDIUM")
	mb:SetSize(31, 31)
	mb:RegisterForClicks("AnyUp")
	mb:EnableMouse(true)
	mb:RegisterForDrag("LeftButton")
	local icon = mb:CreateTexture(nil, "BACKGROUND")
	icon:SetTexture("Interface\\Icons\\Achievement_Halloween_Candy_01")
	icon:SetAllPoints()
	local border = mb:CreateTexture(nil, "OVERLAY")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	border:SetAllPoints()

	mb:SetScript("OnClick", function() TR:ToggleUI() end)
	mb:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
		GameTooltip:SetText("TrickOrRoute")
		local done, total = TR:Counts()
		GameTooltip:AddLine(string.format("%d / %d buckets visited", done, total), 1, 1, 1)
		GameTooltip:AddLine("Click to open the route", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	mb:SetScript("OnLeave", function() GameTooltip:Hide() end)
	mb:SetScript("OnDragStart", function(self)
		self:LockHighlight()
		self:SetScript("OnUpdate", function(self2)
			local mx, my = Minimap:GetCenter()
			local px, py = GetCursorPosition()
			local scale = Minimap:GetEffectiveScale()
			px, py = px / scale, py / scale
			TR.db.minimapAngle = math.deg(math.atan2(px - mx, py - my)) % 360
			RepositionMinimapButton(self2)
		end)
	end)
	mb:SetScript("OnDragStop", function(self)
		self:UnlockHighlight()
		self:SetScript("OnUpdate", nil)
	end)
	RepositionMinimapButton(mb)
	return mb
end

function TR:IndexOfStop(stop)
	for i, s in ipairs(TR.route) do
		if s == stop then return i end
	end
	return nil
end

local function BuildList()
	local content = ui.listScroll:GetScrollChild()
	local y = -4
	local lastRegionKey = nil
	local current = TR:CurrentStop()
	for _, stop in ipairs(TR.route) do
		local frame
		if #listRows > 0 then
			frame = table.remove(listRows)
		else
			frame = CreateFrame("Button", nil, content)
			frame.fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			frame.fs:SetPoint("LEFT")
			frame.fs:SetPoint("RIGHT", frame, "RIGHT", -4, 0)
			frame.fs:SetJustifyH("LEFT")
		end
		frame:SetHeight(stop.regionKey ~= lastRegionKey and 22 or 18)
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
		frame:SetPoint("RIGHT", content, "RIGHT", -6, y)

		if stop.regionKey ~= lastRegionKey then
			lastRegionKey = stop.regionKey
			frame:SetScript("OnClick", nil)
			frame:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(stop.hint or "", 0.8, 0.8, 0.8, true)
				GameTooltip:Show()
			end)
			frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
			frame.fs:SetFontObject("GameFontNormalSmall")
			frame.fs:SetText(Colored(stop.regionName))
		else
			local done = TR:IsDone(stop)
			local isCurrent = current == stop
			local marker = done and "|cff5aff5a[v]|r" or (isCurrent and Colored(">") or "|cff808080-|r")
			local colorTag = done and "|cff606060%s|r" or (isCurrent and "|cffffff00%s|r" or "|cffffffff%s|r")
			frame.fs:SetFontObject("GameFontHighlightSmall")
			frame.fs:SetText(string.format("%s %s", marker,
				string.format(colorTag, string.format("%s - %s", stop.label, stop.zone or ""))))
			frame:SetScript("OnClick", function()
				TR.pointer = TR:IndexOfStop(stop) or TR.pointer
				TR.db.pointer = TR.pointer
				TR:RefreshUI()
			end)
			frame:SetScript("OnEnter", function(self)
				self.fs:SetAlpha(0.7)
				if stop.note then
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:AddLine(stop.note, 1, 0.8, 0.4, true)
					GameTooltip:Show()
				end
			end)
			frame:SetScript("OnLeave", function(self)
				self.fs:SetAlpha(1)
				GameTooltip:Hide()
			end)
		end

		frame:Show()
		y = y - frame:GetHeight()
	end

	content:SetHeight(math.abs(y) + 8)
end

local function BuildUI()
	if ui then return end

	ui = CreateFrame("Frame", "TrickOrRouteFrame", UIParent, "BackdropTemplate")
	ui:SetSize(390, 470)
	ui:SetPoint("CENTER")
	ui:SetMovable(true)
	ui:EnableMouse(true)
	ui:RegisterForDrag("LeftButton")
	ui:SetScript("OnDragStart", ui.StartMoving)
	ui:SetScript("OnDragStop", ui.StopMovingOrSizing)
	ui:SetClampedToScreen(true)
	ui:SetFrameStrata("HIGH")
	ui:SetBackdrop({
		bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
		tile = true, tileSize = 32, edgeSize = 32,
		insets = { left = 8, right = 8, top = 8, bottom = 8 },
	})
	tinsert(UISpecialFrames, "TrickOrRouteFrame") -- ESC closes

	local title = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -14)
	title:SetText(Colored("TrickOrRoute"))

	local close = CreateFrame("Button", nil, ui, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -6, -6)

	local progress = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	progress:SetPoint("TOP", 0, -38)
	ui.progress = progress

	-- region jump buttons
	local regionButtons = {}
	local shortNames = {
		ek = "EK", outland = "OL", kalimdor = "KAL", cata = "D/V",
		northrend = "NR", pandaria = "PA", draenor = "DR", brokenisles = "BI",
		dragonisles = "DI", khazalgar = "KA", midnight = "MD",
	}
	local regions = TrickOrRouteData and TrickOrRouteData.regions or {}
	for i, region in ipairs(regions) do
		local b = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
		b:SetSize(50, 20)
		b:SetText(shortNames[region.key] or region.key)
		b:SetScript("OnClick", function() TR:JumpToRegion(region.key) end)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(region.name, 1, 0.8, 0.4)
			GameTooltip:AddLine(region.hint, 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
		b.regionKey = region.key
		regionButtons[i] = b
		if i <= 6 then
			b:SetPoint("TOPLEFT", 18 + (i - 1) * 60, -60)
		else
			b:SetPoint("TOPLEFT", 18 + (i - 7) * 60, -84)
		end
	end
	ui.regionButtons = regionButtons

	-- stop card
	local card = CreateFrame("Frame", nil, ui, "BackdropTemplate")
	card:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	card:SetBackdropColor(0, 0, 0, 0.55)
	card:SetPoint("TOPLEFT", 18, -116)
	card:SetPoint("RIGHT", -18, 0)
	card:SetHeight(96)
	ui.card = card

	local stopName = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	stopName:SetPoint("TOPLEFT", 10, -8)
	stopName:SetPoint("RIGHT", -70, 0)
	stopName:SetJustifyH("LEFT")
	ui.stopName = stopName

	local stopStatus = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	stopStatus:SetPoint("TOPRIGHT", -10, -10)
	ui.stopStatus = stopStatus

	local stopInfo = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	stopInfo:SetPoint("TOPLEFT", 10, -36)
	ui.stopInfo = stopInfo

	local stopNote = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	stopNote:SetPoint("TOPLEFT", 10, -58)
	stopNote:SetPoint("RIGHT", -10, 0)
	stopNote:SetJustifyH("LEFT")
	stopNote:SetWordWrap(true)
	ui.stopNote = stopNote

	-- buttons
	local function Btn(text, width, anchor, relX, relY)
		local b = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
		b:SetSize(width, 26)
		b:SetText(text)
		b:SetPoint(anchor, relX, relY)
		return b
	end

	local prev = Btn("< Prev", 84, "TOPLEFT", 18, -222)
	prev:SetScript("OnClick", function() TR:AdvancePointer(-1, false) end)

	local waypoint = Btn("Set Waypoint", 130, "TOP", 0, -222)
	waypoint:SetScript("OnClick", function() TR:SetWaypoint(TR:CurrentStop()) end)

	local nextB = Btn("Next >", 84, "TOPRIGHT", -18, -222)
	nextB:SetScript("OnClick", function() TR:AdvancePointer(1, false) end)

	local openMap = Btn("Open Map", 130, "TOPLEFT", 18, -254)
	openMap:SetScript("OnClick", function() TR:OpenMap(TR:CurrentStop()) end)

	local skip = Btn("Skip Stop", 130, "TOPRIGHT", -18, -254)
	skip:SetScript("OnClick", function() TR:SkipCurrent() end)

	local dump = Btn("Dump remaining as /way lines", 260, "TOP", 0, -286)
	dump:SetScript("OnClick", function() TR:PrintRemaining() end)

	-- region hint
	local hint = ui:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	hint:SetPoint("TOPLEFT", 18, -320)
	hint:SetPoint("RIGHT", -18, 0)
	hint:SetJustifyH("LEFT")
	hint:SetWordWrap(true)
	ui.hint = hint

	-- options + footer
	local autoCB = CreateCheckbox(ui, "Auto-advance nearby", function() return TR.db.autoAdvance end,
		function(v) TR.db.autoAdvance = v end)
	autoCB:SetPoint("BOTTOMLEFT", 14, 52)
	ui.autoCB = autoCB

	local tomCB = CreateCheckbox(ui, "Use TomTom", function() return TR.db.useTomTom end,
		function(v) TR.db.useTomTom = v end)
	tomCB:SetPoint("BOTTOMRIGHT", -14, 52)
	ui.tomCB = tomCB

	local footer = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footer:SetPoint("BOTTOMLEFT", 18, 14)
	ui.footer = footer

	-- list view
	local listScroll = CreateFrame("ScrollFrame", nil, ui, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", 18, -116)
	listScroll:SetPoint("BOTTOMRIGHT", -18, 76)
	local content = CreateFrame("Frame", nil, listScroll)
	content:SetWidth(340)
	listScroll:SetScrollChild(content)
	ui.listScroll = listScroll
	ui.listScroll:Hide()

	local listButton = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
	listButton:SetSize(150, 22)
	listButton:SetPoint("BOTTOMRIGHT", -18, 78)
	listButton:SetText("Show full list")
	ui.listButton = listButton
	listButton:SetScript("OnClick", function(self)
		ui.showList = not ui.showList
		self:SetText(ui.showList and "Show route" or "Show full list")
		TR:RefreshUI()
	end)

	ui:Hide()
	TR.ui = ui
end

function TR:RefreshUI()
	if not ui or not ui:IsShown() then return end
	local done, total = TR:Counts()
	ui.progress:SetText(string.format("%d / %d buckets visited", done, total))

	local showList = ui.showList
	ui.listScroll:SetShown(showList)
	ui.card:SetShown(not showList)

	if showList then
		BuildList()
	else
		local stop = TR:CurrentStop()
		if stop then
			ui.stopName:SetText(stop.label or "Candy Bucket")
			ui.stopInfo:SetText(string.format("%s  (%.1f, %.1f)", stop.zone or "?", stop.x, stop.y))
			ui.stopStatus:SetText(TR:IsDone(stop) and "|cff5aff5aDONE|r" or "")
			ui.stopNote:SetText(stop.note or "")
			ui.hint:SetText(stop.hint or "")
		else
			ui.stopName:SetText("All done!")
			ui.stopInfo:SetText("")
			ui.stopStatus:SetText("")
			ui.stopNote:SetText("Every bucket on the route has been visited. Happy Hallow's End!")
			ui.hint:SetText("")
		end
		local treats = GetItemCount(TRICKY_TREAT_ITEM_ID) or 0
		ui.footer:SetText(string.format("Tricky Treats: %d%s", treats,
			TR.db.autoAdvance and "" or "   (auto-advance off)"))
	end

	-- region buttons: dim fully-visited regions
	local regions = TrickOrRouteData and TrickOrRouteData.regions or {}
	for i, region in ipairs(regions) do
		local b = ui.regionButtons[i]
		if b then
			local anyLeft = false
			for _, s in ipairs(TR.route) do
				if s.regionKey == region.key and not TR:IsDone(s) then
					anyLeft = true
					break
				end
			end
			b:SetAlpha(anyLeft and 1 or 0.35)
		end
	end

	if ui.autoCB and ui.autoCB.Refresh then ui.autoCB:Refresh() end
	if ui.tomCB and ui.tomCB.Refresh then ui.tomCB:Refresh() end
end

function TR:ToggleUI()
	if not ui then return end
	if ui:IsShown() then
		ui:Hide()
	else
		ui:Show()
		TR:RefreshUI()
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")

eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_ENTERING_WORLD" then
		TR:BuildRoute()
		BuildUI()
		TR.minimapButton = MakeMinimapButton()
		StartTicker()

		local t = date("*t")
		local active = (t.month == 10 and t.day >= 18) or (t.month == 11 and t.day <= 1)
		if active then
			print(Colored("TrickOrRoute"), "- Hallow's End is live! Type |cffffff00/tor|r for your candy-bucket route.")
		end
	elseif event == "QUEST_TURNED_IN" then
		local questID = ...
		local stop = TR:CurrentStop()
		if TR.db.autoAdvance and stop and questID == stop.q then
			TR:CompleteCurrent()
		end
	elseif event == "CHAT_MSG_LOOT" then
		local msg = ...
		TR:OnLoot(msg)
	end
end)
