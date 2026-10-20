-- Main.lua - TrickOrRoute
-- A guided, efficient tour of every Hallow's End candy bucket.
--
-- The route is ordered by travel phase (portal hubs first), with each region
-- sequenced to avoid backtracking. Inside each zone, Pathing.lua reorders the
-- buckets by their shortest path (keeping the zone's entry and exit stop).
-- Completion is tracked from the server (each bucket is a one-time quest), so
-- progress is per-character and exact.
--
-- Data source: RouteData.lua (see header comment there); the search is in
-- Pathing.lua.
--
-- WoW's Lua is 5.1, where unpack and math.atan2 are stdlib (5.3+ renamed them
-- to table.unpack / math.atan); the checker flags them in every dialect, so
-- that one category is disabled for this file.
---@diagnostic disable: deprecated

local ADDON_NAME, TR = ...

local C_QuestLog = C_QuestLog
local C_Map = C_Map
local C_SuperTrack = C_SuperTrack
local C_Timer = C_Timer
local HANDFUL_OF_TREATS_ITEM_ID = 37586 -- item granted by every candy bucket
local TRICKY_TREAT_ITEM_ID = 33226
local AUTO_ADVANCE_RADIUS = 40 -- yards (default for db.autoRadius)

-- The configured auto-advance radius, bounded to something sane.
local function AutoRadius()
	return math.max(0, math.min(200, tonumber(TR.db.autoRadius) or AUTO_ADVANCE_RADIUS))
end

-- Search (Mapzeroth-style): every typed word must appear in the stop's text.
-- Apostrophes fold away (so "zulaman" still matches Zul'Aman) and punctuation
-- becomes spaces; pure string work, safe to define before the UI exists.
local function FoldText(text)
	text = (text or ""):lower()
	text = text:gsub("['\226\128\153]", "") -- apostrophes join, so "zulaman" still matches
	text = text:gsub("[^%w%s]", " ")
	return text
end

local function QueryTokens(text)
	local tokens = {}
	for token in FoldText(text):gmatch("%S+") do
		tokens[#tokens + 1] = token
	end
	return tokens
end

local function StopMatches(stop, tokens)
	if #tokens == 0 then return true end
	local hay = FoldText(table.concat({
		stop.label or "", stop.zone or "", stop.regionName or "", stop.note or "",
	}, " "))
	for _, token in ipairs(tokens) do
		if not hay:find(token, 1, true) then return false end
	end
	return true
end

-- The checklist's active search, from the route window's search box.
local function ActiveQuery()
	return (TR.ui and TR.ui.query) or ""
end



-- Legacy global item functions (GetItemCount, GetItemIcon) were removed in
-- Midnight; fall back to the C_Item equivalents via these helpers.
local function TreatIcon(itemID)
	if C_Item and C_Item.GetItemIconByID then
		local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
		if ok and icon then return tostring(icon) end -- file IDs must be strings in |T escapes
	end
	if GetItemIcon then
		return GetItemIcon(itemID)
	end
	return nil
end

local function TreatCount(itemID)
	if C_Item and C_Item.GetItemCount then
		local ok, count = pcall(C_Item.GetItemCount, itemID, false)
		if ok and count then return count end
	end
	if GetItemCount then
		return GetItemCount(itemID) or 0
	end
	return 0
end

-- Lua 5.1 has math.atan2, 5.x replacements collapse it into math.atan(y, x)
local atan2 = math.atan2 or math.atan

--------------------------------------------------------------------------------
-- Saved variables
--------------------------------------------------------------------------------

-- Settings live in the account-wide table, so every character sees the same
-- theme, scale, HUD layout and toggles. Progress stays per character: candy
-- buckets are one-time quests and a character may be on either faction.
local ACCOUNT_DEFAULTS = {
	autoAdvance = true,
	useTomTom = false, -- prefer TomTom waypoints when available
	optimizeZones = true, -- order each zone's stops by shortest path
	minimapAngle = 220,
	theme = "dark",    -- Classic / Modern Dark / Steel
	showHud = true,    -- compact tracker under the minimap
	showMinimap = true,
	dockMap = false,   -- sit beside the world map when it opens
	scale = 1,         -- window and mini-tracker scale (0.7 - 1.5)
	autoRadius = 40,   -- yards: advance when this close to the bucket
	routeOnMap = true, -- draw the route between stops on the world map
	routeOnMinimap = true, -- and the current leg on the minimap
	savedRoutes = {},  -- [name] = { query = "..." } saved checklist filters
	-- hudPoint (the dragged mini-tracker position) is written on first drag;
	-- it has no default so it stays nil until then.
}

local CHAR_DEFAULTS = {
	skips = {},        -- [questID] = true, manually skipped stops
	pointer = 1,
	collapsed = {},    -- [regionKey] = true, folded region sections in list view
	minimized = false, -- window collapsed to the compact toolbar
}

-- Which table a key belongs to. Everything else falls through to the
-- per-character table (pointer, pointerQ, skips, collapsed, minimized,
-- activeRoute).
local ACCOUNT_KEYS = {}
for key in pairs(ACCOUNT_DEFAULTS) do ACCOUNT_KEYS[key] = true end
ACCOUNT_KEYS.hudPoint = true

local function CopyTable(source)
	local copy = {}
	for key, value in pairs(source) do copy[key] = value end
	return copy
end

local function FillDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if target[key] == nil then
			target[key] = type(value) == "table" and CopyTable(value) or value
		end
	end
end

-- 1.6.0 and earlier kept every setting in the per-character table. Move them
-- once, so upgrading keeps the player's theme, scale, saved routes and toggles.
local function MigrateAccountSettings(account, char)
	for key in pairs(ACCOUNT_KEYS) do
		local old = char[key]
		if old ~= nil then
			if account[key] == nil then
				account[key] = old
			elseif key == "savedRoutes" and type(old) == "table" then
				if type(account[key]) ~= "table" then
					account[key] = old
				else
					for name, route in pairs(old) do
						if account[key][name] == nil then account[key][name] = route end
					end
				end
			end
			char[key] = nil
		end
	end
end

-- Saved variables load after the addon's files, so this must not run at file
-- scope: it is called on ADDON_LOADED, when both tables are guaranteed to be
-- in the global environment. TR.db is a small view over the two tables, so
-- existing reads and writes keep working unchanged.
local function EnsureDB()
	if type(TrickOrRouteAccountDB) ~= "table" then TrickOrRouteAccountDB = {} end
	if type(TrickOrRouteCharDB) ~= "table" then TrickOrRouteCharDB = {} end

	local account, char = TrickOrRouteAccountDB, TrickOrRouteCharDB
	MigrateAccountSettings(account, char)
	FillDefaults(account, ACCOUNT_DEFAULTS)
	FillDefaults(char, CHAR_DEFAULTS)
	if type(account.savedRoutes) ~= "table" then account.savedRoutes = {} end
	if type(char.skips) ~= "table" then char.skips = {} end
	if type(char.collapsed) ~= "table" then char.collapsed = {} end

	TR.account, TR.char = account, char
	TR.db = setmetatable({}, {
		__index = function(_, key)
			if ACCOUNT_KEYS[key] then return account[key] end
			return char[key]
		end,
		__newindex = function(_, key, value)
			if ACCOUNT_KEYS[key] then
				account[key] = value
			else
				char[key] = value
			end
		end,
	})
	return TR.db
end

function TR:LoadSavedVariables()
	if not TR.db then EnsureDB() end
	return TR.db
end

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
	-- A pointer saved before pointerQ existed is an index into the data order.
	-- Keep the bucket it names, not the index, through the reorder below.
	local db = TR.db or EnsureDB()
	local legacy = (not db.pointerQ) and route[db.pointer or 1] or nil

	-- Reorder each contiguous same-map run before resolving the pointer: the
	-- saved pointer may be an index into the optimized order from last session.
	TR:OptimizeZoneRuns()

	local pointer
	if db.pointerQ then
		for i, stop in ipairs(route) do
			if stop.q == db.pointerQ then pointer = i break end
		end
	end
	if not pointer and legacy then
		for i, stop in ipairs(route) do
			if stop.q == legacy.q then pointer = i break end
		end
	end
	if not pointer then
		pointer = math.max(1, math.min(db.pointer or 1, #route))
	end
	TR.pointer = pointer
	TR:SetPointer(pointer)
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
		if idx then TR:SetPointer(idx) end
	end
end

-- Point at a stop and remember it by quest as well as by index: zones are
-- reordered by shortest path, so an index saved by an older route (or older
-- addon version) could name a different bucket next login.
function TR:SetPointer(index)
	if not index then return end
	TR.pointer = index
	TR.db.pointer = index
	local stop = TR.route and TR.route[index]
	TR.db.pointerQ = stop and stop.q or nil
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

-- Convert a 0..1 map point to world coordinates. C_Map.GetWorldPosFromMapPos
-- returns (continentID, worldPosition); some builds have returned the position
-- first, so both shapes are accepted. (The old single-return assumption made
-- every distance nil, which silently disabled proximity auto-advance.)
local function GetWorldPos(map, x, y)
	local point
	if CreateVector2D then
		point = CreateVector2D(x, y)
	else
		point = { x = x, y = y }
	end
	local ok, continent, pos = pcall(C_Map.GetWorldPosFromMapPos, map, point)
	if not ok then return nil end
	if pos and pos.GetXY then
		local wx, wy = pos:GetXY()
		if wx then return wx, wy, continent end
	end
	-- alternate signature: (position, continentID)
	if continent and type(continent) == "table" and continent.GetXY then
		local wx, wy = continent:GetXY()
		if wx then return wx, wy, pos end
	end
	return nil
end

local function GetStopWorldPos(map, x, y)
	return GetWorldPos(map, x / 100, y / 100)
end

-- Yards for one full unit of map x and y (maps aren't square). Map scale never
-- changes, so each map is measured once and remembered.
local mapYards = {}
local function YardsPerUnit(map)
	local known = mapYards[map]
	if known then return known[1], known[2] end
	local ax, ay = GetWorldPos(map, 0.5, 0.5)
	local bx, by = GetWorldPos(map, 0.51, 0.5)
	local cx, cy = GetWorldPos(map, 0.5, 0.51)
	if not (ax and bx and cx) then return nil end
	local xScale = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) / 0.01
	local yScale = math.sqrt((cx - ax) ^ 2 + (cy - ay) ^ 2) / 0.01
	mapYards[map] = { xScale, yScale }
	return xScale, yScale
end

--------------------------------------------------------------------------------
-- Shortest paths inside a zone (Mapzeroth's Pathfinder + MultiRoute, scaled down)
--
-- Mapzeroth prices a tour's stops with one Dijkstra per stop (FindCosts), then
-- orders them exactly for up to 12 stops and nearest-first + 2-opt beyond
-- (MultiRoute.Order). We do the same inside one zone: the buckets are the
-- nodes, the straight line between two of them in world yards is the edge,
-- and every contiguous run of one map in the route is reordered between its
-- existing first and last stops. Keeping the ends fixed is what lets the zone
-- slot back into the portal-to-portal route around it.
--------------------------------------------------------------------------------

local Pathing = TR.Pathing
local zoneMapNames = {}
local zoneWorld = {}

local function ZoneMapName(map)
	local name = zoneMapNames[map]
	if name then return name end
	local info = C_Map.GetMapInfo and C_Map.GetMapInfo(map)
	name = info and info.name
	if name then zoneMapNames[map] = name end
	return name
end

local function ZoneDisplayName(stop)
	return ZoneMapName(stop.map) or (stop.zone ~= "" and stop.zone) or ("Map " .. tostring(stop.map))
end

-- World position of a bucket, cached by its map point. World coordinates never
-- change, and the same bucket appears in both faction routes and in every
-- rebuild, so this is asked once per bucket per session.
local function ZoneStopWorld(stop)
	local key = ("%d:%.4f:%.4f"):format(stop.map, stop.x, stop.y)
	local cached = zoneWorld[key]
	if cached then return cached[1], cached[2], cached[3] end
	local wx, wy, continent = GetStopWorldPos(stop.map, stop.x, stop.y)
	if wx then
		zoneWorld[key] = { wx, wy, continent }
		return wx, wy, continent
	end
	return nil
end

-- Yards between two buckets in the same zone. World coordinates carry the
-- client's own yard scale, so a non-square map compares correctly; the map
-- fallback (map units times YardsPerUnit) is only for a failed projection.
local function ZoneStopYards(a, b)
	local ax, ay, ac = ZoneStopWorld(a)
	local bx, by, bc = ZoneStopWorld(b)
	if ax and bx then
		-- World coordinates are per continent: never measure across them.
		if ac and bc and ac ~= bc then return nil end
		return math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2)
	end
	if a.map ~= b.map then return nil end
	local xs, ys = YardsPerUnit(a.map)
	if not xs then return nil end
	local dx, dy = (a.x - b.x) / 100 * xs, (a.y - b.y) / 100 * ys
	return math.sqrt(dx * dx + dy * dy)
end

-- The all-pairs shortest paths for a zone's buckets: costs[i][j] in yards,
-- plus paths[i][j] (the bucket sequence) when `wantPaths` is set.
local function ZoneCosts(stops, wantPaths)
	local n = #stops
	if n < 2 or not Pathing then return nil end
	local graph = Pathing.CompleteGraph(n, function(i, j)
		local d = ZoneStopYards(stops[i], stops[j])
		return d or Pathing.INF
	end)
	local costs, paths = Pathing.AllPairs(graph, n)
	return costs, n, wantPaths and paths or nil
end

-- The current faction route's buckets grouped by zone map, in route order.
function TR:ZoneGroups()
	local zones, byMap = {}, {}
	for index, stop in ipairs(TR.route or {}) do
		local zone = byMap[stop.map]
		if not zone then
			zone = { key = stop.map, name = ZoneDisplayName(stop), stops = {}, indices = {} }
			byMap[stop.map] = zone
			zones[#zones + 1] = zone
		end
		zone.stops[#zone.stops + 1] = stop
		zone.indices[#zone.indices + 1] = index
	end
	return zones
end

-- Zones matching a typed search (name, map number or region), best first.
function TR:MatchZones(query)
	local tokens = QueryTokens(query)
	local exact = FoldText(query)
	local matches = {}
	for _, zone in ipairs(TR:ZoneGroups()) do
		local hay = FoldText(table.concat({
			zone.name or "", tostring(zone.key),
			zone.stops[1] and zone.stops[1].regionName or "",
		}, " "))
		local ok = true
		for _, token in ipairs(tokens) do
			if not hay:find(token, 1, true) then ok = false break end
		end
		if ok then
			matches[#matches + 1] = zone
			zone.exact = (FoldText(zone.name or "") == exact)
		end
	end
	table.sort(matches, function(a, b)
		if a.exact ~= b.exact then return a.exact end
		if a.name ~= b.name then return a.name < b.name end
		return a.key < b.key
	end)
	return matches
end

-- All-pairs shortest paths plus the shortest visiting order from every bucket.
-- The paths are the shortest way from one bucket to another; the orders are
-- the shortest way through all of them.
function TR:ZoneShortestPaths(zone)
	if not Pathing then return nil end
	local costs, n, paths = ZoneCosts(zone.stops, true)
	if not costs then return nil end
	local orders, bestStart, best = Pathing.OrderFromEach(costs, n)
	-- Only consecutive stops in the route are actually travelled between: a
	-- zone split across several runs doesn't jump between them in place.
	local current = 0
	local indices = zone.indices or {}
	for i = 1, n - 1 do
		if indices[i] and indices[i + 1] and indices[i] + 1 == indices[i + 1] then
			current = current + costs[i][i + 1]
		end
	end
	return {
		costs = costs, paths = paths, n = n, orders = orders,
		bestStart = bestStart, best = best, current = current,
	}
end

-- A stable cache key for one same-map run: faction, map and the quest IDs in
-- their hand-ordered sequence. Route data only changes with an addon update.
function TR:ZoneRunKey(run)
	local parts = { tostring(TR:MySide()), tostring(run[1] and run[1].map or 0) }
	for i = 1, #run do parts[#parts + 1] = tostring(run[i].q) end
	return table.concat(parts, "|")
end

-- Reorder every contiguous same-map run by its shortest path, keeping the run's
-- first and last stop. Runs of one or two buckets have nothing to reorder, and
-- an order that doesn't beat the hand-tuned one is discarded.
function TR:OptimizeZoneRuns()
	if not (TR.db and TR.db.optimizeZones and Pathing and TR.route) then
		TR.zoneStats = nil
		return
	end
	TR.zoneOrderCache = TR.zoneOrderCache or {}
	TR.zoneStats = {}

	local route = TR.route
	local index = 1
	while index <= #route do
		local map = route[index].map
		local last = index
		while last < #route and route[last + 1].map == map do last = last + 1 end
		local n = last - index + 1

		if n >= 3 then
			local run = {}
			for k = index, last do run[#run + 1] = route[k] end
			local key = TR:ZoneRunKey(run)
			local record = TR.zoneOrderCache[key]
			if record and record.order and #record.order ~= n then record = nil end

			if not record then
				local costs = ZoneCosts(run)
				if costs then
					local before, priced = 0, true
					for k = 1, n - 1 do
						local d = costs[k][k + 1]
						if not d or d >= Pathing.INF then priced = false break end
						before = before + d
					end
					if priced then
						record = { before = before, after = before }
						local candidate, total = Pathing.Order(costs, n, 1, n)
						if candidate and #candidate == n and total < before - 1e-9 then
							record.order, record.after = candidate, total
						end
						TR.zoneOrderCache[key] = record
					end
				end
			end

			if record then
				if record.order then
					local original = {}
					for k = 1, n do original[k] = run[k] end
					for k = 1, n do route[index + k - 1] = original[record.order[k]] end
				end

				local stats = TR.zoneStats[map]
				if not stats then
					stats = { name = ZoneDisplayName(run[1]), n = 0, before = 0, after = 0 }
					TR.zoneStats[map] = stats
				end
				stats.n = stats.n + n
				stats.before = stats.before + record.before
				stats.after = stats.after + record.after
			end
		end

		index = last + 1
	end
end

-- /tor paths [zone]: list zones, or show the shortest order from every bucket
-- in one zone next to the order the route currently uses.
function TR:PrintZonePaths(query)
	local prefix = "|cffff9c1fTrickOrRoute|r"
	if not Pathing then
		print(prefix, "pathing module not loaded.")
		return
	end

	if not query or query == "" then
		local list = {}
		for _, zone in ipairs(TR:ZoneGroups()) do
			if #zone.stops >= 2 then list[#list + 1] = zone end
		end
		table.sort(list, function(a, b) return a.name < b.name end)
		print(prefix, ("zones with more than one bucket (%d):"):format(#list))
		for _, zone in ipairs(list) do
			local stats = TR.zoneStats and TR.zoneStats[zone.key]
			local note = ""
			if stats and stats.before > 0 and stats.after < stats.before then
				note = ("  |cff9cff9c-%d yd (%d%%)|r"):format(stats.before - stats.after,
					math.floor((1 - stats.after / stats.before) * 100 + 0.5))
			end
			print(("  %s (map %d) - %d buckets%s"):format(zone.name, zone.key, #zone.stops, note))
		end
		print("  /tor paths <zone> - shortest order from each bucket")
		return
	end

	local matches = TR:MatchZones(query)
	if #matches == 0 then
		print(prefix, ("no zone matches \"%s\" (try /tor paths)."):format(query))
		return
	end
	if #matches > 1 then
		print(prefix, ("\"%s\" matches %d zones; narrow it down:"):format(query, #matches))
		for i = 1, math.min(#matches, 12) do
			local zone = matches[i]
			print(("  %s (map %d, %d buckets)"):format(zone.name, zone.key, #zone.stops))
		end
		return
	end

	local zone = matches[1]
	if #zone.stops < 2 then
		print(prefix, ("%s has only one bucket; there is nothing to order."):format(zone.name))
		return
	end
	local plan = TR:ZoneShortestPaths(zone)
	if not plan then
		print(prefix, ("%s has no reachable pairs to plan."):format(zone.name))
		return
	end

	print(prefix, ("%s - map %d, %d buckets"):format(zone.name, zone.key, plan.n))
	print(("  current in-zone route: %.0f yd"):format(plan.current))
	local _, fixedTotal = Pathing.Order(plan.costs, plan.n, 1, plan.n)
	if fixedTotal and fixedTotal < plan.current - 1e-9 then
		print(("  shortest, keeping the first and last stop: %.0f yd"):format(fixedTotal))
	end
	if plan.bestStart then
		local info = plan.orders[plan.bestStart]
		print(("  shortest from any bucket: %.0f yd, from %s"):format(info.cost, zone.stops[plan.bestStart].label))
		for i, node in ipairs(info.order) do
			local stop = zone.stops[node]
			print(("    %2d. %s (%s)"):format(i, stop.label, stop.zone or "?"))
		end
	end
	print("  from each bucket (shortest open path):")
	for start = 1, plan.n do
		local info = plan.orders[start]
		local label = zone.stops[start].label or "?"
		if info then
			local nextStop = info.order[2] and zone.stops[info.order[2]]
			local via = nextStop and ("  -> " .. (nextStop.label or "?")) or ""
			print(("    %-28s %6.0f yd%s"):format(label:sub(1, 28), info.cost, via))
		else
			print(("    %-28s %s"):format(label:sub(1, 28), "unreachable"))
		end
	end
end

-- Distance in yards between the player and a stop, or nil if unknown.
function TR:Distance(stop)
	local bestMap = C_Map.GetBestMapForUnit("player")
	if not bestMap then return nil end
	local pPos = C_Map.GetPlayerMapPosition(bestMap, "player")
	if not pPos then return nil end
	local px, py = pPos:GetXY()
	if not px or (px == 0 and py == 0) then return nil end
	local wx, wy, continent = GetWorldPos(bestMap, px, py)
	local sx, sy, stopContinent = GetStopWorldPos(stop.map, stop.x, stop.y)
	if not (wx and sx) then return nil end
	-- World coordinates are per continent: never measure across them.
	if continent and stopContinent and continent ~= stopContinent then return nil end
	return math.sqrt((wx - sx) ^ 2 + (wy - sy) ^ 2)
end

-- Turn needed to face a stop, in radians (0 straight ahead, positive left),
-- or nil when the player and the stop aren't on the same map.
function TR:HeadingTo(stop)
	if not stop then return nil end
	local map = C_Map.GetBestMapForUnit("player")
	if not map then return nil end
	local pPos = C_Map.GetPlayerMapPosition(map, "player")
	if not pPos then return nil end
	local px, py = pPos:GetXY()
	if not px or (px == 0 and py == 0) then return nil end

	-- The stop may live on a city map while the player is on the zone map (and
	-- the reverse): carry it across through world coordinates, as Mapzeroth does.
	local tx, ty
	if stop.map == map then
		tx, ty = stop.x / 100, stop.y / 100
	else
		local wx, wy, continent = GetStopWorldPos(stop.map, stop.x, stop.y)
		if not wx or not continent then return nil end
		local point = CreateVector2D and CreateVector2D(wx, wy) or { x = wx, y = wy }
		-- Returns (uiMapID, mapPosition): pcall puts the vector third.
		local ok, _, mapPos = pcall(C_Map.GetMapPosFromWorldPos, continent, point, map)
		if not (ok and mapPos and mapPos.GetXY) then return nil end
		tx, ty = mapPos:GetXY()
		if not tx then return nil end
	end

	local xScale, yScale = YardsPerUnit(map)
	if not xScale then return nil end
	local facing = GetPlayerFacing and GetPlayerFacing()
	if not facing then return nil end
	-- North is up the map, so a target's northness is minus its y difference.
	local east = (tx - px) * xScale
	local north = -(ty - py) * yScale
	local bearing = atan2(-east, north) -- counter-clockwise from north
	local turn = bearing - facing
	turn = (turn + math.pi) % (2 * math.pi) - math.pi
	return turn
end

-- Set the game's waypoint (and TomTom's arrow if configured) on a stop.
function TR:SetWaypoint(stop, silent)
	if not stop then return end
	local title = string.format("%s (%s)", stop.label, stop.zone or "")
	local tomTom = TomTom
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
	-- C_Map.OpenWorldMap (added 11.1.5) opens the map in one secure call, and
	-- works even when the Blizzard_WorldMap frame hasn't been created yet (the
	-- old Show + SetMapID pair silently did nothing in that case).
	if C_Map.OpenWorldMap then
		local ok = pcall(C_Map.OpenWorldMap, stop.map)
		if ok then return end
	end
	local frame = WorldMapFrame
	if frame and frame.SetMapID then
		frame:Show()
		pcall(frame.SetMapID, frame, stop.map)
		return
	end
	print(ADDON_NAME, "- the world map is not available right now; try again.")
end

-- The game's own map-pin link (what the map's "share pin" produces).
-- Clicking it in chat sets that spot as the reader's map waypoint.
local function MapPinLink(stop)
	local map = C_Map
	if not (map and map.CanSetUserWaypointOnMap) then return nil end
	local ok, can = pcall(map.CanSetUserWaypointOnMap, stop.map)
	if not (ok and can) then return nil end
	return ("|cffffff00|Hworldmap:%d:%d:%d|h[%s]|h|r"):format(
		stop.map, math.floor(stop.x * 100 + 0.5), math.floor(stop.y * 100 + 0.5),
		MAP_PIN_HYPERLINK or "Map Pin Location")
end

-- Put a stop into the chat box as "Name - Zone (x, y) [Map Pin Location]",
-- ready for the player to send. Nothing is sent for them.
function TR:ShareStop(stop)
	if not stop then return end
	local line = ("%s - %s (%.1f, %.1f)"):format(stop.label or "Candy Bucket", stop.zone or "?", stop.x, stop.y)
	local pin = MapPinLink(stop)
	if pin then line = line .. " " .. pin end
	local util = ChatFrameUtil
	local insert = (util and util.InsertLink) or ChatEdit_InsertLink
	if insert and insert(line) then return end
	local open = (util and util.OpenChat) or ChatFrame_OpenChat
	if open then open(line) end
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
		-- A saved route's search is a filter: "next" stays inside it.
		local tokens = QueryTokens(ActiveQuery())
		local target = nil
		local start = TR.pointer
		for step = 1, #route do
			local idx = ((start - 1 + step) % #route) + 1
			if not TR:IsDone(route[idx]) and StopMatches(route[idx], tokens) then
				target = idx
				break
			end
		end
		TR.pointer = target or TR.pointer
	else
		TR.pointer = ((TR.pointer - 1 + dir) % #route) + 1
	end
	TR:SetPointer(TR.pointer)
	TR:RefreshUI()
end

function TR:JumpToRegion(regionKey)
	TR.db.collapsed[regionKey] = nil -- reveal the section if the full list is open
	local route = TR.route
	for step = 0, #route - 1 do
		local idx = ((TR.pointer - 1 + step) % #route) + 1
		if route[idx].regionKey == regionKey and not TR:IsDone(route[idx]) then
			TR:SetPointer(idx)
			TR:RefreshUI()
			return
		end
	end
	-- region fully done: show its first stop anyway
	for idx, stop in ipairs(route) do
		if stop.regionKey == regionKey then
			TR:SetPointer(idx)
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
	-- looser than the ticker: loot events can lag a step behind arrival
	if dist and dist < math.max(AutoRadius() * 1.5, 60) then
		TR:CompleteCurrent()
	end
end

local ticker, refreshTicker, arrowTicker
local function StartTicker()
	if ticker then ticker:Cancel() end
	if refreshTicker then refreshTicker:Cancel() end
	if arrowTicker then arrowTicker:Cancel() end
	ticker = C_Timer.NewTicker(1.0, function()
		if not TR.db.autoAdvance then return end
		local stop = TR:CurrentStop()
		if not stop or TR:IsDone(stop) then return end
		local dist = TR:Distance(stop)
		if dist and dist < AutoRadius() then
			TR:CompleteCurrent()
		end
	end)
	-- keep the live distance readout and direction arrow fresh while visible
	refreshTicker = C_Timer.NewTicker(0.5, function()
		if TR.ui and TR.ui:IsShown() and not TR.ui.showList and not TR.ui.minimized then
			TR:UpdateDistance()
		end
		if TR.hud and TR.hud:IsShown() then
			TR:UpdateHud()
		end
	end)
	-- the arrow turns more often than the text needs to
	arrowTicker = C_Timer.NewTicker(0.1, function()
		if (TR.hud and TR.hud:IsShown()) or (TR.ui and TR.ui:IsShown()) then
			TR:UpdateArrows()
		end
	end)
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Forward declarations: the theme and the map-route drawing live in the UI
-- section below, but the slash commands above need them (`/tor theme`,
-- `/tor reset`).
local themeOrder, ApplyTheme, currentTheme, DrawRouteOnMap

local function HandleCommand(msg)
	TR:LoadSavedVariables()
	local raw = (msg or ""):gsub("^%s*(.-)%s*$", "%1")
	local cmd = raw:lower()
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
	elseif cmd == "optimize" then
		TR.db.optimizeZones = not TR.db.optimizeZones
		-- Rebuilding is deterministic, but keep the same bucket current rather
		-- than the same index (the two orders differ).
		local stop = TR:CurrentStop()
		TR.db.pointerQ = stop and stop.q or nil
		TR:BuildRoute()
		TR:RefreshUI()
		print(ADDON_NAME, "- shortest-path zone ordering:", TR.db.optimizeZones and "ON" or "OFF")
	elseif cmd == "paths" or cmd:match("^paths%s") then
		TR:PrintZonePaths(raw:match("^paths%s+(.+)$"))
	elseif cmd == "tomtom" then
		TR.db.useTomTom = not TR.db.useTomTom
		print(ADDON_NAME, "- prefer TomTom:", TR.db.useTomTom and "ON" or "OFF")
		TR:RefreshUI()
	elseif cmd == "theme" then
		local index = 1
		for i, key in ipairs(themeOrder) do
			if key == (TR.db.theme or "dark") then index = i end
		end
		TR.db.theme = themeOrder[(index % #themeOrder) + 1]
		ApplyTheme()
		print(ADDON_NAME, "- theme:", currentTheme.name)
	elseif cmd:match("^scale") then
		local n = tonumber(cmd:match("^scale%s+(%d+%.?%d*)$"))
		if n then
			TR.db.scale = math.max(0.7, math.min(1.5, n))
			TR:ApplyScale()
		end
		print(ADDON_NAME, "- UI scale:", ("%.2f"):format(TR.db.scale or 1),
			"(use /tor scale 0.7 - 1.5)")
	elseif cmd == "hud" then
		TR.db.showHud = not TR.db.showHud
		print(ADDON_NAME, "- mini tracker:", TR.db.showHud and "ON" or "OFF")
		TR:UpdateHud()
	elseif cmd == "minimap" then
		TR.db.showMinimap = not TR.db.showMinimap
		print(ADDON_NAME, "- minimap button:", TR.db.showMinimap and "ON" or "OFF")
		TR:ApplyMinimapVisibility()
	elseif cmd:match("^save") then
		local name = raw:match("^save%s+(.+)$")
		local query = (TR.ui and TR.ui.query) or ""
		if not name or name == "" then
			print(ADDON_NAME, "- usage: /tor save <name> (saves the current checklist search)")
		elseif query == "" then
			print(ADDON_NAME, "- nothing to save: type a search in the checklist first.")
		else
			name = name:sub(1, 32)
			TR.db.savedRoutes[name] = { query = query }
			print(ADDON_NAME, "- saved route \"" .. name .. "\": " .. query)
		end
	elseif cmd:match("^route$") or cmd:match("^route%s") then
		local name = raw:match("^route%s+(.+)$")
		if not name or name == "" then
			print(ADDON_NAME, "- usage: /tor route <name>, /tor routes, /tor unroute")
		elseif (TR.db.savedRoutes or {})[name] then
			TR.db.activeRoute = name
			local query = TR.db.savedRoutes[name].query or ""
			if TR.ui and TR.ui.searchBox then
				TR.ui.showList = true
				TR.ui.searchBox:SetText(query)
				if TR.ui.searchBox.scripts and TR.ui.searchBox.scripts.OnTextChanged then
					TR.ui.searchBox.scripts.OnTextChanged(TR.ui.searchBox)
				end
			end
			TR:RefreshUI()
			print(ADDON_NAME, "- route \"" .. name .. "\": " .. query)
		else
			print(ADDON_NAME, "- no saved route named \"" .. name .. "\" (see /tor routes)")
		end
	elseif cmd == "routes" then
		local names = {}
		for name in pairs(TR.db.savedRoutes or {}) do names[#names + 1] = name end
		table.sort(names)
		if #names == 0 then
			print(ADDON_NAME, "- no saved routes yet; save one with /tor save <name>")
		else
			print(ADDON_NAME, "- saved routes (apply with /tor route <name>, clear with /tor unroute):")
			for _, name in ipairs(names) do
				print("  \"" .. name .. "\" - " .. (TR.db.savedRoutes[name].query or ""))
			end
		end
	elseif cmd == "unroute" then
		TR.db.activeRoute = nil
		if TR.ui and TR.ui.searchBox then
			TR.ui.searchBox:SetText("")
			if TR.ui.searchBox.scripts and TR.ui.searchBox.scripts.OnTextChanged then
				TR.ui.searchBox.scripts.OnTextChanged(TR.ui.searchBox)
			end
		end
		TR:RefreshUI()
		print(ADDON_NAME, "- saved-route filter cleared.")
	elseif cmd == "settings" then
		TR:OpenSettings()
	elseif cmd == "list" then
		TR:PrintRemaining()
	elseif cmd == "unskip" then
		wipe(TR.db.skips)
		print(ADDON_NAME, "- all manual skips cleared.")
		TR:RefreshUI()
	elseif cmd == "reset" then
		TrickOrRouteAccountDB = nil
		TrickOrRouteCharDB = nil
		TR.db = EnsureDB()
		TR:BuildRoute()
		ApplyTheme()
		TR:ApplyScale()
		TR:UpdateHud()
		DrawRouteOnMap()
		TR:RefreshUI()
		print(ADDON_NAME, "- reset.")
	else
		print("|cffff9c1fTrickOrRoute|r commands: (no arg = toggle UI), next, prev, wp, map, skip, auto, optimize, paths [zone], tomtom, hud, minimap, theme, scale, save <name>, route <name>, routes, unroute, settings, list, unskip, reset")
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

--------------------------------------------------------------------------------
-- Mapzeroth-inspired extras: ETA, themes, HUD tracker, map docking
--------------------------------------------------------------------------------

local FLY_SPEED = 21.7 -- yards per second at 310% mount speed (rough)

local function FormatETA(d)
	local seconds = d / FLY_SPEED
	if seconds < 100 then
		return ("~%ds"):format(math.max(1, math.floor(seconds + 0.5)))
	end
	return ("~%dm"):format(math.floor(seconds / 60 + 0.5))
end

local THEMES = {
	classic = {
		name = "Classic",
		bg = "Interface\\DialogFrame\\UI-DialogBox-Background-Dark",
		edge = "Interface\\DialogFrame\\UI-DialogBox-Border",
		edgeSize = 32,
		bgColor = { 1, 1, 1, 1 },
		cardBg = { 0, 0, 0, 0.55 },
		hudBg = { 0.04, 0.04, 0.06, 0.88 },
		accent = { 1, 0.61, 0.12 },
	},
	dark = {
		name = "Modern Dark",
		bg = "Interface\\Buttons\\WHITE8X8",
		edge = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		bgColor = { 0.07, 0.07, 0.09, 0.96 },
		cardBg = { 0.02, 0.02, 0.03, 0.9 },
		hudBg = { 0.05, 0.05, 0.07, 0.9 },
		accent = { 0.95, 0.77, 0.22 },
	},
	steel = {
		name = "Steel",
		bg = "Interface\\Buttons\\WHITE8X8",
		edge = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		bgColor = { 0.16, 0.18, 0.22, 0.97 },
		cardBg = { 0.10, 0.11, 0.14, 0.92 },
		hudBg = { 0.10, 0.11, 0.14, 0.92 },
		accent = { 0.55, 0.80, 1 },
	},
}
themeOrder = { "classic", "dark", "steel" }

currentTheme = THEMES.classic

local function ThemeByName(key)
	return THEMES[key] or THEMES.classic
end

function ApplyTheme()
	currentTheme = ThemeByName(TR.db.theme)
	if ui then
		ui:SetBackdrop({
			bgFile = currentTheme.bg,
			edgeFile = currentTheme.edge,
			tile = (currentTheme.edgeSize > 12), tileSize = 32,
			edgeSize = currentTheme.edgeSize,
			insets = { left = 2, right = 2, top = 2, bottom = 2 },
		})
		ui:SetBackdropColor(unpack(currentTheme.bgColor))
		if ui.card then
			ui.card:SetBackdropColor(unpack(currentTheme.cardBg))
		end
		if ui.titleFont then
			ui.titleFont:SetTextColor(unpack(currentTheme.accent))
		end
		if ui.stopName then
			ui.stopName:SetTextColor(unpack(currentTheme.accent))
		end
	end
	if TR.hud then
		TR.hud:SetBackdropColor(unpack(currentTheme.hudBg))
	end
	if TR.UpdateArrows then TR:UpdateArrows() end
end

-- Sit beside the world map while it is open (opt-in), restore on close.
local function DockToMap(dock)
	local frame = TR.ui
	if not frame or not WorldMapFrame then return end
	if dock then
		if not frame.docked then
			local p, rel, rp, x, y = frame:GetPoint()
			frame.savedPoint = {
				point = p, rel = rel, relPoint = rp, x = x, y = y,
				relName = (rel == Minimap and "minimap") or (rel == UIParent and "uiparent") or nil,
			}
		end
		frame:ClearAllPoints()
		frame:SetPoint("TOPRIGHT", WorldMapFrame, "TOPLEFT", -8, 0)
		frame.docked = true
	elseif frame.docked then
		frame:ClearAllPoints()
		local s = frame.savedPoint
		if s and s.relName == "minimap" then
			frame:SetPoint(s.point, Minimap, s.relPoint, s.x, s.y)
		elseif s and s.relName == "uiparent" then
			frame:SetPoint(s.point, UIParent, s.relPoint, s.x, s.y)
		elseif s and s.rel then
			frame:SetPoint(s.point, s.rel, s.relPoint, s.x, s.y)
		elseif s then
			frame:SetPoint(s.point, UIParent, s.relPoint, s.x, s.y)
		else
			frame:SetPoint("CENTER")
		end
		frame.docked = nil
	end
end

local function HookWorldMap()
	if not WorldMapFrame then
		C_Timer.After(10, HookWorldMap) -- Blizzard_WorldMap may not be loaded yet
		return
	end
	hooksecurefunc(WorldMapFrame, "Show", function()
		if TR.db.dockMap and TR.ui and TR.ui:IsShown() and not TR.ui.minimized then
			DockToMap(true)
		end
	end)
	hooksecurefunc(WorldMapFrame, "Hide", function()
		if TR.db.dockMap and TR.ui and TR.ui.docked then
			DockToMap(false)
		end
	end)
end

-- Compact always-on tracker under the minimap (Mapzeroth-style navigator).
local function MakeHud()
	if TR.hud then return TR.hud end
	local hud = CreateFrame("Button", "TrickOrRouteHUD", UIParent, "BackdropTemplate")
	hud:SetSize(300, 32)
	hud:SetPoint("TOP", Minimap, "BOTTOM", 0, -6)
	hud:SetMovable(true)
	hud:EnableMouse(true)
	hud:RegisterForDrag("LeftButton")
	hud:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	hud:SetClampedToScreen(true)
	hud:SetFrameStrata("HIGH")
	hud:SetScript("OnDragStart", hud.StartMoving)
	hud:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local p, rel, rp, x, y = self:GetPoint()
		TR.db.hudPoint = {
			point = p, relPoint = rp, x = x, y = y,
			rel = (rel == Minimap and "minimap") or "uiparent",
		}
	end)
	hud:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = false, edgeSize = 10,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	hud:SetBackdropColor(0.05, 0.05, 0.07, 0.9)

	-- restore the saved dragged position (frames can't live in saved variables)
	if TR.db.hudPoint then
		local s = TR.db.hudPoint
		if s.rel == "minimap" then
			hud:ClearAllPoints()
			hud:SetPoint(s.point, Minimap, s.relPoint, s.x, s.y)
		else
			hud:ClearAllPoints()
			hud:SetPoint(s.point, UIParent, s.relPoint, s.x, s.y)
		end
	end

	-- direction arrow (Mapzeroth-style navigator): turns to point at the bucket
	local arrow = hud:CreateTexture(nil, "OVERLAY")
	arrow:SetTexture(("Interface\\AddOns\\%s\\Media\\Arrow"):format(ADDON_NAME))
	arrow:SetSize(26, 26)
	arrow:SetPoint("LEFT", hud, "LEFT", 6, 0)

	local icon = hud:CreateTexture(nil, "OVERLAY")
	icon:SetTexture("Interface\\Icons\\Achievement_Halloween_Candy_01")
	icon:SetSize(20, 20)
	icon:SetPoint("LEFT", arrow, "RIGHT", 4, 0)

	local name = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
	name:SetPoint("RIGHT", hud, "RIGHT", -90, 0)
	name:SetJustifyH("LEFT")
	name:SetWordWrap(false)

	local dist = hud:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	dist:SetPoint("RIGHT", hud, "RIGHT", -8, 0)
	dist:SetJustifyH("RIGHT")

	hud.arrow, hud.icon, hud.name, hud.dist = arrow, icon, name, dist

	hud:SetScript("OnClick", function(_, button)
		if button == "RightButton" then
			TR:ToggleUI()
		else
			TR:SetWaypoint(TR:CurrentStop())
		end
	end)
	hud:SetScript("OnEnter", function(self)
		local stop = TR:CurrentStop()
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if stop then
			GameTooltip:AddLine(stop.label or "Candy Bucket", 1, 0.8, 0.4)
			GameTooltip:AddLine(("%s (%.1f, %.1f)"):format(stop.zone or "?", stop.x, stop.y), 1, 1, 1)
			if stop.note then
				GameTooltip:AddLine(stop.note, 1, 0.85, 0.6, true)
			end
			GameTooltip:AddLine("Left-click: set waypoint | Right-click: open window", 0.7, 0.7, 0.7, true)
		else
			GameTooltip:AddLine("All done! Happy Hallow's End!", 0.4, 1, 0.4)
		end
		GameTooltip:Show()
	end)
	hud:SetScript("OnLeave", function() GameTooltip:Hide() end)

	TR.hud = hud
	return hud
end

function TR:UpdateHud()
	local hud = TR.hud
	if not hud then return end
	if not TR.db.showHud then
		hud:Hide()
		return
	end
	hud:SetBackdropColor(unpack(currentTheme.hudBg))
	hud.name:SetTextColor(unpack(currentTheme.accent))
	local stop = TR:CurrentStop()
	if stop then
		hud.name:SetText(("Next: %s"):format(stop.label or "Candy Bucket"))
		local d = TR:Distance(stop)
		if d then
			local color = "|cffffffff"
			if d <= AutoRadius() then
				color = "|cff40ff40"
			elseif d <= 120 then
				color = "|cffffd200"
			end
			local dText = ("%.0f yd"):format(d)
			if d < 2000 then
				dText = dText .. " " .. FormatETA(d)
			end
			hud.dist:SetText(color .. dText .. "|r")
		else
			hud.dist:SetText("")
		end
	else
		hud.name:SetText("All done!")
		hud.dist:SetText("")
	end
	hud:Show()
	TR:UpdateArrows()
end

-- Point the arrow textures at the current stop. Called often while visible, so it
-- only does the cheap facing maths (map-per-yard scales are cached).
function TR:UpdateArrows()
	local stop = TR:CurrentStop()
	local turn = (stop and not TR:IsDone(stop)) and TR:HeadingTo(stop) or nil
	local shown = turn ~= nil
	local d = shown and TR:Distance(stop) or nil

	local function paint(arrow)
		if not arrow then return end
		arrow:SetShown(shown)
		if not shown then return end
		arrow:SetRotation(turn)
		if d and d <= AutoRadius() then
			arrow:SetVertexColor(0.30, 1, 0.35)
		elseif d and d <= 120 then
			arrow:SetVertexColor(1, 0.83, 0.2)
		else
			arrow:SetVertexColor(unpack(currentTheme.accent))
		end
	end

	paint(TR.hud and TR.hud.arrow)
	if TR.ui and TR.ui:IsShown() and not TR.ui.showList and not TR.ui.minimized then
		paint(TR.ui.arrow)
	end
end

function TR:ApplyMinimapVisibility()
	if TR.minimapButton then
		TR.minimapButton:SetShown(TR.db.showMinimap ~= false)
	end
end

-- Window and mini-tracker scale (small screens, big monitors).
function TR:ApplyScale(value)
	if value ~= nil then
		TR.db.scale = value
	end
	local scale = math.max(0.7, math.min(1.5, tonumber(TR.db.scale) or 1))
	TR.db.scale = scale
	if ui then ui:SetScale(scale) end
	if TR.hud then TR.hud:SetScale(scale) end
end

--------------------------------------------------------------------------------
-- Route on the map and minimap (Mapzeroth's RouteLines / MinimapLines, adapted)
--
-- Zone-level world maps draw a dot at each bucket on that map and a line
-- between route-adjacent ones (visited stops fade to grey, the current one is
-- gold). The minimap draws only the current leg (player -> bucket -> next),
-- re-drawn every 0.2s and clipped to the minimap's shape, whatever minimap
-- addon has made of it.
--------------------------------------------------------------------------------

-- Where a stop (map coords 0..100) lands on the map being shown, as 0..1, or nil.
local function ProjectOntoMap(map, x, y, mapID)
	if map == mapID then return x / 100, y / 100 end
	local wx, wy, continent = GetStopWorldPos(map, x, y)
	if not wx or not continent then return nil end
	local point = CreateVector2D and CreateVector2D(wx, wy) or { x = wx, y = wy }
	-- Returns (uiMapID, mapPosition): pcall puts the vector third.
	local ok, _, pos = pcall(C_Map.GetMapPosFromWorldPos, continent, point, mapID)
	if not (ok and pos and pos.GetXY) then return nil end
	local px, py = pos:GetXY()
	if not px then return nil end
	return px, py
end

local mapRoute = { frame = nil, lines = {}, used = 0, hooked = false }

local function MapRouteFrame()
	if mapRoute.frame then return mapRoute.frame end
	local parent = WorldMapFrame and WorldMapFrame.GetCanvas and WorldMapFrame:GetCanvas()
	if not parent then return nil end
	local frame = CreateFrame("Frame", nil, parent)
	frame:SetAllPoints(parent)
	frame:SetFrameLevel((parent:GetFrameLevel() or 1) + 40)
	mapRoute.frame = frame
	return frame
end

local function HideMapRoute()
	for i = 1, mapRoute.used do mapRoute.lines[i]:Hide() end
	mapRoute.used = 0
end

local function MapRun(frame, x1, y1, x2, y2, r, g, b, a, thickness)
	mapRoute.used = mapRoute.used + 1
	local line = mapRoute.lines[mapRoute.used]
	if not line then
		line = frame:CreateLine(nil, "OVERLAY")
		mapRoute.lines[mapRoute.used] = line
	end
	line:Show()
	line:SetThickness(thickness)
	line:SetColorTexture(r, g, b, a)
	line:SetStartPoint("TOPLEFT", frame, x1, -y1)
	line:SetEndPoint("TOPLEFT", frame, x2, -y2)
end

-- A dot: a 1-unit stub with a fat thickness (Line has no round cap).
local function MapDot(frame, x, y, r, g, b, a, thickness)
	MapRun(frame, x, y, x + 0.75, y, r, g, b, a, thickness)
end

local function RouteColor(s)
	if s.current then return 1, 0.82, 0.1 end      -- the stop you are on: gold
	if s.done then return 0.45, 0.45, 0.45 end     -- visited: grey
	return 1, 0.55, 0.12                           -- to visit: ember
end

-- The stops on `mapID` (a zone map), in route order, projected through world
-- coordinates. Only zone/city maps draw: continent and cosmic maps put whole
-- expansions in the same space and would smear the route into spaghetti.
local function StopsOnMap(mapID)
	local info = C_Map.GetMapInfo and C_Map.GetMapInfo(mapID)
	if not info then return nil end
	local zone = Enum and Enum.UIMapType and Enum.UIMapType.Zone or 3
	local micro = Enum and Enum.UIMapType and Enum.UIMapType.Micro or 4
	if info.mapType ~= zone and info.mapType ~= micro then return nil end
	local stops = {}
	for index, stop in ipairs(TR.route) do
		local px, py = ProjectOntoMap(stop.map, stop.x, stop.y, mapID)
		if px then
			stops[#stops + 1] = {
				index = index, x = px, y = py,
				done = TR:IsDone(stop), current = (index == TR.pointer),
			}
		end
	end
	return stops
end

function DrawRouteOnMap()
	HideMapRoute()
	if not TR.db.routeOnMap then return end
	local map = WorldMapFrame
	if not (map and map.GetMapID and map:IsShown()) then return end
	local frame = MapRouteFrame()
	if not frame then return end
	local W, H = frame:GetWidth(), frame:GetHeight()
	if not (W and W > 0) then return end
	-- Drawing never raises an error into the map: a failure just clears the route.
	pcall(function()
		local stops = StopsOnMap(map:GetMapID())
		if not stops then return end
		-- screen-scale conversion, matching Mapzeroth's unitOf
		local unit = 1
		local mine, uiScale = frame:GetEffectiveScale(), UIParent and UIParent:GetEffectiveScale()
		if mine and uiScale and mine > 0 then unit = uiScale / mine end
		local thickness = 3.5 * unit
		local prev
		for _, s in ipairs(stops) do
			local r, g, b = RouteColor(s)
			local a = s.done and 0.35 or 0.9
			if prev and prev.index + 1 == s.index then
				-- the segment, over its dark casing (keeps it readable on map art)
				MapRun(frame, prev.x * W, prev.y * H, s.x * W, s.y * H, 0, 0, 0, 0.55 * a, thickness + 2.5 * unit)
				MapRun(frame, prev.x * W, prev.y * H, s.x * W, s.y * H, r, g, b, a, thickness)
			end
			MapDot(frame, s.x * W, s.y * H, r, g, b, a, 9 * unit)
			prev = s
		end
	end)
end

--------------------------------------------------------------------------------
-- The current leg on the minimap
--------------------------------------------------------------------------------

local miniRoute = { frame = nil, lines = {}, used = 0, since = 0, indoors = false }

-- How many yards the minimap spans, by zoom level (0 furthest out); the client
-- keeps separate scales indoors and out.
local MINIMAP_SIZES = {
	indoor = { [0] = 300, 240, 180, 120, 80, 50 },
	outdoor = { [0] = 466 + 2 / 3, 400, 333 + 1 / 3, 266 + 2 / 3, 200, 133 + 1 / 3 },
}

-- Minimap shapes, by what GetMinimapShape() says (none means round): for each
-- quarter whether it is round (true) or square. LibDBIcon's quarter order.
local MINIMAP_SHAPES = {
	ROUND = { true, true, true, true },
	SQUARE = { false, false, false, false },
	["CORNER-TOPLEFT"] = { false, false, false, true },
	["CORNER-TOPRIGHT"] = { false, false, true, false },
	["CORNER-BOTTOMLEFT"] = { false, true, false, false },
	["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
	["SIDE-LEFT"] = { false, true, false, true },
	["SIDE-RIGHT"] = { true, false, true, false },
	["SIDE-TOP"] = { false, false, true, true },
	["SIDE-BOTTOM"] = { true, true, false, false },
	["TRICORNER-TOPLEFT"] = { false, true, true, true },
	["TRICORNER-TOPRIGHT"] = { true, false, true, true },
	["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
	["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false },
}

local function MiniQuarter(x, y)
	local q = 1
	if x < 0 then q = q + 1 end
	if y > 0 then q = q + 2 end
	return q
end

local function MiniInside(x, y, radius, quarters)
	if quarters[MiniQuarter(x, y)] then return x * x + y * y <= radius * radius end
	return math.abs(x) <= radius and math.abs(y) <= radius
end

-- The part of a segment inside a circle of `radius` about the origin, or nil.
local function MiniClipCircle(x1, y1, x2, y2, radius)
	local r2 = radius * radius
	if x1 * x1 + y1 * y1 <= r2 and x2 * x2 + y2 * y2 <= r2 then return x1, y1, x2, y2 end
	local dx, dy = x2 - x1, y2 - y1
	local a = dx * dx + dy * dy
	if a == 0 then return nil end
	local b = 2 * (x1 * dx + y1 * dy)
	local c = x1 * x1 + y1 * y1 - r2
	local disc = b * b - 4 * a * c
	if disc <= 0 then return nil end
	local root = math.sqrt(disc)
	local low, high = math.max(0, (-b - root) / (2 * a)), math.min(1, (-b + root) / (2 * a))
	if low >= high then return nil end
	return x1 + dx * low, y1 + dy * low, x1 + dx * high, y1 + dy * high
end

-- The part of a segment inside the square of half-width `half` about the origin.
local function MiniClipSquare(x1, y1, x2, y2, half)
	local dx, dy = x2 - x1, y2 - y1
	local low, high = 0, 1
	for _, edge in ipairs({ { -dx, x1 + half }, { dx, half - x1 }, { -dy, y1 + half }, { dy, half - y1 } }) do
		local p, q = edge[1], edge[2]
		if p == 0 then
			if q < 0 then return nil end
		else
			local t = q / p
			if p < 0 then low = math.max(low, t) else high = math.min(high, t) end
		end
	end
	if low >= high then return nil end
	return x1 + dx * low, y1 + dy * low, x1 + dx * high, y1 + dy * high
end

-- The parts of a segment inside a minimap of `radius` and shape `quarters`:
-- { { x1, y1, x2, y2 }, ... } (cut where it crosses between quarters).
local function MiniClipShape(x1, y1, x2, y2, radius, quarters)
	local dx, dy = x2 - x1, y2 - y1
	local cuts = { 0, 1 }
	if dx ~= 0 and (x1 < 0) ~= (x2 < 0) then cuts[#cuts + 1] = -x1 / dx end
	if dy ~= 0 and (y1 > 0) ~= (y2 > 0) then cuts[#cuts + 1] = -y1 / dy end
	table.sort(cuts)
	local out = {}
	for i = 1, #cuts - 1 do
		local a, b = cuts[i], cuts[i + 1]
		if b > a then
			local ax, ay, bx, by = x1 + dx * a, y1 + dy * a, x1 + dx * b, y1 + dy * b
			local round = quarters[MiniQuarter((ax + bx) / 2, (ay + by) / 2)]
			local cx1, cy1, cx2, cy2
			if round then cx1, cy1, cx2, cy2 = MiniClipCircle(ax, ay, bx, by, radius)
			else cx1, cy1, cx2, cy2 = MiniClipSquare(ax, ay, bx, by, radius) end
			if cx1 then out[#out + 1] = { cx1, cy1, cx2, cy2 } end
		end
	end
	return out
end

local function MiniYardsAcross()
	local zoom = Minimap.GetZoom and Minimap:GetZoom() or 3
	local scale = miniRoute.indoors and MINIMAP_SIZES.indoor or MINIMAP_SIZES.outdoor
	return scale[zoom] or scale[3]
end

local function MiniRun(frame, x1, y1, x2, y2, r, g, b, a, thickness)
	miniRoute.used = miniRoute.used + 1
	local line = miniRoute.lines[miniRoute.used]
	if not line then
		line = frame:CreateLine(nil, "OVERLAY")
		miniRoute.lines[miniRoute.used] = line
	end
	line:Show()
	line:SetThickness(thickness)
	line:SetColorTexture(r, g, b, a)
	line:SetStartPoint("CENTER", frame, x1, y1)
	line:SetEndPoint("CENTER", frame, x2, y2)
end

local function MiniHide()
	for i = 1, miniRoute.used do miniRoute.lines[i]:Hide() end
	miniRoute.used = 0
end

-- Forward declaration: MiniFrame's OnUpdate closure calls this, and it is
-- defined below (`local f; function f() end` idiom).
local DrawMiniRoute

local function MiniFrame()
	if miniRoute.frame then return miniRoute.frame end
	if not Minimap then return nil end
	local frame = CreateFrame("Frame", nil, Minimap)
	frame:SetAllPoints(Minimap)
	frame:SetFrameLevel((Minimap:GetFrameLevel() or 1) + 2)
	frame:SetScript("OnUpdate", function(_, elapsed)
		miniRoute.since = (miniRoute.since or 0) + elapsed
		if miniRoute.since >= 0.2 then
			miniRoute.since = 0
			pcall(DrawMiniRoute)
		end
	end)
	frame:SetScript("OnEvent", function()
		miniRoute.indoors = (IsIndoors and IsIndoors()) and true or false
	end)
	frame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
	miniRoute.frame = frame
	miniRoute.indoors = (IsIndoors and IsIndoors()) and true or false
	return frame
end

function DrawMiniRoute() -- assigns the forward-declared local
	MiniHide()
	if not TR.db.routeOnMinimap then return end
	local map = C_Map.GetBestMapForUnit("player")
	local pos = map and C_Map.GetPlayerMapPosition(map, "player")
	if not pos then return end
	local px, py = pos:GetXY()
	if not px or (px == 0 and py == 0) then return end
	local xScale, yScale = YardsPerUnit(map)
	if not xScale then return end

	-- the current bucket, then the next incomplete one after it
	local legs = {}
	local current = TR:CurrentStop()
	if current and not TR:IsDone(current) then legs[#legs + 1] = current end
	for step = 1, #TR.route do
		local idx = ((TR.pointer - 1 + step) % #TR.route) + 1
		if not TR:IsDone(TR.route[idx]) then legs[#legs + 1] = TR.route[idx] break end
	end
	if #legs == 0 then return end

	local width = Minimap.GetWidth and Minimap:GetWidth()
	if not width or width <= 0 then return end
	local radius = width / 2 - 3
	local shape = type(GetMinimapShape) == "function" and GetMinimapShape() or "ROUND"
	local quarters = MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND
	local ypp = MiniYardsAcross() / width -- yards per pixel

	-- The minimap turns with the player if they have set it to.
	local angle = 0
	if GetCVar and GetCVar("rotateMinimap") == "1" then angle = -(GetPlayerFacing and GetPlayerFacing() or 0) end

	local playerX, playerY = px * xScale, py * yScale
	local function toPixels(stop)
		local sx, sy = ProjectOntoMap(stop.map, stop.x, stop.y, map)
		if not sx then return nil end
		local east, north = (sx * xScale) - playerX, -((sy * yScale) - playerY)
		if angle ~= 0 then
			local cos, sin = math.cos(angle), math.sin(angle)
			east, north = east * cos - north * sin, east * sin + north * cos
		end
		return east / ypp, north / ypp
	end

	local frame = MiniFrame()
	if not frame then return end
	pcall(function()
		local prevPx, prevPy = 0, 0 -- the player is the centre
		for _, stop in ipairs(legs) do
			local bx, by = toPixels(stop)
			if bx and by then
				for _, part in ipairs(MiniClipShape(prevPx, prevPy, bx, by, radius, quarters)) do
					MiniRun(frame, part[1], part[2], part[3], part[4], 1, 0.55, 0.12, 0.9, 2.5)
				end
				-- the bucket's dot, fat enough to spot on the rim (culled off-window)
				if MiniInside(bx, by, radius, quarters) then
					MiniRun(frame, bx - 0.5, by, bx + 0.5, by, 1, 0.82, 0.1, 1, 7)
				end
				prevPx, prevPy = bx, by
			end
		end
	end)
end

local function HookMapRoute()
	if mapRoute.hooked or not WorldMapFrame then return end
	mapRoute.hooked = true
	for _, method in ipairs({ "OnMapChanged", "OnCanvasScaleChanged" }) do
		if WorldMapFrame[method] then
			hooksecurefunc(WorldMapFrame, method, function() DrawRouteOnMap() end)
		end
	end
end

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

-- Lay out checkboxes side by side. CheckButton frames are just the 26px box --
-- the label doesn't count toward frame width, so it must be measured to avoid
-- neighboring checkboxes stamping on each other's text.
local function CheckboxRow(parent, items, startX, startY)
	local x = startX
	local created = {}

	-- dark plate behind the whole row so the options read clearly on the panel
	local plate = parent:CreateTexture(nil, "BACKGROUND")
	plate:SetColorTexture(0, 0, 0, 0.35)

	for _, item in ipairs(items) do
		local cb = CreateCheckbox(parent, item.text, item.get, item.set)
		cb:ClearAllPoints()
		cb:SetPoint("BOTTOMLEFT", x, startY)

		local label = rawget(cb, "Text") or cb.text
		if label then
			label:SetFontObject("GameFontHighlightSmall")
			label:SetWordWrap(false)
			label:SetTextColor(1, 0.87, 0.62) -- warm gold: readable on the dark panel
			cb:HookScript("OnEnter", function() label:SetTextColor(1, 1, 0.92) end)
			cb:HookScript("OnLeave", function() label:SetTextColor(1, 0.87, 0.62) end)
		end

		-- brighten the tick so checked state is obvious at a glance
		local check = cb.GetCheckedTexture and cb:GetCheckedTexture()
		if check then
			check:SetVertexColor(0.4, 1, 0.45)
			check:SetAlpha(1)
		end

		local labelWidth = (label and label.GetStringWidth and label:GetStringWidth()) or 60
		x = x + 26 + labelWidth + 16
		created[#created + 1] = cb
	end

	-- size/position the plate to hug the measured row
	plate:SetPoint("BOTTOMLEFT", startX - 6, startY - 3)
	plate:SetSize(x - startX - 10, 30)

	created.plate = plate
	return created
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
		GameTooltip:AddLine(string.format("%d / %d buckets visited (%d%%)", done, total,
			total > 0 and math.floor(done / total * 100 + 0.5) or 0), 1, 1, 1)
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
			TR.db.minimapAngle = math.deg(atan2(px - mx, py - my)) % 360
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
	local y = -32 -- rows start below the static search bar
	local current = TR:CurrentStop()
	local tokens = QueryTokens(ui.query)
	local filtering = #tokens > 0

	-- rows are created once and reused by index; extras are hidden at the end
	local rowIndex = 0
	local function NextRow()
		rowIndex = rowIndex + 1
		local frame = listRows[rowIndex]
		if not frame then
			frame = CreateFrame("Button", nil, content)
			frame.bg = frame:CreateTexture(nil, "BACKGROUND")
			frame.bg:SetAllPoints()
			frame.bg:SetColorTexture(1, 0.75, 0.1, 0.10)
			frame.bg:Hide()
			-- labels are top-anchored and never wrap: glyphs stay inside their row
			frame.fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			frame.fs:SetPoint("TOPLEFT", 2, -2)
			frame.fs:SetPoint("RIGHT", frame, "RIGHT", -4, -2)
			frame.fs:SetJustifyH("LEFT")
			frame.fs:SetWordWrap(false)
			frame.count = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
			frame.count:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -6, -2)
			frame.count:SetJustifyH("RIGHT")
			frame.count:SetWordWrap(false)
			listRows[rowIndex] = frame
		end
		frame:ClearAllPoints()
		frame:SetPoint("TOPLEFT", content, "TOPLEFT", 4, y)
		frame:SetPoint("RIGHT", content, "RIGHT", -6, y)
		return frame
	end

	-- group the contiguous route into region sections
	local groups, group = {}, nil
	for _, stop in ipairs(TR.route) do
		if not group or stop.regionKey ~= group.key then
			group = { key = stop.regionKey, name = stop.regionName, hint = stop.hint, stops = {} }
			groups[#groups + 1] = group
		end
		group.stops[#group.stops + 1] = stop
	end

	for _, g in ipairs(groups) do
		-- while searching, a section is shown only if it has a match, and is always open
		local matched = g.stops
		if filtering then
			matched = {}
			for _, stop in ipairs(g.stops) do
				if StopMatches(stop, tokens) then matched[#matched + 1] = stop end
			end
		end

		if not (filtering and #matched == 0) then
			local collapsed = (not filtering) and ((TR.db.collapsed[g.key] and true) or false) or false

			-- region header: click folds/unfolds the section
			local frame = NextRow()
			frame:SetHeight(26)
			local remaining = 0
			for _, s in ipairs(g.stops) do
				if not TR:IsDone(s) then remaining = remaining + 1 end
			end
			frame:SetScript("OnClick", function()
				if TR.db.collapsed[g.key] then
					TR.db.collapsed[g.key] = nil
				else
					TR.db.collapsed[g.key] = true
				end
				TR:RefreshUI()
			end)
			frame:SetScript("OnEnter", function(self)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(g.name or "", 1, 0.8, 0.4)
				if filtering then
					GameTooltip:AddLine("Clear the search to fold sections.", 0.6, 0.6, 0.6, true)
				else
					GameTooltip:AddLine("Click to expand or collapse this section.", 0.6, 0.6, 0.6, true)
				end
				GameTooltip:Show()
			end)
			frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
			frame.fs:SetFontObject("GameFontNormalSmall")
			frame.fs:SetText(("|cffffd100%s|r %s"):format(collapsed and "[+]" or "[-]", Colored(g.name)))
			if filtering then
				frame.count:SetText(("%d match%s"):format(#matched, #matched == 1 and "" or "es"))
			else
				frame.count:SetText(remaining > 0 and ("%d left"):format(remaining) or "")
			end
			frame.bg:Hide()
			frame:Show()
			y = y - frame:GetHeight()

			if not collapsed then
				for _, stop in ipairs(matched) do
					local row = NextRow()
					row:SetHeight(22)
					local done = TR:IsDone(stop)
					local isCurrent = current == stop
					local marker = done and "|cff5aff5a[v]|r" or (isCurrent and Colored(">") or "|cff808080-|r")
					local colorTag = done and "|cff606060%s|r" or (isCurrent and "|cffffff00%s|r" or "|cffffffff%s|r")
					row.bg:SetShown(isCurrent)
					row.count:SetText("")
					row.fs:SetFontObject("GameFontHighlightSmall")
					row.fs:SetText(("%s %s"):format(marker,
						(colorTag):format(("%s - %s"):format(stop.label, stop.zone or ""))))
					row:SetScript("OnClick", function()
						if IsShiftKeyDown() then
							-- share a clickable map pin (Mapzeroth's ChatShare idea)
							TR:ShareStop(stop)
							return
						elseif IsControlKeyDown() then
							-- plain /way line for TomTom, Paste or Mapzeroth's multi-stop box
							print(Colored("TrickOrRoute"), ("/way #%d %.2f %.2f %s"):format(stop.map, stop.x, stop.y, stop.label))
							return
						end
						TR:SetPointer(TR:IndexOfStop(stop) or TR.pointer)
						TR:RefreshUI()
					end)
					row:SetScript("OnEnter", function(self)
						self.fs:SetAlpha(0.7)
						GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
						if stop.note then
							GameTooltip:AddLine(stop.note, 1, 0.8, 0.4, true)
						end
						GameTooltip:AddLine("Shift-click: share a map pin in chat.", 0.7, 0.7, 0.7, true)
						GameTooltip:AddLine("Ctrl-click: print a /way line.", 0.7, 0.7, 0.7, true)
						GameTooltip:Show()
					end)
					row:SetScript("OnLeave", function(self)
						self.fs:SetAlpha(1)
						GameTooltip:Hide()
					end)
					row:Show()
					y = y - row:GetHeight()
				end
			end
		end
	end

	-- "no matches" line, and hiding rows that are not used this pass
	if not ui.noMatches then
		ui.noMatches = content:CreateFontString(nil, "OVERLAY", "GameFontDisable")
		ui.noMatches:SetPoint("TOPLEFT", content, "TOPLEFT", 6, -6)
		ui.noMatches:SetText("No stops match that search.")
	end
	ui.noMatches:SetShown(filtering and rowIndex == 0)

	-- hide rows that are not used this pass
	for i = rowIndex + 1, #listRows do
		listRows[i]:Hide()
	end

	content:SetHeight(math.abs(y) + 8)
end

local function BuildUI()
	if ui then return end

	ui = CreateFrame("Frame", "TrickOrRouteFrame", UIParent, "BackdropTemplate")
	ui:SetSize(404, 520)
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

	-- header: candy icon + title + close button
	local title = ui:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOP", 0, -12)
	title:SetText("TrickOrRoute") -- accent color applied by ApplyTheme
	ui.titleFont = title

	local headerIcon = ui:CreateTexture(nil, "OVERLAY")
	headerIcon:SetTexture("Interface\\Icons\\Achievement_Halloween_Candy_01")
	headerIcon:SetSize(20, 20)
	headerIcon:SetPoint("RIGHT", title, "LEFT", -6, 0)

	local close = CreateFrame("Button", nil, ui, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -4, -4)

	-- minimize: collapse the window to just the title bar + progress bar
	local minimize = CreateFrame("Button", nil, ui)
	-- Match the Close button's hit area, not the glyph's: a 20px target next to
	-- the 32px Close button is easy to miss.
	local closeWidth, closeHeight = close:GetWidth() or 0, close:GetHeight() or 0
	minimize:SetSize(closeWidth > 0 and closeWidth or 32, closeHeight > 0 and closeHeight or 32)
	minimize:SetPoint("TOPRIGHT", close, "TOPLEFT", 2, 0)
	local minGlyph = minimize:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	minGlyph:SetText("-")
	minGlyph:SetPoint("CENTER")
	minimize:SetScript("OnEnter", function() minGlyph:SetTextColor(1, 1, 0.4) end)
	minimize:SetScript("OnLeave", function() minGlyph:SetTextColor(1, 1, 1) end)
	minimize:SetScript("OnClick", function()
		ui.minimized = not ui.minimized
		TR.db.minimized = ui.minimized
		TR:RefreshUI()
	end)
	ui.minimizeButton = minimize
	ui.minimizeGlyph = minGlyph

	-- header progress bar (ember -> gold as the route fills up)
	local progress = CreateFrame("StatusBar", nil, ui)
	progress:SetSize(372, 16)
	progress:SetPoint("TOPLEFT", 16, -44)
	progress:SetMinMaxValues(0, 1)
	progress:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	local progressBg = progress:CreateTexture(nil, "BACKGROUND")
	progressBg:SetAllPoints()
	progressBg:SetColorTexture(0.10, 0.07, 0.03, 0.85)
	progress.text = progress:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	progress.text:SetPoint("CENTER")
	ui.progress = progress

	-- region picker: one dropdown instead of a strip of buttons. The menu is
	-- built when it opens (and refreshed on route changes), so the remaining
	-- counts and the current region are always current.
	local regions = TrickOrRouteData and TrickOrRouteData.regions or {}
	local stripTop = -70
	local dropdown = CreateFrame("DropdownButton", nil, ui, "WowStyle1DropdownTemplate")
	dropdown:SetWidth(372)
	dropdown:SetPoint("TOPLEFT", 16, stripTop)
	dropdown:SetDefaultText("Jump to region")
	dropdown:SetupMenu(function(_, rootDescription)
		rootDescription:CreateTitle("Jump to region")
		local current = TR:CurrentStop()
		-- One pass over the route, not one per region: the menu is regenerated on
		-- every RefreshUI, and IsDone pings the quest log.
		local remainingByRegion = {}
		for _, s in ipairs(TR.route or {}) do
			if not TR:IsDone(s) then
				remainingByRegion[s.regionKey] = (remainingByRegion[s.regionKey] or 0) + 1
			end
		end
		for _, region in ipairs(regions) do
			local remaining = remainingByRegion[region.key] or 0
			local allDone = remaining == 0
			local label = region.name
			if allDone then
				label = "|cff6fdf6f" .. label .. "|r"
			elseif current and current.regionKey == region.key then
				label = "|cffffd100" .. label .. "|r"
			end
			local radio = rootDescription:CreateRadio(label,
				function() return current and current.regionKey == region.key end,
				function() TR:JumpToRegion(region.key) end)
			-- SetTooltip takes an initializer, not a string.
			radio:SetTooltip(function(tooltip)
				GameTooltip_SetTitle(tooltip, region.name)
				if allDone then
					GameTooltip_AddNormalLine(tooltip, "All visited!")
				else
					GameTooltip_AddNormalLine(tooltip, ("%d bucket%s left"):format(
						remaining, remaining == 1 and "" or "s"))
				end
			end)
		end
	end)
	ui.regionDropdown = dropdown

	-- one row for the picker, then the stop card
	local stripHeight = dropdown:GetHeight()
	if not stripHeight or stripHeight <= 0 then stripHeight = 32 end
	local cardTop = stripTop - stripHeight - 10
	local actionsTop = cardTop - 120 - 6
	-- no region-hint line: the tour hint lives in the list headers only
	local fullHeight = math.max(440, math.abs(actionsTop) + 90 + 6 + 103)
	ui.fullHeight = fullHeight

	-- stop card
	local card = CreateFrame("Frame", nil, ui, "BackdropTemplate")
	card:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true, tileSize = 16, edgeSize = 12,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	card:SetBackdropColor(0, 0, 0, 0.55)
	card:SetPoint("TOPLEFT", 16, cardTop)
	card:SetPoint("RIGHT", -16, 0)
	card:SetHeight(120)
	ui.card = card

	local stopName = card:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	stopName:SetPoint("TOPLEFT", 12, -8)
	stopName:SetPoint("RIGHT", -118, 0)
	stopName:SetJustifyH("LEFT")
	ui.stopName = stopName

	-- direction arrow in the header, pointing at the bucket (Mapzeroth's navigator)
	local cardArrow = card:CreateTexture(nil, "OVERLAY")
	cardArrow:SetTexture(("Interface\\AddOns\\%s\\Media\\Arrow"):format(ADDON_NAME))
	cardArrow:SetSize(26, 26)
	cardArrow:SetPoint("TOPRIGHT", -14, -7)
	ui.arrow = cardArrow

	local stopStatus = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	-- Below the arrow, not beside the name: a long stop name would otherwise run
	-- straight into "Stop 130 / 200".
	stopStatus:SetPoint("TOPRIGHT", -12, -38)
	ui.stopStatus = stopStatus

	local stopInfo = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	stopInfo:SetPoint("TOPLEFT", 12, -38)
	stopInfo:SetPoint("RIGHT", -110, 0)
	stopInfo:SetJustifyH("LEFT")
	stopInfo:SetWordWrap(false)
	ui.stopInfo = stopInfo

	-- live distance readout, refreshed by the ticker in StartTicker
	local stopDist = card:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
	stopDist:SetPoint("TOPRIGHT", -12, -56)
	stopDist:SetJustifyH("RIGHT")
	ui.dist = stopDist

	local stopNote = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	stopNote:SetPoint("TOPLEFT", 12, -76)
	stopNote:SetPoint("RIGHT", -12, 0)
	stopNote:SetJustifyH("LEFT")
	stopNote:SetWordWrap(true)
	stopNote:SetTextColor(1, 0.85, 0.6)
	ui.stopNote = stopNote

	-- action buttons
	local function Btn(text, width)
		local b = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
		b:SetSize(width, 26)
		b:SetText(text)
		return b
	end

	local function AddTooltip(b, line1, line2)
		b:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(line1, 1, 1, 1, true)
			if line2 then GameTooltip:AddLine(line2, 0.8, 0.8, 0.8, true) end
			GameTooltip:Show()
		end)
		b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	end

	local prev = Btn("< Prev", 86)
	prev:SetPoint("TOPLEFT", 16, actionsTop)
	prev:SetScript("OnClick", function() TR:AdvancePointer(-1, false) end)

	local nextB = Btn("Next >", 86)
	nextB:SetPoint("TOPRIGHT", -16, actionsTop)
	nextB:SetScript("OnClick", function() TR:AdvancePointer(1, false) end)

	-- the primary action gets gold text so the eye lands on it first
	local waypoint = Btn("|cffffd100Set Waypoint|r", 140)
	waypoint:SetPoint("TOP", 0, actionsTop)
	waypoint:SetScript("OnClick", function() TR:SetWaypoint(TR:CurrentStop()) end)
	AddTooltip(waypoint, "Set the map waypoint (or TomTom arrow) on this stop.")

	local openMap = Btn("Open Map", 160)
	openMap:SetPoint("TOPLEFT", 16, actionsTop - 32)
	openMap:SetScript("OnClick", function() TR:OpenMap(TR:CurrentStop()) end)
	AddTooltip(openMap, "Open the world map centered on this stop.")

	local skip = Btn("Skip Stop", 160)
	skip:SetPoint("TOPRIGHT", -16, actionsTop - 32)
	skip:SetScript("OnClick", function() TR:SkipCurrent() end)
	AddTooltip(skip, "Skip this stop permanently for this character",
		"(e.g. rep-gated inns). Clear later with /tor unskip.")

	local dump = Btn("Export /way lines", 372)
	dump:SetPoint("TOP", 0, actionsTop - 64)
	dump:SetScript("OnClick", function() TR:PrintRemaining() end)
	AddTooltip(dump, "Print every remaining stop as TomTom /way lines.",
		"Bulk-import them with the Paste addon.")

	ui.actionButtons = { prev, waypoint, nextB, openMap, skip, dump }

	-- options + footer: two measured checkbox rows + treats + list toggle
	local rowA = CheckboxRow(ui, {
		{ text = "Auto-advance nearby", get = function() return TR.db.autoAdvance end,
			set = function(v) TR.db.autoAdvance = v end },
		{ text = "Use TomTom", get = function() return TR.db.useTomTom end,
			set = function(v) TR.db.useTomTom = v end },
	}, 10, 62)
	ui.autoCB, ui.tomCB = rowA[1], rowA[2]
	local plateA = rowA.plate

	local rowB = CheckboxRow(ui, {
		{ text = "Mini tracker", get = function() return TR.db.showHud end,
			set = function(v)
				TR.db.showHud = v
				TR:UpdateHud()
			end },
		{ text = "Dock beside map", get = function() return TR.db.dockMap end,
			set = function(v)
				TR.db.dockMap = v
				if v and WorldMapFrame and WorldMapFrame:IsShown() and ui:IsShown() and not ui.minimized then
					DockToMap(true)
				elseif not v then
					DockToMap(false)
				end
			end },
		{ text = "Minimap button", get = function() return TR.db.showMinimap end,
			set = function(v)
				TR.db.showMinimap = v
				TR:ApplyMinimapVisibility()
			end },
	}, 10, 34)
	ui.hudCB, ui.dockCB, ui.minimapCB = rowB[1], rowB[2], rowB[3]
	ui.checkboxPlates = { plateA, rowB.plate }

	local footer = ui:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	footer:SetPoint("BOTTOMLEFT", 12, 11)
	ui.footer = footer

	-- Paint the footer's treat count. RefreshUI calls this; the BAG_UPDATE hook
	-- calls it directly (see below) so looting updates the number without a
	-- full repaint. The count is remembered so the hook can skip no-op repaints.
	local lastTreats
	function TR:UpdateTreatFooter()
		local treats = TreatCount(TRICKY_TREAT_ITEM_ID)
		lastTreats = treats
		local icon = TreatIcon(TRICKY_TREAT_ITEM_ID)
		local iconTag = icon and ("|T" .. icon .. ":15:15:0:0|t") or ""
		local suffix = TR.db.autoAdvance and "" or "  |cff808080(auto-advance off)|r"
		footer:SetText(string.format("%s Tricky Treats: %d%s", iconTag, treats, suffix))
	end

	-- BAG_UPDATE fires for every bag change (looting, buying, crafting), so the
	-- handler stays as cheap as one item count and a comparison; it only paints
	-- when the number actually moved and the window is up to see it.
	TR.treatWatcher = function()
		if not (TR.ui and TR.ui.footer and TR.ui.footer:IsShown()) then return end
		local treats = TreatCount(TRICKY_TREAT_ITEM_ID)
		if treats ~= lastTreats then TR:UpdateTreatFooter() end
	end

	-- list view
	local listScroll = CreateFrame("ScrollFrame", nil, ui, "UIPanelScrollFrameTemplate")
	listScroll:SetPoint("TOPLEFT", 16, cardTop)
	listScroll:SetPoint("BOTTOMRIGHT", -16, 96)
	local content = CreateFrame("Frame", nil, listScroll)
	content:SetWidth(356)
	listScroll:SetScrollChild(content)
	ui.listScroll = listScroll
	ui.listScroll:Hide()

	-- static bar at the top of the list: search box + fold/unfold every region
	local listBar = CreateFrame("Frame", nil, ui)
	listBar:SetSize(368, 24)
	listBar:SetPoint("TOPLEFT", 16, cardTop)
	local barBg = listBar:CreateTexture(nil, "BACKGROUND")
	barBg:SetAllPoints()
	barBg:SetColorTexture(0.10, 0.08, 0.05, 1)

	local searchBox = CreateFrame("EditBox", nil, listBar, "InputBoxTemplate")
	searchBox:SetSize(232, 20)
	searchBox:SetPoint("LEFT", listBar, "LEFT", 2, 0)
	searchBox:SetAutoFocus(false)
	searchBox:SetTextInsets(6, 22, 0, 0)
	searchBox:SetText("")
	ui.searchBox = searchBox
	ui.query = ""

	local searchHint = searchBox:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	searchHint:SetPoint("LEFT", searchBox, "LEFT", 7, 0)
	searchHint:SetText("Search stops and zones...")
	searchHint:SetAlpha(0.75)
	ui.searchHint = searchHint

	local clearSearch = CreateFrame("Button", nil, listBar)
	clearSearch:SetSize(18, 18)
	clearSearch:SetPoint("RIGHT", searchBox, "RIGHT", -3, 0)
	local clearGlyph = clearSearch:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	clearGlyph:SetPoint("CENTER")
	clearGlyph:SetText("x")
	clearSearch:SetScript("OnEnter", function() clearGlyph:SetTextColor(1, 0.4, 0.4) end)
	clearSearch:SetScript("OnLeave", function() clearGlyph:SetTextColor(1, 1, 1) end)
	clearSearch:SetScript("OnClick", function()
		searchBox:SetText("")
		searchBox:ClearFocus()
	end)

	local function OnSearchChanged(self)
		ui.query = self:GetText() or ""
		searchHint:SetShown(ui.query == "")
		if ui.listScroll then ui.listScroll:SetVerticalScroll(0) end
		TR:RefreshUI()
	end
	searchBox:SetScript("OnTextChanged", OnSearchChanged)
	searchBox:SetScript("OnEscapePressed", function(self)
		self:SetText("")
		self:ClearFocus()
	end)
	searchBox:SetScript("OnEnterPressed", function(self)
		local tokens = QueryTokens(ui.query)
		if #tokens == 0 then return end
		for _, stop in ipairs(TR.route) do
			if StopMatches(stop, tokens) then
				TR:SetPointer(TR:IndexOfStop(stop) or TR.pointer)
				TR:RefreshUI()
				break
			end
		end
		self:ClearFocus()
	end)

	local expandAll = CreateFrame("Button", nil, listBar, "UIPanelButtonTemplate")
	expandAll:SetSize(104, 20)
	expandAll:SetPoint("RIGHT", listBar, "RIGHT", -2, 0)
	expandAll:SetText("Collapse all")
	expandAll:SetScript("OnClick", function()
		local anyCollapsed = false
		for _, stop in ipairs(TR.route) do
			if TR.db.collapsed[stop.regionKey] then anyCollapsed = true end
		end
		wipe(TR.db.collapsed)
		if not anyCollapsed then
			for _, stop in ipairs(TR.route) do
				TR.db.collapsed[stop.regionKey] = true
			end
		end
		TR:RefreshUI()
	end)
	ui.listBar = listBar
	ui.expandAll = expandAll

	local listButton = CreateFrame("Button", nil, ui, "UIPanelButtonTemplate")
	listButton:SetSize(140, 22)
	listButton:SetPoint("BOTTOMRIGHT", -8, 6)
	listButton:SetText("Show full list")
	ui.listButton = listButton
	listButton:SetScript("OnClick", function(self)
		ui.showList = not ui.showList
		self:SetText(ui.showList and "Show route" or "Show full list")
		TR:RefreshUI()
	end)

	ui.minimized = (TR.db.minimized and true) or false
	ui:SetHeight(fullHeight)
	ui:Hide()
	TR.ui = ui
end

function TR:UpdateDistance()
	if not ui or not ui.dist or not ui:IsShown() or ui.showList or ui.minimized then return end
	local stop = TR:CurrentStop()
	local d = stop and not TR:IsDone(stop) and TR:Distance(stop) or nil
	if not d then
		ui.dist:SetText("")
		return
	end
	local distText
	if d < 1000 then
		distText = string.format("%.0f yd", d)
	else
		distText = string.format("%.1f k yd", d / 1000)
	end
	if d < 2000 then
		distText = distText .. " " .. FormatETA(d)
	end
	if d <= AutoRadius() then
		ui.dist:SetText("|cff40ff40" .. distText .. "|r") -- in auto-advance range
	elseif d <= 120 then
		ui.dist:SetText("|cffffd200" .. distText .. "|r") -- getting close
	else
		ui.dist:SetText("|cffffffff" .. distText .. "|r")
	end
end

function TR:RefreshUI()
	if not ui or not ui:IsShown() then return end
	local currentStop = TR:CurrentStop()

	-- header progress bar
	local done, total = TR:Counts()
	local frac = (total > 0) and (done / total) or 0
	ui.progress:SetValue(frac)
	-- shade the bar from ember to gold as the route fills up
	ui.progress:SetStatusBarColor(0.6 + 0.4 * frac, 0.25 + 0.42 * frac, 0.08 + 0.02 * frac)
	ui.progress.text:SetText(string.format("%d / %d buckets visited  (%d%%)", done, total,
		math.floor(frac * 100 + 0.5)))

	-- window state: minimized toolbar vs. full window; card vs. list view
	local minimized = ui.minimized and true or false
	local showList = not minimized and (ui.showList and true or false) or false
	ui:SetHeight(minimized and 100 or (ui.fullHeight or 520))
	ui.minimizeGlyph:SetText(minimized and "+" or "-")
	ui.listScroll:SetShown(showList)
	ui.listBar:SetShown(showList)
	ui.listButton:SetShown(not minimized)
	ui.listButton:SetText(showList and "Show route" or "Show full list")
	ui.card:SetShown(not minimized and not showList)
	for _, b in ipairs(ui.actionButtons) do b:SetShown(not minimized and not showList) end
	ui.regionDropdown:SetShown(not minimized)
	ui.autoCB:SetShown(not minimized)
	if ui.tomCB then
		ui.tomCB:SetShown(not minimized and TomTom ~= nil)
	end
	-- row B is not part of any anchored chain, hide it explicitly
	for _, cb in ipairs({ ui.hudCB, ui.dockCB, ui.minimapCB }) do
		if cb then cb:SetShown(not minimized) end
	end
	-- the option plates are textures, so they must be toggled by hand
	for _, plate in ipairs(ui.checkboxPlates or {}) do
		plate:SetShown(not minimized)
	end
	ui.footer:SetShown(not minimized)

	if showList then
		BuildList()
	else
		local stop = currentStop
		if stop then
			ui.stopName:SetText(stop.label or "Candy Bucket")
			ui.stopInfo:SetText(string.format("%s |cffb0b0b0(%.1f, %.1f)|r", stop.zone or "?", stop.x, stop.y))
			if TR:IsDone(stop) then
				ui.stopStatus:SetText("|cff3dff3dDONE|r")
			else
				ui.stopStatus:SetText(("|cffb0b0b0Stop %d / %d|r"):format(TR.pointer, #TR.route))
			end
			ui.stopNote:SetText(stop.note or "")
		else
			ui.stopName:SetText("All done!")
			ui.stopInfo:SetText("")
			ui.stopStatus:SetText("")
			ui.stopNote:SetText("Every bucket on the route has been visited. Happy Hallow's End!")
		end
		TR:UpdateDistance()
	end

	-- footer: treat count with the candy icon
	TR:UpdateTreatFooter()

	-- refresh the region picker's selection text and its green/gold labels
	if ui.regionDropdown and not minimized and not ui.regionDropdown:IsMenuOpen() then
		ui.regionDropdown:GenerateMenu()
	end

	if ui.autoCB and ui.autoCB.Refresh then ui.autoCB:Refresh() end
	if ui.tomCB and ui.tomCB.Refresh then ui.tomCB:Refresh() end
	-- tomCB visibility is handled in the window-state block above
	TR:UpdateHud()
	DrawRouteOnMap()
end

function TR:ToggleUI()
	if not ui then return end
	if ui:IsShown() then
		ui:Hide()
	else
		ui:Show()
		TR:RefreshUI()
		if TR.db.dockMap and WorldMapFrame and WorldMapFrame:IsShown() and not ui.minimized then
			DockToMap(true)
		end
		DrawRouteOnMap()
	end
end

--------------------------------------------------------------------------------
-- Init
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("CHAT_MSG_LOOT")
eventFrame:RegisterEvent("BAG_UPDATE")

eventFrame:SetScript("OnEvent", function(_, event, ...)
	if event == "ADDON_LOADED" then
		-- Saved variables are only guaranteed from here on (the addon's files
		-- run first), so this is the first safe point to read settings.
		local loaded = ...
		if loaded == ADDON_NAME then TR:LoadSavedVariables() end
		return
	end
	if event == "PLAYER_ENTERING_WORLD" then
		TR:LoadSavedVariables()
		TR:BuildRoute()

		-- PLAYER_ENTERING_WORLD fires on every loading screen: build the UI,
		-- timers and hooks once, or they would stack up on each zone.
		if not TR.initialized then
			TR.initialized = true
			BuildUI()
			TR.minimapButton = MakeMinimapButton()
			TR:ApplyMinimapVisibility()
			MakeHud()
			ApplyTheme()
			TR:ApplyScale()
			HookWorldMap()
			HookMapRoute()
			MiniFrame() -- drives the minimap leg redraw from its OnUpdate
			StartTicker()

			local t = date("*t")
			local active = (t.month == 10 and t.day >= 18) or (t.month == 11 and t.day <= 1)
			if active then
				print(Colored("TrickOrRoute"), "- Hallow's End is live! Type |cffffff00/tor|r for your candy-bucket route.")
			end
		elseif TR.ui and TR.ui:IsShown() then
			TR:RefreshUI()
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
	elseif event == "BAG_UPDATE" then
		-- Keep the footer's Tricky Treat count current while looting. The
		-- watcher (built with the UI) compares the count first, so a burst of
		-- bag events costs one item count each, not a repaint.
		if TR.treatWatcher then TR.treatWatcher() end
	end
end)

--------------------------------------------------------------------------------
-- Addon compartment (minimap addon menu), wired up in TrickOrRoute.toc
--------------------------------------------------------------------------------

function TrickOrRouteCompartmentOnClick()
	TR:ToggleUI()
end

function TrickOrRouteCompartmentOnEnter(_, buttonName)
	local btn = buttonName and _G[buttonName]
	if btn then
		GameTooltip:SetOwner(btn, "ANCHOR_BOTTOMLEFT")
	else
		GameTooltip:SetOwner(Minimap, "ANCHOR_BOTTOMLEFT")
	end
	GameTooltip:SetText(Colored("TrickOrRoute"))
	local done, total = TR:Counts()
	GameTooltip:AddLine(("%d / %d buckets visited (%d%%)"):format(done, total,
		total > 0 and math.floor(done / total * 100 + 0.5) or 0), 1, 1, 1)
	GameTooltip:AddLine("Click to open the route", 0.8, 0.8, 0.8)
	GameTooltip:Show()
end

function TrickOrRouteCompartmentOnLeave()
	GameTooltip:Hide()
end

--------------------------------------------------------------------------------
-- Settings page (the game's own Settings window; Mapzeroth's OptionsPanel)
--
-- One row per option: sliders for the auto-advance radius and the UI scale,
-- checkboxes for the on/off settings, a theme cycler. Handed to the game as a
-- canvas category (Settings API, with the older InterfaceOptions fallback) and
-- opened with /tor settings.
--------------------------------------------------------------------------------

local settingsState = { frame = nil, registered = false, category = nil, widgets = {} }

local function BuildSettingsPage()
	local frame = CreateFrame("Frame", "TrickOrRouteSettings", UIParent)
	frame.name = "TrickOrRoute"
	settingsState.frame = frame
	local top = 84

	local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 20, -16)
	title:SetText("TrickOrRoute")

	local desc = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	desc:SetPoint("TOPLEFT", 20, -44)
	desc:SetPoint("RIGHT", -20, 0)
	desc:SetJustifyH("LEFT")
	desc:SetWordWrap(true)
	desc:SetText("An efficient guided tour of every Hallow's End candy bucket. Options are account-wide; progress is per character.")

	-- A slider row: its label, the slider, and its live value beside it.
	local function sliderRow(text, min, max, step, getter, setter, formatter)
		local rowLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
		rowLabel:SetPoint("TOPLEFT", 20, -top)
		rowLabel:SetText(text)

		local slider = CreateFrame("Slider", nil, frame, "OptionsSliderTemplate")
		slider:SetPoint("TOPLEFT", 24, -(top + 34))
		slider:SetSize(280, 18)
		slider:SetMinMaxValues(min, max)
		slider:SetValueStep(step)
		slider:SetObeyStepOnDrag(true)

		local value = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		value:SetPoint("LEFT", slider, "RIGHT", 14, 0)

		slider:SetScript("OnValueChanged", function(_, raw)
			setter(math.floor(raw / step + 0.5) * step)
			value:SetText(formatter(getter()))
		end)

		settingsState.widgets[#settingsState.widgets + 1] = {
			slider = slider, value = value, format = formatter, get = getter,
		}
		top = top + 78
	end

	sliderRow("Auto-advance radius", 0, 200, 5,
		function() return AutoRadius() end,
		function(v) TR.db.autoRadius = v end,
		function(v) return string.format("%d yd", v) end)

	sliderRow("UI scale", 0.7, 1.5, 0.05,
		function() return tonumber(TR.db.scale) or 1 end,
		function(v) TR:ApplyScale(v) end,
		function(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end)

	-- A checkbox row: CreateCheckbox already keeps the get/set pair fresh.
	local function toggle(text, key, onChange)
		local cb = CreateCheckbox(frame, text,
			function() return TR.db[key] end,
			function(v)
				TR.db[key] = v
				if onChange then onChange(v) end
			end)
		cb:SetPoint("TOPLEFT", 16, -(top + 8))
		settingsState.widgets[#settingsState.widgets + 1] = { check = cb, key = key }
		top = top + 30
	end

	toggle("Auto-advance nearby", "autoAdvance")
	toggle("Order stops within each zone by shortest path", "optimizeZones", function()
		local stop = TR:CurrentStop()
		TR.db.pointerQ = stop and stop.q or nil
		TR:BuildRoute()
		TR:RefreshUI()
	end)
	toggle("Use TomTom when available", "useTomTom")
	toggle("Mini tracker under the minimap", "showHud")
	toggle("Dock beside the world map", "dockMap")
	toggle("Minimap button", "showMinimap")
	toggle("Route between stops on the world map", "routeOnMap", function() DrawRouteOnMap() end)
	toggle("Current leg on the minimap", "routeOnMinimap")

	-- theme cycler + a reset button (the game's Reset button only works in the
	-- Settings window, so older fallbacks get one here too)
	local themeBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	themeBtn:SetSize(160, 22)
	themeBtn:SetPoint("TOPLEFT", 20, -(top + 14))
	themeBtn:SetText(("Theme: %s"):format(currentTheme.name))
	themeBtn:SetScript("OnClick", function()
		local index = 1
		for i, key in ipairs(themeOrder) do
			if key == (TR.db.theme or "dark") then index = i end
		end
		TR.db.theme = themeOrder[(index % #themeOrder) + 1]
		ApplyTheme()
		themeBtn:SetText(("Theme: %s"):format(currentTheme.name))
	end)
	settingsState.widgets[#settingsState.widgets + 1] = { themeBtn = themeBtn }
	top = top + 34

	local resetBtn = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	resetBtn:SetSize(120, 22)
	resetBtn:SetPoint("TOPLEFT", 20, -(top + 6))
	resetBtn:SetText("Reset options")
	resetBtn:SetScript("OnClick", function()
		TR.db.autoRadius = AUTO_ADVANCE_RADIUS
		TR:ApplyScale(1)
		ApplyTheme()
		TR:SyncSettings()
	end)

	-- The hooks the game's Settings window calls on a canvas page.
	frame:SetScript("OnShow", function() TR:SyncSettings() end)
	frame.OnCommit = function() end
	frame.OnDefault = function()
		TR.db.autoRadius = AUTO_ADVANCE_RADIUS
		TR:ApplyScale(1)
		TR:SyncSettings()
	end
	frame.OnRefresh = function() TR:SyncSettings() end

	return frame
end

-- Show the current settings in the controls.
function TR:SyncSettings()
	if not settingsState.frame then return end
	for _, w in ipairs(settingsState.widgets) do
		if w.slider then
			local v = w.get()
			w.slider:SetValue(v)
			w.value:SetText(w.format(v))
		elseif w.check and w.check.Refresh then
			w.check:Refresh()
		elseif w.themeBtn then
			w.themeBtn:SetText(("Theme: %s"):format(currentTheme.name))
		end
	end
end

-- Add the page to the game's Settings window (once).
function TR:RegisterSettings()
	if settingsState.registered then return true end
	if not settingsState.frame then BuildSettingsPage() end
	local frame = settingsState.frame
	if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
		settingsState.category = Settings.RegisterCanvasLayoutCategory(frame, "TrickOrRoute")
		Settings.RegisterAddOnCategory(settingsState.category)
	elseif InterfaceOptions_AddCategory then
		InterfaceOptions_AddCategory(frame) -- older clients
	else
		return false
	end
	settingsState.registered = true
	return true
end

function TR:OpenSettings()
	if not TR:RegisterSettings() then
		print(ADDON_NAME, "- settings are available in the route window's checkboxes.")
		return
	end
	if Settings and Settings.OpenToCategory and settingsState.category then
		-- the category object is Blizzard's; its GetID method is invisible to the
		-- checker, which only sees the empty table we assigned into
		---@diagnostic disable-next-line: undefined-field
		Settings.OpenToCategory(settingsState.category:GetID())
	elseif InterfaceOptionsFrame_OpenToCategory then
		InterfaceOptionsFrame_OpenToCategory(settingsState.frame)
	end
end
