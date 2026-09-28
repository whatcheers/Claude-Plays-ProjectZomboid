# ClaudeBot: let an AI play Project Zomboid

A Project Zomboid **Build 42** mod that turns singleplayer into a turn-based game an AI agent
(or any script) can play. The agent sends a handful of commands, the game unpauses and runs them
using the game's own actions (pathfinding, looting, doors, windows, eating, fighting...), then
**pauses itself** and writes out what the character sees.

It was built so [Claude Code](https://claude.com/claude-code) could play Zomboid from a terminal,
and on its first run it looted a gas station, raided a restaurant kitchen, looked up the Rosewood
Fire Department online, walked there, killed six zombies and took a fire axe without getting hurt.

```
== turn 905546181 | pause reason: done | 7/9 11:55 (day 0.21)
  ok  drop 914781365 1383305858: dropping 2
  ok  take 469459249 1160753816: taking Firefighter Axe, Crowbar
  ok  equip 469459249: equipping Firefighter Axe
pos 8142.5,11730.5,0 inside firestorage | health 100 | weight 13.92/14 | hand: Firefighter Axe
zombies (1):
  Z#9 at 8150.11,11735.55 d=8 seen targetingMe
map: ...
11733                ? ? ? ?|. . . . . ? ? ? ? ? ?|. . .
                            +- d - - - - - - - D -+
11734                ? ? ? ?|. . . . . . . . ~ . . . . .
11735                 WC . .D. . . . . . . @ . . . . Z .
```

## How it works

- **The mod** (`mod/ClaudeBot`) polls `~/Zomboid/Lua/claudebot/cmd.txt`. When a new turn
  arrives it queues the commands as normal timed actions and unpauses the game.
- The game **auto-pauses** when the queue finishes, a new zombie comes into view, a zombie gets
  within 2.5 tiles, the character gets hurt, gets surrounded or exhausted mid-fight, or dies.
- On pause it writes `state.json`: time, stats, wounds, inventory, visible zombies, nearby
  doors, windows, water and containers (contents only when within reach, so no x-ray looting),
  plus an ASCII map with walls, doors and windows.
- **`pz.py`** is the driver: it sends a turn, waits for the pause and pretty-prints the state.

Fighting uses the game's real melee: face the target and swing. `fight` can hold position or
hunt zombies within 14 tiles.

## Install

1. Copy (or link) `mod/ClaudeBot` into your mods folder: `C:\Users\<you>\Zomboid\mods\ClaudeBot`
   (`~/Zomboid/mods/ClaudeBot` on Linux/macOS). On Windows, `install.cmd` creates the link for you.
2. In the game, enable **ClaudeBot** under Mods and start a **new singleplayer** game.
   Use a throwaway character. It will do dumb things, and deaths in Zomboid are permanent.
3. You need Python 3.8+ for the driver. No packages required.

Tested on Build 42.20.4 (Windows). Singleplayer only.

## Use

```
python pz.py do look                          # print the current state (doesn't unpause)
python pz.py do "scan 150"                    # nearby buildings and room layouts
python pz.py do "go 8286 12230" "loot 8285 12229 food"
python pz.py do "equip 469459249" "fight 5"
python pz.py do continue                      # resume a turn that paused early
python pz.py state                            # re-print the last state
```

Full command list, the state format and play tips are in **[PLAYING.md](PLAYING.md)**. It's
written so you can hand it straight to an AI agent: point Claude Code (or anything that can run
a shell command) at this folder and tell it to read `PLAYING.md` and survive.

## Development

All the logic is in `mod/ClaudeBot/42/media/lua/client/ClaudeBot.lua` and can be
**hot-reloaded** while the game runs: `python pz.py reload`. B42 disables `loadstring` for
mods, so `python pz.py eval "R = p:getHealth()"` runs Lua through the game's own
`reloadLuaFile` instead, which is handy for poking at the API.

Errors land in `~/Zomboid/console.txt`, and the loader writes its status to
`~/Zomboid/Lua/claudebot/loader.txt`.

**Heads-up:** the mod will run whatever commands and `eval.lua` land in that folder, so
anything on your PC that can write there can drive your character. It's meant for local play.

## Known rough edges

- A window `open` followed by `climb` in the same turn loses the climb; send them in separate turns.
- It can't get through locked interior doors yet.
- The map only marks walls the game reports as blocking movement, and furniture shows as `o`.
- No sleeping, cooking, building or vehicles yet.

## License

MIT
