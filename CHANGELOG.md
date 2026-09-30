# Changelog

Versions follow [semver](https://semver.org/). The version lives in three places that must match:
`modversion` in both `mod.info` files, `B.VERSION` in `ClaudeBot.lua`, and `VERSION` in `pz.py`
(the driver warns when the game is running a different one). Each release is tagged `vX.Y.Z`.

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
