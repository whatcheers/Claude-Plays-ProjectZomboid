# Changelog

Versions follow [semver](https://semver.org/). The version lives in three places that must match:
`modversion` in both `mod.info` files, `B.VERSION` in `ClaudeBot.lua`, and `VERSION` in `pz.py`
(the driver warns when the game is running a different one). Each release is tagged `vX.Y.Z`.

## 0.5.0 — 2026-09-30

### Fixed
- **Weapons dropped in a fall are picked back up.**
  - Falling while climbing a fence (the fall outcome of `ClimbOverFenceState` calls `dropHandItems`) left the
    axe on the ground with nothing reported. A player lost its axe that way.
  - A reflex now notices the held melee weapon on the ground, picks it up, re-equips it, and resumes
    the interrupted line. A weapon you `drop` on purpose is left alone.
- **Lines no longer run during window animations.**
  - Opening, closing and climbing happen in player states that run after the action leaves the queue
    and wipe the queue when they end.
  - The next line used to start mid-animation. It saw the window as it was, and its actions were wiped.
    `open` then `climb` silently didn't climb, and the old auto-resume skipped the lost climb.
  - Each line now holds until the character settles. The game doesn't consult `waitToStart` here,
    so it's done in `update()`.
- **`window open|close|climb` check their outcome.** They report `window is open`, `climbed through`, or
  `still on the same side (the window is closed, locked, barricaded...)`, and a failure stops the
  lines after it. It used to always say `ok`.
- **`go`/`travel` with no floor** use the highest floor at or below yours that has a floor at the target,
  so walking outside from upstairs no longer fails.
- Tests: `tests/floor_default.lua`.

### Changed
- `pz-player` looks after the survivor's needs every turn, before goals: eat, drink, sleep when
  fatigued, rest, read against stress and boredom, bandage, painkillers.

## 0.4.0 — 2026-09-30

### Added
- **`pz.py watch`**: a live turn feed in the browser, served to the home network on port 5160.
  - A status strip at the top.
  - Every turn, newest first: commands, `ok`/`ERR` results, `skip` for NOT RUN lines, pause reason, and time since the last turn.
  - It is read-only and uses only the standard library (`watch.html`).
- Every `pz.py do` appends to `claudebot/turns.jsonl`, whoever is driving: commands, results, reason, task, reflexes, and the `brief` snapshot.
  Test: `tests/test_turnlog.py`.

## 0.3.0 — 2026-09-30

### Added
- **The `pz-player` agent** (`.claude/agents/pz-player.md`). It plays from a goal list on Sonnet until
  something breaks (bitten, dead, a mod bug seen twice, stuck, 150 turns). Then it returns a report
  of about 15 lines, with the bug's exact command and output. It can't edit code, and each run starts fresh.
  - Measured on the last play sessions: game turns re-read the whole mod-development context, which
    grew to about 200k tokens (median).
  - One session spent 559 model calls on 86 turns.
  - Splitting play (the player) from development (the supervisor session) keeps each turn cheap.
- `pz.py brief`: a status of about 5 lines (time, position, base, fort, health, wounds, weapons, food,
  water, zombies) for the supervisor to check in with.
- `install.cmd` also copies the agent to `~/.claude/agents`, so sessions started outside the repo
  can use it.

### Fixed
- A failed line no longer lets the rest of the turn run from the wrong place. The one-time
  auto-resume after a queue wipe (meant for window opening or getting up) also fired after failures:
  - after `go` PATH FAILED, the `loot` on the next line ran wherever the character stood;
  - a `take` whose walk to the container failed printed no check line, and the turn jumped to `home`.
  Failed walks (`walkAdj`/`walkToContainer`, which only force-stop) are now reported on their
  line as `couldn't walk there (no route)`, and the lines after a failure are listed as `NOT RUN`.
  Regression test: `tests/failed_walk.lua`.

## 0.2.0 — 2026-09-30

### Added
- **Driving.** `cars`, `enter`, `engine [off]`, `drive x y [x y ...] [max=kmh]`, `reverse [tiles] [left|right]`, `exit`.
  Lua can't press the car's keys (`CarController` reads `GameKeyboard`, which has no setter), so the
  mod writes the keys to hold to `claudebot/keys.txt` and `pz.py do` presses them in the game
  window with `SendInput`. `drive` follows the line between waypoints (pure pursuit), pulses the
  steering in proportion to the error, K-turns when the next waypoint is behind, backs up when
  blocked, and reports back-ups, K-turn moves, steering flips and the worst distance off the line.
- The key pump takes the game window once per turn and lets go (every key released) if you click
  away, so a human can step in mid-drive.
- `pz.py` warns when the loaded mod's version differs from the driver's.
- Sleep, crafting (`recipes`, `craft`), `barricade`, `lock`, `chop`, `build`, `find`, `fort` (911368f).
- Live regression tests in `tests/` (64c74eb).

### Changed
- Every action command verifies its outcome instead of trusting "queued" (911368f).
- Zombie detection from a car seat: distance is measured from the car, and sight falls back to
  the character's own line of sight. A zombie was run over without a pause before this.
- Melee reflexes are skipped while in a vehicle.

### Fixed
- Floor attacks on downed zombies; `loot`, `put`, `travel` and `home` robustness (92bd304).
- Failed goal tasks stop the commands that depend on them; bites under bandages are still
  counted (64c74eb).

## 0.1.0 — 2026-09-27

First public release: turn-based remote control, reflexes, resumable queue, goal commands
(`travel`, `home`, `sweep`, `survey`, `secure`, `stash`), README and PLAYING.md.
