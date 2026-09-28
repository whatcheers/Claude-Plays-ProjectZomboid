# Playing Project Zomboid through ClaudeBot

You control one survivor in a paused, turn-based Project Zomboid game. Each turn you send some
commands; the game runs them and pauses again, then you read the new state. Commands run top to
bottom, and each one is evaluated when its turn comes (so `go` then `loot` loots where you arrive).

```
python pz.py do "<command>" "<command>" ...
```

The driver waits for the pause (up to 3 minutes of real time) and prints the state.

## Why a turn ended (`pause reason`)

| reason | meaning |
|---|---|
| `done` | everything you queued finished |
| `new zombie #N at D tiles` | a zombie came into view within 15 tiles; rest of your queue is kept |
| `zombie #N within D tiles` | a zombie is right next to you |
| `hurt (health H)` | you took damage |
| `surrounded: N zombies within 2 tiles` / `exhausted` | the fight stopped for your safety |
| `turn time limit` | 2 in-game hours passed (change with `maxturn`) |
| `DEAD` | that's it |
| `idle` | the turn only had instant commands (`look`, `scan`, ...) |

After an early pause, send `continue` as the first line to resume the leftover queue. Any other
first command clears it.

## Commands

IDs are item IDs (`#123456`) from the state; coordinates are world tiles (`x y`, floor `z` optional).

**Instant** (don't unpause the game)

| command | does |
|---|---|
| `look` | nothing; just prints the state |
| `scan [radius]` | lists buildings within radius (default 150) with their room types, plus the room layout of the nearest big one |
| `say <text>` | the character says it |
| `speed <1-4>` | game speed while turns run |
| `maxturn <minutes>` | in-game minutes before a turn auto-pauses (default 120) |
| `eval` | runs `claudebot/eval.lua` (use `python pz.py eval "R = ..."`) |

**Queued**

| command | does |
|---|---|
| `go x y [z]` | pathfind there (reports `PATH FAILED` if there's no route) |
| `step dx dy` | pathfind relative to where you are |
| `door x y` | walk to the door on that tile and open or close it |
| `window x y open\|close\|smash\|clearglass\|climb` | window actions (`climb` is the default) |
| `take id [id...]` | move items into your main inventory (from containers, bodies, the floor or your bags) |
| `loot x y [filter]` | take everything (or names matching `filter`) from all containers on a tile |
| `put id x y [n]` | put an item into container `n` (default 1) on a tile |
| `drop id [id...]` | drop to the floor |
| `eat id [fraction]` / `drink id [fraction]` | eat or drink (1 = all) |
| `drinkat x y` | drink from a sink, toilet or other water source |
| `fill id x y` | fill a container from a water source |
| `equip id [2h\|off]` / `unequip id` | hands |
| `wear id` / `read id` | clothing, books |
| `bandage id BodyPart` | e.g. `bandage 123 Hand_L` |
| `wait minutes` | pass time (runs at speed 3) |
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
