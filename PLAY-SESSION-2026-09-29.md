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
