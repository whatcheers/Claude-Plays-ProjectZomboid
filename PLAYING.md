# Playing Project Zomboid through ClaudeBot

You control one survivor in a paused, turn-based Project Zomboid game. Each turn you send some
commands; the game runs them and pauses again, then you read the new state. Commands run top to
bottom, and each one is evaluated when its turn comes (so `go` then `loot` loots where you arrive).

```
python pz.py do "<command>" "<command>" ...
```

The driver waits for the pause (up to 10 minutes of real time) and prints a short summary: results,
position, stats, real wounds, zombies (the ones coming for you first), what entered or left your
inventory, and a one-line count of what's nearby. Ask for more only when you need it:

```
python pz.py near    # doors, windows, water, container contents, floor items
python pz.py map     # the tile map
python pz.py inv     # your inventory
python pz.py full    # everything (or add --full to a do)
```

## Supervisor and player

In Claude Code, keep playing and developing in separate contexts. Every model call re-reads the
whole conversation, so a game turn played in a session full of mod development costs as much as
that whole history. In one session, 86 game turns rode on 559 model calls and a context of about
200k tokens.

- **The supervisor** (your main session) picks goals, reads reports, and fixes and reloads the mod.
  `python pz.py brief` gives it a few-line status without a full dump.
- **The player** is the `pz-player` agent (`.claude/agents/pz-player.md`; `install.cmd` installs it
  for sessions started elsewhere). It gets a goal list and plays until something breaks: bitten,
  dead, a mod bug seen twice, stuck, or 150 turns. Then it returns a report of about 15 lines,
  with the bug's exact command and output. It never edits code, and each run starts fresh.
- **Watching:** `python pz.py watch` serves a live page on port 5160 of the home network
  (http://\<this PC\>:5160, phone too). It shows a status strip and every turn: commands, results,
  errors, and NOT RUN lines. Every `pz.py do` is logged to `claudebot/turns.jsonl`, whoever is
  driving. The page is read-only; chat happens in the Claude session.
  Tabs split the feed by agent: each turn is tagged with `PZ_AGENT` (unset = `supervisor`).
  `python pz.py report <agent> [file]` puts a run's final report on its tab.

## Why a turn ended (`pause reason`)

| reason | meaning |
|---|---|
| `done` | everything you queued finished |
| `new zombie #N at D tiles` | a zombie came into view within 8 tiles, or within 15 and coming for you; rest of your queue is kept |
| `zombie #N within D tiles` | a zombie got right next to you (once per zombie; one that was already in reach when the turn started won't pause it again) |
| `BITTEN (health H)` | a new bite. Every bite is fatal eventually |
| `hurt (health H)` | you lost more than 8 health this turn (change with `hurtpause`) |
| `surrounded: N zombies within 2 tiles` / `exhausted` | the fight stopped for your safety |
| `turn time limit` | 2 in-game hours passed (change with `maxturn`) |
| `DEAD` | that's it |
| `idle` | the turn only had instant commands (`look`, `scan`, ...) |

Lines run one at a time: each starts only after the one before it has finished and been checked.
If a line fails, the rest of the turn is listed as `NOT RUN`. If something cuts a line short without
an error (the game dropped its actions), it runs again once, then fails with `interrupted before it
finished`. A reflex (fight, rearm, picking up a dropped weapon) re-runs the line it interrupted.
After an early pause, send `continue` as the first line to pick up at the interrupted line; any other
first command starts a fresh turn.

## Commands

IDs are item IDs (`#123456`) from the state; coordinates are world tiles (`x y`, floor `z` optional).

**Instant** (don't unpause the game)

| command | does |
|---|---|
| `look` | nothing; just prints the state |
| `scan [radius]` | lists buildings within radius (default 150) with their room types, plus the room layout of the nearest big one |
| `say <text>` | the character says it |
| `light [on\|off]` | flip every light switch in the room you're in (needs grid power) |
| `speed <1-4>` | game speed while turns run |
| `maxturn <minutes>` | in-game minutes before a turn auto-pauses (default 120) |
| `hurtpause <health>` | health lost in one turn before it pauses as `hurt` (default 8) |
| `eval` | runs `claudebot/eval.lua` (use `python pz.py eval "R = ..."`) |
| `find word[,word...] [radius]` | every loaded container or floor spot (default 60 tiles, all floors) holding items whose type or name contains a word, nearest first. E.g. `find plank,nailsbox,saw 80` |
| `fort [here]` | the base's (or this building's) exterior windows and doors: planks per window, open/locked, whether you carry the key. The summary also prints a `fort:` line whenever you're inside the base |
| `recipes id` | what the right-click menu can craft from that item, numbered. **Recipes you lack the tool for don't appear at all** (a ham shows nothing without a knife) |

**Queued**

| command | does |
|---|---|
| `go x y [z]` | pathfind there (reports `PATH FAILED` if there's no route). No `z`: your floor if x,y has one there, else the next one down (so outdoors from upstairs goes to the ground) |
| `step dx dy` | pathfind relative to where you are |
| `door x y` | walk to the door on that tile and open or close it |
| `window x y open\|close\|smash\|clearglass\|climb` | window actions (`climb` is the default). `open`, `close` and `climb` add a check line: `window is open`, `climbed through`, or why not |
| `take id [id...]` | move items into your main inventory (from containers, bodies, the floor or your bags) |
| `loot x y [filter words] [max]` | take everything (or names matching the filter, `*` = all, `rope,twine` = either) from all containers and the floor on a tile, at most `max`; also searches bags inside containers. E.g. `loot 8143 11727 firefighter axe 2` |
| `put id x y [n]` | put an item into container `n` (default 1) on a tile; refuses up front if it's full |
| `pack id [id...]` | move items from main inventory into your worn bag (`take` or `loot` them first). `Name*N` / `Name*` instead of an id picks N / all loose items whose name contains Name |
| `drop id [id...]` | drop to the floor; takes `Name*N` / `Name*` like `pack` (`drop Rag*`) |
| `eat id [fraction]` / `drink id [fraction]` | eat or drink (1 = all); `eat` on pills takes one dose |
| `drinkat x y` | drink from a sink, toilet or other water source |
| `fill id x y` | fill a container from a water source |
| `equip id [2h\|off]` / `unequip id` | hands |
| `wear id` / `read id` | clothing, books |
| `bandage id BodyPart` | e.g. `bandage 123 Hand_L` |
| `wait minutes` | pass time (runs at speed 3) |
| `craft id [n] [all\|xK]` | do recipe `n` (default 1) from `recipes id`; reports what it made (`+2 Rag, -1 Tank Top`). `all` / `xK` repeats it on more items of the same type (`craft 123 2 all` rips every sheet) |
| `barricade x y [n]` | nail `n` planks (default 1, max 4 per side) over the window or door on that tile, from the side you're on. Needs a hammer, planks and 2 nails each; opens a Box of Nails if needed. Reports how many actually went up |
| `lock x y [off]` | close and lock (or unlock) a door; needs its key on you |
| `chop x y` | fell the tree on that tile with your best axe; logs and branches drop on the stump's tile, and a check line lists them (`felled: +7 Log, ...`). Refuses below 0.15 endurance: exhaustion stops the swings. A size-8 (JUMBOXXL) tree gives 7 logs, size 6 gives 4, size 4 gives 2 |
| `build Entity x y [w\|n]` | place a build-menu entity on a tile's west or north edge, e.g. `build LogFence x y w`. Materials count from inventory **and the 8 tiles around you**, so build next to heavy ones (logs) instead of carrying them. Skill-gated ones (wooden fences need Carpentry 3) fail with "can't build" |
| `sleep [x y \| floor]` | walk to the nearest bed on this floor (or the one at x y) and sleep; no bed = floor. Turn ends on waking |
| `enter [x y]` | walk to the car at x y (or the nearest within 8 tiles) and get in the driver's seat |
| `engine [off]` | start the engine (needs its key in inventory; can fail, just try again) or shut it off |
| `drive x y [x y ...] [max=kmh]` | drive through the waypoints (default 25 km/h). Pick them along roads, every corner a waypoint. Follows the line between waypoints, K-turns when the next one is behind you, backs up when blocked, brakes to a stop at the last. **Takes over the game window's keyboard** (see below) |
| `reverse [tiles] [left\|right]` | back up that far (default 4), optionally steering, then stop. Use it to get out of a nose-in spot first |
| `exit` | get out |
| `fight [minutes] [hold]` | melee the nearest zombie. By default it **hunts** visible zombies within 14 tiles; `hold` only swings at ones that reach you. Ends when none are left, time is up, 3+ are within 2 tiles, or endurance runs low. Put it **last** in a turn. |

## Reading the state

- `stats`: 0–1 values (hunger, thirst, fatigue, endurance...). Anything over ~0.25 is worth dealing with.
- `wounds`: body parts with damage, e.g. `bleeding`, `scratched`, `BITTEN`.
- `zombies`: `seen` means in your line of sight. `targetingMe` means it's coming for you.
- `containers`: contents are listed only within 2.5 tiles; farther ones show type and item count.
- `buildings` (after `scan`): distance, direction, bounding box, floors and room types.

### Map legend

Each tile is one character, and the characters between tiles are the walls on that edge.

```
@ you     Z zombie (seen)   z zombie (heard, not seen)
. floor   , outdoors        o blocked (furniture, fence...)   T tree   ^ stairs
C container   ~ water source   i items on the floor   ? not seen yet
| -  wall     D d  door closed/open     W w x  window closed/open/smashed   % barricaded
```

## Play tips

- Early on, fight one zombie at a time. Groups of three or more are how survivors die.
- A zombie that's `targetingMe` will come to you: `fight 3 hold` and let it walk into the swing.
- The character drinks on their own when thirsty if a water bottle is in inventory.
- `scan` first, then move in 50–70 tile legs; long paths through unloaded areas fail.
- Look things up. The real game map is at https://map.projectzomboid.com/ and it uses the same
  world coordinates as the state. The Rosewood Fire Department (≈8148,11730) has a storage room
  full of fire axes.
- If a turn silently does nothing, check `~/Zomboid/console.txt` for a Lua error.
- `take`, `loot`, `craft`, `barricade` and `build` add a second result line that checks the outcome
  (`got all 3`, `1/1 planks up`, `missing: Plank #123`). Trust that line, not the first "ok".
- Walking through a locked door with its key unlocks it and leaves it that way. `home` locks
  the base's doors again on arrival; after any other return, check the `fort:` line.
- `OVERLOADED` in the summary means over 1.25× your carry limit: you're slow, which is what gets
  you caught. Carry 3–4 planks (3 kg each) per trip.
- Moving bulk (logs are 9 kg: one per trip): `python pz.py haul Log fromX fromY toX toY [trips] [perTrip]`
  sends one turn of `loot` → `go` → `drop` cycles.
- Bindings for log builds: one bed Sheet rips into 10 Rags (`craft id 2 all`).
- No skill yet? A log fence (2 logs + 2 rags) needs none; it's climbable. A log wall (4 logs + 4 rags) isn't: `chop` a tree, stand by the logs, `build LogFence`.

## Driving

Lua can't work the pedals: the car reads `GameKeyboard`, which has no setter. So `drive` and
`reverse` decide which keys to hold every tick and write them to `claudebot/keys.txt`, and
`pz.py do` presses them in the game window with `SendInput` (W/A/S/D/Space as scancodes; change
`SCAN` in pz.py if your binds differ). It brings the window to the front once when a drive starts.
If you click away mid-drive, it lets go of every key and leaves the window alone until the next
turn, so a human can step in.

- `cars [radius]` (instant) lists vehicles nearby: gas, whether you carry the key, engine, locked.
- Parked cars are the main hazard. Waypoints that pass beside one in a turn will clip it.
- Every drive result reports back-ups, K-turn moves, steering flips and the worst distance off
  the line, so you can tell a clean drive from a lucky one.

## Known game bugs (Build 42)

- The vanilla `ISBarricadeAction` checks `ItemType.HAMMER`, which is `nil`, so it always fails
  silently. `barricade` uses a fixed copy (`ClaudeBotBarricade`).
- Barricading needs loose `Nails`, not a `Box of Nails`.
