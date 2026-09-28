-- Redirect for hot reload: the in-game loader from the first session looks here.
-- Pulls in the real bot file from the B42 folder.
if ClaudeBotLoader then reloadLuaFile(getModInfoByID("ClaudeBot"):getDir() .. "/42/media/lua/client/ClaudeBot.lua") end
