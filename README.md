# pz-bot

Turn-based remote control for Project Zomboid B42 (singleplayer), so Claude can play.

- `mod/ClaudeBot/`: the game mod, a thin loader that runs `runtime/bot.lua`
- `runtime/bot.lua`: all bot logic. The game reads it from `~/Zomboid/Lua/claudebot/`; `python pz.py reload` hot-reloads it
- `runtime/` also holds `cmd.txt`, `state.json` and the loader status (gitignored)
- `pz.py`: driver. `python pz.py do "go 100 200" "loot 101 200"` sends a turn, waits for the auto-pause and prints the state
- `install.cmd`: creates the two junctions into `~/Zomboid` (already done on this PC)
