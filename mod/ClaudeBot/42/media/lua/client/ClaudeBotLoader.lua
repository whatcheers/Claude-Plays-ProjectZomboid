-- Thin loader. Real logic is in ~/Zomboid/Lua/claudebot/bot.lua so it can be
-- hot-reloaded: touching claudebot/reload.txt re-reads and re-runs it.
ClaudeBotLoader = ClaudeBotLoader or {}
local L = ClaudeBotLoader

local function readAll(path)
	local r = getFileReader(path, false)
	if not r then return nil end
	local lines = {}
	local l = r:readLine()
	while l do lines[#lines + 1] = l; l = r:readLine() end
	r:close()
	return table.concat(lines, "\n")
end

local function writeStatus(msg)
	local w = getFileWriter("claudebot/loader.txt", true, false)
	w:write(tostring(msg))
	w:close()
end

function L.load()
	local src = readAll("claudebot/bot.lua")
	if not src then writeStatus("ERR bot.lua missing"); return false end
	local f, err = loadstring(src, "bot.lua")
	if not f then writeStatus("ERR compile: " .. tostring(err)); print("[ClaudeBot] " .. tostring(err)); return false end
	local ok, e = pcall(f)
	if not ok then writeStatus("ERR run: " .. tostring(e)); print("[ClaudeBot] " .. tostring(e)); return false end
	writeStatus("OK loaded " .. tostring(getTimestampMs()))
	return true
end

L.lastReload = L.lastReload or readAll("claudebot/reload.txt")
L.lastCheck = 0
L.lastErr = nil

local function checkReload()
	local now = getTimestampMs()
	if now - L.lastCheck < 1000 then return end
	L.lastCheck = now
	local r = readAll("claudebot/reload.txt")
	if r and r ~= L.lastReload then
		L.lastReload = r
		L.load()
	end
end

local function call(name, ...)
	if ClaudeBot and ClaudeBot[name] then
		local ok, e = pcall(ClaudeBot[name], ...)
		if not ok then
			e = tostring(e)
			if e ~= L.lastErr then
				L.lastErr = e
				print("[ClaudeBot] " .. name .. ": " .. e)
				writeStatus("ERR " .. name .. ": " .. e)
			end
		end
	end
end

L.load()
Events.OnTick.Add(function() call("onTick") end)
Events.OnRenderTick.Add(function() checkReload(); call("onRender") end)
Events.OnPlayerUpdate.Add(function(p) call("onPlayerUpdate", p) end)
