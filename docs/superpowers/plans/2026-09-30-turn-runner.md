# Turn Runner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task (the user chose **Native** execution: build it in the supervisor session, then have one fresh reviewer on the strongest model check the whole change). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ClaudeBot runs a turn's lines itself, one at a time. The game's timed-action queue only
ever holds the current line's actions, so a wipe of that queue can no longer lose or mix up lines.

**Architecture:**
- The new `B.run` holds the turn's lines, each with a status.
- `B.runTick(p)` is called from `B.monitor` in place of the old queue-empty/auto-resume block. It
  starts the current line, holds while anything else owns the character, judges the line once the
  queue has drained and settled, then advances or fails.
- A tiny `ClaudeBotLineEnd` action queued after each line's actions shows whether the line ran to
  its end.
- Window lines get a `check` function instead of the separate watch list.

**Tech Stack:** Project Zomboid B42 Lua mod (`ClaudeBot.lua`, hot-reloaded), Python driver `pz.py`.
Live tests are Lua snippets run in the game with `python pz.py eval (Get-Content tests/X.lua -Raw)`
from PowerShell.

**Spec:** `docs/superpowers/specs/2026-09-30-turn-runner-design.md` (committed c3b04a5)

## Global Constraints
- All paths are relative to `~/projects/pz-bot`. The mod is `mod/ClaudeBot/42/media/lua/client/ClaudeBot.lua`
  ("CB" below). Line numbers are from v0.5.0 plus the spec commit; re-find anchors by text.
- CB uses CRLF-or-LF as the file already has it. Edit with the Edit tool, matching existing text exactly.
- After every CB edit: run `python pz.py reload`. It must print `OK reloaded`.
- Tests need the game running with the survivor in the world, paused, and idle. Run them from PowerShell.
- Every command function (`B.cmds.*`, `B.immediate.*`) keeps its signature `fn(p, args, line)`
  and its return message. `state.json` and `pz.py` formats don't change.
- Result lines for lines that never ran start with `NOT RUN:`. `watch.html` highlights that prefix.
- A turn made only of instant commands still runs them with the game paused and dumps `idle`.
  The eval tests rely on it.
- Versioning: minor bump to **0.6.0** in `mod/ClaudeBot/mod.info`, `mod/ClaudeBot/42/mod.info`,
  `B.VERSION` in CB, and `VERSION` in `pz.py`. Add a CHANGELOG entry, tag `v0.6.0`, and push with `--follow-tags`.

## Review Focus
1. **A reflex fight or rearm in the middle of a line** should re-run that line afterwards, not skip it, and
   it shouldn't use up a retry. Pinned in Task 2's `resume_after_combat.lua` rewrite.
2. **A new bite or hurt pause while a line is waiting to start** should pause before the line runs.
   Pinned in Task 2's `injury_before_resume.lua` rewrite.
3. **A goal task (`home`) failing** should mark every later line NOT RUN and end the turn with
   `task failed: home`. Pinned in Task 2's `failed_task.lua` rewrite.
4. **`continue` after an early pause** should resume at the interrupted line, with any new lines appended.
   Pinned in Task 3's `run_continue.lua`.
5. **A line wiped with no failure recorded** should re-run once, then fail with
   `interrupted before it finished`. Pinned in Task 3's `run_retry.lua`.

## File map
- **Modify CB** (the one file the loader hot-reloads; the runner has to live there):
  - add the runner section (`B.newRun`, `B.curLine`, `ClaudeBotLineEnd`, `B.setCheck`, `B.startLine`,
    `B.failRun`, `B.runTick`, `B.swingSettled`);
  - rewrite `B.lineFailed`, `B.interrupt`, `startTask`, `B.finishTask`, `B.endFight` (one line),
    `B.startTurn`, `B.monitor` (the deferred block and the queue-empty block), `B.cmds.bash`,
    `B.cmds.window` (climb/open/close checks), and the `s.queue` field in `B.state`;
  - delete `ClaudeBotStep`, `B.resumePending`, `B.watchAction`, `B.watchTick`, and the `runAfterImm` read.
- **Modify tests:** `tests/failed_walk.lua`, `resume_after_combat.lua`, `combat_stall.lua`,
  `injury_before_resume.lua`, `failed_task.lua`, `tests/README.md`.
- **Create tests:** `tests/run_retry.lua`, `tests/run_continue.lua`.
- **Docs:** `PLAYING.md`, `CHANGELOG.md`, `docs/superpowers/plans/2026-09-30-turn-runner.md`
  (a copy of this plan).

---

### Task 1: Save the plan into the repo

**Files:** Create `docs/superpowers/plans/2026-09-30-turn-runner.md`

- [ ] **Step 1:** Copy this plan file (`~/.claude/plans/yeah-thats-not-it-wondrous-sundae.md`) to
  `docs/superpowers/plans/2026-09-30-turn-runner.md`.
- [ ] **Step 2: Commit**
```bash
cd ~/projects/pz-bot && git add docs/superpowers/plans/2026-09-30-turn-runner.md && git commit -m "Plan: turn runner"
```

---

### Task 2: The runner replaces the old engine (all at once; the old flags are too entangled to switch half-way)

**Files:** Modify CB and `tests/{failed_walk,resume_after_combat,combat_stall,injury_before_resume,failed_task}.lua`.

**Interfaces (produced, used by Task 3 and by commands):**
- `B.run = { lines = { {text, verb, args, status, tries, msg, ended, failMsg, check, task} }, cur = int, clearedTick = int|nil, quietSince = ms|nil }`
- `status` is one of `"waiting" | "running" | "done" | "failed" | "notrun"`.
- `B.newRun(entries)` takes `entries` = list of `{text, verb, args}` and returns a run.
- `B.curLine()` returns the current line table, or nil.
- `B.setCheck(fn)` attaches `fn(p) -> msg | error(reason)` to the line being started.
  Only valid inside a command function.
- `B.lineFailed(msg)` records a failure on the running line and prints `ERR <line>: msg`.
- `B.runTick(p)` is called by `B.monitor`. It ends the turn itself.
- `B.interrupt(p)` is unchanged for callers: it clears the game queue and re-waits the running line.

- [ ] **Step 1: Rewrite the five internals tests against `B.run` (they will fail: `B.newRun` is nil).**

`tests/failed_walk.lua` (full replacement):
```lua
-- A failed walk or PATH FAILED fails its line and the rest are NOT RUN; the walk hook records it.
local keys = {'zombies', 'upkeep', 'endTurn', 'turnActive', 'tickN', 'results', 'run',
    'fight', 'task', 'fleeing', 'bash', 'turnHealth', 'turnBites', 'turnDeadline', 'turnSeen',
    'turnClose', 'hordeWarned', 'wasAsleep', 'reflexLog'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local function fresh(texts)
    ended = nil
    B.zombies = function() return {} end
    B.upkeep = function() return false end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.turnActive, B.tickN, B.results, B.reflexLog = true, 4, {}, {}
    B.task, B.fight, B.fleeing, B.bash = nil, nil, nil, nil
    local e = {}
    for _, t in ipairs(texts) do e[#e + 1] = {t, t:match('%S+'), {}} end
    B.run = B.newRun(e)
    B.run.lines[1].status, B.run.lines[1].tries = 'running', 1
    B.run.quietSince = getTimestampMs() - 5000
    B.turnSeen, B.turnClose = {}, {}
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
    B.turnBites = B.biteCount(p)
    B.turnDeadline = getGameTime():getWorldAgeHours() * 60 + 120
    B.wasAsleep, B.hordeWarned = nil, nil
end
local ok, err = pcall(function()
    assert(#ISTimedActionQueue.getTimedActionQueue(p).queue == 0, 'run this with the game paused and idle')
    -- 1. PATH FAILED on the running line: it fails, the rest are NOT RUN, the turn ends
    fresh({'go 8175 11673', 'loot 8175 11673 rice'})
    B.lineFailed('PATH FAILED (no route)')
    B.monitor(p)
    assert(B.run.lines[1].status == 'failed', 'line not failed: ' .. tostring(B.run.lines[1].status))
    assert(B.run.lines[2].status == 'notrun', 'next line not NOT RUN')
    assert(ended == 'done', 'turn did not end: ' .. tostring(ended))
    local last = B.results[#B.results]
    assert(last.cmd == 'loot 8175 11673 rice' and not last.ok and last.msg:find('^NOT RUN'), 'NOT RUN not reported')
    -- 2. a failed walk (walkAdj / walkToContainer force-stop) records on the running line
    fresh({'take 1 2', 'home'})
    local fake = setmetatable({ character = {
        getPathFindBehavior2 = function() return { update = function() return BehaviorResult.Failed end, cancel = function() end } end,
        setPath2 = function() end,
    }, forceStop = function() end }, { __index = ISWalkToTimedAction })
    ISWalkToTimedAction.update(fake)
    assert(B.run.lines[1].failMsg, 'walk failure not recorded on the line')
    last = B.results[#B.results]
    assert(last and not last.ok and last.cmd == 'take 1 2', 'walk failure not reported on its line')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: failed lines stop the rest; failed walks are recorded on their line' or ('FAIL: ' .. tostring(err))
```

`tests/resume_after_combat.lua` (full replacement):
```lua
-- A reflex fight mid-line re-runs that line afterwards without using up a retry.
local keys = {'zombies', 'upkeep', 'endTurn', 'turnActive', 'tickN', 'run', 'results',
    'fight', 'task', 'fleeing', 'bash', 'turnHealth', 'turnBites', 'turnDeadline', 'turnSeen',
    'turnClose', 'hordeWarned', 'wasAsleep', 'kills', 'reflexLog'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended, started = nil, 0
local ok, err = pcall(function()
    B.cmds._probe = function() started = started + 1; return 'probing' end
    B.zombies = function() return {} end
    B.upkeep = function() return false end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.turnActive, B.tickN, B.results, B.reflexLog = true, 4, {}, {}
    B.task, B.fleeing, B.bash = nil, nil, nil
    B.turnSeen, B.turnClose = {}, {}
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
    B.turnBites = B.biteCount(p)
    B.turnDeadline = getGameTime():getWorldAgeHours() * 60 + 120
    B.wasAsleep, B.hordeWarned = nil, nil
    B.run = B.newRun({{'_probe', '_probe', {}}})
    B.run.lines[1].status, B.run.lines[1].tries = 'running', 1
    B.interrupt(p)
    assert(B.run.lines[1].status == 'waiting' and B.run.lines[1].tries == 0, 'interrupted line not re-queued without a retry charge')
    -- the runner holds while the reflex fight owns the character (B.runTick directly: a real
    -- fightTick inside B.monitor would end this stub fight in the same call)
    B.fight = {untilMin = B.turnDeadline, reflex = true, targets = {}}
    B.tickN = 10
    B.runTick(p)
    assert(started == 0, 'line restarted during the fight')
    B.fight = nil
    B.tickN = 15
    B.runTick(p)
    assert(started == 1 and B.run.lines[1].status == 'running', 'line did not restart after the fight')
    assert(not ended, 'turn ended before the line finished: ' .. tostring(ended))
    ISTimedActionQueue.clear(p)
end)
B.cmds._probe = nil
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: a reflex fight re-runs the interrupted line afterwards' or ('FAIL: ' .. tostring(err))
```

`tests/combat_stall.lua`: in `keys`, replace `'pending', 'resumeFrom', 'deferred',` with `'run',`.
Replace the line `B.pending, B.resumeFrom, B.deferred, B.task = {}, nil, nil, nil` with `B.run, B.task = nil, nil`.

`tests/injury_before_resume.lua` (full replacement):
```lua
-- A new bite or a big health loss pauses before a waiting line starts.
local keys = {'endTurn', 'biteCount', 'turnActive', 'turnBites', 'turnHealth', 'run', 'tickN', 'results'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended, started = nil, 0
local ok, err = pcall(function()
    B.cmds._probe = function() started = started + 1; return 'probing' end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.biteCount = function() return 1 end
    B.results = {}
    B.turnActive, B.turnBites, B.tickN = true, 0, 4
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
    B.run = B.newRun({{'_probe', '_probe', {}}})
    B.monitor(p)
    assert(ended and ended:find('BITTEN', 1, true) and started == 0, 'a waiting line bypassed the new-bite pause')
    ended = nil
    B.turnActive, B.turnBites, B.tickN = true, 1, 4
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth() + B.hurtPause + 1
    B.run = B.newRun({{'_probe', '_probe', {}}})
    B.monitor(p)
    assert(ended and ended:find('hurt', 1, true) and started == 0, 'a waiting line bypassed the health-loss pause')
end)
B.cmds._probe = nil
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: bites and health loss pause before a waiting line starts' or ('FAIL: ' .. tostring(err))
```

`tests/failed_task.lua` (full replacement):
```lua
-- A failed trip stops the lines after it; a successful one lets them run.
local keys = {'task', 'run', 'results', 'reflexLog', 'turnActive', 'endTurn', 'setSpeedRaw', 'upkeep', 'tickN'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local ok, err = pcall(function()
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.setSpeedRaw = function() end
    B.upkeep = function() return false end
    B.results, B.reflexLog, B.turnActive, B.tickN = {}, {}, true, 4
    local t = {line = 'home'}
    B.run = B.newRun({{'home', 'home', {}}, {'lock 8153 11676', 'lock', {'8153', '11676'}}})
    B.run.lines[1].status, B.run.lines[1].tries, B.run.lines[1].task = 'running', 1, t
    B.task = t
    B.finishTask(false, 'STUCK: regression fixture')
    B.runTick(p)
    assert(ended == 'task failed: home', 'failed trip did not end the turn: ' .. tostring(ended))
    assert(B.run.lines[2].status == 'notrun', 'dependent line still runnable')
    assert(not B.results[#B.results].ok and B.results[#B.results].msg:find('^NOT RUN'), 'skipped line not reported')
    -- success: the trip's line is done and the next one is up
    ended, B.turnActive = nil, true
    t = {line = 'home'}
    B.run = B.newRun({{'home', 'home', {}}, {'look', 'look', {}}})
    B.run.lines[1].status, B.run.lines[1].tries, B.run.lines[1].task = 'running', 1, t
    B.task = t
    B.finishTask(true, 'arrived')
    B.runTick(p)
    assert(not ended and B.run.lines[1].status == 'done' and B.run.cur == 2, 'successful trip did not advance')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: failed tasks stop dependent lines; successful tasks advance' or ('FAIL: ' .. tostring(err))
```

- [ ] **Step 2: Run them and confirm they fail.**
```powershell
cd ~/projects/pz-bot; foreach ($t in 'failed_walk','resume_after_combat','injury_before_resume','failed_task') { "$t -> " + (python pz.py eval (Get-Content "tests/$t.lua" -Raw) | Select-String 'eval:') }
```
Expected: each prints `FAIL: ...` (calling nil `newRun`), or, for `injury_before_resume`, a failed assertion.

- [ ] **Step 3: Add the runner section to CB,** directly after the `ClaudeBotCall` definition (`function ClaudeBotCall:new ... end`).
  It replaces `B.watchAction`/`B.watchTick`: delete those two functions and their comment block.
```lua
---------------------------------------------------------------- turn runner
-- ClaudeBot owns the turn's queue: B.run.lines run one at a time, and the game's timed-action
-- queue only ever holds the current line's actions. The game wipes that queue freely (window and
-- climb states when they end, fights, failed walks), so a line is judged only once the queue has
-- drained and the character has settled. docs/superpowers/specs/2026-09-30-turn-runner-design.md
local SETTLE_MS = 300

function B.newRun(entries)
	local r = { lines = {}, cur = 1 }
	for _, e in ipairs(entries) do
		r.lines[#r.lines + 1] = { text = e[1], verb = e[2], args = e[3], status = "waiting", tries = 0 }
	end
	return r
end

function B.curLine() return B.run and B.run.lines[B.run.cur] end

-- queued after a line's own actions: if it runs, the line ran to its end
ClaudeBotLineEnd = ISBaseTimedAction:derive("ClaudeBotLineEnd")
function ClaudeBotLineEnd:isValid() return true end
function ClaudeBotLineEnd:perform() self.l.ended = true; ISBaseTimedAction.perform(self) end
function ClaudeBotLineEnd:new(p, l)
	local o = ISBaseTimedAction.new(self, p)
	o.l, o.maxTime = l, 1
	o.stopOnWalk, o.stopOnRun, o.stopOnAim = false, false, false
	return o
end

-- a command judges its own outcome: fn(p) returns a message or errors with the reason
function B.setCheck(fn) if B.starting then B.starting.check = fn end end

function B.startLine(p, l)
	l.status, l.tries = "running", l.tries + 1
	l.ended, l.failMsg, l.check, l.task = nil, nil, nil, nil
	B.starting = l
	local ok, msg = pcall(B.cmds[l.verb] or B.immediate[l.verb], p, l.args, l.text)
	B.starting = nil
	B.res(l.text, ok, ok and msg or tostring(msg))
	if not ok then l.status = "failed"; return end
	if B.immediate[l.verb] then l.status = "done"; return end
	if B.task then l.task = B.task; return end
	-- `fight` runs as B.fight, not queued actions: it's done when the fight is (the runner holds meanwhile)
	if B.fight then l.ended = true; return end
	Q(ClaudeBotLineEnd:new(p, l))
end

-- a line failed: everything after it is NOT RUN, and the turn ends
function B.failRun(p, l)
	local r = B.run
	for i = r.cur + 1, #r.lines do
		r.lines[i].status = "notrun"
		B.res(r.lines[i].text, false, "NOT RUN: '" .. l.text .. "' failed")
	end
	r.cur = #r.lines + 1
	ISTimedActionQueue.clear(p)
	B.endTurn(l.task and ("task failed: " .. l.text) or "done")
end

-- actions started mid-swing are rejected; let a swing finish (force it after 1.5 s)
function B.swingSettled(p)
	local swinging = try(function() return p:isPerformingAttackAnimation() end) or p:getCurrentState() == SwipeStatePlayer.instance()
	if not swinging then B.swingSince = nil; return true end
	B.swingSince = B.swingSince or getTimestampMs()
	if getTimestampMs() - B.swingSince > 1500 then
		p:setPerformingAttackAnimation(false); p:setIsAiming(false); p:setAttackStarted(false)
		p:changeState(IdleState.instance())
	end
	return false
end

function B.runTick(p)
	local r = B.run
	if not r then return end
	if B.fight or B.fleeing or B.bash or p:isAsleep() or B.busyState(p:getCurrentState()) then r.quietSince = nil; return end
	local q = ISTimedActionQueue.getTimedActionQueue(p).queue
	local l = r.lines[r.cur]
	if not l then
		if #q > 0 then return end
		if B.upkeep(p) then return end
		B.run = nil
		B.endTurn("done")
		return
	end
	if l.status == "waiting" then
		-- clear() cancels anything added in the same tick; other actions (rearm, pick-ups) go first
		if r.clearedTick == B.tickN or #q > 0 or not B.swingSettled(p) then return end
		B.startLine(p, l)
		if l.status == "failed" then return B.failRun(p, l) end
		if l.status == "done" then r.cur = r.cur + 1 end
		return
	end
	if l.task then
		if B.task == l.task then return end
		if not l.task.ok then l.status = "failed"; return B.failRun(p, l) end
		l.status, r.cur = "done", r.cur + 1
		return
	end
	if #q > 0 then r.quietSince = nil; return end
	r.quietSince = r.quietSince or getTimestampMs()
	if getTimestampMs() - r.quietSince < SETTLE_MS then return end
	r.quietSince = nil
	if l.failMsg then l.status = "failed"
	elseif l.check then
		local ok, msg = pcall(l.check, p)
		B.res(l.text, ok, ok and msg or tostring(msg):gsub("^.-:%d+: ", ""))
		l.status = ok and "done" or "failed"
	elseif l.ended then l.status = "done"
	elseif l.tries < 2 then
		l.status = "waiting"
		B.rlog("again: " .. l.text .. " (it was cut short)")
		return
	else
		B.res(l.text, false, "interrupted before it finished")
		l.status = "failed"
	end
	if l.status == "failed" then return B.failRun(p, l) end
	r.cur = r.cur + 1
end
```

- [ ] **Step 4: Rewrite `B.lineFailed`** (its current body reads `B.pending`/`B.pendingIdx`):
```lua
-- An action of the running line failed (no route...). Report it on that line and mark it failed
-- for the runner.
function B.lineFailed(msg)
	local l = B.curLine()
	if l and l.status == "running" then l.failMsg = l.failMsg or msg end
	B.res(l and l.text or "?", false, msg)
end
```
Keep the `ISWalkToTimedAction:update` hook below it unchanged.

- [ ] **Step 5: Delete the whole `ClaudeBotStep` block** (from `ClaudeBotStep = ISBaseTimedAction:derive` through the
  end of `function ClaudeBotStep:new`, including the hold comment). In `B.cmds.bash`, replace
  `Q(ClaudeBotStep:new(p, "bash", "_bashgo", { a[1], a[2], a[3] }))` with:
```lua
	Q(ClaudeBotCall:new(p, "bash", function(p) return B.cmds._bashgo(p, { a[1], a[2], a[3] }) end))
```

- [ ] **Step 6: Window checks use `B.setCheck`.** In `B.cmds.window`, replace the open/close branch and the climb branch:
```lua
	if verb == "open" or verb == "close" then
		Q(ISOpenCloseWindow:new(p, w))
		B.setCheck(function(p)
			if w:IsOpen() == (verb == "open") then return "window is " .. (verb == "open" and "open" or "closed") end
			error("still " .. (w:IsOpen() and "open" or "closed") .. " (" .. windowWhy(w) .. ")")
		end)
	elseif verb == "smash" then Q(ISSmashWindow:new(p, w))
	elseif verb == "clearglass" then Q(ISRemoveBrokenGlass:new(p, w))
	elseif verb == "climb" then
		local act, side, started = ISClimbThroughWindow:new(p, w, 0), nil, false
		local perform = act.perform
		act.perform = function(self) side, started = windowSide(self.character, w), true; perform(self) end
		Q(act)
		B.setCheck(function(p)
			if started and windowSide(p, w) ~= side then return "climbed through" end
			error("still on the same side (" .. (started and "" or "the climb never started; ") .. windowWhy(w) .. ")")
		end)
	else error("window verb: open|close|smash|clearglass|climb") end
```
Delete the now-unused `local line = "window " .. ...` line.

- [ ] **Step 7: `B.interrupt`, tasks and fights.**

Replace `B.interrupt` and delete `B.resumePending` (and the two comment lines above `B.interrupt`
that mention `B.pending`):
```lua
-- A reflex (fight, rearm, flee, weapon pick-up) takes over: clear the game queue and put the
-- running line back to waiting, so the runner starts it again afterwards. A reflex isn't the
-- line's fault, so it doesn't count as a try.
function B.interrupt(p)
	if B.task then B.task.interrupted = true end
	local l = B.curLine()
	if l and l.status == "running" and not l.task then l.status, l.tries = "waiting", l.tries - 1 end
	if B.run then B.run.clearedTick = B.tickN end
	ISTimedActionQueue.clear(p)
end
```
Replace `startTask` and `B.finishTask` (and fix the comment above them):
```lua
-- A goal owns the character until it finishes; the runner holds the turn's later lines meanwhile.
local function startTask(t, line)
	t.line = line
	B.task = t
end

function B.finishTask(ok, msg)
	local t = B.task
	B.task = nil
	t.ok = ok
	B.setSpeedRaw(B.speed)
	B.res(t.line, ok, msg)
	-- walking in through a locked door with its key unlocks it and leaves it that way
	if ok and t.home then
		local n = B.lockBase(P())
		if n > 0 then B.rlog("locking " .. n .. " base door" .. (n > 1 and "s" or "") .. " behind you") end
	end
end
```
In `B.endFight`, delete the line `if f.reflex then B.resumePending() end`.

- [ ] **Step 8: `B.startTurn` builds `B.run`.** Replace everything from `local cont = false` through the
  end of the `for _, l in ipairs(lines) do ... end` loop with:
```lua
	local cont = false
	if lines[1] and lines[1]:match("^%s*continue") then cont = true; table.remove(lines, 1) end
	if not cont or not B.run then
		if #ISTimedActionQueue.getTimedActionQueue(p).queue > 0 or p:getCharacterActions():size() > 0 then ISTimedActionQueue.clear(p) end
		B.fight = nil; B.bash = nil; B.task = nil; B.fleeing = nil
		B.run = nil
		B.setSpeedRaw(B.speed)
	else
		-- a hit or a pause stopped the turn: run the interrupted line again, then the rest
		local l = B.curLine()
		if l and l.status == "running" and not l.task and #ISTimedActionQueue.getTimedActionQueue(p).queue == 0 then l.status = "waiting" end
	end
	if try(function() return p:isPerformingAttackAnimation() end) then p:setPerformingAttackAnimation(false) end
	p:setIsAiming(false)
	local entries = {}
	for _, l in ipairs(lines) do
		local args = {}
		for w in l:gmatch("%S+") do args[#args + 1] = w end
		local verb = table.remove(args, 1)
		if not (B.cmds[verb] or B.immediate[verb]) then
			B.res(l, false, "unknown command")
		elseif B.immediate[verb] and #entries == 0 and not B.run then
			-- instant commands before any queued one run now, with the game still paused
			local ok, msg = pcall(B.immediate[verb], p, args, l)
			B.res(l, ok, msg)
		else
			entries[#entries + 1] = { l, verb, args }
		end
	end
	if B.run then
		for _, e in ipairs(B.newRun(entries).lines) do table.insert(B.run.lines, e) end
	elseif #entries > 0 then
		B.run = B.newRun(entries)
	end
	local needRun = B.run ~= nil and B.run.cur <= #B.run.lines
```
Also delete `B.autoResumed = {}` near the top of `B.startTurn`. The rest of `startTurn` (from `B.turnHealth = ...`) is
unchanged and still uses `needRun`.

- [ ] **Step 9: `B.monitor`.** Delete the whole `if B.deferred then ... end` block (the swing handling now lives in
  `B.swingSettled`). Delete the line `if B.watches and B.watchTick(p) then return end`. Replace the block that
  starts `if #q == 0 and not B.deferred and not B.fight ...` and runs to its matching `end` (the auto-resume and
  NOT RUN reporting), together with the `local q = ...` line and the two comment lines just above it, with:
```lua
	B.runTick(p)
```
- [ ] **Step 10: `B.state` queue field.** Replace the three `s.queue` lines with:
```lua
	s.queue = {}
	local r = B.run
	for i = r and r.cur or 1, r and #r.lines or 0 do s.queue[#s.queue + 1] = r.lines[i].text end
```
- [ ] **Step 11: Leftovers.** The following must return no hits (the second list comes from `B.startTurn`):
```bash
cd ~/projects/pz-bot && grep -n "ClaudeBotStep\|B\.pending\|pendingIdx\|resumeFrom\|failedIdx\|autoResumed\|B\.deferred\|B\.watches\|watchAction\|watchTick\|resumePending\|runAfterImm" mod/ClaudeBot/42/media/lua/client/ClaudeBot.lua
```
Expected: no output. Fix any hit, following the patterns above.

- [ ] **Step 12: Reload and run all game tests.**
```powershell
cd ~/projects/pz-bot; python pz.py reload; foreach ($t in 'failed_walk','resume_after_combat','combat_stall','injury_before_resume','failed_task','covered_bite','window_target','floor_default') { "$t -> " + (python pz.py eval (Get-Content "tests/$t.lua" -Raw) | Select-String 'eval:') }; python tests/test_turnlog.py
```
Expected: 8 × `PASS`, plus `PASS: turn log lines`. Also check the console: `Select-String -Path ~/Zomboid/console.txt -Pattern "ClaudeBot" | Select-Object -Last 5` shows no new errors.

- [ ] **Step 13: Commit**
```bash
cd ~/projects/pz-bot && git add mod tests && git commit -m "Turn runner: ClaudeBot runs a turn's lines one at a time and owns its queue"
```

---

### Task 3: Retry and continue behavior, plus live scenarios

**Files:** Create `tests/run_retry.lua` and `tests/run_continue.lua`; modify `tests/README.md`.

**Interfaces:** Consumes `B.newRun`, `B.runTick`, `B.curLine`, `B.startTurn` from Task 2.

- [ ] **Step 1: Write `tests/run_retry.lua`**
```lua
-- A line wiped with no failure recorded runs again once, then fails with a reason.
local keys = {'run', 'results', 'reflexLog', 'endTurn', 'turnActive', 'tickN', 'upkeep', 'fight', 'task', 'fleeing', 'bash'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local ok, err = pcall(function()
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.upkeep = function() return false end
    B.results, B.reflexLog, B.turnActive, B.tickN = {}, {}, true, 7
    B.fight, B.task, B.fleeing, B.bash = nil, nil, nil, nil
    B.run = B.newRun({{'look', 'look', {}}, {'say x', 'say', {'x'}}})
    local l = B.run.lines[1]
    l.status, l.tries, l.verb = 'running', 1, '_none'  -- a queued line whose actions got wiped
    B.run.quietSince = getTimestampMs() - 5000
    B.runTick(p)
    assert(l.status == 'waiting' and not ended, 'first wipe should re-queue the line')
    l.status, l.tries = 'running', 2
    B.run.quietSince = getTimestampMs() - 5000
    B.runTick(p)
    assert(l.status == 'failed' and ended == 'done', 'second wipe should fail the line')
    local found = false
    for _, r in ipairs(B.results) do if r.cmd == 'look' and not r.ok and r.msg == 'interrupted before it finished' then found = true end end
    assert(found, 'no "interrupted before it finished" result')
    assert(B.run.lines[2].status == 'notrun', 'line after the failure still runnable')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: a cut-short line runs again once, then fails with a reason' or ('FAIL: ' .. tostring(err))
```
- [ ] **Step 2: Write `tests/run_continue.lua`**
```lua
-- `continue` keeps the unfinished run, restarts the interrupted line and appends new lines.
local keys = {'run', 'results', 'turnActive', 'setPaused', 'writeFile', 'dumpState', 'turn'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ok, err = pcall(function()
    B.setPaused, B.writeFile, B.dumpState = function() end, function() end, function() end
    B.run = B.newRun({{'go 1 2', 'go', {'1', '2'}}, {'look', 'look', {}}})
    B.run.lines[1].status, B.run.lines[1].tries = 'running', 1
    B.startTurn(12345, {'continue', 'say hi'})
    local r = B.run
    assert(r and r.cur == 1 and r.lines[1].status == 'waiting', 'interrupted line not restarted')
    assert(#r.lines == 3 and r.lines[3].text == 'say hi', 'new line not appended')
    B.startTurn(12346, {'look'})
    assert(B.run == nil, 'a fresh instant-only turn should drop the old run')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
B.turnActive = false
R = ok and 'PASS: continue resumes at the interrupted line and appends new ones' or ('FAIL: ' .. tostring(err))
```
- [ ] **Step 3: Run both; they should pass against Task 2's code.** If either fails, fix `B.runTick`/`B.startTurn`, not the test, unless
  the test contradicts the spec.
```powershell
cd ~/projects/pz-bot; foreach ($t in 'run_retry','run_continue') { "$t -> " + (python pz.py eval (Get-Content "tests/$t.lua" -Raw) | Select-String 'eval:') }
```
Expected: 2 × `PASS`.
- [ ] **Step 4: Add both to `tests/README.md`** after the `floor_default.lua` line:
```
python pz.py eval (Get-Content 'tests/run_retry.lua' -Raw)
python pz.py eval (Get-Content 'tests/run_continue.lua' -Raw)
```
- [ ] **Step 5: Live scenarios in the game** (the survivor starts at base 8153,11677). Each must show the listed results.
```bash
cd ~/projects/pz-bot
python pz.py do "go 8198 11683" "window 8198 11682 open" "window 8198 11682 climb" "window 8198 11682 climb" "window 8198 11682 close" "say done"
```
  - Expected, in order: go ok; `open` → `window is open`; climb → `climbed through` (twice); `close` → `window is closed`;
    say ok. The end position is outside at 8198,11682.x. Results are strictly in line order.
```bash
python pz.py do "take 1917193521" "home"
```
  - Expected: `ERR take 1917193521: couldn't walk there (no route)`, then `ERR home: NOT RUN: 'take 1917193521' failed`.
    If the freezer item is gone, pick any unreachable container item from `find`.
```bash
python pz.py do "home" "go 8157 11683" "look"
```
  - Expected: home arrives; the fort line is locked; go ok; look ok; the turn ends `done`.
```bash
python pz.py eval "p:dropHandItems() R='dropped'"; python pz.py do "wait 1" "say after"
```
  - Expected: reflexes show `dropped Firefighter Axe ... picking it back up`; `wait 1` ok; `say after` ok; hand holds the axe.
  - If any scenario misbehaves, apply superpowers:systematic-debugging (a per-tick trace like the one used on
    2026-09-30: wrap `B.onPlayerUpdate` to log state name and queue) before changing code.
- [ ] **Step 6: Commit**
```bash
cd ~/projects/pz-bot && git add tests && git commit -m "Tests: runner retry and continue"
```

---

### Task 4: Docs, release, and a player run

**Files:** Modify `PLAYING.md`, `CHANGELOG.md`, the 4 version spots.

- [ ] **Step 1: `PLAYING.md`.** Replace the paragraph starting `After an early pause, send \`continue\``, which currently reads
  "After an early pause, send `continue` as the first line to resume the leftover queue. Any other first command clears it.", with:
```
Lines run one at a time: each starts only after the one before it has finished and been checked.
If a line fails, the rest of the turn is listed as `NOT RUN`. If something cuts a line short without
an error (the game dropped its actions), it runs again once, then fails with `interrupted before it
finished`. A reflex (fight, rearm, picking up a dropped weapon) re-runs the line it interrupted.
After an early pause, send `continue` as the first line to pick up at the interrupted line; any other
first command starts a fresh turn.
```
- [ ] **Step 2: Bump to 0.6.0** in the 4 places, then run `python pz.py reload` and `python pz.py do look`. There must be no `WARNING` line.
- [ ] **Step 3: `CHANGELOG.md`.** Add above `## 0.5.0`:
```
## 0.6.0 — 2026-09-30

### Changed
- **Turn runner: ClaudeBot runs a turn's lines itself, one at a time.** The game's action queue only
  ever holds the current line's actions. Each line is judged once they've drained and the character
  has settled (window/climb/fall states and swings included):
  - by its check (window open/close/climb);
  - by a recorded failure (PATH FAILED, couldn't walk there);
  - or by an end marker queued after its actions.
  A failed line stops the turn (`NOT RUN: '<line>' failed`). A line cut short with no error runs
  again once, then fails with `interrupted before it finished`. Reflexes re-run the line they
  interrupted.
- Removed the old engine and its flags: `ClaudeBotStep`, the deferred queue, `pending`/`pendingIdx`/
  `resumeFrom`/`failedIdx`, the one-time auto-resume, and the window watch list. Spec:
  `docs/superpowers/specs/2026-09-30-turn-runner-design.md`.
- Tests rewritten against the runner; new: `tests/run_retry.lua`, `tests/run_continue.lua`.
```
- [ ] **Step 4: Run the full suite one last time** (the 10 game tests plus `test_turnlog.py`). All must PASS.
- [ ] **Step 5: Commit, tag, push**
```bash
cd ~/projects/pz-bot && git add -A PLAYING.md CHANGELOG.md pz.py mod && git commit -m "Release 0.6.0: turn runner" && git tag -a v0.6.0 -m "v0.6.0: turn runner" && git push --follow-tags origin main
```
- [ ] **Step 6: Player run** (from the supervisor session): send a Sonnet player, following
  `.claude/agents/pz-player.md`, on the fire-station trip. Goals: bring back a stash of axes and food; look after
  needs; normal 150-turn cap.
  - Afterwards, compare its `runtime/turns.jsonl` rows against the v0.5.0 run's rows:
    count ERR, NOT RUN, and `again:` reflex lines per turn.
  - Report anything the runner got wrong, with the exact turn row.

## Verification (end to end)
- **The 10 game tests plus the log test pass** (Task 4, Step 4).
- **The four live scenarios in Task 3, Step 5 behave as listed.** Results come in line order, window
  checks are truthful, an unreachable `take` stops the turn, and a dropped weapon is recovered and the
  line re-run.
- **The feed at http://192.168.1.35:5160** shows the player run's turns with no unexplained `ERR`/`skip` rows.
- **`grep` for the old flags** returns nothing (Task 2, Step 11).
