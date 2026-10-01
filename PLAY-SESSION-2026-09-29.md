# Gameplay handoff — September 29, 2026

Stopped at the user's request to conserve usage. Game is paused, character alive.

## Current state

- July 10, 08:56. Home: 8153,11677,0; user explicitly confirmed this boarded house is home.
- Position 8153.5,11676.5. Health 79.39. Six of six windows boarded; exterior door locked.
- Left forearm was bitten during the return trip. Both that wound and the right upper-arm laceration are bandaged. Zombie infection stat 0.25. No health/infection edits were made.
- Food and water stocked; firefighter axe equipped. Fresh radish and zucchini stored in home fridge at 8155,11678. Sewing kit, whetstone, pliers, vise grips and funnel stored in wardrobe at 8152,11677.

## Code and control

Repository: C:/Users/whatcheer/projects/pz-bot. Read PLAYING.md there.
Use `python pz.py do look` to obtain live state; do not trust an old state file after a restart.
Game bridge works. Desktop Computer Use helper was unavailable after retry and reset.
Zomboid/Lua/claudebot and mods/ClaudeBot are junctions into the repository, outside workspace write permissions.

Changed and hot-reloaded mod/ClaudeBot/42/media/lua/client/ClaudeBot.lua:

1. Empty queue no longer ends the turn when combat has deferred interrupted movement. Regression passed and real combat confirmed resumption to exact target 8183.5,11671.5.
2. Window commands prefer IsoWindow over IsoWindowFrame, which may precede it on the same tile. Open/close are idempotent; bare frames only support climb. Live target regression passed.
3. Failed reloadLuaFile eval no longer reports successful nil. Completion sentinel catches failure; intentional error and legitimate nil smoke checks passed.
4. Four futile attacks pause the turn instead of immediately restarting reflex combat. Downed targets no longer reset the failure counter every attempt. Simulated live regression passed.
5. Bite and health-loss checks run before deferred work/animation early returns. Simulated live regression passed.

Final regression checks on the loaded bot passed: combat_stall, injury_before_resume, resume_after_combat. Window regression passed before the unrelated combat safety changes. git diff --check was clean before final safety changes; final check accompanies handoff.

Tests staged under .work/pz-bot/tests and copied into repository tests. No commit or push.

## What went wrong / next work

During the trip home, a downed zombie repeatedly triggered ineffective reflex fights. The bot reported the home travel task stuck, continued subsequent storage commands, and was bitten. The new combat/injury safeguards were added afterward and cannot undo that outcome.

Still unresolved: open followed by climb in one turn can lose the climb; issue separate turns. A failed travel task still allows dependent commands to proceed. The driver returns exit code 0 for command-level errors, so inspect results[].ok. Combat against ground targets needs investigation before another excursion; do not test that by risking a healthy survivor unnecessarily.

Preserve this survivor/save and the bite unless the user requests otherwise. No background gameplay was started.

## Resumed session

User reloaded and said `go`. Confirmed live at home, July 10 08:58, infection unchanged in kind (0.27). Sharpened the axe using the recovered whetstone and stored the stone again. Added another fix: B.finishTask(false, ...) pauses, reports dependent commands NOT RUN, and clears their pending/deferred state. Successful tasks still resume subsequent commands. The live failed_task.lua regression failed before the change and passed afterward. Changes remain uncommitted.

Latest checkpoint: July 10 09:54, paused inside home at 8153.5,11678.5. Health 83.1, endurance 1, pain 0, infection 1.66. No new attack or injury this resumed session. Forearm dressing was exhausted; replaced it with a clean rag using normal remove/apply timed actions. Three spare clean rags and a dirty reusable bandage remain in inventory.

Recovered Hacksaw #1783680016, Handiknife #986314897, and Rope #255335180 from a nested garbage bag in dumpster 8146,11679. They are now stored with the hammer in wardrobe 8152,11677. Sawed one yard log into three planks; applied one each at 8152,11680, 8153,11685, and 8156,11685. VERIFIED: all six home windows now have TWO planks, exterior door locked. Two logs remain in the yard at 8153,11666. Painkillers #51833292 returned to medicine cabinet 8155,11676 after one normal dose. The spare sports shirt was ripped into four clean rags, one used for dressing.

Policy now intentionally has `melee=off`: new threats pause for agent inspection. Keep that cautious policy until grounded combat is investigated. `find` searches nested bags, but `loot` only matches top-level items; approach, inspect `near`, and use `take <id>` for nested items.

Dressing removal revealed that `bp:bitten()` returns false under bandages. That caused a false new-bite alarm when the old dressing came off. Fixed bite counting and wound reporting to also use `getBiteTime()>0`, verified against the actual covered wound (timer about 65). The covered_bite.lua regression failed before, passed after, and checks that an additional bite still increases the count. The alarm during care was the OLD bite, not another attack.

## Claude supply run (same day, later)

Goal from the user: stock the base for the *next* survivor. This one is infected
(zombie_infection 1.66 → 5.67 over ~3 game hours) and won't last.

State at the end: July 10 12:38, inside the base, health 90.7, door locked,
6/6 windows double-planked. Game saved.

### Base supply manifest (Rosewood house, 8152–8158 × 11676–11685)

| where | what |
|---|---|
| kitchen shelves 8157,11678 | Rice, White Beans (Dried), Canned Sardines, Canned Tuna, Canned Carrots, Peanut Butter |
| kitchen counter 8157,11679 | 2 Cooking Pots + Kettle, **full of clean water (4.5 L)**; pans, utensils |
| fridge 8155,11678 | Ham, radish, zucchini (these will rot) |
| medicine cabinet 8155,11676 | **First Aid Kit**, Forceps, Bandage ×2, Adhesive Bandage ×2, Adhesive Tape ×2, Suture Needle ×2, Painkillers |
| wardrobe 8152,11678 | **Padded Jacket** (bite protection), Kitchen Knife, Paring Knife, Water Bottle, Lighter, Painkillers, Alcohol Wipes, **Vehicle Key – Franklin Valuline** (van not located yet) |
| dresser 8154,11684 | **3 Firefighter Axes** (13/13), Hatchet |
| wardrobe 8156,11682 | Gas Can (for the van) |
| wardrobe 8152,11677 | FULL (16/17 kg): hammer, saw, handiknife, rope, sewing kit, whetstone, pliers, older loot |
| yard 8153,11666 | 2 logs, branches; log fence panel at 8154,11666 |

Stocks nearby: ~30 planks at the carpenter shop crates 8122,11685-86; 20+ fire axes at the
fire station 8136–8156,11727–11738; more gas cans at the car supply store 8123/8131,11645.

### Code fixed during the run (all hit live, then verified live)

- Combat: `setAimAtFloor` before swings/shoves, so zombies on the ground take a downward
  swing or a stomp. A crawler that would have stalled died without tripping the 4-swing check.
- `travel` aimed at a blocked tile (counter, shelf) now targets the nearest free tile.
- `loot`: multi-word filters (`loot x y firefighter axe 2` took 3 before), and it searches
  bags nested in containers (hatchet inside a dumpster's garbage bag).
- `put` checks the container has room first ("wardrobe is full (15.97/17 kg)") and verifies
  after; before, a full container silently refused and `put` said ok.
- `home` locks the base's exterior doors you have keys for on arrival (walking in through a
  locked door with its key leaves it unlocked; it happened every trip).

## Fence materials run (2026-09-30, game July 11–12)

Goal from the user: gather what a perimeter fence needs, then die near the base.

**The yard** runs x 8147–8163, y 11663–11686. West side 11670–11686 and the south side are tall
fences (`fencing_01_72/73`, not climbable). The rest is low and climbable (`fencing_01_120/121/122`):
the whole east side at x=8164, the west side 11663–11669, and the north side 8148–8156. The north
side has a **7-tile gap, 8157–8163 on y=11663** (the driveway; the van is parked inside).

**Recipes (no skill needed):** Log Wall = 4 Log + 4 bindings (not climbable). Log Fence = 2 Log +
2 bindings (climbable). Bindings = Rag, dirty rag, Twine, Rope or Sheet Rope.

| pile | what |
|---|---|
| gap, around 8158–8161,11664–11666 | ~33 Log, 143 Rag, 5 Rope, 3 Twine |
| east fence, 8162,11668 | ~21 Log |
| total | **54 Log**: 7 log walls close the north gap (28 logs), leaving 26 logs for 6 more walls on the east side |

Materials count within 1 tile of where you stand, so stand in the pile and build its neighbours, or
carry 1 log per trip (9 kg). Every tree within ~45 tiles has been felled apart from one at 8120,11704.
The next logs are farther out.

## Prep run (2026-09-30, game July 13, survivor Brent)

Brent wears a Padded Jacket, Leather Gloves and a Duffel Bag; he carries a Firefighter Axe, a Hacksaw and a Screwdriver.
North wall at y=11663: walls at 8157-8158 and 8163, LogGates at 8159-8160 and 8161-8162 (4-tile van opening).

| where | added this run |
|---|---|
| kitchen counter 8157,11679 | all 16 seed packet types, Gardening Trowel, 2 Box of Nails, Peanut Butter, 2 Rice, Canned Peas, Canned Fruit Beverage, Evaporated Milk, Crackers, Sugar Cubes |
| kitchen shelves 8157,11678 | Cereal, 2 Sugar Cubes (shelves now full) |
| medicine cabinet 8155,11676 | Disinfectant, Painkillers, Rubber Gloves, ~5 Adhesive Bandages |
| dresser 8154,11684 | Shovel |

Not carried: about 33 planks in crates at 8243,11693 (locked house); antibiotics at 8243,11688 (same house, unreachable);
8 bags of concrete powder in crate 8138,11669; garden hoes, a scythe and trowels in crate 8137,11669.
No grocery within 120 tiles on foot; no generator, sledgehammer or propane torch seen.
