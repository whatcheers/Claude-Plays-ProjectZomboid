-- ClaudeBot: turn-based remote control for Project Zomboid (B42, singleplayer).
-- Files live in ~/Zomboid/Lua/claudebot/:
--   cmd.txt    : line 1 = turn id, following lines = commands (see PLAYING.md)
--   state.json : written whenever a turn ends (the game auto-pauses)
--   eval.lua   : optional snippet run by the "eval" command (debugging)
ClaudeBot = ClaudeBot or {}
local B = ClaudeBot
B.VERSION = 1
B.results = B.results or {}
B.turn = B.turn or 0
B.speed = B.speed or 1
B.zids = B.zids or {}
B.nextZid = B.nextZid or 1
B.lastPoll = 0
B.maxTurnMin = B.maxTurnMin or 120
B.mapR = B.mapR or 12

local DIR = "claudebot/"

local function P() return getSpecificPlayer(0) end
local function r2(v) return math.floor(v * 100 + 0.5) / 100 end
local function nowMin() return getGameTime():getWorldAgeHours() * 60 end
local function try(f, ...) local ok, v = pcall(f, ...); if ok then return v end return nil end

---------------------------------------------------------------- json / files
local function esc(s)
	s = tostring(s)
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", ""):gsub("\t", " ")
	return s
end

local function enc(v, out)
	local t = type(v)
	if t == "table" then
		local empty = true
		for _ in pairs(v) do empty = false; break end
		if v[1] ~= nil or empty then
			out[#out + 1] = "["
			for i = 1, #v do
				if i > 1 then out[#out + 1] = "," end
				enc(v[i], out)
			end
			out[#out + 1] = "]"
		else
			out[#out + 1] = "{"
			local first = true
			for k, val in pairs(v) do
				if not first then out[#out + 1] = "," end
				first = false
				out[#out + 1] = '"' .. esc(k) .. '":'
				enc(val, out)
			end
			out[#out + 1] = "}"
		end
	elseif t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then out[#out + 1] = "null"
		else out[#out + 1] = tostring(math.floor(v * 1000 + 0.5) / 1000) end
	elseif t == "boolean" then
		out[#out + 1] = tostring(v)
	elseif v == nil then
		out[#out + 1] = "null"
	else
		out[#out + 1] = '"' .. esc(v) .. '"'
	end
end

function B.json(v) local out = {}; enc(v, out); return table.concat(out) end

function B.readFile(name)
	local r = getFileReader(DIR .. name, false)
	if not r then return nil end
	local lines = {}
	local l = r:readLine()
	while l do lines[#lines + 1] = l; l = r:readLine() end
	r:close()
	return table.concat(lines, "\n")
end

function B.writeFile(name, s)
	local w = getFileWriter(DIR .. name, true, false)
	w:write(s)
	w:close()
end

---------------------------------------------------------------- pause
function B.setPaused(p)
	local sc = UIManager.getSpeedControls()
	if not sc then return end
	if p then sc:SetCurrentGameSpeed(0) else sc:SetCurrentGameSpeed(B.speed) end
end

function B.isPaused()
	local sc = UIManager.getSpeedControls()
	return sc ~= nil and sc:getCurrentGameSpeed() == 0
end

---------------------------------------------------------------- zombies
function B.zid(z)
	local id = B.zids[z]
	if not id then id = B.nextZid; B.nextZid = id + 1; B.zids[z] = id end
	return id
end

local function canSee(p, z)
	local sq = z:getCurrentSquare()
	if sq and try(function() return sq:isCanSee(0) end) then return true end
	return false
end

function B.zombies(p, radius)
	local out = {}
	local list = getCell():getZombieList()
	local px, py, pz = p:getX(), p:getY(), math.floor(p:getZ())
	for i = 0, list:size() - 1 do
		local z = list:get(i)
		if z and z:isDead() then
			B.zids[z] = nil
		elseif z then
			local dx, dy = z:getX() - px, z:getY() - py
			local d = math.sqrt(dx * dx + dy * dy)
			if d <= radius then
				local sameZ = math.floor(z:getZ()) == pz
				local seen = sameZ and canSee(p, z)
				if seen or (sameZ and d < 4) then out[#out + 1] = { z = z, d = d, seen = seen } end
			end
		end
	end
	table.sort(out, function(a, b) return a.d < b.d end)
	return out
end

---------------------------------------------------------------- world scan helpers
local function sqAt(x, y, z) return getCell():getGridSquare(x, y, z) end

local function objList(sq)
	local t = {}
	local objs = sq:getObjects()
	for i = 0, objs:size() - 1 do t[#t + 1] = objs:get(i) end
	return t
end

local function isDoor(o)
	return instanceof(o, "IsoDoor") or (instanceof(o, "IsoThumpable") and o:isDoor())
end
local function isWindow(o) return instanceof(o, "IsoWindow") end

local function waterAmount(o)
	if instanceof(o, "IsoWorldInventoryObject") then return 0 end
	return try(function() return o:getFluidAmount() end) or 0
end

-- containers on a square: {c=ItemContainer, obj=owner, kind=string}
function B.containersOn(sq)
	local out = {}
	for _, o in ipairs(objList(sq)) do
		local n = try(function() return o:getContainerCount() end) or 0
		for ci = 0, n - 1 do
			local c = o:getContainerByIndex(ci)
			if c then out[#out + 1] = { c = c, obj = o, kind = c:getType() } end
		end
	end
	local bodies = try(function() return sq:getDeadBodys() end)
	if bodies then
		for i = 0, bodies:size() - 1 do
			local b = bodies:get(i)
			if b:getContainer() then out[#out + 1] = { c = b:getContainer(), obj = b, kind = "corpse" } end
		end
	end
	return out
end

function B.floorItems(sq)
	local out = {}
	local wos = sq:getWorldObjects()
	for i = 0, wos:size() - 1 do
		local wo = wos:get(i)
		if wo:getItem() then out[#out + 1] = wo end
	end
	return out
end

---------------------------------------------------------------- item description
local function itemInfo(item, p)
	local t = { id = item:getID(), name = item:getDisplayName(), type = item:getFullType() }
	t.cat = try(function() return item:getDisplayCategory() end) or try(function() return item:getCategory() end)
	t.w = r2(try(function() return item:getUnequippedWeight() end) or 0)
	if p then
		if p:getPrimaryHandItem() == item then t.hand = "primary" end
		if p:getSecondaryHandItem() == item then t.hand = (t.hand and "both" or "secondary") end
		if try(function() return item:isWorn() end) then t.worn = true end
	end
	if instanceof(item, "Food") then
		t.hunger = r2(item:getHungerChange() * 100)
		if try(function() return item:isRotten() end) then t.rotten = true end
		if try(function() return item:isCooked() end) then t.cooked = true end
		if try(function() return item:isFrozen() end) then t.frozen = true end
		if try(function() return item:isbDangerousUncooked() end) and not t.cooked then t.rawDanger = true end
	end
	local fc = try(function() return item:getFluidContainer() end)
	if fc then
		t.fluid = r2(fc:getAmount()) .. "/" .. r2(fc:getCapacity())
		local pf = try(function() return fc:getPrimaryFluid() end)
		if pf then t.fluidType = try(function() return pf:getFluidTypeString() end) or tostring(pf) end
		if try(function() return fc:isPoisonous() end) then t.poison = true end
	end
	if instanceof(item, "HandWeapon") then
		t.weapon = true
		t.dmg = r2(item:getMaxDamage())
		t.range = r2(item:getMaxRange())
		t.cond = item:getCondition() .. "/" .. item:getConditionMax()
		if item:isRanged() then t.ranged = true; t.ammo = try(function() return item:getCurrentAmmoCount() end) end
	end
	if instanceof(item, "InventoryContainer") then
		t.bag = true
		t.cap = try(function() return item:getInventory():getCapacity() end)
	end
	if instanceof(item, "Literature") then t.book = true end
	return t
end

local function containerItems(c, p, depth)
	local out = {}
	local items = c:getItems()
	for i = 0, items:size() - 1 do
		local it = items:get(i)
		local info = itemInfo(it, p)
		if info.bag and depth < 2 then info.items = containerItems(it:getInventory(), p, depth + 1) end
		out[#out + 1] = info
	end
	return out
end

-- find an item by id near the player (inventory, bags, containers/corpses/floor within r)
function B.findItem(p, id, r)
	r = r or 3
	local inv = p:getInventory()
	local it = inv:getItemById(id)
	if it then return it, it:getContainer(), nil end
	local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
	for dx = -r, r do for dy = -r, r do
		local sq = sqAt(px + dx, py + dy, pz)
		if sq then
			for _, e in ipairs(B.containersOn(sq)) do
				local f = e.c:getItemById(id)
				if f then return f, f:getContainer(), nil end
			end
			for _, wo in ipairs(B.floorItems(sq)) do
				if wo:getItem():getID() == id then return wo:getItem(), nil, wo end
			end
		end
	end end
	return nil
end

---------------------------------------------------------------- map
function B.map(p, R)
	local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
	local x0, y0 = px - R, py - R
	local W = 2 * R + 1
	local G = {}
	for r = 1, 2 * W + 1 do
		local row = {}
		for c = 1, 2 * W + 1 do row[c] = " " end
		G[r] = row
	end
	local zpos = {}
	for _, e in ipairs(B.zombies(p, R * 1.5)) do
		zpos[math.floor(e.z:getX()) .. "," .. math.floor(e.z:getY())] = e.seen and "Z" or "z"
	end
	for ty = 0, W - 1 do for tx = 0, W - 1 do
		local sq = sqAt(x0 + tx, y0 + ty, pz)
		local r, c = 2 * ty + 2, 2 * tx + 2
		if sq then
			local seen = try(function() return sq:isSeen(0) end)
			if seen == false then
				G[r][c] = "?"
			else
				local ch = " "
				if sq:getFloor() then ch = sq:isOutside() and "," or "." end
				if try(function() return not sq:isFree(false) end) and sq:getFloor() then ch = "o" end
				if try(function() return sq:HasTree() end) then ch = "T" end
				if try(function() return sq:HasStairs() end) then ch = "^" end
				local hasWater = false
				for _, o in ipairs(objList(sq)) do
					if waterAmount(o) > 0 then hasWater = true end
					if isDoor(o) then
						local n = o:getNorth()
						local open = try(function() return o:IsOpen() end)
						local dch = open and "d" or "D"
						if try(function() return o:isBarricaded() end) then dch = "%" end
						if n then G[r - 1][c] = dch else G[r][c - 1] = dch end
					elseif isWindow(o) then
						local n = o:getNorth()
						local wch = "W"
						if try(function() return o:IsOpen() end) then wch = "w" end
						if try(function() return o:isSmashed() end) then wch = "x" end
						if try(function() return o:isBarricaded() end) then wch = "%" end
						if n then G[r - 1][c] = wch else G[r][c - 1] = wch end
					end
				end
				if #B.containersOn(sq) > 0 then ch = "C" end
				if hasWater then ch = "~" end
				if #B.floorItems(sq) > 0 and ch ~= "C" then ch = "i" end
				local zk = zpos[(x0 + tx) .. "," .. (y0 + ty)]
				if zk then ch = zk end
				if x0 + tx == px and y0 + ty == py then ch = "@" end
				G[r][c] = ch
				local nsq, wsq = sqAt(x0 + tx, y0 + ty - 1, pz), sqAt(x0 + tx - 1, y0 + ty, pz)
				if G[r - 1][c] == " " and (try(function() return sq:getWall(true) end) or (nsq and try(function() return sq:isBlockedTo(nsq) end))) then G[r - 1][c] = "-" end
				if G[r][c - 1] == " " and (try(function() return sq:getWall(false) end) or (wsq and try(function() return sq:isBlockedTo(wsq) end))) then G[r][c - 1] = "|" end
			end
		end
	end end
	-- corners
	for r = 1, 2 * W + 1, 2 do for c = 1, 2 * W + 1, 2 do
		local h = (G[r][c - 1] and G[r][c - 1] ~= " ") or (G[r][c + 1] and G[r][c + 1] ~= " ")
		local v = (G[r - 1] and G[r - 1][c] ~= " ") or (G[r + 1] and G[r + 1][c] ~= " ")
		if h and v then G[r][c] = "+" end
	end end
	local lines = {}
	for r = 1, 2 * W + 1 do lines[#lines + 1] = table.concat(G[r]) end
	return { x0 = x0, y0 = y0, lines = lines }
end

---------------------------------------------------------------- state
local STATS = { "HUNGER", "THIRST", "FATIGUE", "ENDURANCE", "PANIC", "STRESS", "BOREDOM", "UNHAPPINESS", "PAIN", "SICKNESS", "WETNESS", "TEMPERATURE", "INTOXICATION", "ZOMBIE_INFECTION" }

function B.state(reason)
	local p = P()
	local s = { turn = B.turn, reason = reason, paused = B.isPaused(), results = B.results, version = B.VERSION, loaderErr = ClaudeBotLoader and ClaudeBotLoader.lastErr }
	local gt = getGameTime()
	s.time = { day = gt:getDay() + 1, month = gt:getMonth() + 1, year = gt:getYear(), hour = gt:getHour(), min = gt:getMinutes(), daysSurvived = r2(gt:getWorldAgeHours() / 24) }
	if not p then s.noPlayer = true; return s end
	s.dead = p:isDead()
	s.pos = { x = r2(p:getX()), y = r2(p:getY()), z = math.floor(p:getZ()) }
	s.outside = p:isOutside()
	s.asleep = p:isAsleep()
	local bd = p:getBodyDamage()
	s.health = r2(bd:getOverallBodyHealth())
	s.stats = {}
	for _, k in ipairs(STATS) do
		local v = try(function() return p:getStats():get(CharacterStat[k]) end)
		if v then s.stats[k:lower()] = r2(v) end
	end
	local wounds = {}
	local parts = bd:getBodyParts()
	for i = 0, parts:size() - 1 do
		local bp = parts:get(i)
		local f = {}
		if bp:bleeding() then f[#f + 1] = "bleeding" end
		if bp:scratched() then f[#f + 1] = "scratched" end
		if bp:bitten() then f[#f + 1] = "BITTEN" end
		if bp:isCut() then f[#f + 1] = "laceration" end
		if bp:deepWounded() then f[#f + 1] = "deepwound" end
		if try(function() return bp:getFractureTime() > 0 end) then f[#f + 1] = "fracture" end
		if try(function() return bp:haveGlass() end) then f[#f + 1] = "glass" end
		if try(function() return bp:isInfectedWound() end) then f[#f + 1] = "infected" end
		if bp:bandaged() then f[#f + 1] = "bandaged" end
		if #f > 0 or bp:getHealth() < 100 then
			wounds[#wounds + 1] = { part = BodyPartType.ToString(bp:getType()), hp = r2(bp:getHealth()), flags = table.concat(f, ",") }
		end
	end
	s.wounds = wounds
	s.weight = r2(p:getInventory():getCapacityWeight()) .. "/" .. r2(p:getMaxWeight())
	s.inventory = containerItems(p:getInventory(), p, 0)
	local ph = p:getPrimaryHandItem()
	s.primary = ph and (ph:getDisplayName() .. " #" .. ph:getID()) or nil
	local q = ISTimedActionQueue.getTimedActionQueue(p).queue
	s.queue = {}
	for i = 1, #q do s.queue[#s.queue + 1] = q[i].line or q[i].Type or "?" end

	-- zombies
	s.zombies = {}
	for _, e in ipairs(B.zombies(p, 30)) do
		local z = e.z
		local zi = { id = B.zid(z), x = r2(z:getX()), y = r2(z:getY()), d = r2(e.d), seen = e.seen }
		if try(function() return z:isOnFloor() end) then zi.down = true end
		if try(function() return z:isCrawling() end) then zi.crawler = true end
		if try(function() return z:getTarget() == p end) then zi.targetingMe = true end
		s.zombies[#s.zombies + 1] = zi
	end

	s.zdebug = {}
	local zl = getCell():getZombieList()
	for i = 0, zl:size() - 1 do
		local z = zl:get(i)
		local dx, dy = z:getX() - p:getX(), z:getY() - p:getY()
		local d = math.sqrt(dx * dx + dy * dy)
		if d < 12 then
			s.zdebug[#s.zdebug + 1] = string.format("#%d d=%.1f dead=%s floor=%s health=%.2f seen=%s", B.zid(z), d, tostring(z:isDead()),
				tostring(try(function() return z:isOnFloor() end)), z:getHealth(), tostring(canSee(p, z)))
		end
	end
	-- nearby objects
	local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
	local R = B.mapR
	s.containers, s.doors, s.windows, s.water, s.floor = {}, {}, {}, {}, {}
	for dx = -R, R do for dy = -R, R do
		local sq = sqAt(px + dx, py + dy, pz)
		if sq and try(function() return sq:isSeen(0) end) ~= false then
			local x, y = px + dx, py + dy
			local d = math.sqrt(dx * dx + dy * dy)
			for ci, e in ipairs(B.containersOn(sq)) do
				local ce = { x = x, y = y, i = ci, kind = e.kind, n = e.c:getItems():size() }
				if d <= 2.5 then ce.items = containerItems(e.c, nil, 1) end
				s.containers[#s.containers + 1] = ce
			end
			for _, wo in ipairs(B.floorItems(sq)) do
				local fi = { x = x, y = y }
				if d <= 2.5 then
					local inf = itemInfo(wo:getItem(), nil)
					for k, v in pairs(inf) do fi[k] = v end
				else
					fi.name = wo:getItem():getDisplayName()
				end
				s.floor[#s.floor + 1] = fi
			end
			for _, o in ipairs(objList(sq)) do
				if isDoor(o) then
					s.doors[#s.doors + 1] = { x = x, y = y, edge = o:getNorth() and "N" or "W", open = try(function() return o:IsOpen() end),
						locked = try(function() return o:isLocked() end), barricaded = try(function() return o:isBarricaded() end) }
				elseif isWindow(o) then
					s.windows[#s.windows + 1] = { x = x, y = y, edge = o:getNorth() and "N" or "W", open = try(function() return o:IsOpen() end),
						smashed = try(function() return o:isSmashed() end), glassRemoved = try(function() return o:isGlassRemoved() end),
						barricaded = try(function() return o:isBarricaded() end), locked = try(function() return o:isLocked() end) }
				elseif waterAmount(o) > 0 then
					s.water[#s.water + 1] = { x = x, y = y, name = try(function() return o:getObjectName() end) or "water",
						amount = r2(waterAmount(o)), tainted = try(function() return o:isTaintedWater() end) }
				end
			end
		end
	end end
	s.scan = B.scanResult; B.scanResult = nil
	local ok, m = pcall(B.map, p, R)
	if ok then s.map = m else s.mapErr = tostring(m) end
	local room = p:getCurrentSquare() and p:getCurrentSquare():getRoom()
	s.room = room and try(function() return room:getName() end) or nil
	return s
end

function B.dumpState(reason)
	local ok, s = pcall(B.state, reason)
	if not ok then s = { turn = B.turn, reason = reason, error = tostring(s), results = B.results } end
	B.writeFile("state.json", B.json(s))
end

---------------------------------------------------------------- timed actions
ClaudeBotStep = ISBaseTimedAction:derive("ClaudeBotStep")
function ClaudeBotStep:isValid() return true end
function ClaudeBotStep:update() end
function ClaudeBotStep:start() end
function ClaudeBotStep:stop() ISBaseTimedAction.stop(self) end
function ClaudeBotStep:perform()
	self:beginAddingActions()
	local ok, msg = pcall(B.cmds[self.verb], self.character, self.args, self.line)
	self:endAddingActions()
	B.res(self.line, ok, msg)
	ISBaseTimedAction.perform(self)
end
function ClaudeBotStep:new(p, line, verb, args)
	local o = ISBaseTimedAction.new(self, p)
	o.line, o.verb, o.args = line, verb, args
	o.maxTime = 1
	o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
	return o
end

ClaudeBotWait = ISBaseTimedAction:derive("ClaudeBotWait")
function ClaudeBotWait:isValid() return true end
function ClaudeBotWait:start() B.setSpeedRaw(B.waitSpeed or 3) end
function ClaudeBotWait:update() if nowMin() >= self.untilMin then self:forceComplete() end end
function ClaudeBotWait:stop() B.setSpeedRaw(B.speed); ISBaseTimedAction.stop(self) end
function ClaudeBotWait:perform() B.setSpeedRaw(B.speed); ISBaseTimedAction.perform(self) end
function ClaudeBotWait:new(p, mins)
	local o = ISBaseTimedAction.new(self, p)
	o.untilMin = nowMin() + mins
	o.maxTime = -1
	o.line = "wait " .. mins
	o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
	return o
end

function B.setSpeedRaw(v)
	local sc = UIManager.getSpeedControls()
	if sc and sc:getCurrentGameSpeed() ~= 0 then sc:SetCurrentGameSpeed(v) end
end

function B.res(line, ok, msg)
	B.results[#B.results + 1] = { cmd = line, ok = ok and (msg ~= false), msg = msg ~= nil and tostring(msg) or nil }
end

---------------------------------------------------------------- commands
local Q = function(a) ISTimedActionQueue.add(a) end
local function num(v, name) local n = tonumber(v); if not n then error("need number for " .. (name or "arg")) end return n end
local function itemArg(p, v)
	local it, cont, wo = B.findItem(p, num(v, "item id"), 4)
	if not it then error("item #" .. tostring(v) .. " not found nearby") end
	return it, cont, wo
end

local function findOn(sq, pred)
	if not sq then return nil end
	for _, o in ipairs(objList(sq)) do if pred(o) then return o end end
	return nil
end

-- move an item into main inventory (walking as needed); queues actions
local function toInventory(p, it, cont, wo)
	if wo then
		luautils.walkAdj(p, wo:getSquare(), true)
		Q(ISGrabItemAction:new(p, wo, ISWorldObjectContextMenu.grabItemTime(p, wo)))
		return
	end
	if cont == p:getInventory() then return end
	if cont:isInCharacterInventory(p) then
		Q(ISInventoryTransferAction:new(p, it, cont, p:getInventory()))
		return
	end
	luautils.walkToContainer(cont, 0)
	Q(ISInventoryTransferAction:new(p, it, cont, p:getInventory()))
end

B.cmds = {}
B.immediate = {}

B.immediate.look = function(p) return "ok" end

-- eval: runs claudebot/eval.lua (written by pz.py) via reloadLuaFile; the
-- snippet sets ClaudeBot.evalResult. Stand-in for loadstring, which B42 disables.
B.immediate.eval = function(p)
	B.evalResult = nil
	reloadLuaFile(Core.getMyDocumentFolder() .. "/Lua/claudebot/eval.lua")
	return tostring(B.evalResult)
end

-- scan [radius]: nearest buildings from the map (what the character's map shows)
B.immediate.scan = function(p, a)
	local R = tonumber(a[1]) or 150
	local px, py = p:getX(), p:getY()
	local all = getWorld():getMetaGrid():getBuildings()
	local found = {}
	for i = 0, all:size() - 1 do
		local b = all:get(i)
		local cx, cy = b:getX() + b:getW() / 2, b:getY() + b:getH() / 2
		local dx, dy = cx - px, cy - py
		local d = math.sqrt(dx * dx + dy * dy)
		if d <= R then found[#found + 1] = { b = b, d = d, cx = cx, cy = cy } end
	end
	table.sort(found, function(x, y) return x.d < y.d end)
	local lines = {}
	for i = 1, math.min(#found, 15) do
		local e = found[i]
		local rooms, seen = {}, {}
		local rs = e.b:getRooms()
		for j = 0, rs:size() - 1 do
			local n = rs:get(j):getName()
			if n and not seen[n] then seen[n] = true; rooms[#rooms + 1] = n end
		end
		local dir = (e.cy < py - 3 and "N" or (e.cy > py + 3 and "S" or "")) .. (e.cx < px - 3 and "W" or (e.cx > px + 3 and "E" or ""))
		local flags = ""
		if try(function() return e.b:isHasBeenVisited() end) then flags = flags .. " visited" end
		if try(function() return e.b:isAllExplored() end) then flags = flags .. " explored" end
		lines[#lines + 1] = string.format("%dm %s: box %d,%d %dx%d floors %d%s | %s", math.floor(e.d), dir, e.b:getX(), e.b:getY(), e.b:getW(), e.b:getH(),
			(try(function() return e.b:getMaxLevel() end) or 0) + 1, flags, table.concat(rooms, ","))
	end
	-- room layout of the building we're in / next to
	local here = nil
	for i = 1, #found do
		if found[i].b:getRooms():size() > 2 and found[i].d < 60 then here = found[i]; break end
	end
	if here then
		lines[#lines + 1] = "   rooms of the " .. math.floor(here.d) .. "m building:"
		local rs = here.b:getRooms()
		for j = 0, rs:size() - 1 do
			local r = rs:get(j)
			lines[#lines + 1] = string.format("   room %s at %d,%d %dx%d floor %d", r:getName(), r:getX(), r:getY(), r:getW(), r:getH(), r:getZ())
		end
	end
	B.scanResult = lines
	return #found .. " buildings within " .. R
end
B.immediate.say = function(p, a, line) p:Say((line:gsub("^%s*say%s*", ""))); return "said" end
B.immediate.speed = function(p, a) B.speed = num(a[1]); return "speed " .. B.speed end
B.cmds.fight = function(p, a)
	B.fight = { untilMin = nowMin() + (tonumber(a[1]) or 5), hunt = a[2] ~= "hold" }
	return B.fight.hunt and "hunting" or "holding position"
end
B.immediate.maxturn = function(p, a) B.maxTurnMin = num(a[1]); return "max turn " .. B.maxTurnMin .. " min" end

function B.path(p, x, y, z)
	local act = ISPathFindAction:pathToLocationF(p, x + 0.5, y + 0.5, z)
	act:setOnFail(function() B.res("go " .. x .. " " .. y, false, "PATH FAILED (no route)") end)
	Q(act)
end

B.cmds.go = function(p, a)
	local x, y = num(a[1], "x"), num(a[2], "y")
	local z = tonumber(a[3]) or math.floor(p:getZ())
	B.path(p, x, y, z)
	return "pathing to " .. x .. "," .. y .. "," .. z
end
B.cmds.step = function(p, a)
	local x, y = math.floor(p:getX()) + num(a[1], "dx"), math.floor(p:getY()) + num(a[2], "dy")
	B.path(p, x, y, math.floor(p:getZ()))
	return "pathing to " .. x .. "," .. y
end
B.cmds.door = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local d = findOn(sq, isDoor)
	if not d then error("no door at " .. a[1] .. "," .. a[2]) end
	if luautils.walkAdjWindowOrDoor(p, sq, d, true) then Q(ISOpenCloseDoor:new(p, d)) end
	return (try(function() return d:IsOpen() end) and "closing" or "opening") .. " door"
end
B.cmds.window = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local w = findOn(sq, function(o) return isWindow(o) or instanceof(o, "IsoWindowFrame") end)
	if not w then error("no window at " .. a[1] .. "," .. a[2]) end
	local verb = a[3] or "climb"
	if not luautils.walkAdjWindowOrDoor(p, sq, w, true) then error("can't reach window") end
	if verb == "open" or verb == "close" then Q(ISOpenCloseWindow:new(p, w))
	elseif verb == "smash" then Q(ISSmashWindow:new(p, w))
	elseif verb == "clearglass" then Q(ISRemoveBrokenGlass:new(p, w))
	elseif verb == "climb" then Q(ISClimbThroughWindow:new(p, w, 0))
	else error("window verb: open|close|smash|clearglass|climb") end
	return verb .. " window"
end
B.cmds.take = function(p, a)
	local names = {}
	for _, v in ipairs(a) do
		local it, cont, wo = itemArg(p, v)
		toInventory(p, it, cont, wo)
		names[#names + 1] = it:getDisplayName()
	end
	return "taking " .. table.concat(names, ", ")
end
B.cmds.loot = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	if not sq then error("no square") end
	local filter = a[3] and a[3]:lower()
	local n = 0
	for _, e in ipairs(B.containersOn(sq)) do
		local items = e.c:getItems()
		local list = {}
		for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
		for _, it in ipairs(list) do
			if not filter or it:getDisplayName():lower():find(filter, 1, true) or it:getFullType():lower():find(filter, 1, true) then
				toInventory(p, it, e.c, nil); n = n + 1
			end
		end
	end
	for _, wo in ipairs(B.floorItems(sq)) do
		local it = wo:getItem()
		if not filter or it:getDisplayName():lower():find(filter, 1, true) then toInventory(p, it, nil, wo); n = n + 1 end
	end
	return "looting " .. n .. " items"
end
B.cmds.put = function(p, a)
	local it = itemArg(p, a[1])
	local sq = sqAt(num(a[2]), num(a[3]), math.floor(p:getZ()))
	local cs = B.containersOn(sq)
	local e = cs[tonumber(a[4]) or 1]
	if not e then error("no container there") end
	if p:isEquipped(it) then Q(ISUnequipAction:new(p, it, 50)) end
	luautils.walkToContainer(e.c, 0)
	Q(ISInventoryTransferAction:new(p, it, it:getContainer(), e.c))
	return "putting " .. it:getDisplayName()
end
B.cmds.drop = function(p, a)
	local items = {}
	for _, v in ipairs(a) do items[#items + 1] = itemArg(p, v) end
	ISInventoryPaneContextMenu.onDropItems(items, 0)
	return "dropping " .. #items
end
B.cmds.eat = function(p, a)
	local it, cont, wo = itemArg(p, a[1])
	if wo or not cont:isInCharacterInventory(p) then toInventory(p, it, cont, wo) end
	ISInventoryPaneContextMenu.eatItem(it, tonumber(a[2]) or 1, 0)
	return "eating " .. it:getDisplayName()
end
B.cmds.drink = function(p, a)
	local it, cont, wo = itemArg(p, a[1])
	if wo or not cont:isInCharacterInventory(p) then toInventory(p, it, cont, wo) end
	ISInventoryPaneContextMenu.onDrinkFluid(it, tonumber(a[2]) or 1, p)
	return "drinking " .. it:getDisplayName()
end
B.cmds.drinkat = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local w = findOn(sq, function(o) return waterAmount(o) > 0 end)
	if not w then error("no water source there") end
	if not luautils.walkAdjObject(p, w, true, true) then error("can't reach water") end
	Q(ISTakeWaterAction:new(p, nil, w, w:isTaintedWater()))
	return "drinking from " .. (try(function() return w:getObjectName() end) or "water")
end
B.cmds.fill = function(p, a)
	local it, cont, wo = itemArg(p, a[1])
	if wo or not cont:isInCharacterInventory(p) then toInventory(p, it, cont, wo) end
	local sq = sqAt(num(a[2]), num(a[3]), math.floor(p:getZ()))
	local w = findOn(sq, function(o) return waterAmount(o) > 0 end)
	if not w then error("no water source there") end
	if not luautils.walkAdjObject(p, w, true, true) then error("can't reach water") end
	Q(ISTakeWaterAction:new(p, it, w, w:isTaintedWater()))
	return "filling " .. it:getDisplayName()
end
B.cmds.equip = function(p, a)
	local it = itemArg(p, a[1])
	local two = a[2] == "2h" or (try(function() return it:isTwoHandWeapon() end) or false)
	ISInventoryPaneContextMenu.equipWeapon(it, a[2] ~= "off", two, 0)
	return "equipping " .. it:getDisplayName()
end
B.cmds.unequip = function(p, a)
	local it = itemArg(p, a[1])
	ISInventoryPaneContextMenu.unequipItem(it, 0)
	return "unequipping " .. it:getDisplayName()
end
B.cmds.wear = function(p, a)
	local it, cont, wo = itemArg(p, a[1])
	if wo or not cont:isInCharacterInventory(p) then toInventory(p, it, cont, wo) end
	Q(ISWearClothing:new(p, it))
	return "wearing " .. it:getDisplayName()
end
B.cmds.read = function(p, a)
	local it, cont, wo = itemArg(p, a[1])
	if wo or not cont:isInCharacterInventory(p) then toInventory(p, it, cont, wo) end
	Q(ISReadABook:new(p, it))
	return "reading " .. it:getDisplayName()
end
B.cmds.bandage = function(p, a)
	local it = itemArg(p, a[1])
	local part = p:getBodyDamage():getBodyPart(BodyPartType.FromString(a[2]))
	if not part then error("unknown body part " .. tostring(a[2])) end
	Q(ISApplyBandage:new(p, p, it, part, true))
	return "bandaging " .. a[2]
end
B.cmds.wait = function(p, a)
	Q(ClaudeBotWait:new(p, tonumber(a[1]) or 10))
	return "waiting"
end

---------------------------------------------------------------- fighting
function B.attack(p, z)
	p:faceThisObject(z)
	if p:isAttackStarted() or try(function() return p:isPerformingAttackAnimation() end) then return end
	if B.attackImpl then return B.attackImpl(p, z) end
	p:setIsAiming(true)
	p:DoAttack(0)
end

function B.fightTick(p)
	local f = B.fight
	if nowMin() > f.untilMin then B.fight = nil; p:setIsAiming(false); B.res("fight", true, "fight time limit"); return end
	local zs = B.zombies(p, f.hunt and 14 or 8)
	if #zs == 0 then B.fight = nil; B.res("fight", true, "no zombies in range, fight over"); p:setIsAiming(false); return end
	local near = 0
	for _, e in ipairs(zs) do if e.d < 2 then near = near + 1 end end
	if near >= 3 then B.fight = nil; B.endTurn("surrounded: " .. near .. " zombies within 2 tiles"); return end
	if p:getStats():get(CharacterStat.ENDURANCE) < 0.25 then B.fight = nil; B.endTurn("exhausted"); return end
	local t = zs[1]
	local w = p:getPrimaryHandItem()
	local range = (w and instanceof(w, "HandWeapon") and w:getMaxRange()) or 0.9
	if t.d <= range + 0.3 then
		if f.pathing then ISTimedActionQueue.clear(p); f.pathing = false end
		B.attack(p, t.z)
	elseif f.hunt and t.seen and t.d < 14 then
		local now = getTimestampMs()
		if not f.pathing or now - (f.lastPath or 0) > 1500 then
			ISTimedActionQueue.clear(p)
			ISTimedActionQueue.add(ISPathFindAction:pathToLocationF(p, t.z:getX(), t.z:getY(), t.z:getZ()))
			f.pathing, f.lastPath = true, now
		end
	else
		p:faceThisObject(t.z)
	end
end

---------------------------------------------------------------- turn loop
function B.visibleSet(p)
	local s = {}
	for _, e in ipairs(B.zombies(p, 30)) do if e.seen then s[B.zid(e.z)] = true end end
	return s
end

function B.startTurn(id, lines)
	local p = P()
	B.turn = id
	B.results = {}
	if not p or p:isDead() then B.dumpState(p and "dead" or "no player"); return end
	local cont = false
	if lines[1] and lines[1]:match("^%s*continue") then cont = true; table.remove(lines, 1) end
	B.deferred = nil
	if not cont then
		if #ISTimedActionQueue.getTimedActionQueue(p).queue > 0 or p:getCharacterActions():size() > 0 then ISTimedActionQueue.clear(p) end
		B.fight = nil
	end
	if try(function() return p:isPerformingAttackAnimation() end) then p:setPerformingAttackAnimation(false) end
	p:setIsAiming(false)
	local needRun = cont
	for _, l in ipairs(lines) do
		local args = {}
		for w in l:gmatch("%S+") do args[#args + 1] = w end
		local verb = table.remove(args, 1)
		if B.immediate[verb] then
			local ok, msg = pcall(B.immediate[verb], p, args, l)
			B.res(l, ok, msg)
			if B.runAfterImm then needRun = true; B.runAfterImm = nil end
		elseif B.cmds[verb] then
			-- queued one tick later: clear() -> StopAllActionQueue cancels anything added this tick
			B.deferred = B.deferred or {}
			table.insert(B.deferred, { l, verb, args })
			needRun = true
		else
			B.res(l, false, "unknown command")
		end
	end
	B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
	B.turnSeen = B.visibleSet(p)
	B.turnClose = {}
	B.turnDeadline = nowMin() + B.maxTurnMin
	B.turnStartReal = getTimestampMs()
	if needRun then
		B.turnActive = true
		B.writeFile("state.json", B.json({ turn = id, running = true }))
		B.setPaused(false)
	else
		B.turnActive = false
		B.dumpState("idle")
	end
end

function B.endTurn(reason)
	B.turnActive = false
	B.setPaused(true)
	B.dumpState(reason)
end

function B.monitor(p)
	if not B.turnActive then return end
	if p:isDead() then B.endTurn("DEAD"); return end
	B.tickN = (B.tickN or 0) + 1
	if B.deferred then
		-- let a swing finish before queueing; actions started mid-swing are rejected
		local swinging = try(function() return p:isPerformingAttackAnimation() end) or p:getCurrentState() == SwipeStatePlayer.instance()
		if swinging then
			B.swingSince = B.swingSince or getTimestampMs()
			if getTimestampMs() - B.swingSince > 1500 then
				p:setPerformingAttackAnimation(false); p:setIsAiming(false); p:setAttackStarted(false)
				p:changeState(IdleState.instance())
			end
			return
		end
		B.swingSince = nil
		for _, d in ipairs(B.deferred) do Q(ClaudeBotStep:new(p, d[1], d[2], d[3])) end
		B.deferred = nil
		return
	end
	if B.fight then B.fightTick(p) end
	if not B.turnActive or B.tickN % 5 ~= 0 then return end
	for _, e in ipairs(B.zombies(p, 20)) do
		local id = B.zid(e.z)
		if e.seen and not B.turnSeen[id] and e.d <= 15 then
			B.turnSeen[id] = true
			if not B.fight then B.endTurn("new zombie #" .. id .. " at " .. r2(e.d) .. " tiles"); return end
		end
		if e.d < 2.5 and not B.fight and not B.turnClose[id] then
			B.turnClose[id] = true
			B.endTurn("zombie #" .. id .. " within " .. r2(e.d) .. " tiles"); return
		end
	end
	local h = p:getBodyDamage():getOverallBodyHealth()
	if h < B.turnHealth - 2 then B.turnHealth = h; B.endTurn("hurt (health " .. r2(h) .. ")"); return end
	if nowMin() > B.turnDeadline then B.endTurn("turn time limit"); return end
	local q = ISTimedActionQueue.getTimedActionQueue(p).queue
	if #q == 0 and not B.fight and not p:isAsleep() then B.endTurn("done") end
end

function B.poll()
	local now = getTimestampMs()
	if now - B.lastPoll < 250 then return end
	B.lastPoll = now
	local raw = B.readFile("cmd.txt")
	if not raw or raw == B.lastCmdRaw then return end
	B.lastCmdRaw = raw
	local lines = {}
	for rawl in raw:gmatch("[^\n]+") do
		local l = rawl:gsub("\r", "")
		if l:match("%S") then lines[#lines + 1] = l end
	end
	local id = tonumber(lines[1])
	if not id or id == B.turn then return end
	table.remove(lines, 1)
	B.startTurn(id, lines)
end

function B.onTick() B.poll() end
function B.onRender() B.poll() end
function B.onPlayerUpdate(p) if p == P() then B.monitor(p) end end

-- don't replay a stale cmd.txt on (re)load
if B.lastCmdRaw == nil then B.lastCmdRaw = B.readFile("cmd.txt") end
B.writeFile("loaded.txt", "bot.lua v" .. B.VERSION .. " loaded at " .. tostring(getTimestampMs()))
