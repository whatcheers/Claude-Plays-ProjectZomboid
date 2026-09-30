-- ClaudeBot: turn-based remote control for Project Zomboid (B42, singleplayer).
-- Files live in ~/Zomboid/Lua/claudebot/:
--   cmd.txt    : line 1 = turn id, following lines = commands (see PLAYING.md)
--   state.json : written whenever a turn ends (the game auto-pauses)
--   eval.lua   : optional snippet run by the "eval" command (debugging)
ClaudeBot = ClaudeBot or {}
local B = ClaudeBot
B.VERSION = "0.6.0"  -- keep in step with mod.info and pz.py
B.results = B.results or {}
B.turn = B.turn or 0
B.speed = B.speed or 1
B.zids = B.zids or {}
B.nextZid = B.nextZid or 1
B.lastPoll = 0
B.maxTurnMin = B.maxTurnMin or 120
B.mapR = B.mapR or 12
B.hurtPause = B.hurtPause or 8  -- health lost in one turn before it pauses as "hurt"

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
	-- from a car seat the square vision check misses zombies in plain view (one walked up
	-- to the house and got run over without a pause); ask the character directly
	if p:getVehicle() and try(function() return p:CanSee(z) end) then return true end
	return false
end

function B.zombies(p, radius)
	local out = {}
	local list = getCell():getZombieList()
	local px, py, pz = p:getX(), p:getY(), math.floor(p:getZ())
	-- in a car, measure from the car: the driver sits ~2.5 tiles behind the bumper
	local car = p:getVehicle()
	if car then px, py = car:getX(), car:getY() end
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
		if bp:bitten() or bp:getBiteTime() > 0 then f[#f + 1] = "BITTEN" end
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
	s.overloaded = p:getInventory():getCapacityWeight() > p:getMaxWeight() * 1.25
	local home = B.baseBuilding and try(function() return B.baseBuilding(p) end)
	local here = p:getCurrentSquare() and p:getCurrentSquare():getBuilding()
	if home and here and here:getDef() == home then
		local _, sum = B.fortInfo(p, home)
		s.fort = sum
	end
	local ph = p:getPrimaryHandItem()
	s.primary = ph and (ph:getDisplayName() .. " #" .. ph:getID()) or nil
	s.queue = {}
	local r = B.run
	for i = r and r.cur or 1, r and #r.lines or 0 do s.queue[#s.queue + 1] = r.lines[i].text end

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
	s.survey = B.surveyResult; B.surveyResult = nil
	s.reflexes = B.reflexLog
	s.task = B.task and try(function() return B.task:status(p) end) or nil
	s.policy = B.policyString and B.policyString(B.policy) or nil
	s.base = B.getBase and B.getBase() or nil
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

-- An action of the running line failed (no route...). Report it on that line and mark it failed
-- for the runner.
function B.lineFailed(msg)
	local l = B.curLine()
	if l and l.status == "running" then l.failMsg = l.failMsg or msg end
	B.res(l and l.text or "?", false, msg)
end

-- A failed walk (walkAdj, walkToContainer: take, loot, put...) only force-stops, which wipes
-- the queue with no callback. Goal tasks watch their own walks.
B.walkUpdate = B.walkUpdate or ISWalkToTimedAction.update
function ISWalkToTimedAction:update()
	B.walkUpdate(self)
	if self.result == BehaviorResult.Failed and B.turnActive and not B.task then B.lineFailed("couldn't walk there (no route)") end
end

---------------------------------------------------------------- commands
local Q = function(a) ISTimedActionQueue.add(a) end
local function num(v, name) local n = tonumber(v); if not n then error("need number for " .. (name or "arg")) end return n end
local function itemArg(p, v, r)
	local it, cont, wo = B.findItem(p, num(v, "item id"), r or 4)
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

-- light [on|off]: flip every light switch in the current room
B.immediate.light = function(p, a)
	local want = a[1] ~= "off"
	local room = p:getSquare() and p:getSquare():getRoom()
	if not room then error("not in a room") end
	local px, py, pz = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
	local n = 0
	for dx = -20, 20 do for dy = -20, 20 do
		local sq = sqAt(px + dx, py + dy, pz)
		if sq and sq:getRoom() == room then
			for _, o in ipairs(objList(sq)) do
				if instanceof(o, "IsoLightSwitch") and o:isActivated() ~= want then o:toggle(); n = n + 1 end
			end
		end
	end end
	return "switched " .. n .. " light(s) " .. (want and "on" or "off") .. (getWorld():isHydroPowerOn() and "" or " (no grid power)")
end

-- eval: runs claudebot/eval.lua (written by pz.py) via reloadLuaFile; the
-- snippet sets ClaudeBot.evalResult. Stand-in for loadstring, which B42 disables.
B.immediate.eval = function(p)
	-- reloadLuaFile logs script errors without necessarily throwing them here.
	local pending = {}
	B.evalResult = pending
	reloadLuaFile(Core.getMyDocumentFolder() .. "/Lua/claudebot/eval.lua")
	if B.evalResult == pending then error("eval did not complete; see Zomboid/console.txt") end
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
-- reload [id]: equip (if given) and load the gun in hand from loose rounds / magazines in inventory
B.cmds.reload = function(p, a)
	local g = a[1] and itemArg(p, a[1]) or p:getPrimaryHandItem()
	if not g or not instanceof(g, "HandWeapon") or not g:isRanged() then error("no gun") end
	if p:getPrimaryHandItem() ~= g then
		ISInventoryPaneContextMenu.equipWeapon(g, true, g:isTwoHandWeapon(), 0)
	end
	ISReloadWeaponAction.BeginAutomaticReload(p, g)
	return "reloading " .. g:getDisplayName() .. " (" .. g:getCurrentAmmoCount() .. "/" .. g:getMaxAmmo() .. ")"
end

-- bash x y [minutes]: walk up to a door or window and hit it until it breaks. Loud.
B.cmds.bash = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local o = findOn(sq, function(o) return isDoor(o) or isWindow(o) end)
	if not o then error("no door or window at " .. a[1] .. "," .. a[2]) end
	if not luautils.walkAdjWindowOrDoor(p, sq, o, true) then error("can't reach it") end
	Q(ClaudeBotCall:new(p, "bash", function(p) return B.cmds._bashgo(p, { a[1], a[2], a[3] }) end))
	return "going to bash " .. (try(function() return o:getObjectName() end) or "it")
end
B.cmds._bashgo = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local o = findOn(sq, function(o) return isDoor(o) or isWindow(o) end)
	if not o then return "already gone" end
	B.bash = { sq = sq, obj = o, swings = 0, untilMin = nowMin() + (tonumber(a[3]) or 15) }
	return "swinging"
end
B.immediate.maxturn =function(p, a) B.maxTurnMin = num(a[1]); return "max turn " .. B.maxTurnMin .. " min" end
B.immediate.hurtpause = function(p, a) B.hurtPause = num(a[1]); return "pause after losing " .. B.hurtPause .. " health" end

function B.path(p, x, y, z)
	local act = ISPathFindAction:pathToLocationF(p, x + 0.5, y + 0.5, z)
	act:setOnFail(function() B.lineFailed("PATH FAILED (no route)") end)
	Q(act)
end

-- No floor given: the highest floor at or below yours that has a floor at x,y. From upstairs,
-- a spot outdoors has no square on your level at all, so the path used to fail.
function B.floorFor(x, y, z)
	for fz = z, 0, -1 do
		local sq = sqAt(x, y, fz)
		if sq and sq:getFloor() then return fz end
	end
	return z
end
B.cmds.go = function(p, a)
	local x, y = num(a[1], "x"), num(a[2], "y")
	local z = tonumber(a[3]) or B.floorFor(x, y, math.floor(p:getZ()))
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
-- which side of a window's wall edge the character is on
local function windowSide(p, w)
	local sq = w:getSquare()
	if w:getNorth() then return p:getY() < sq:getY() end
	return p:getX() < sq:getX()
end
local function windowWhy(w)
	local bits = {}
	if instanceof(w, "IsoWindow") then
		if not w:IsOpen() and not w:isSmashed() then bits[#bits + 1] = "closed" end
		if w:isLocked() or w:isPermaLocked() then bits[#bits + 1] = "locked" end
	end
	if try(function() return w:isBarricaded() end) then bits[#bits + 1] = "barricaded" end
	return #bits > 0 and ("the window is " .. table.concat(bits, ", ")) or "the game didn't do it; something in the way?"
end
B.cmds.window = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local verb = a[3] or "climb"
	if verb ~= "open" and verb ~= "close" and verb ~= "smash" and verb ~= "clearglass" and verb ~= "climb" then
		error("window verb: open|close|smash|clearglass|climb")
	end
	-- Frames may appear before the actual window in a square's object list.
	-- Only climb a bare frame when there is no working window to interact with.
	local w = findOn(sq, isWindow)
	if not w then
		w = findOn(sq, function(o) return instanceof(o, "IsoWindowFrame") end)
		if not w then error("no window at " .. a[1] .. "," .. a[2]) end
		if verb ~= "climb" then error("bare window frame: only climb is supported") end
	elseif (verb == "open" and w:IsOpen()) or (verb == "close" and not w:IsOpen()) then
		return "window already " .. (verb == "open" and "open" or "closed")
	end
	if not luautils.walkAdjWindowOrDoor(p, sq, w, true) then error("can't reach window") end
	if verb == "open" or verb == "close" then
		Q(ISOpenCloseWindow:new(p, w))
		B.setCheck(function(p)
			if w:IsOpen() == (verb == "open") then return "window is " .. (verb == "open" and "open" or "closed") end
			error("still " .. (w:IsOpen() and "open" or "closed") .. " (" .. windowWhy(w) .. ")")
		end)
	elseif verb == "smash" then Q(ISSmashWindow:new(p, w))
	elseif verb == "clearglass" then Q(ISRemoveBrokenGlass:new(p, w))
	elseif verb == "climb" then
		local act, side, started = ISClimbThroughWindow:new(p, w, 0), nil, false
		local perform = act.perform
		act.perform = function(self) side, started = windowSide(self.character, w), true; perform(self) end
		Q(act)
		B.setCheck(function(p)
			if started and windowSide(p, w) ~= side then return "climbed through" end
			error("still on the same side (" .. (started and "" or "the climb never started; ") .. windowWhy(w) .. ")")
		end)
	else error("window verb: open|close|smash|clearglass|climb") end
	return verb .. " window"
end
-- after the transfers, check every item really landed in main inventory; retry the missing
-- ones once (a hit or a full hand drops the queue mid-way), then name what's still missing
function B.verifyTaken(p, items, line, retried)
	Q(ClaudeBotCall:new(p, line, function(p)
		local inv, missing = p:getInventory(), {}
		for _, e in ipairs(items) do
			if e.it:getContainer() ~= inv then missing[#missing + 1] = e end
		end
		if #missing == 0 then return "got all " .. #items end
		if not retried then
			for _, e in ipairs(missing) do
				local it, cont, wo = B.findItem(p, e.it:getID(), 25)
				if it then toInventory(p, it, cont, wo) end
			end
			B.verifyTaken(p, missing, line, true)
			return nil
		end
		local names = {}
		for _, e in ipairs(missing) do names[#names + 1] = e.it:getDisplayName() .. " #" .. e.it:getID() end
		error("missing: " .. table.concat(names, ", "))
	end))
end
B.cmds.take = function(p, a)
	local names, items = {}, {}
	for _, v in ipairs(a) do
		-- far reach, so ids from survey work: it walks there
		local it, cont, wo = itemArg(p, v, 25)
		toInventory(p, it, cont, wo)
		names[#names + 1] = it:getDisplayName()
		items[#items + 1] = { it = it }
	end
	B.verifyTaken(p, items, "take")
	return "taking " .. table.concat(names, ", ")
end
B.cmds.loot = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	if not sq then error("no square") end
	-- loot x y [filter words...] [max]: the filter can be several words ("firefighter axe");
	-- a trailing number caps how many; "*" or no filter matches everything
	local words = {}
	for i = 3, #a do words[#words + 1] = a[i] end
	local max = math.huge
	if #words > 0 and tonumber(words[#words]) then max = tonumber(table.remove(words)) end
	local filter = #words > 0 and table.concat(words, " "):lower() or nil
	if filter == "*" then filter = nil end
	local n, taken = 0, {}
	local function match(it) return not filter or it:getDisplayName():lower():find(filter, 1, true) or it:getFullType():lower():find(filter, 1, true) end
	-- also look inside bags in the container (garbage bags in dumpsters, purses in wardrobes)
	local function scan(c, depth)
		local items = c:getItems()
		local list = {}
		for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
		for _, it in ipairs(list) do
			if n < max and match(it) then toInventory(p, it, c, nil); n = n + 1; taken[#taken + 1] = { it = it }
			elseif filter and depth < 2 and instanceof(it, "InventoryContainer") then scan(it:getInventory(), depth + 1) end
		end
	end
	for _, e in ipairs(B.containersOn(sq)) do scan(e.c, 0) end
	for _, wo in ipairs(B.floorItems(sq)) do
		local it = wo:getItem()
		if n < max and match(it) then toInventory(p, it, nil, wo); n = n + 1; taken[#taken + 1] = { it = it } end
	end
	if n > 0 then B.verifyTaken(p, taken, "loot") end
	return "looting " .. n .. " items"
end
B.cmds.put = function(p, a)
	local it = itemArg(p, a[1])
	local sq = sqAt(num(a[2]), num(a[3]), math.floor(p:getZ()))
	local cs = B.containersOn(sq)
	local e = cs[tonumber(a[4]) or 1]
	if not e then error("no container there") end
	-- a full container refuses the transfer silently, so check first and after
	if not try(function() return e.c:hasRoomFor(p, it) end) then
		error(e.kind .. " is full (" .. r2(e.c:getCapacityWeight()) .. "/" .. r2(e.c:getEffectiveCapacity(p)) .. " kg); try another container")
	end
	if p:isEquipped(it) then Q(ISUnequipAction:new(p, it, 50)) end
	luautils.walkToContainer(e.c, 0)
	Q(ISInventoryTransferAction:new(p, it, it:getContainer(), e.c))
	Q(ClaudeBotCall:new(p, "put", function(p)
		if it:getContainer() ~= e.c then error(it:getDisplayName() .. " did not go into the " .. e.kind) end
	end))
	return "putting " .. it:getDisplayName()
end
-- pack id [id...]: move items into the worn (or held) bag
B.cmds.pack = function(p, a)
	local bag = p:getClothingItem_Back() or p:getSecondaryHandItem()
	if not bag or not instanceof(bag, "InventoryContainer") then error("no worn bag") end
	local dest = bag:getItemContainer()
	for _, v in ipairs(a) do
		local it, cont, wo = itemArg(p, v)
		if wo then
			toInventory(p, it, cont, wo)
			Q(ISInventoryTransferAction:new(p, it, p:getInventory(), dest))
		elseif cont ~= dest then
			if not cont:isInCharacterInventory(p) then luautils.walkToContainer(cont, 0) end
			Q(ISInventoryTransferAction:new(p, it, cont, dest))
		end
	end
	return "packing " .. #a .. " into " .. bag:getDisplayName()
end
B.cmds.drop = function(p, a)
	local items = {}
	for _, v in ipairs(a) do items[#items + 1] = itemArg(p, v) end
	B.letGo = B.letGo or {}
	for _, it in ipairs(items) do B.letGo[it:getID()] = true end
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

-- runs fn(p) when it reaches the front of the queue (after walks/transfers queued before it)
ClaudeBotCall = ISBaseTimedAction:derive("ClaudeBotCall")
function ClaudeBotCall:isValid() return true end
function ClaudeBotCall:perform()
	self:beginAddingActions()
	local ok, msg = pcall(self.fn, self.character)
	self:endAddingActions()
	if not ok or msg then B.res(self.line, ok, msg) end
	ISBaseTimedAction.perform(self)
end
function ClaudeBotCall:new(p, line, fn)
	local o = ISBaseTimedAction.new(self, p)
	o.line, o.fn, o.maxTime = line, fn, 1
	o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
	return o
end

---------------------------------------------------------------- turn runner
-- ClaudeBot owns the turn's queue: B.run.lines run one at a time, and the game's timed-action
-- queue only ever holds the current line's actions. The game wipes that queue freely (window and
-- climb states when they end, fights, failed walks), so a line is judged only once the queue has
-- drained and the character has settled. docs/superpowers/specs/2026-09-30-turn-runner-design.md
local SETTLE_MS = 300

function B.newRun(entries)
	local r = { lines = {}, cur = 1 }
	for _, e in ipairs(entries) do
		r.lines[#r.lines + 1] = { text = e[1], verb = e[2], args = e[3], status = "waiting", tries = 0 }
	end
	return r
end

function B.curLine() return B.run and B.run.lines[B.run.cur] end

-- queued after a line's own actions: if it runs, the line ran to its end
ClaudeBotLineEnd = ISBaseTimedAction:derive("ClaudeBotLineEnd")
function ClaudeBotLineEnd:isValid() return true end
function ClaudeBotLineEnd:perform() self.l.ended = true; ISBaseTimedAction.perform(self) end
function ClaudeBotLineEnd:new(p, l)
	local o = ISBaseTimedAction.new(self, p)
	o.l, o.maxTime = l, 1
	o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
	return o
end

-- a command judges its own outcome: fn(p) returns a message or errors with the reason
function B.setCheck(fn) if B.starting then B.starting.check = fn end end

function B.startLine(p, l)
	l.status, l.tries = "running", l.tries + 1
	l.ended, l.failMsg, l.check, l.task = nil, nil, nil, nil
	B.starting = l
	local ok, msg = pcall(B.cmds[l.verb] or B.immediate[l.verb], p, l.args, l.text)
	B.starting = nil
	B.res(l.text, ok, ok and msg or tostring(msg))
	if not ok then l.status = "failed"; return end
	if B.immediate[l.verb] then l.status = "done"; return end
	if B.task then l.task = B.task; return end
	-- `fight` runs as B.fight, not queued actions: it's done when the fight is (the runner holds meanwhile)
	if B.fight then l.ended = true; return end
	Q(ClaudeBotLineEnd:new(p, l))
end

-- a line failed: everything after it is NOT RUN, and the turn ends
function B.failRun(p, l)
	local r = B.run
	for i = r.cur + 1, #r.lines do
		r.lines[i].status = "notrun"
		B.res(r.lines[i].text, false, "NOT RUN: '" .. l.text .. "' failed")
	end
	r.cur = #r.lines + 1
	ISTimedActionQueue.clear(p)
	B.endTurn(l.task and ("task failed: " .. l.text) or "done")
end

-- actions started mid-swing are rejected; let a swing finish (force it after 1.5 s)
function B.swingSettled(p)
	local swinging = try(function() return p:isPerformingAttackAnimation() end) or p:getCurrentState() == SwipeStatePlayer.instance()
	if not swinging then B.swingSince = nil; return true end
	B.swingSince = B.swingSince or getTimestampMs()
	if getTimestampMs() - B.swingSince > 1500 then
		p:setPerformingAttackAnimation(false); p:setIsAiming(false); p:setAttackStarted(false)
		p:changeState(IdleState.instance())
	end
	return false
end

function B.runTick(p)
	local r = B.run
	if not r then return end
	if B.fight or B.fleeing or B.bash or p:isAsleep() or B.busyState(p:getCurrentState()) then r.quietSince = nil; return end
	local q = ISTimedActionQueue.getTimedActionQueue(p).queue
	local l = r.lines[r.cur]
	if not l then
		if #q > 0 then return end
		if B.upkeep(p) then return end
		B.run = nil
		B.endTurn("done")
		return
	end
	if l.status == "waiting" then
		-- clear() cancels anything added in the same tick; other actions (rearm, pick-ups) go first
		if r.clearedTick == B.tickN or #q > 0 or not B.swingSettled(p) then return end
		B.startLine(p, l)
		if l.status == "failed" then return B.failRun(p, l) end
		if l.status == "done" then r.cur = r.cur + 1 end
		return
	end
	if l.task then
		if B.task == l.task then return end
		if not l.task.ok then l.status = "failed"; return B.failRun(p, l) end
		l.status, r.cur = "done", r.cur + 1
		return
	end
	if #q > 0 then r.quietSince = nil; return end
	r.quietSince = r.quietSince or getTimestampMs()
	if getTimestampMs() - r.quietSince < SETTLE_MS then return end
	r.quietSince = nil
	if l.failMsg then l.status = "failed"
	elseif l.check then
		local ok, msg = pcall(l.check, p)
		B.res(l.text, ok, ok and msg or tostring(msg):gsub("^.-:%d+: ", ""))
		l.status = ok and "done" or "failed"
	elseif l.ended then l.status = "done"
	elseif l.tries < 2 then
		l.status = "waiting"
		B.rlog("again: " .. l.text .. " (it was cut short)")
		return
	else
		B.res(l.text, false, "interrupted before it finished")
		l.status = "failed"
	end
	if l.status == "failed" then return B.failRun(p, l) end
	r.cur = r.cur + 1
end

-- item counts by name in main inventory, and a "+2 Rag, -1 Tank Top" diff of two of them
function B.invCounts(p)
	local t, items = {}, p:getInventory():getItems()
	for i = 0, items:size() - 1 do local n = items:get(i):getDisplayName(); t[n] = (t[n] or 0) + 1 end
	return t
end
function B.invDiff(a, b)
	local out = {}
	for n, c in pairs(b) do if c > (a[n] or 0) then out[#out + 1] = "+" .. (c - (a[n] or 0)) .. " " .. n end end
	for n, c in pairs(a) do if c > (b[n] or 0) then out[#out + 1] = "-" .. (c - (b[n] or 0)) .. " " .. n end end
	table.sort(out)
	return table.concat(out, ", ")
end

-- recipes id: what the right-click menu offers to craft from item #id
local function craftList(p, it)
	local conts = ISInventoryPaneContextMenu.getContainers(p)
	-- the game only searches worn/equipped bags; a carried bag's items would show nothing
	local own = it:getContainer()
	if own and not conts:contains(own) then conts:add(own) end
	local list = CraftRecipeManager.getUniqueRecipeItems(it, p, conts)
	local out = {}
	for i = 0, (list and list:size() or 0) - 1 do
		local r = list:get(i)
		local logic = HandcraftLogic.new(p, nil, nil)
		logic:setIsoObject(logic:findCraftSurface(p, 2))
		logic:setContainers(conts)
		logic:setRecipeFromContextClick(r, it)
		out[#out + 1] = { recipe = r, name = getText(r:getTranslationName()), can = logic:canPerformCurrentRecipe() }
	end
	return out
end
B.immediate.recipes = function(p, a)
	local it = itemArg(p, a[1])
	local rs = craftList(p, it)
	if #rs == 0 then return "nothing craftable from " .. it:getDisplayName() end
	local s = {}
	for i, r in ipairs(rs) do s[#s + 1] = i .. ") " .. r.name .. (r.can and "" or " [missing stuff]") end
	return it:getDisplayName() .. ": " .. table.concat(s, "; ")
end
-- craft id [n]: do recipe n (default 1) from `recipes id`
B.cmds.craft = function(p, a)
	local it, cont, wo = itemArg(p, a[1])
	local n = tonumber(a[2]) or 1
	if wo or not cont:isInCharacterInventory(p) then toInventory(p, it, cont, wo) end
	Q(ClaudeBotCall:new(p, "craft", function(p)
		local r = craftList(p, it)[n]
		if not r then error("no recipe " .. n .. " for " .. it:getDisplayName()) end
		if not r.can then error("can't do " .. r.name .. " (missing tools or materials)") end
		local before = B.invCounts(p)
		ISInventoryPaneContextMenu.OnNewCraft(it, r.recipe, p:getPlayerNum(), false)
		Q(ClaudeBotCall:new(p, "craft", function(p)
			local d = B.invDiff(before, B.invCounts(p))
			if d == "" then error(r.name .. " made nothing (interrupted?)") end
			return r.name .. ": " .. d
		end))
		return "crafting " .. r.name
	end))
	return "craft queued"
end

-- barricade x y [n]: nail n planks (default 1, max 4 per side) over the window or door on
-- that tile, from whichever side you're standing on. Needs a hammer, planks and 2 loose Nails
-- each (`craft` a Box of Nails open first). Puts your weapon back in hand afterwards.
local function hasTag(it, tag) return try(function() return it:hasTag(tag) end) end
-- vanilla ISBarricadeAction:isValid checks hasEquippedTag(ItemType.HAMMER), which is nil in
-- this build, so it always fails; same action with the hammer check fixed
ClaudeBotBarricade = ISBarricadeAction:derive("ClaudeBotBarricade")
function ClaudeBotBarricade:isValid()
	local p, o = self.character, self.item
	if not instanceof(o, "BarricadeAble") or o:getObjectIndex() == -1 then return false end
	local b = o:getBarricadeForCharacter(p)
	if b and not b:canAddPlank() then return false end
	if not p:hasEquippedTag(ItemTag.HAMMER) or not p:hasEquipped("Plank") then return false end
	if p:getInventory():getItemCount("Base.Nails", true) < 2 then return false end
	return true
end
B.cmds.barricade = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local o = findOn(sq, function(o) return isWindow(o) or isDoor(o) end)
	if not o then error("no window or door at " .. a[1] .. "," .. a[2]) end
	local inv = p:getInventory()
	local hammer = p:getPrimaryHandItem()
	if not (hammer and hasTag(hammer, ItemTag.HAMMER)) then
		hammer = inv:getFirstTagEvalRecurse(ItemTag.HAMMER, function(it) return not it:isBroken() end)
	end
	if not hammer then error("no hammer") end
	local planks = inv:getAllTypeRecurse("Plank")
	local nails = inv:getItemCountRecurse("Nails")
	local box = inv:getFirstTypeRecurse("NailsBox")
	local n = math.min(tonumber(a[3]) or 1, planks:size(), math.floor((nails + (box and 100 or 0)) / 2))
	if n < 1 then error("need a plank and 2 nails (have " .. planks:size() .. " planks, " .. nails .. " nails)") end
	local b = try(function() return o:getBarricadeForCharacter(p) end)
	local had = b and b:getNumPlanks() or 0
	n = math.min(n, 4 - had)
	if n < 1 then error("already 4 planks on this side") end
	if nails < 2 * n and box then
		Q(ClaudeBotCall:new(p, "barricade", function(p)
			for _, r in ipairs(craftList(p, box)) do
				if r.can then ISInventoryPaneContextMenu.OnNewCraft(box, r.recipe, p:getPlayerNum(), false); return "opened a Box of Nails" end
			end
			error("could not open the Box of Nails")
		end))
	end
	local weapon = p:getPrimaryHandItem()
	if not luautils.walkAdjWindowOrDoor(p, o:getSquare(), o) then error("can't reach it") end
	if hammer:getContainer() ~= inv then Q(ISInventoryTransferAction:new(p, hammer, hammer:getContainer(), inv)) end
	Q(ISEquipWeaponAction:new(p, hammer, 50, true, false))
	for i = 0, n - 1 do
		local pl = planks:get(i)
		if pl:getContainer() ~= inv then Q(ISInventoryTransferAction:new(p, pl, pl:getContainer(), inv)) end
		Q(ISEquipWeaponAction:new(p, pl, 50, false, false))
		Q(ClaudeBotBarricade:new(p, o, false, false))
	end
	-- the vanilla action fails silently (see ClaudeBotBarricade), so count what actually went up
	Q(ClaudeBotCall:new(p, "barricade", function(p)
		local nb = try(function() return o:getBarricadeForCharacter(p) end)
		local now = nb and nb:getNumPlanks() or 0
		if now - had < n then error((now - had) .. "/" .. n .. " planks went up (now " .. now .. " on this side)") end
		return n .. "/" .. n .. " planks up (now " .. now .. " on this side)"
	end))
	if weapon and weapon ~= hammer then
		Q(ISEquipWeaponAction:new(p, weapon, 50, true, try(function() return weapon:isTwoHandWeapon() end) or false))
	end
	return "barricading " .. (isWindow(o) and "window" or "door") .. " at " .. a[1] .. "," .. a[2] .. " with " .. n .. " plank" .. (n > 1 and "s" or "")
end

-- lock x y [off]: close and lock (or unlock) the door on that tile; needs its key on you
B.cmds.lock = function(p, a)
	local o = findOn(sqAt(num(a[1]), num(a[2]), math.floor(p:getZ())), isDoor)
	if not o then error("no door at " .. a[1] .. "," .. a[2]) end
	local lock = a[3] ~= "off"
	if not luautils.walkAdjWindowOrDoor(p, o:getSquare(), o) then error("can't reach the door") end
	if lock and try(function() return o:IsOpen() end) then Q(ISOpenCloseDoor:new(p, o)) end
	Q(ISLockDoor:new(p, o, lock))
	return (lock and "locking" or "unlocking") .. " door at " .. a[1] .. "," .. a[2]
end

-- chop x y: fell the tree on that tile with your best axe (logs drop around it)
B.cmds.chop = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local tree = sq and try(function() return sq:getTree() end)
	if not tree then error("no tree at " .. a[1] .. "," .. a[2]) end
	local axe = p:getInventory():getFirstEvalRecurse(function(it) return not it:isBroken() and try(function() return it:hasTag(ItemTag.CHOP_TREE) end) end)
	if not axe then error("no axe") end
	ISWorldObjectContextMenu.doChopTree(p, tree)
	return "chopping the tree at " .. a[1] .. "," .. a[2] .. " with " .. axe:getDisplayName()
end

-- build Entity x y [w|n]: place a build-menu entity (e.g. LogFence) on a tile, facing its
-- west or north edge (default w). Materials count from inventory and the 8 tiles around
-- where you stand, so drop heavy ones (logs) next to the spot first.
function B.objectInfo(name)
	local infos = SpriteConfigManager.GetObjectInfoList()
	for i = 0, infos:size() - 1 do
		local info = infos:get(i)
		if info:getName() == name or (info:getScript() and info:getScript():getName() == name) then return info end
	end
end
B.cmds.build = function(p, a)
	local name = a[1] or error("build what? e.g. build LogFence x y w")
	local info = B.objectInfo(name)
	if not info then error("no buildable entity named " .. name) end
	local x, y, z = num(a[2]), num(a[3]), math.floor(p:getZ())
	local sq = sqAt(x, y, z)
	if not sq then error("square not loaded") end
	local be = ISBuildIsoEntity:new(p, info, a[4] == "n" and 2 or 1, ISInventoryPaneContextMenu.getContainers(p))
	be.player = p:getPlayerNum()
	local face = be:getFace()
	if not face then error(name .. " has no buildable face") end
	be.north = be.nSprite == 2
	-- the cursor's render pass normally works out whether it's wall-like (walk to the edge
	-- rather than onto a free tile); do the same from the face's first sprite
	for xx = 0, face:getWidth() - 1 do for yy = 0, face:getHeight() - 1 do
		local ti = face:getTileInfo(xx, yy, 0)
		local spr = ti and ti:getSpriteName() and getSprite(ti:getSpriteName())
		if spr and be.isWallLike == nil then
			local pr = spr:getProperties()
			be.isWallLike = pr:has(IsoPropertyType.WALL_N) or pr:has(IsoPropertyType.WALL_W) or pr:has(IsoPropertyType.WALL_N_TRANS) or pr:has(IsoPropertyType.WALL_W_TRANS)
		end
	end end
	if not be:isValid(sq) then error("can't build " .. name .. " at " .. x .. "," .. y .. " (blocked, or missing materials/skill within reach)") end
	-- the sprites this face places, to check the result by (object counts also move when
	-- dropped items or materials come and go)
	local sprites = {}
	for xx = 0, face:getWidth() - 1 do for yy = 0, face:getHeight() - 1 do
		local ti = face:getTileInfo(xx, yy, 0)
		if ti and ti:getSpriteName() then sprites[ti:getSpriteName()] = true end
	end end
	local function count()
		local n = 0
		for _, o in ipairs(objList(sq)) do
			local s = o:getSprite() and o:getSprite():getName()
			if s and sprites[s] then n = n + 1 end
		end
		return n
	end
	local before = count()
	be:tryBuild(x, y, z)
	Q(ClaudeBotCall:new(p, "build", function(p)
		if count() > before then return name .. " built at " .. x .. "," .. y end
		error(name .. " not built (interrupted, or materials not in reach)")
	end))
	return "building " .. name .. " at " .. x .. "," .. y .. (be.north and " (north edge)" or " (west edge)")
end

-- sleep [x y | floor]: walk to the nearest bed on this floor (or the one at x y) and sleep;
-- no bed in reach means the floor. Uses the game's own sleep code, minus the confirm dialog.
local function isBed(o) return try(function() return o:getProperties():has(IsoFlagType.bed) end) end
function B.findBed(p, r)
	local px, py, z = math.floor(p:getX()), math.floor(p:getY()), math.floor(p:getZ())
	local best, bd
	for dx = -r, r do for dy = -r, r do
		local sq = sqAt(px + dx, py + dy, z)
		local bed = sq and findOn(sq, isBed)
		if bed then
			local d = dx * dx + dy * dy
			if not bd or d < bd then best, bd = bed, d end
		end
	end end
	return best
end
function B.sleepBlocker(p)
	local st = p:getStats()
	if st:getNumVisibleZombies() > 0 or st:getNumChasingZombies() > 0 or st:getNumVeryCloseZombies() > 0 then return "zombies around" end
	if p:getSleepingTabletEffect() < 2000 then
		if p:getMoodles():getMoodleLevel(MoodleType.PAIN) >= 2 and st:get(CharacterStat.FATIGUE) <= 0.85 then return "too much pain" end
		if p:getMoodles():getMoodleLevel(MoodleType.PANIC) >= 1 then return "panicking" end
	end
	return nil
end
ClaudeBotSleep = ISBaseTimedAction:derive("ClaudeBotSleep")
function ClaudeBotSleep:isValid() return true end
function ClaudeBotSleep:perform()
	ISBaseTimedAction.perform(self)
	local p = self.character
	local why = B.sleepBlocker(p)
	if why then B.res("sleep", false, "can't sleep: " .. why); return end
	p:setVariable("ExerciseStarted", false)
	p:setVariable("ExerciseEnded", true)
	ISWorldObjectContextMenu.onSleepWalkToComplete(p:getPlayerNum(), self.bed)
	B.res("sleep", p:isAsleep(), p:isAsleep() and ("asleep " .. (self.bed and "in bed" or "on the floor")) or "didn't fall asleep")
end
function ClaudeBotSleep:new(p, bed)
	local o = ISBaseTimedAction.new(self, p)
	o.bed, o.maxTime = bed, 1
	o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
	return o
end
B.cmds.sleep = function(p, a)
	local why = B.sleepBlocker(p)
	if why then error("can't sleep: " .. why) end
	local bed
	if a[1] == "floor" then bed = nil
	elseif a[1] then
		bed = findOn(sqAt(num(a[1]), num(a[2]), math.floor(p:getZ())), isBed)
		if not bed then error("no bed at " .. a[1] .. "," .. a[2]) end
	else bed = B.findBed(p, 12) end
	if bed and not AdjacentFreeTileFinder.isTileOrAdjacent(p:getCurrentSquare(), bed:getSquare()) then
		if not luautils.walkAdj(p, bed:getSquare(), true) then error("can't reach the bed") end
	end
	Q(ClaudeBotSleep:new(p, bed))
	return bed and ("going to bed at " .. bed:getX() .. "," .. bed:getY()) or "sleeping on the floor"
end

---------------------------------------------------------------- fighting
function B.attack(p, z)
	p:faceThisObject(z)
	if p:isAttackStarted() or try(function() return p:isPerformingAttackAnimation() end) then return end
	if B.attackImpl then return B.attackImpl(p, z) end
	local w = p:getPrimaryHandItem()
	if w and instanceof(w, "HandWeapon") and w:isRanged() then
		if w:getCurrentAmmoCount() == 0 and not w:isRoundChambered() then
			B.fight = nil; B.endTurn("out of ammo: reload"); return
		end
		-- the game only allocates the BallisticsController while the player has been aiming a
		-- firearm for a frame; DoAttack without one crashes CombatManager (NPE) and exits to menu
		p:setIsAiming(true)
		p:updateBallistics()
		if not p:getBallisticsController() then
			B.fight = nil; B.endTurn("gun not ready (no ballistics controller)"); return
		end
	end
	p:setIsAiming(true)
	p:DoAttack(0)
end

-- bash: swing at a door/window/barricade until it breaks (see B.cmds.bash)
function B.bashTick(p)
	local b = B.bash
	local gone = true
	for _, o in ipairs(objList(b.sq)) do if o == b.obj then gone = false end end
	if gone or (isDoor(b.obj) and try(function() return b.obj:IsOpen() end)) then
		B.bash = nil; p:setIsAiming(false); B.res("bash", true, "broke through after " .. b.swings .. " swings"); return
	end
	if nowMin() > b.untilMin then B.bash = nil; p:setIsAiming(false); B.res("bash", false, "gave up after " .. b.swings .. " swings"); return end
	if p:getStats():get(CharacterStat.ENDURANCE) < 0.3 then B.bash = nil; B.endTurn("exhausted"); return end
	p:faceThisObject(b.obj)
	if p:isAttackStarted() or try(function() return p:isPerformingAttackAnimation() end) then return end
	local w = p:getPrimaryHandItem()
	if w and instanceof(w, "HandWeapon") and w:isRanged() then B.bash = nil; B.endTurn("can't bash with a gun in hand: equip a melee weapon"); return end
	b.swings = b.swings + 1
	-- a zombie on the ground only takes a downward swing; a normal one passes over it
	B.aimFloor(p, z)
	p:setIsAiming(true)
	p:DoAttack(0)
end
function B.aimFloor(p, z)
	local down = z and (try(function() return z:isOnFloor() end) or false) or false
	try(function() p:setAimAtFloor(down) end)
end

-- shove (or stomp, if it's down) with whatever is in hand; never fires a gun
function B.shove(p, z)
	p:faceThisObject(z)
	if p:isAttackStarted() or try(function() return p:isPerformingAttackAnimation() end) then return end
	try(function() p:setDoShove(true) end)
	B.aimFloor(p, z)
	p:DoAttack(0)
end

-- ends a fight; reflex and task fights log instead of adding a command result
function B.endFight(p, ok, msg)
	local f = B.fight
	B.fight = nil
	p:setIsAiming(false)
	B.aimFloor(p, nil)
	local kills = 0
	for z in pairs(f.targets or {}) do if z:isDead() then kills = kills + 1 end end
	B.kills = (B.kills or 0) + kills
	if f.reflex or f.task then
		B.rlog((f.shove and "brawl" or "fight") .. ": " .. msg .. ", " .. kills .. " killed, " .. (f.swings or 0) .. " swings")
	else
		B.res("fight", ok, msg .. ", " .. kills .. " killed")
	end
end

function B.fightTick(p)
	local f = B.fight
	if nowMin() > f.untilMin then B.endFight(p, true, "fight time limit"); return end
	-- only zombies in sight: one heard through a wall can't be hit, and swinging at it
	-- burns endurance and strains muscles
	f.ignore = f.ignore or {}
	local zs = {}
	for _, e in ipairs(B.zombies(p, f.radius or (f.hunt and 14 or 8))) do
		if e.seen and not f.ignore[e.z] then zs[#zs + 1] = e end
	end
	if #zs == 0 then B.endFight(p, true, "no zombies in sight, fight over"); return end
	local near = 0
	for _, e in ipairs(zs) do if e.d < 2 then near = near + 1 end end
	if near >= 3 then B.fight = nil; B.endTurn("surrounded: " .. near .. " zombies within 2 tiles"); return end
	if p:getStats():get(CharacterStat.ENDURANCE) < 0.25 then B.fight = nil; B.endTurn("exhausted"); return end
	local t = zs[1]
	local w = p:getPrimaryHandItem()
	local range = (not f.shove and w and instanceof(w, "HandWeapon") and w:getMaxRange()) or 0.9
	if t.d <= range + 0.3 then
		if f.pathing then ISTimedActionQueue.clear(p); f.pathing = false end
		f.targets = f.targets or {}
		f.targets[t.z] = true
		local busy = p:isAttackStarted() or try(function() return p:isPerformingAttackAnimation() end)
		if not busy then
			f.swings = (f.swings or 0) + 1
			-- 4 swings that don't hurt or drop it: something's in the way, stop
			f.tries = f.tries or {}
			local tr = f.tries[t.z]
			local hp = t.z:getHealth()
			local down = try(function() return t.z:isOnFloor() end)
			if not tr or hp < tr.hp or (down and not tr.down) then
				f.tries[t.z] = { hp = hp, n = 1, down = down }
			else
				tr.n = tr.n + 1
				tr.down = down
				if tr.n > 4 then
					-- Ignoring only within this fight let reflexes immediately retry
					-- the same un-hittable enemy in a fresh fight. Stop for a decision.
					local reason = "combat stalled: Z#" .. B.zid(t.z) .. " (4 swings, no damage); reposition or retreat"
					B.endFight(p, false, reason)
					B.endTurn(reason)
					return
				end
			end
		end
		if f.shove then B.shove(p, t.z) else B.attack(p, t.z) end
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

---------------------------------------------------------------- standing orders
local POLICY_DEFAULTS = { melee = "auto", rearm = "on", shove = "on", flee = 3, eat = 0.35, bandage = "on" }
function B.policyString(t)
	local ks = {}
	for k in pairs(POLICY_DEFAULTS) do ks[#ks + 1] = k end
	table.sort(ks)
	local out = {}
	for _, k in ipairs(ks) do out[#out + 1] = k .. "=" .. tostring(t[k]) end
	return table.concat(out, " ")
end
function B.loadPolicy()
	local pol = {}
	for k, v in pairs(POLICY_DEFAULTS) do pol[k] = v end
	for k, v in (B.readFile("policy.txt") or ""):gmatch("(%w+)=(%S+)") do
		if POLICY_DEFAULTS[k] ~= nil then pol[k] = tonumber(v) or v end
	end
	return pol
end
B.policy = B.loadPolicy()
local function pon(k) local v = B.policy[k]; return v == "on" or v == "auto" end

-- policy [key=value ...]: standing orders; saved to policy.txt so they outlive the character
B.immediate.policy = function(p, a)
	for _, kv in ipairs(a) do
		local k, v = kv:match("^(%w+)=(%S+)$")
		if not k or POLICY_DEFAULTS[k] == nil then error("unknown setting " .. kv .. "; defaults: " .. B.policyString(POLICY_DEFAULTS)) end
		B.policy[k] = tonumber(v) or v
	end
	if #a > 0 then B.writeFile("policy.txt", B.policyString(B.policy)) end
	return B.policyString(B.policy)
end

function B.rlog(msg)
	B.reflexLog = B.reflexLog or {}
	if #B.reflexLog < 40 then B.reflexLog[#B.reflexLog + 1] = msg end
end

local function isMelee(w)
	return w ~= nil and instanceof(w, "HandWeapon") and not w:isRanged()
		and not try(function() return w:isBroken() end) and w:getMaxDamage() >= 0.3
end
local function isGun(w) return w ~= nil and instanceof(w, "HandWeapon") and w:isRanged() end

-- visit items in a container and the bags inside it
local function eachItem(c, fn, depth)
	local items = c:getItems()
	local list = {}
	for i = 0, items:size() - 1 do list[#list + 1] = items:get(i) end
	for _, it in ipairs(list) do
		fn(it)
		if instanceof(it, "InventoryContainer") and (depth or 0) < 2 then eachItem(it:getInventory(), fn, (depth or 0) + 1) end
	end
end

function B.bestMelee(p)
	local best
	eachItem(p:getInventory(), function(it)
		if isMelee(it) and (not best or it:getMaxDamage() > best:getMaxDamage()) then best = it end
	end)
	return best
end

-- true when a close zombie is something the reflexes will deal with
function B.canDefend(p)
	if B.policy.melee ~= "auto" then return false end
	if isMelee(p:getPrimaryHandItem()) then return true end
	return pon("rearm") and B.bestMelee(p) ~= nil
end

---------------------------------------------------------------- interrupts
-- A reflex (fight, rearm, flee, weapon pick-up) takes over: clear the game queue and put the
-- running line back to waiting, so the runner starts it again afterwards. A reflex isn't the
-- line's fault, so it doesn't count as a try.
function B.interrupt(p)
	if B.task then B.task.interrupted = true end
	local l = B.curLine()
	if l and l.status == "running" and not l.task then l.status, l.tries = "waiting", l.tries - 1 end
	if B.run then B.run.clearedTick = B.tickN end
	ISTimedActionQueue.clear(p)
end

---------------------------------------------------------------- reflexes
function B.reflexTick(p)
	if B.policy.melee ~= "auto" or p:getVehicle() then return end
	local zs = {}
	for _, e in ipairs(B.zombies(p, 3.5)) do if e.seen then zs[#zs + 1] = e end end
	if #zs == 0 then return end
	local close = 0
	for _, e in ipairs(zs) do if e.d < 2 then close = close + 1 end end
	local fleeN = tonumber(B.policy.flee)
	if fleeN and close >= fleeN then B.startFlee(p, zs); return end
	local t = zs[1]
	local w = p:getPrimaryHandItem()
	if not isMelee(w) and pon("rearm") then
		local best = B.bestMelee(p)
		if best then
			if getTimestampMs() < (B.rearmUntil or 0) then return end
			B.rearmUntil = getTimestampMs() + 3000
			B.interrupt(p)
			ISInventoryPaneContextMenu.equipWeapon(best, true, best:isTwoHandWeapon(), 0)
			B.rlog("equipped " .. best:getDisplayName() .. " (Z#" .. B.zid(t.z) .. " at " .. r2(t.d) .. ")")
			return
		end
	end
	if isMelee(w) then
		if t.d <= w:getMaxRange() + 0.3 then
			B.interrupt(p)
			B.fight = { untilMin = nowMin() + 3, reflex = true, radius = 3 }
		end
	elseif pon("shove") and not isGun(w) and t.d <= 1.2 then
		B.interrupt(p)
		B.fight = { untilMin = nowMin() + 3, reflex = true, shove = true, radius = 2 }
	end
end

-- Falling over a fence (the fall outcome of ClimbOverFenceState calls dropHandItems) leaves the
-- weapon on the ground with nothing said. Notice it and pick it back up; the interrupted line
-- resumes afterwards, as after any reflex. A weapon you `drop` on purpose is let go.
function B.recoverWeapon(p)
	local w = p:getPrimaryHandItem()
	-- held again: a deliberate `drop` of it earlier no longer counts
	if isMelee(w) then B.heldWeapon = w; if B.letGo then B.letGo[w:getID()] = nil end; return end
	local h = B.heldWeapon
	if not h then return end
	local wo = h:getWorldItem()
	if not wo or (B.letGo and B.letGo[h:getID()]) then
		-- put away, swapped, or dropped on purpose: stop watching it once it has left the hand
		if h:getContainer() or wo then B.heldWeapon = nil end
		return
	end
	B.heldWeapon = nil
	local sq = wo:getSquare()
	local at = sq and (sq:getX() .. "," .. sq:getY()) or "?"
	if not pon("rearm") then B.rlog("dropped " .. h:getDisplayName() .. " at " .. at); return end
	B.interrupt(p)
	toInventory(p, h, nil, wo)
	Q(ClaudeBotCall:new(p, "pick up dropped " .. h:getDisplayName(), function(p)
		if h:getContainer() ~= p:getInventory() then error("couldn't get it back; it's on the ground at " .. at) end
		ISInventoryPaneContextMenu.equipWeapon(h, true, h:isTwoHandWeapon(), 0)
	end))
	B.rlog("dropped " .. h:getDisplayName() .. " at " .. at .. " (a fall?); picking it back up")
end

-- run from a group: pick a free square ~10 tiles away from their centre, veering if blocked
function B.startFlee(p, zs)
	local px, py, pz = p:getX(), p:getY(), math.floor(p:getZ())
	local cx, cy, n = 0, 0, 0
	for _, e in ipairs(zs) do if e.d < 4 then cx = cx + e.z:getX(); cy = cy + e.z:getY(); n = n + 1 end end
	local dx, dy = px - cx / n, py - cy / n
	local len = math.sqrt(dx * dx + dy * dy)
	if len < 0.01 then dx, dy, len = 1, 0, 1 end
	dx, dy = dx / len, dy / len
	for _, ang in ipairs({ 0, 0.5, -0.5, 1.0, -1.0, 1.6, -1.6 }) do
		local c, s = math.cos(ang), math.sin(ang)
		local vx, vy = dx * c - dy * s, dx * s + dy * c
		for _, dist in ipairs({ 10, 7, 5 }) do
			local tx, ty = math.floor(px + vx * dist), math.floor(py + vy * dist)
			local sq = sqAt(tx, ty, pz)
			if sq and sq:getFloor() and try(function() return sq:isFree(false) end) then
				B.interrupt(p)
				try(function() p:setRunning(true) end)
				Q(ISPathFindAction:pathToLocationF(p, tx + 0.5, ty + 0.5, pz))
				B.fleeing = { n = n, untilMs = getTimestampMs() + 20000 }
				B.rlog("fleeing " .. n .. " zombies toward " .. tx .. "," .. ty)
				return
			end
		end
	end
	B.endTurn("surrounded: " .. n .. " zombies close and nowhere to run")
end

function B.fleeTick(p)
	local f = B.fleeing
	if #ISTimedActionQueue.getTimedActionQueue(p).queue == 0 or getTimestampMs() > f.untilMs then
		B.fleeing = nil
		ISTimedActionQueue.clear(p)
		try(function() p:setRunning(false) end)
		B.endTurn("fled from " .. f.n .. " zombies")
	end
end

-- bandage bleeding, then eat, when nothing is near; returns true if it queued something
function B.upkeep(p)
	if #B.zombies(p, 8) > 0 then return false end
	B.upkeepTried = B.upkeepTried or {}
	if pon("bandage") then
		local parts = p:getBodyDamage():getBodyParts()
		for i = 0, parts:size() - 1 do
			local bp = parts:get(i)
			if bp:bleeding() and not bp:bandaged() then
				local band
				eachItem(p:getInventory(), function(it)
					if not band and not B.upkeepTried[it] and (try(function() return it:getBandagePower() end) or 0) > 0
						and not try(function() return it:isWorn() end) then band = it end
				end)
				if band then
					B.upkeepTried[band] = true
					if band:getContainer() ~= p:getInventory() then Q(ISInventoryTransferAction:new(p, band, band:getContainer(), p:getInventory())) end
					Q(ISApplyBandage:new(p, p, band, bp, true))
					B.rlog("bandaging " .. BodyPartType.ToString(bp:getType()) .. " with " .. band:getDisplayName())
					return true
				end
			end
		end
	end
	local eat = tonumber(B.policy.eat)
	local hunger = p:getStats():get(CharacterStat.HUNGER)
	if eat and hunger > eat then
		local want = (hunger - 0.1) * 100
		local cands = {}
		eachItem(p:getInventory(), function(it)
			if instanceof(it, "Food") and not B.upkeepTried[it] then
				local h = -(it:getHungerChange() * 100)
				local bad = try(function() return it:isRotten() end) or try(function() return it:isPoison() end)
					or (try(function() return it:isbDangerousUncooked() end) and not try(function() return it:isCooked() end))
				if h >= 3 and not bad then cands[#cands + 1] = { it = it, h = h } end
			end
		end)
		table.sort(cands, function(a, b) return a.h < b.h end)
		local pick = cands[#cands]
		for _, c in ipairs(cands) do if c.h >= want then pick = c; break end end
		if pick then
			B.upkeepTried[pick.it] = true
			ISInventoryPaneContextMenu.eatItem(pick.it, 1, 0)
			B.rlog("eating " .. pick.it:getDisplayName() .. " (hunger " .. r2(hunger) .. ")")
			return true
		end
	end
	return false
end

---------------------------------------------------------------- goal commands
-- A goal owns the character until it finishes; the runner holds the turn's later lines meanwhile.
local function startTask(t, line)
	t.line = line
	B.task = t
end

function B.finishTask(ok, msg)
	local t = B.task
	B.task = nil
	t.ok = ok
	B.setSpeedRaw(B.speed)
	B.res(t.line, ok, msg)
	-- walking in through a locked door with its key unlocks it and leaves it that way
	if ok and t.home then
		local n = B.lockBase(P())
		if n > 0 then B.rlog("locking " .. n .. " base door" .. (n > 1 and "s" or "") .. " behind you") end
	end
end

function B.taskTick(p)
	if #ISTimedActionQueue.getTimedActionQueue(p).queue > 0 then return end
	local t = B.task
	local ok, err = pcall(t.tick, t, p)
	if not ok and B.task == t then B.finishTask(false, "error: " .. tostring(err)) end
end

local function freeNear(x, y, z, r)
	for rr = 0, r do
		for dx = -rr, rr do for dy = -rr, rr do
			if math.max(math.abs(dx), math.abs(dy)) == rr then
				local sq = sqAt(x + dx, y + dy, z)
				if sq and sq:getFloor() and try(function() return sq:isFree(false) end) then return x + dx, y + dy end
			end
		end end
	end
	return nil
end

-- travel: legs of up to 50 tiles; veers sideways after a failed or stuck leg
local TURNS = { 0, 0.6, -0.6, 1.2, -1.2 }
local LEGS = { 50, 30, 30, 20, 20 }
local function travelTick(t, p)
	-- a target on a counter or other blocked tile can never be reached; aim beside it
	if not t.checked then
		t.checked = true
		local sq = sqAt(t.x, t.y, t.z)
		if sq and not try(function() return sq:isFree(false) end) then
			local fx, fy = freeNear(t.x, t.y, t.z, 2)
			if fx then t.x, t.y = fx, fy end
		end
	end
	local px, py, pz = p:getX(), p:getY(), math.floor(p:getZ())
	local dx, dy = t.x + 0.5 - px, t.y + 0.5 - py
	local d = math.sqrt(dx * dx + dy * dy)
	if t.pathing then
		-- judge legs by progress toward the goal, not by movement: walking back and forth
		-- in front of a locked door moves plenty and gets nowhere
		t.pathing = false
		if not t.failed and d < t.best - 2 then t.best, t.fails = d, 0
		elseif not t.interrupted then t.fails = t.fails + 1 end
		t.failed, t.interrupted = false, false
		if t.fails >= #TURNS then
			return B.finishTask(false, "STUCK: no progress toward " .. t.x .. "," .. t.y .. " in " .. t.fails
				.. " tries; closest " .. r2(t.best) .. " tiles, now at " .. math.floor(px) .. "," .. math.floor(py)
				.. ". Locked door or fence? Find another way in (window, other door)")
		end
	end
	if d < 1.5 and pz == t.z then return B.finishTask(true, "arrived at " .. t.x .. "," .. t.y .. " in " .. t.legs .. " legs") end
	local tx, ty, tz
	if d <= 50 and t.fails == 0 then
		tx, ty, tz = t.x, t.y, t.z
	else
		local ang = TURNS[math.min(t.fails + 1, #TURNS)]
		local c, s = math.cos(ang), math.sin(ang)
		local ux, uy = dx / d, dy / d
		local vx, vy = ux * c - uy * s, ux * s + uy * c
		-- long legs run at ground level (the pathfinder takes the stairs)
		-- retries veer (TURNS) and shorten: a long leg often ends in a fenced yard
		local L = math.min(d, LEGS[math.min(t.fails + 1, #LEGS)])
		while L >= 4 and not tx do
			tx, ty = freeNear(math.floor(px + vx * L), math.floor(py + vy * L), 0, 3)
			L = L * 0.6
		end
		tz = 0
		if not tx then
			t.fails = t.fails + 1
			if t.fails >= #TURNS then return B.finishTask(false, "STUCK: no walkable ground toward " .. t.x .. "," .. t.y) end
			return
		end
	end
	t.legs = t.legs + 1
	t.lastX, t.lastY = px, py
	local act = ISPathFindAction:pathToLocationF(p, tx + 0.5, ty + 0.5, tz)
	act:setOnFail(function() t.failed = true end)
	Q(act)
	t.pathing = true
end

function B.newTravel(x, y, z)
	return { kind = "travel", x = x, y = y, z = z, fails = 0, legs = 0, best = math.huge, fast = true, tick = travelTick,
		status = function(t, p) return "travel to " .. t.x .. "," .. t.y .. "," .. t.z .. " (leg " .. t.legs .. ")" end }
end

B.cmds.travel = function(p, a, line)
	local x, y = num(a[1], "x"), num(a[2], "y")
	startTask(B.newTravel(x, y, tonumber(a[3]) or B.floorFor(x, y, math.floor(p:getZ()))), line)
	return "traveling"
end

function B.getBase()
	local raw = B.readFile("base.txt")
	local x, y, z = (raw or ""):match("(%-?%d+)%s+(%-?%d+)%s+(%-?%d+)")
	if not x then return nil end
	return { x = tonumber(x), y = tonumber(y), z = tonumber(z) }
end

B.immediate.setbase = function(p, a)
	local x = tonumber(a[1]) or math.floor(p:getX())
	local y = tonumber(a[2]) or math.floor(p:getY())
	local z = tonumber(a[3]) or math.floor(p:getZ())
	B.writeFile("base.txt", x .. " " .. y .. " " .. z)
	return "base set to " .. x .. "," .. y .. "," .. z
end

B.cmds.home = function(p, a, line)
	local b = B.getBase()
	if not b then error("no base yet: setbase first") end
	local t = B.newTravel(b.x, b.y, b.z)
	t.home = true
	startTask(t, line)
	return "heading home to " .. b.x .. "," .. b.y .. "," .. b.z
end

-- the building you're in, or the nearest one within maxD tiles (a BuildingDef)
---------------------------------------------------------------- vehicles
-- Lua can't press the car's pedals: CarController reads GameKeyboard, which has no setter.
-- So `drive` decides which keys to hold every tick and writes them to keys.txt, and pz.py
-- presses them in the game window (SendInput) until the turn ends.
local function vehName(v) return try(function() return v:getScript():getName() end) or "vehicle" end

function B.vehicles(p, r)
	local out, seen = {}, {}
	local px, py = math.floor(p:getX()), math.floor(p:getY())
	for x = px - r, px + r do for y = py - r, py + r do
		local sq = sqAt(x, y, 0)
		local v = sq and sq:getVehicleContainer()
		if v and not seen[v] then
			seen[v] = true
			local dx, dy = v:getX() - p:getX(), v:getY() - p:getY()
			out[#out + 1] = { v = v, d = math.sqrt(dx * dx + dy * dy) }
		end
	end end
	table.sort(out, function(a, b) return a.d < b.d end)
	return out
end

function B.vehInfo(p, v)
	local s = vehName(v) .. " @" .. math.floor(v:getX()) .. "," .. math.floor(v:getY())
	local gas = try(function() return v:getPartById("GasTank") end)
	if gas then s = s .. string.format(" gas %.0f/%.0f", gas:getContainerContentAmount(), gas:getContainerCapacity()) end
	local key = try(function() return p:getInventory():haveThisKeyId(v:getKeyId()) end) or try(function() return v:isKeysInIgnition() end)
	s = s .. (key and " KEY" or " no key")
	if try(function() return v:isEngineRunning() end) then s = s .. " engine on" end
	if try(function() return v:isAnyDoorLocked() end) then s = s .. " locked" end
	if v:getDriver() then s = s .. (v:getDriver() == p and " (you drive)" or " (occupied)") end
	return s
end

-- cars [radius]: vehicles nearby, nearest first
B.immediate.cars = function(p, a)
	local list = B.vehicles(p, tonumber(a[1]) or 30)
	local out = {}
	for i = 1, math.min(#list, 12) do out[#out + 1] = r2(list[i].d) .. "m " .. B.vehInfo(p, list[i].v) end
	return #list .. " vehicles\n      " .. table.concat(out, "\n      ")
end

local function vehicleArg(p, a)
	if a[1] and a[2] then
		local sq = sqAt(num(a[1]), num(a[2]), 0)
		local v = sq and sq:getVehicleContainer()
		if not v then error("no vehicle at " .. a[1] .. "," .. a[2]) end
		return v
	end
	local list = B.vehicles(p, 8)
	if not list[1] then error("no vehicle within 8 tiles") end
	return list[1].v
end

-- enter [x y]: get into the driver's seat of the car at x y (or the nearest one)
B.cmds.enter = function(p, a, line)
	if p:getVehicle() then error("already in a vehicle") end
	local v = vehicleArg(p, a)
	ISVehicleMenu.onEnter(p, v, 0)
	Q(ClaudeBotCall:new(p, line, function(pp)
		if pp:getVehicle() == v and v:isDriver(pp) then return "in the driver's seat: " .. B.vehInfo(pp, v) end
		error("didn't get in (seat blocked, or the path failed)")
	end))
	return "getting into " .. vehName(v)
end

local function driving(p)
	local v = p:getVehicle()
	if not v or not v:isDriver(p) then error("not in a driver's seat") end
	return v
end

-- engine [off]: start (needs the key or a hotwire) or shut off the engine
B.cmds.engine = function(p, a, line)
	local v = driving(p)
	if a[1] == "off" then
		Q(ISShutOffVehicleEngine:new(p))
		return "shutting off"
	end
	if v:isEngineRunning() then return "already running" end
	Q(ISStartVehicleEngine:new(p))
	Q(ClaudeBotWait:new(p, 1))
	Q(ClaudeBotCall:new(p, line, function(pp)
		if v:isEngineRunning() or v:isEngineStarted() then return "engine running" end
		error("engine didn't start (try again; cold or damaged engines fail)")
	end))
	return "starting the engine"
end

-- exit: stop and get out
B.cmds.exit = function(p, a, line)
	driving(p)
	B.setKeys("")
	ISVehicleMenu.onExit(p)
	Q(ClaudeBotCall:new(p, line, function(pp)
		if pp:getVehicle() then error("still in the vehicle (exit blocked?)") end
		return "out at " .. math.floor(pp:getX()) .. "," .. math.floor(pp:getY())
	end))
	return "getting out"
end

function B.setKeys(k)
	if k == B.keysHeld then return end
	B.keysHeld = k
	B.keySeq = (B.keySeq or 0) + 1
	B.writeFile("keys.txt", B.keySeq .. "\n" .. k .. "\n")
end

local function wrapAng(a)
	while a > math.pi do a = a - 2 * math.pi end
	while a < -math.pi do a = a + 2 * math.pi end
	return a
end

-- drive: pure pursuit through the waypoints; slow for turns, brake to a stop at the end
local function driveTick(t, p)
	local v = p:getVehicle()
	if not v or not v:isDriver(p) then B.setKeys(""); return B.finishTask(false, "not in a driver's seat") end
	if not v:isEngineRunning() then B.setKeys(""); return B.finishTask(false, "engine isn't running (engine)") end
	local now = getTimestampMs()
	-- a pause stops the ticks but not the clock; don't count it as being stuck
	if t.lastMs and now - t.lastMs > 500 then
		t.stuckSince = nil
		if t.revUntil then t.revUntil = now + 1200 end
	end
	t.lastMs = now
	local vx, vy = v:getX(), v:getY()
	local speed = v:getCurrentSpeedKmHour()
	local pt = t.pts[t.i]
	local dx, dy = pt[1] + 0.5 - vx, pt[2] + 0.5 - vy
	local d = math.sqrt(dx * dx + dy * dy)
	local last = t.i == #t.pts
	t.dist = d
	if not last and d < 4 then t.i = t.i + 1; return end
	if last and d < 3 then
		if math.abs(speed) > 1 then B.setKeys("SPACE"); return end
		B.setKeys("")
		return B.finishTask(true, "arrived at " .. math.floor(vx) .. "," .. math.floor(vy) .. " (" .. #t.pts .. " waypoints, " .. t.stucks .. " back-ups, " .. (t.kturns or 0) .. " K-turn moves, " .. (t.flips or 0) .. " steering flips, worst " .. r2(t.maxOff or 0) .. " tiles off the line)")
	end
	local f = v:getForwardVector(Vector3f.new())
	-- aim at a point LOOK tiles ahead on the segment from the previous waypoint, not at the
	-- waypoint itself: aiming straight at it cuts corners and weaves across the road
	local ax, ay = pt[1] + 0.5, pt[2] + 0.5
	local prev = t.pts[t.i - 1] or t.start
	local sx, sy = prev[1] + 0.5, prev[2] + 0.5
	local lx, ly = ax - sx, ay - sy
	local len = math.sqrt(lx * lx + ly * ly)
	if len > 1 and d > 4 then
		local ux, uy = lx / len, ly / len
		local proj = (vx - sx) * ux + (vy - sy) * uy
		t.maxOff = math.max(t.maxOff or 0, math.abs((vx - sx) * uy - (vy - sy) * ux))
		local s = math.min(len, math.max(0, proj) + 4)
		ax, ay = sx + ux * s, sy + uy * s
	end
	local err = wrapAng(math.atan2(ay - vy, ax - vx) - math.atan2(f:z(), f:x()))
	if t.revUntil and now < t.revUntil then
		-- backing up flips the steering: swing the nose toward where you want to go
		B.setKeys("S " .. (err < 0 and "D" or "A"))
		return
	end
	t.revUntil = nil
	-- target well behind: a K-turn. Short full-lock pulls forward, short reverses on the
	-- opposite lock. Driving it out in one arc needs a whole street and hits the parked cars.
	if not t.kturn and math.abs(err) > 1.9 then t.kturn = { fwd = true, x = vx, y = vy, at = now, n = 0 } end
	if t.kturn then
		local k = t.kturn
		if math.abs(err) < 0.9 then
			t.kturn = nil
		else
			local mx, my = vx - k.x, vy - k.y
			local moved = math.sqrt(mx * mx + my * my)
			if moved > 2 or now - k.at > 2500 then
				if math.abs(speed) > 1 then B.setKeys("SPACE"); return end
				k.fwd, k.x, k.y, k.at, k.n = not k.fwd, vx, vy, now, k.n + 1
				t.kturns = (t.kturns or 0) + 1
				if k.n > 12 then B.setKeys(""); return B.finishTask(false, "couldn't turn around at " .. math.floor(vx) .. "," .. math.floor(vy) .. " (no room?)") end
			end
			local lock = err < 0 and "A" or "D"
			if k.fwd then B.setKeys((math.abs(speed) < 6 and "W " or "") .. lock)
			else B.setKeys((math.abs(speed) < 6 and "S " or "") .. (lock == "A" and "D" or "A")) end
			return
		end
	end
	local keys = {}
	-- steering is on/off, so pulse it: hold the key for a share of each 250 ms that grows
	-- with the error (full lock only past ~0.5 rad). Holding it on any error overshoots.
	local duty = math.min(1, math.max(0, (math.abs(err) - 0.03) / 0.5))
	if duty > 0 and (now % 250) < duty * 250 then keys[#keys + 1] = err < 0 and "A" or "D" end
	local side = err < -0.03 and -1 or (err > 0.03 and 1 or 0)
	if side ~= 0 and t.side and side ~= t.side then t.flips = (t.flips or 0) + 1 end
	if side ~= 0 then t.side = side end
	local target = t.max
	if math.abs(err) > 0.4 then target = math.min(target, 12) end
	if math.abs(err) > 1.2 then target = math.min(target, 7) end
	if last then target = math.min(target, 4 + d * 1.5) end
	local gas = false
	if speed < target - 1 then keys[#keys + 1] = "W"; gas = true
	elseif speed > target + 4 then keys[#keys + 1] = "SPACE" end
	-- pressing the gas without moving: something's in the way; back up and try again
	if gas and speed < 1.5 then
		t.stuckSince = t.stuckSince or now
		if now - t.stuckSince > 2500 then
			t.stuckSince = nil
			t.stucks = t.stucks + 1
			if t.stucks > 5 then B.setKeys(""); return B.finishTask(false, "STUCK at " .. math.floor(vx) .. "," .. math.floor(vy) .. " after 5 back-ups; " .. r2(d) .. " tiles from waypoint " .. t.i) end
			t.revUntil = now + 1500
		end
	else
		t.stuckSince = nil
	end
	B.setKeys(table.concat(keys, " "))
end

-- reverse [tiles] [left|right]: back straight up (or steering) that far, then stop
local function reverseTick(t, p)
	local v = p:getVehicle()
	if not v or not v:isDriver(p) or not v:isEngineRunning() then B.setKeys(""); return B.finishTask(false, "not driving a running vehicle") end
	local now = getTimestampMs()
	if t.lastMs and now - t.lastMs > 500 then t.movedAt = now end
	t.lastMs = now
	local dx, dy = v:getX() - t.x0, v:getY() - t.y0
	local d = math.sqrt(dx * dx + dy * dy)
	local speed = v:getCurrentSpeedKmHour()
	if d >= t.dist then
		if math.abs(speed) > 1 then B.setKeys("SPACE"); return end
		B.setKeys("")
		return B.finishTask(true, "backed up " .. r2(d) .. " tiles to " .. math.floor(v:getX()) .. "," .. math.floor(v:getY()))
	end
	if math.abs(speed) > 1.5 then t.movedAt = now end
	if now - t.movedAt > 3000 then B.setKeys(""); return B.finishTask(false, "blocked after backing up " .. r2(d) .. " tiles") end
	B.setKeys((math.abs(speed) < 8 and "S" or "") .. (t.steer and " " .. t.steer or ""))
end

B.cmds.reverse = function(p, a, line)
	local v = driving(p)
	local steer = (a[2] == "left" and "A") or (a[2] == "right" and "D") or nil
	B.setSpeedRaw(1)
	startTask({ kind = "reverse", dist = tonumber(a[1]) or 4, steer = steer, x0 = v:getX(), y0 = v:getY(), movedAt = getTimestampMs(), tick = reverseTick,
		status = function(t) return "reversing" end }, line)
	return "backing up " .. (tonumber(a[1]) or 4) .. " tiles"
end

-- drive x y [x y ...] [max=kmh]: drive through waypoints (pick them along roads)
B.cmds.drive = function(p, a, line)
	driving(p)
	local pts, max, nums = {}, 25, {}
	for _, w in ipairs(a) do
		local m = w:match("^max=(%d+)$")
		if m then max = tonumber(m) else nums[#nums + 1] = num(w, "coordinate") end
	end
	if #nums < 2 or #nums % 2 == 1 then error("need x y pairs") end
	for i = 1, #nums, 2 do pts[#pts + 1] = { nums[i], nums[i + 1] } end
	B.setSpeedRaw(1)
	local v = p:getVehicle()
	startTask({ kind = "drive", pts = pts, i = 1, max = max, start = { math.floor(v:getX()), math.floor(v:getY()) }, stucks = 0, tick = driveTick,
		status = function(t) return "drive to waypoint " .. t.i .. "/" .. #t.pts .. " (" .. r2(t.dist or 0) .. " tiles)" end }, line)
	return "driving " .. #pts .. " waypoints at up to " .. max .. " km/h"
end

function B.buildingAt(p, maxD)
	local sq = p:getCurrentSquare()
	local b = sq and sq:getBuilding()
	if b then return b:getDef() end
	local px, py = p:getX(), p:getY()
	local all = getWorld():getMetaGrid():getBuildings()
	local best, bd
	for i = 0, all:size() - 1 do
		local d = all:get(i)
		local ex = math.max(d:getX() - px, 0, px - (d:getX() + d:getW()))
		local ey = math.max(d:getY() - py, 0, py - (d:getY() + d:getH()))
		local dist = math.sqrt(ex * ex + ey * ey)
		if dist <= maxD and (not best or dist < bd) then best, bd = d, dist end
	end
	return best
end

local function maxLevel(bdef) return try(function() return bdef:getMaxLevel() end) or 0 end

-- exterior doors/windows of a building on floor z that let zombies in (open or smashed)
function B.breaches(bdef, z)
	local out = {}
	for x = bdef:getX() - 1, bdef:getX() + bdef:getW() + 1 do
		for y = bdef:getY() - 1, bdef:getY() + bdef:getH() + 1 do
			local sq = sqAt(x, y, z)
			if sq then
				for _, o in ipairs(objList(sq)) do
					local door, win = isDoor(o), isWindow(o)
					if door or win then
						local n = o:getNorth()
						local other = n and sqAt(x, y - 1, z) or sqAt(x - 1, y, z)
						if other and sq:isOutside() ~= other:isOutside() and not try(function() return o:isBarricaded() end) then
							local what
							if door and try(function() return o:IsOpen() end) then what = "open door"
							elseif win and try(function() return o:isSmashed() end) then what = "smashed window"
							elseif win and try(function() return o:IsOpen() end) then what = "open window" end
							if what then out[#out + 1] = { what = what, x = x, y = y, edge = n and "N" or "W", obj = o, sq = sq, other = other } end
						end
					end
				end
			end
		end
	end
	return out
end

local function breachText(list)
	local t = {}
	for _, b in ipairs(list) do t[#t + 1] = b.what .. " " .. b.x .. "," .. b.y .. b.edge end
	return #t > 0 and table.concat(t, "; ") or "none"
end

-- every exterior door and window of a building on floor z, with its state
-- (nil if the area isn't loaded)
function B.openings(bdef, z)
	local out, loaded = { doors = 0, windows = 0, bad = 0, locked = 0 }, false
	for x = bdef:getX() - 1, bdef:getX() + bdef:getW() + 1 do
		for y = bdef:getY() - 1, bdef:getY() + bdef:getH() + 1 do
			local sq = sqAt(x, y, z)
			if sq then
				loaded = true
				for _, o in ipairs(objList(sq)) do
					local door, win = isDoor(o), isWindow(o)
					if door or win then
						local other = o:getNorth() and sqAt(x, y - 1, z) or sqAt(x - 1, y, z)
						if other and sq:isOutside() ~= other:isOutside() then
							if door then
								out.doors = out.doors + 1
								if try(function() return o:isLocked() end) then out.locked = out.locked + 1 end
								if try(function() return o:IsOpen() end) then out.bad = out.bad + 1 end
							else
								out.windows = out.windows + 1
								if try(function() return o:isSmashed() or o:IsOpen() end) then out.bad = out.bad + 1 end
							end
						end
					end
				end
			end
		end
	end
	return loaded and out or nil
end

-- homes [radius]: nearby houses ranked by how easy they are to hold: few ground-floor
-- openings, nothing already broken, an upstairs to retreat to
B.immediate.homes = function(p, a)
	local R = tonumber(a[1]) or 120
	local px, py = p:getX(), p:getY()
	local all = getWorld():getMetaGrid():getBuildings()
	local found = {}
	for i = 0, all:size() - 1 do
		local b = all:get(i)
		local dx, dy = b:getX() + b:getW() / 2 - px, b:getY() + b:getH() / 2 - py
		local d = math.sqrt(dx * dx + dy * dy)
		if d <= R and b:getW() * b:getH() <= 700 then
			local rs, names, bedroom, n = b:getRooms(), {}, false, 0
			for j = 0, rs:size() - 1 do
				local nm = rs:get(j):getName() or "?"
				n = n + 1
				if nm == "bedroom" then bedroom = true end
				if not names[nm] then names[nm] = true; names[#names + 1] = nm end
			end
			if bedroom and n <= 20 then
				local g = B.openings(b, 0)
				if g then
					local floors = maxLevel(b) + 1
					-- lower is better: each opening is something to watch or board up
					local score = g.doors * 2 + g.windows + g.bad * 6 - (floors > 1 and 4 or 0)
					found[#found + 1] = { b = b, d = d, g = g, floors = floors, score = score, names = names }
				end
			end
		end
	end
	table.sort(found, function(x, y) return x.score < y.score end)
	local lines = {}
	for i = 1, math.min(#found, 10) do
		local e = found[i]
		local b = e.b
		lines[#lines + 1] = string.format("score %d | %dm | box %d,%d %dx%d | floors %d | ground: %d doors (%d locked), %d windows, %d open/broken%s | %s",
			e.score, math.floor(e.d), b:getX(), b:getY(), b:getW(), b:getH(), e.floors, e.g.doors, e.g.locked, e.g.windows, e.g.bad,
			try(function() return b:isAllExplored() end) and " | explored" or "", table.concat(e.names, ","))
	end
	B.scanResult = lines
	return #found .. " houses within " .. R .. " (loaded area only), best first"
end

-- a free square inside the room, nearest its middle (nil if none loaded)
local function roomSpot(rd)
	local cx, cy = rd:getX() + rd:getW() / 2, rd:getY() + rd:getH() / 2
	local best, bd
	for x = rd:getX(), rd:getX() + rd:getW() - 1 do
		for y = rd:getY(), rd:getY() + rd:getH() - 1 do
			local sq = sqAt(x, y, rd:getZ())
			local room = sq and sq:getRoom()
			if room and try(function() return room:getRoomDef() == rd end) and try(function() return sq:isFree(false) end) then
				local d = (x + 0.5 - cx) ^ 2 + (y + 0.5 - cy) ^ 2
				if not best or d < bd then best, bd = { x = x, y = y, z = rd:getZ() }, d end
			end
		end
	end
	return best
end

-- sweep: visit every room on this floor, hunt what's seen there, report breaches
local function sweepTick(t, p)
	if t.cur then
		-- a path can end without reaching the spot (and without calling onFail), so check
		local off = math.sqrt((p:getX() - t.spot.x - 0.5) ^ 2 + (p:getY() - t.spot.y - 0.5) ^ 2)
		if t.failed or off > 2 then
			t.unreachable[#t.unreachable + 1] = t.cur:getName() .. "@" .. t.spot.x .. "," .. t.spot.y
			B.rlog("sweep: missed " .. t.cur:getName() .. " (" .. (t.failed and "no path" or r2(off) .. " tiles short") .. ")")
		else
			local seen = false
			for _, e in ipairs(B.zombies(p, 12)) do if e.seen then seen = true end end
			if seen and t.fights < 3 then
				t.fights = t.fights + 1
				B.fight = { untilMin = nowMin() + 5, hunt = true, task = true, radius = 12 }
				return
			end
			t.cleared = t.cleared + 1
		end
		t.cur, t.failed, t.fights = nil, false, 0
	end
	local px, py = p:getX(), p:getY()
	local bestI, bestSpot, bd
	for i, rd in ipairs(t.rooms) do
		local spot = roomSpot(rd)
		if spot then
			local d = (spot.x - px) ^ 2 + (spot.y - py) ^ 2
			if not bestI or d < bd then bestI, bestSpot, bd = i, spot, d end
		end
	end
	if not bestI then
		for _, rd in ipairs(t.rooms) do t.unreachable[#t.unreachable + 1] = rd:getName() .. "(not loaded)" end
		return B.finishTask(true, "swept " .. t.cleared .. "/" .. t.total .. " rooms on floor " .. t.z .. ", killed " .. (B.kills - t.kills0)
			.. (#t.unreachable > 0 and "; unreachable: " .. table.concat(t.unreachable, ",") or "")
			.. "; breaches: " .. breachText(B.breaches(t.bdef, t.z)))
	end
	t.cur, t.spot = table.remove(t.rooms, bestI), bestSpot
	local act = ISPathFindAction:pathToLocationF(p, bestSpot.x + 0.5, bestSpot.y + 0.5, bestSpot.z)
	act:setOnFail(function() t.failed = true end)
	Q(act)
end

B.cmds.sweep = function(p, a, line)
	local bdef = B.buildingAt(p, 20)
	if not bdef then error("no building within 20 tiles") end
	local z = math.floor(p:getZ())
	local rooms = {}
	local rs = bdef:getRooms()
	for i = 0, rs:size() - 1 do
		local rd = rs:get(i)
		if rd:getZ() == z then rooms[#rooms + 1] = rd end
	end
	B.kills = B.kills or 0
	startTask({ kind = "sweep", bdef = bdef, z = z, rooms = rooms, total = #rooms, cleared = 0, fights = 0,
		unreachable = {}, kills0 = B.kills, tick = sweepTick,
		status = function(t) return "sweep " .. t.cleared .. "/" .. t.total .. " rooms" end }, line)
	return "sweeping " .. #rooms .. " rooms on floor " .. z
end

-- secure: close the building's open exterior doors and windows from the inside
B.cmds.secure = function(p, a)
	local bdef = B.buildingAt(p, 20)
	if not bdef then error("no building within 20 tiles") end
	local z = math.floor(p:getZ())
	local closing, left = 0, {}
	for _, b in ipairs(B.breaches(bdef, z)) do
		if b.what == "smashed window" then
			left[#left + 1] = b
		else
			local inside = b.sq:isOutside() and b.other or b.sq
			Q(ISPathFindAction:pathToLocationF(p, inside:getX() + 0.5, inside:getY() + 0.5, z))
			if b.what == "open door" then Q(ISOpenCloseDoor:new(p, b.obj)) else Q(ISOpenCloseWindow:new(p, b.obj)) end
			closing = closing + 1
		end
	end
	-- curtains: a zombie that sees you through a window breaks it
	local curtains = 0
	for x = bdef:getX() - 1, bdef:getX() + bdef:getW() + 1 do
		for y = bdef:getY() - 1, bdef:getY() + bdef:getH() + 1 do
			local sq = sqAt(x, y, z)
			if sq then
				for _, o in ipairs(objList(sq)) do
					if instanceof(o, "IsoCurtain") and try(function() return o:IsOpen() end) then
						ISWorldObjectContextMenu.onOpenCloseCurtain(nil, o, 0)
						curtains = curtains + 1
					end
				end
			end
		end
	end
	return "closing " .. closing .. " doors/windows and " .. curtains .. " curtains; still open: " .. breachText(left)
end

-- survey [filter]: what the building's containers hold, without walking to them
B.immediate.survey = function(p, a)
	local bdef = B.buildingAt(p, 20)
	if not bdef then error("no building within 20 tiles") end
	local filter = a[1] and a[1]:lower()
	if filter == "weapon" or filter == "weapons" then
		-- real melee weapons, strongest first
		local found = {}
		for z = 0, maxLevel(bdef) do
			for x = bdef:getX(), bdef:getX() + bdef:getW() - 1 do
				for y = bdef:getY(), bdef:getY() + bdef:getH() - 1 do
					local sq = sqAt(x, y, z)
					if sq then
						for _, e in ipairs(B.containersOn(sq)) do
							eachItem(e.c, function(it)
								if isMelee(it) and it:getMaxDamage() >= 0.5 then found[#found + 1] = { it = it, x = x, y = y, z = z, kind = e.kind } end
							end)
						end
						for _, wo in ipairs(B.floorItems(sq)) do
							if isMelee(wo:getItem()) and wo:getItem():getMaxDamage() >= 0.5 then found[#found + 1] = { it = wo:getItem(), x = x, y = y, z = z, kind = "floor" } end
						end
					end
				end
			end
		end
		table.sort(found, function(a, b) return a.it:getMaxDamage() > b.it:getMaxDamage() end)
		local lines = {}
		for i = 1, math.min(#found, 15) do
			local f = found[i]
			lines[#lines + 1] = string.format("%d,%d,%d %s: %s #%d dmg %.2f cond %d/%d", f.x, f.y, f.z, f.kind, f.it:getDisplayName(), f.it:getID(),
				f.it:getMaxDamage(), f.it:getCondition(), f.it:getConditionMax())
		end
		B.surveyResult = lines
		return #found .. " melee weapons"
	end
	local lines, nC, nEmpty = {}, 0, 0
	for z = 0, maxLevel(bdef) do
		for x = bdef:getX(), bdef:getX() + bdef:getW() - 1 do
			for y = bdef:getY(), bdef:getY() + bdef:getH() - 1 do
				local sq = sqAt(x, y, z)
				if sq then
					for ci, e in ipairs(B.containersOn(sq)) do
						nC = nC + 1
						local items = e.c:getItems()
						if items:size() == 0 then nEmpty = nEmpty + 1 end
						local names, order = {}, {}
						for i = 0, items:size() - 1 do
							local it = items:get(i)
							local nm = it:getDisplayName()
							local cat = (try(function() return it:getDisplayCategory() end) or ""):lower()
							if not filter or nm:lower():find(filter, 1, true) or it:getFullType():lower():find(filter, 1, true) or cat:find(filter, 1, true) then
								local key = filter and (nm .. " #" .. it:getID()) or nm
								if not names[key] then names[key] = 0; order[#order + 1] = key end
								names[key] = names[key] + 1
							end
						end
						if #order > 0 then
							local parts = {}
							for _, k in ipairs(order) do parts[#parts + 1] = names[k] > 1 and (k .. " x" .. names[k]) or k end
							local txt = table.concat(parts, ", ")
							if #txt > 160 then txt = txt:sub(1, 157) .. "..." end
							lines[#lines + 1] = string.format("%d,%d,%d %s%s: %s", x, y, z, e.kind, ci > 1 and ("#" .. ci) or "", txt)
						end
					end
				end
			end
		end
	end
	local total = #lines
	if not filter and total > 30 then
		for i = #lines, 31, -1 do lines[i] = nil end
		lines[#lines + 1] = "... " .. (total - 30) .. " more; narrow it: survey <word> matches item names, types and categories (weapon, food, firstaid, container...)"
	end
	B.surveyResult = lines
	return nC .. " containers (" .. nEmpty .. " empty), " .. total .. " with matches"
end

-- stash x y [n] [keep id ...] [all]: put carried things in container n at x,y. Keeps worn
-- and equipped items and the listed ids; "all" empties bags too.
-- find type[,type...] [radius]: every loaded container or floor spot (default 60 tiles, all
-- floors) holding items whose type or name contains one of the words; nearest first
B.immediate.find = function(p, a)
	if not a[1] then error("find what? e.g. find plank,nails,saw 60") end
	local words = {}
	for w in a[1]:lower():gmatch("[^,]+") do words[#words + 1] = w end
	local R = tonumber(a[2]) or 60
	local px, py = math.floor(p:getX()), math.floor(p:getY())
	local function match(it)
		local t, n = it:getType():lower(), it:getDisplayName():lower()
		for _, w in ipairs(words) do if t:find(w, 1, true) or n:find(w, 1, true) then return it:getDisplayName() end end
	end
	local spots = {}
	local function add(x, y, z, where, name)
		local k = x .. "," .. y .. "," .. z .. " " .. where
		local e = spots[k]
		if not e then e = { k = k, d = math.sqrt((x - px) ^ 2 + (y - py) ^ 2), n = {} }; spots[k] = e end
		e.n[name] = (e.n[name] or 0) + 1
	end
	for z = 0, 3 do for x = px - R, px + R do for y = py - R, py + R do
		local sq = sqAt(x, y, z)
		if sq then
			for _, e in ipairs(B.containersOn(sq)) do
				eachItem(e.c, function(it) local m = match(it); if m then add(x, y, z, e.kind, m) end end)
			end
			for _, wo in ipairs(B.floorItems(sq)) do
				local m = match(wo:getItem()); if m then add(x, y, z, "floor", m) end
			end
		end
	end end end
	local list = {}
	for _, e in pairs(spots) do list[#list + 1] = e end
	if #list == 0 then return "none within " .. R end
	table.sort(list, function(x, y) return x.d < y.d end)
	local lines = {}
	for i = 1, math.min(#list, 25) do
		local e, bits = list[i], {}
		for n, c in pairs(e.n) do bits[#bits + 1] = n .. (c > 1 and (" x" .. c) or "") end
		lines[#lines + 1] = math.floor(e.d) .. "m " .. e.k .. ": " .. table.concat(bits, ", ")
	end
	return #list .. " spots" .. (#list > 25 and " (nearest 25)" or "") .. "\n      " .. table.concat(lines, "\n      ")
end

-- fortification of a building: every exterior window/door with planks per side, state, key
function B.fortInfo(p, bdef)
	local rows, win, boarded, doors, locked = {}, 0, 0, 0, 0
	for z = 0, maxLevel(bdef) do
		for x = bdef:getX() - 1, bdef:getX() + bdef:getW() + 1 do
			for y = bdef:getY() - 1, bdef:getY() + bdef:getH() + 1 do
				local sq = sqAt(x, y, z)
				if sq then
					for _, o in ipairs(objList(sq)) do
						local door, w = isDoor(o), isWindow(o)
						if door or w then
							local other = o:getNorth() and sqAt(x, y - 1, z) or sqAt(x - 1, y, z)
							if other and sq:isOutside() ~= other:isOutside() then
								local b1 = try(function() return o:getBarricadeOnSameSquare() end)
								local b2 = try(function() return o:getBarricadeOnOppositeSquare() end)
								local pl = (b1 and b1:getNumPlanks() or 0) + (b2 and b2:getNumPlanks() or 0)
								local f = {}
								if try(function() return o:IsOpen() end) then f[#f + 1] = "OPEN" end
								if w and try(function() return o:isSmashed() end) then f[#f + 1] = "SMASHED" end
								if door then
									doors = doors + 1
									local lk = try(function() return o:isLocked() end)
									if lk then locked = locked + 1; f[#f + 1] = "locked" else f[#f + 1] = "UNLOCKED" end
									local kid = try(function() return o:getKeyId() end)
									if kid and kid ~= -1 then
										f[#f + 1] = (try(function() return p:getInventory():haveThisKeyId(kid) end) and "key: have" or "key: NOT CARRIED")
									end
								else
									win = win + 1
									if pl > 0 then boarded = boarded + 1 end
								end
								rows[#rows + 1] = string.format("%s %d,%d,%d planks=%d %s", door and "door" or "window", x, y, z, pl, table.concat(f, " "))
							end
						end
					end
				end
			end
		end
	end
	return rows, string.format("%d/%d windows boarded, %d/%d doors locked", boarded, win, locked, doors)
end
-- queue closing and locking every unlocked exterior base door you carry the key for
function B.lockBase(p)
	local bdef = B.baseBuilding(p)
	if not bdef then return 0 end
	local n = 0
	for z = 0, maxLevel(bdef) do
		for x = bdef:getX() - 1, bdef:getX() + bdef:getW() + 1 do
			for y = bdef:getY() - 1, bdef:getY() + bdef:getH() + 1 do
				local sq = sqAt(x, y, z)
				for _, o in ipairs(sq and objList(sq) or {}) do
					local other = isDoor(o) and (o:getNorth() and sqAt(x, y - 1, z) or sqAt(x - 1, y, z))
					if other and sq:isOutside() ~= other:isOutside() and not try(function() return o:isLocked() end) then
						local kid = try(function() return o:getKeyId() end)
						if kid and kid ~= -1 and try(function() return p:getInventory():haveThisKeyId(kid) end) then
							if luautils.walkAdjWindowOrDoor(p, o:getSquare(), o) then
								if try(function() return o:IsOpen() end) then Q(ISOpenCloseDoor:new(p, o)) end
								Q(ISLockDoor:new(p, o, true))
								n = n + 1
							end
						end
					end
				end
			end
		end
	end
	return n
end
function B.baseBuilding(p)
	local b = B.getBase()
	local sq = b and sqAt(b.x, b.y, b.z)
	local bd = sq and sq:getBuilding()
	return bd and bd:getDef()
end
-- fort: the base's openings (or this building's with "fort here")
B.immediate.fort = function(p, a)
	local bdef = (a[1] ~= "here" and B.baseBuilding(p)) or B.buildingAt(p, 20)
	if not bdef then error("no base set and no building nearby") end
	local rows, sum = B.fortInfo(p, bdef)
	return sum .. "\n      " .. table.concat(rows, "\n      ")
end

B.cmds.stash = function(p, a)
	local sq = sqAt(num(a[1]), num(a[2]), math.floor(p:getZ()))
	local cs = B.containersOn(sq)
	-- a small third number picks the container; item ids are big
	local n, first = 1, 3
	if tonumber(a[3]) and tonumber(a[3]) < 10 then n, first = tonumber(a[3]), 4 end
	local e = cs[n]
	if not e then error("no container there") end
	local keep, all = {}, false
	for i = first, #a do
		if a[i] == "all" then all = true elseif tonumber(a[i]) then keep[tonumber(a[i])] = true end
	end
	local inv = p:getInventory()
	local list = {}
	local function consider(it)
		if keep[it:getID()] or p:isEquipped(it) or try(function() return it:isWorn() end) then return end
		if try(function() return instanceof(it, "Key") or it:getFullType():find("KeyRing", 1, true) ~= nil end) then return end
		list[#list + 1] = it
	end
	eachItem(inv, function(it)
		if it:getContainer() == inv then consider(it)
		elseif all then consider(it) end
	end)
	luautils.walkToContainer(e.c, 0)
	local room = e.c:getCapacity() - e.c:getCapacityWeight()
	local moved, skipped = 0, 0
	for _, it in ipairs(list) do
		local w = it:getUnequippedWeight()
		if w <= room then
			room = room - w
			Q(ISInventoryTransferAction:new(p, it, it:getContainer(), e.c))
			moved = moved + 1
		else
			skipped = skipped + 1
		end
	end
	return "stashing " .. moved .. " items in " .. e.kind .. (skipped > 0 and ("; " .. skipped .. " didn't fit") or "")
end

---------------------------------------------------------------- turn loop
function B.biteCount(p)
	local n, parts = 0, p:getBodyDamage():getBodyParts()
	-- bitten() hides covered wounds; the timer preserves the underlying injury.
	for i = 0, parts:size() - 1 do
		local bp = parts:get(i)
		if bp:bitten() or bp:getBiteTime() > 0 then n = n + 1 end
	end
	return n
end

function B.visibleSet(p)
	local s = {}
	for _, e in ipairs(B.zombies(p, 30)) do if e.seen then s[B.zid(e.z)] = true end end
	return s
end

function B.startTurn(id, lines)
	local p = P()
	B.turn = id
	B.results = {}
	B.reflexLog = {}
	B.upkeepTried = {}
	if not p or p:isDead() then B.dumpState(p and "dead" or "no player"); return end
	local cont = false
	if lines[1] and lines[1]:match("^%s*continue") then cont = true; table.remove(lines, 1) end
	if not cont or not B.run then
		if #ISTimedActionQueue.getTimedActionQueue(p).queue > 0 or p:getCharacterActions():size() > 0 then ISTimedActionQueue.clear(p) end
		B.fight = nil; B.bash = nil; B.task = nil; B.fleeing = nil
		B.run = nil
		B.setSpeedRaw(B.speed)
	else
		-- a hit or a pause stopped the turn: run the interrupted line again, then the rest
		local l = B.curLine()
		if l and l.status == "running" and not l.task and #ISTimedActionQueue.getTimedActionQueue(p).queue == 0 then l.status = "waiting" end
	end
	if try(function() return p:isPerformingAttackAnimation() end) then p:setPerformingAttackAnimation(false) end
	p:setIsAiming(false)
	local entries = {}
	for _, l in ipairs(lines) do
		local args = {}
		for w in l:gmatch("%S+") do args[#args + 1] = w end
		local verb = table.remove(args, 1)
		if not (B.cmds[verb] or B.immediate[verb]) then
			B.res(l, false, "unknown command")
		elseif B.immediate[verb] and #entries == 0 and not B.run then
			-- instant commands before any queued one run now, with the game still paused
			local ok, msg = pcall(B.immediate[verb], p, args, l)
			B.res(l, ok, msg)
		else
			entries[#entries + 1] = { l, verb, args }
		end
	end
	if B.run then
		for _, e in ipairs(B.newRun(entries).lines) do table.insert(B.run.lines, e) end
	elseif #entries > 0 then
		B.run = B.newRun(entries)
	end
	local needRun = B.run ~= nil and B.run.cur <= #B.run.lines
	B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
	B.turnBites = B.biteCount(p)
	B.turnSeen = B.visibleSet(p)
	-- zombies already in reach were reported last turn; re-pausing on them every turn
	-- means no timed action (equip, take) ever finishes while one is chewing on you
	B.turnClose = {}
	for _, e in ipairs(B.zombies(p, 2.5)) do B.turnClose[B.zid(e.z)] = true end
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
	if B.keysHeld and B.keysHeld ~= "" then B.setKeys("") end
	B.setPaused(true)
	B.dumpState(reason)
end

local BUSY_STATES = { "OpenWindowState", "CloseWindowState", "SmashWindowState", "ClimbThroughWindowState",
	"ClimbOverFenceState", "ClimbOverWallState", "ClimbSheetRopeState", "ClimbDownSheetRopeState",
	"PlayerGetUpState", "PlayerFallDownState", "PlayerKnockedDown", "PlayerOnGroundState" }
function B.busyState(st)
	if not st then return false end
	for _, n in ipairs(BUSY_STATES) do
		local cls = _G[n]
		if cls and st == cls.instance() then return true end
	end
	return false
end

function B.monitor(p)
	if not B.turnActive then return end
	if p:isDead() then B.endTurn("DEAD"); return end
	-- Check before deferred work or animation waits can return early.
	local h = p:getBodyDamage():getOverallBodyHealth()
	local bites = B.biteCount(p)
	if bites > (B.turnBites or bites) then B.turnBites = bites; B.turnHealth = h; B.endTurn("BITTEN (health " .. r2(h) .. ")"); return end
	if B.turnHealth and h < B.turnHealth - B.hurtPause then B.turnHealth = h; B.endTurn("hurt (health " .. r2(h) .. ")"); return end
	B.tickN = (B.tickN or 0) + 1
	-- window/fence climbs run as player states after their action leaves the queue
	local st = p:getCurrentState()
	-- window, climb and fall animations run as player states after their action leaves the
	-- queue; ending the turn then pauses mid-animation and the window never opens
	local climbing = B.busyState(st) or (try(function() return p:isClimbing() end) or false)
	if B.fight then B.fightTick(p)
	elseif B.fleeing then B.fleeTick(p)
	elseif not B.bash and not climbing and not p:isAsleep() and B.tickN % 3 == 0 then B.recoverWeapon(p); B.reflexTick(p) end
	if B.bash then B.bashTick(p) end
	if not B.turnActive then return end
	if B.task and not B.fight and not B.fleeing and not climbing then B.taskTick(p) end
	if not B.turnActive or B.tickN % 5 ~= 0 then return end
	local defend = B.canDefend(p)
	if B.task and B.task.fast and B.tickN % 10 == 0 then
		B.setSpeedRaw((#B.zombies(p, 15) > 0 or B.fight) and B.speed or 3)
	end
	local coming = 0
	for _, e in ipairs(B.zombies(p, 20)) do
		local id = B.zid(e.z)
		local targeting = try(function() return e.z:getTarget() == p end)
		if e.seen and targeting and e.d <= 15 then coming = coming + 1 end
		-- a far zombie that isn't after you isn't news yet; it can still trigger later
		-- once it gets close or starts coming
		if e.seen and not B.turnSeen[id] and e.d <= 15 and (e.d <= 8 or targeting) then
			B.turnSeen[id] = true
			if not B.fight and not defend then B.endTurn("new zombie #" .. id .. " at " .. r2(e.d) .. " tiles"); return end
			B.rlog("saw Z#" .. id .. " at " .. r2(e.d) .. (targeting and " (coming)" or ""))
		end
		if e.d < 2.5 and not B.fight and not B.turnClose[id] and not defend then
			B.turnClose[id] = true
			B.endTurn("zombie #" .. id .. " within " .. r2(e.d) .. " tiles"); return
		end
	end
	-- warn once per group (again only if it grows by 2); forget it once they stop coming
	local horde = (tonumber(B.policy.flee) or 3) + 1
	if coming < horde then B.hordeWarned = nil end
	if coming >= horde and (not B.hordeWarned or coming >= B.hordeWarned + 2) then
		B.hordeWarned = coming
		B.endTurn("horde: " .. coming .. " zombies coming for you"); return
	end
	-- a night's sleep runs past the turn limit; the turn ends when you wake up
	local asleep = p:isAsleep()
	if B.wasAsleep and not asleep then B.wasAsleep = nil; B.endTurn("woke up (fatigue " .. r2(p:getStats():get(CharacterStat.FATIGUE)) .. ")"); return end
	B.wasAsleep = asleep or nil
	if nowMin() > B.turnDeadline and not asleep then B.endTurn("turn time limit"); return end
	if climbing then B.climbSeen = true; return end
	B.runTick(p)
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
