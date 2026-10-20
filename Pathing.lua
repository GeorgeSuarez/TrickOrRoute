-- Pathing.lua - shortest paths and shortest visiting orders.
--
-- This is the same two-step idea Mapzeroth uses for a tour (Pathfinder.lua +
-- MultiRoute.lua), scaled down to one zone:
--
--   1. Pathfinder: Dijkstra over a node graph, once from every bucket, so we
--      know the shortest way from each bucket to every other (Mapzeroth's
--      Pathfinder:FindCosts does the same for a tour's stops).
--   2. MultiRoute: the quickest order to visit them all - exact Held-Karp up
--      to EXACT_LIMIT stops, nearest-first improved by 2-opt/or-opt beyond
--      (Mapzeroth's MultiRoute.Order).
--
-- No WoW API is touched here, so the search can be reasoned about (and tested)
-- on its own. Main.lua supplies the graph: the buckets are the nodes and the
-- distance between two is the straight line in world yards.

local _, TR = ...

local Pathing = {}
TR.Pathing = Pathing

Pathing.INF = math.huge
Pathing.EXACT_LIMIT = 12 -- stops; the exact search's work grows as 2^n * n^2

--------------------------------------------------------------------------------
-- Dijkstra
--------------------------------------------------------------------------------

-- Binary min-heap of { priority, payload }, the same shape as Mapzeroth's.
local function heapPush(heap, item)
	heap[#heap + 1] = item
	local i = #heap
	while i > 1 do
		local parent = math.floor(i / 2)
		if heap[parent][1] <= heap[i][1] then break end
		heap[parent], heap[i] = heap[i], heap[parent]
		i = parent
	end
end

local function heapPop(heap)
	local top = heap[1]
	local last = table.remove(heap)
	if #heap > 0 then
		heap[1] = last
		local i, n = 1, #heap
		while true do
			local left, right, smallest = i * 2, i * 2 + 1, i
			if left <= n and heap[left][1] < heap[smallest][1] then smallest = left end
			if right <= n and heap[right][1] < heap[smallest][1] then smallest = right end
			if smallest == i then break end
			heap[smallest], heap[i] = heap[i], heap[smallest]
			i = smallest
		end
	end
	return top
end

-- Cheapest cost from `start` to every node it can reach.
-- graph[from] = { { to = node, cost = seconds/yards }, ... }
-- targets (optional) = { [node] = true }: stop once they have all been priced.
-- Returns dist, prev (for rebuilding the paths).
function Pathing.Dijkstra(graph, start, targets)
	local dist, prev = {}, {}
	local left = 0
	if targets then
		for _ in pairs(targets) do left = left + 1 end
	end
	dist[start] = 0
	local heap = {}
	heapPush(heap, { 0, start })
	while #heap > 0 do
		local item = heapPop(heap)
		local d, node = item[1], item[2]
		if d == dist[node] then
			if targets and targets[node] then
				left = left - 1
				if left <= 0 then break end
			end
			for _, edge in ipairs(graph[node] or {}) do
				local newDist = d + edge.cost
				local known = dist[edge.to]
				if known == nil or newDist < known then
					dist[edge.to] = newDist
					prev[edge.to] = node
					heapPush(heap, { newDist, edge.to })
				end
			end
		end
	end
	return dist, prev
end

-- A complete graph: every node joined to every other, with cost(i, j).
function Pathing.CompleteGraph(n, cost)
	local graph = {}
	for i = 1, n do
		local edges = {}
		for j = 1, n do
			if i ~= j then
				local c = cost(i, j)
				if c and c < Pathing.INF then
					edges[#edges + 1] = { to = j, cost = c }
				end
			end
		end
		graph[i] = edges
	end
	return graph
end

-- Shortest paths from each node to each node: costs[i][j] and paths[i][j]
-- (a list of node indices, or nil when j can't be reached from i).
function Pathing.AllPairs(graph, n)
	local costs, paths = {}, {}
	for i = 1, n do
		local dist, prev = Pathing.Dijkstra(graph, i)
		costs[i], paths[i] = {}, {}
		for j = 1, n do
			costs[i][j] = dist[j] or Pathing.INF
			if i == j then
				paths[i][j] = { i }
			elseif dist[j] then
				local path, node, guard = { j }, prev[j], 0
				while node and guard <= n do
					table.insert(path, 1, node)
					node = prev[node]
					guard = guard + 1
				end
				paths[i][j] = path
			end
		end
	end
	return costs, paths
end

--------------------------------------------------------------------------------
-- Ordering the stops
--------------------------------------------------------------------------------

local function costAt(cost, i, j)
	if type(cost) == "table" then
		local row = cost[i]
		return (row and row[j]) or Pathing.INF
	end
	return cost(i, j) or Pathing.INF
end

local function pathCost(cost, order)
	local total, from = 0, order[1]
	for i = 2, #order do
		total = total + costAt(cost, from, order[i])
		from = order[i]
	end
	return total
end

-- Exact: the quickest order from `start` (fixed) through every node, ending at
-- `finish` when one is given (Held-Karp over the nodes in between). The bitmask
-- is stored as a number, as Mapzeroth's exactOrder does, so no bit library is
-- needed.
local function exactFrom(cost, n, start, finish)
	if n == 1 then return { 1 }, 0 end

	local middle, indexOf = {}, {}
	for i = 1, n do
		if i ~= start and i ~= finish then
			middle[#middle + 1] = i
			indexOf[i] = #middle
		end
	end
	local m = #middle
	if m == 0 then
		local d = costAt(cost, start, finish)
		if d >= Pathing.INF then return nil end
		return { start, finish }, d
	end

	local pow = {}
	for i = 1, m do pow[i] = 2 ^ (i - 1) end
	local full = 2 ^ m - 1
	local width = n + 1

	-- best[mask * width + node] = quickest way from start through the nodes in
	-- mask, ending at node; prev remembers the node before it.
	local best, prev = {}, {}
	for j = 1, m do
		local d = costAt(cost, start, middle[j])
		if d < Pathing.INF then
			best[pow[j] * width + middle[j]] = d
		end
	end
	for mask = 1, full do
		for j = 1, m do
			local here = best[mask * width + middle[j]]
			if here and here < Pathing.INF then
				for k = 1, m do
					if math.floor(mask / pow[k]) % 2 == 0 then
						local to = middle[k]
						local newDist = here + costAt(cost, middle[j], to)
						local key = (mask + pow[k]) * width + to
						if newDist < (best[key] or Pathing.INF) then
							best[key], prev[key] = newDist, middle[j]
						end
					end
				end
			end
		end
	end

	local last, total = nil, Pathing.INF
	for j = 1, m do
		local node = middle[j]
		local d = best[full * width + node]
		if d then
			if finish then d = d + costAt(cost, node, finish) end
			if d < total then total, last = d, node end
		end
	end
	if not last or total >= Pathing.INF then return nil end

	local order, mask, node = {}, full, last
	while node do
		table.insert(order, 1, node)
		local before = prev[mask * width + node]
		mask = mask - pow[indexOf[node]]
		node = before
	end
	table.insert(order, 1, start)
	if finish then order[#order + 1] = finish end
	return order, total
end

-- Nearest first, then improved until no single move helps: a stretch turned
-- round (2-opt), or one stop taken out and put somewhere else (or-opt). Stops
-- pinned at the ends never move.
local function improveOrder(cost, order, startFixed, finishFixed, yield)
	local n = #order
	local total = pathCost(cost, order)
	local lo = startFixed and 2 or 1
	local hi = finishFixed and (n - 1) or n
	local improved, passes = true, 0
	while improved and passes < 50 do
		improved, passes = false, passes + 1

		for i = lo, hi - 1 do
			for j = i + 1, hi do
				local trial = {}
				for k = 1, i - 1 do trial[#trial + 1] = order[k] end
				for k = j, i, -1 do trial[#trial + 1] = order[k] end
				for k = j + 1, n do trial[#trial + 1] = order[k] end
				local t = pathCost(cost, trial)
				if t < total - 1e-9 then
					order, total, improved = trial, t, true
				end
			end
			if yield then yield() end
		end

		for i = lo, hi do
			for j = lo, hi do
				if i ~= j then
					local trial = {}
					for k = 1, n do
						if k ~= i then trial[#trial + 1] = order[k] end
					end
					table.insert(trial, j, order[i])
					local t = pathCost(cost, trial)
					if t < total - 1e-9 then
						order, total, improved = trial, t, true
					end
				end
			end
			if yield then yield() end
		end
	end
	return order, total
end

local function nearestOrder(cost, n, start, finish)
	local order, used = { start }, { [start] = true }
	if finish then used[finish] = true end
	local from = start
	local count = finish and (n - 1) or n
	for _ = 2, count do
		local pick, pickCost
		for k = 1, n do
			if not used[k] then
				local d = costAt(cost, from, k)
				if d < (pickCost or Pathing.INF) then pick, pickCost = k, d end
			end
		end
		if not pick or pickCost >= Pathing.INF then return nil end
		order[#order + 1] = pick
		used[pick] = true
		from = pick
	end
	if finish then order[#order + 1] = finish end
	return order
end

local function heuristicFrom(cost, n, start, finish, yield)
	local order = nearestOrder(cost, n, start, finish)
	if not order then return nil end
	return improveOrder(cost, order, start ~= nil, finish ~= nil, yield)
end

local function exactOrder(cost, n, start, finish)
	if not start then
		-- No fixed entry: try every entry, keeping the best (the same search
		-- Mapzeroth's exactOrder does from its single fixed start).
		local bestOrder, bestTotal
		for s = 1, n do
			if not finish or s ~= finish then
				local order, total = exactFrom(cost, n, s, finish)
				if order and total < (bestTotal or Pathing.INF) then
					bestOrder, bestTotal = order, total
				end
			end
		end
		return bestOrder, bestTotal
	end
	return exactFrom(cost, n, start, finish)
end

local function heuristicOrder(cost, n, start, finish, yield)
	if start then return heuristicFrom(cost, n, start, finish, yield) end
	local bestOrder, bestTotal
	for s = 1, n do
		if not finish or s ~= finish then
			local order, total = heuristicFrom(cost, n, s, finish, yield)
			if order and total < (bestTotal or Pathing.INF) then
				bestOrder, bestTotal = order, total
			end
		end
	end
	return bestOrder, bestTotal
end

-- The quickest order to visit nodes 1..n, starting at `start` (nil: any),
-- ending at `finish` (nil: anywhere). `cost` is a function (i, j) or a table
-- cost[i][j]. Returns the order and its total, or nil when a stop can't be
-- reached.
function Pathing.Order(cost, n, start, finish, opts)
	opts = opts or {}
	if n <= 0 then return {}, 0 end
	if n == 1 then return { start or 1 }, 0 end
	if start and finish and start == finish then return nil end

	local order, total
	if n <= (opts.exactLimit or Pathing.EXACT_LIMIT) then
		order, total = exactOrder(cost, n, start, finish)
	else
		order, total = heuristicOrder(cost, n, start, finish, opts.yield)
	end
	if not order or not total or total >= Pathing.INF then return nil end
	return order, total
end

-- The shortest open path from every start, as
--   orders[start] = { order = {...}, cost = number }
-- and the best start/cost. `finish` (optional) pins the last stop.
function Pathing.OrderFromEach(cost, n, finish, opts)
	local orders, bestStart, bestTotal = {}, nil, nil
	for start = 1, n do
		if not finish or start ~= finish then
			local order, total = Pathing.Order(cost, n, start, finish, opts)
			if order then
				orders[start] = { order = order, cost = total }
				if not bestTotal or total < bestTotal then
					bestStart, bestTotal = start, total
				end
			end
		end
	end
	return orders, bestStart, bestTotal
end
