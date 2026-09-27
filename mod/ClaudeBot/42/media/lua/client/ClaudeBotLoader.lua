-- Event glue + hot reload. ClaudeBot.lua (all the logic) is loaded by the game
-- before this file; touching claudebot/reload.txt re-runs it via reloadLuaFile.
ClaudeBotLoader = ClaudeBotLoader or {}
local L = ClaudeBotLoader

local function readAll(path)
	local r = getFileReader(path, false)
	if not r then return nil end
	local lines = {}
	local l = r:readLine()
	while l do lines[#lines + 1] = l; l = r:readLine() end
	r:close()
	return table.concat(lines, "
")
end

local function writeStatus(msg)
	local w = getFileWriter("claudebot/loader.txt", true, false)
	w:write(tostring(msg))
	w:close()
end

function L.botPath()
	local info = getModInfoByID("ClaudeBot")
	return info:getDir() .. "/media/lua/client/ClaudeBot.lua"
end

function L.load()
	local ok, e = pcall(function() reloadLuaFile(L.botPath()) end)
	if not ok then writeStatus("ERR reload: " .. tostring(e)); return false end
	writeStatus("OK reloaded " .. tostring(ClaudeBot and ClaudeBot.VERSION) .. " at " .. tostring(getTimestampMs()) .. " from " .. L.botPath())
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

writeStatus(ClaudeBot and ("OK bot v" .. tostring(ClaudeBot.VERSION)) or "ERR ClaudeBot.lua did not load")
Events.OnTick.Add(function() call("onTick") end)
Events.OnRenderTick.Add(function() checkReload(); call("onRender") end)
Events.OnPlayerUpdate.Add(function(p) call("onPlayerUpdate", p) end)
