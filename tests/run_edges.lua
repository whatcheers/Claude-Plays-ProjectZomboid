-- Runner edge cases from the v0.6.0 review minors, plus the paths no other test pinned.
local keys = {'run', 'results', 'reflexLog', 'endTurn', 'turnActive', 'tickN', 'upkeep', 'fight',
    'task', 'fleeing', 'bash', 'setPaused', 'writeFile', 'dumpState', 'turn', 'turnDeadline',
    'turnHealth', 'turnBites', 'turnSeen', 'turnClose', 'turnStartReal', 'setSpeedRaw'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended, starts = nil, 0
local function fresh(texts)
    ended, starts = nil, 0
    B.results, B.reflexLog, B.turnActive, B.tickN = {}, {}, true, 7
    B.fight, B.task, B.fleeing, B.bash = nil, nil, nil, nil
    local e = {}
    for _, t in ipairs(texts) do e[#e + 1] = {t, t:match('%S+'), {}} end
    B.run = B.newRun(e)
    return B.run.lines[1]
end
local function settle() B.run.quietSince = getTimestampMs() - 5000; B.tickN = B.tickN + 1; B.runTick(p) end
local function logged(s) return table.concat(B.reflexLog, '; '):find(s, 1, true) ~= nil end
local ok, err = pcall(function()
    B.cmds._probe = function() starts = starts + 1; return 'probing' end
    B.cmds._fighter = function() starts = starts + 1; B.fight = {untilMin = 1e12, targets = {}}; return 'fighting' end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.upkeep = function() return false end
    B.setSpeedRaw = function() end
    B.setPaused, B.writeFile, B.dumpState = function() end, function() end, function() end

    -- minor: a walk failing while the line is only waiting (a reflex's pick-up, lockBase after
    -- `home`) is logged, not pinned on the line
    local l = fresh({'_probe'})
    B.lineFailed('could not walk there (no route)')
    assert(not l.failMsg and #B.results == 0 and logged('no route'), 'waiting line took the blame for a walk failure')
    -- ...and with no run at all (end-of-turn upkeep) it's logged, not reported as "?"
    B.run = nil
    B.lineFailed('could not walk there (no route)')
    assert(#B.results == 0, 'a walk failure outside any line was reported as a result')

    -- minor: startTurn marks its own queue clear, so no line starts in that tick
    B.run = nil; B.tickN = 20; B.turnActive = false
    B.startTurn(5151, {'_probe'})
    assert(B.run and B.run.clearedTick == 21, 'startTurn did not mark its clear: ' .. tostring(B.run and B.run.clearedTick))

    -- minor: a failed line leaves no orphaned goal task behind
    l = fresh({'_probe', 'look'})
    l.status, l.tries, l.failMsg = 'running', 1, 'boom'
    B.task = {line = 'travel 1 2'}
    settle()
    assert(ended == 'done' and B.task == nil, 'failRun left B.task set')

    -- gap: the plain happy path, judged done by its end marker
    l = fresh({'_probe', 'look'})
    l.status, l.tries, l.ended = 'running', 1, true
    settle()
    assert(l.status == 'done' and B.run.cur == 2 and B.run.lines[2].status == 'waiting', 'end marker did not finish the line')

    -- gap: a `fight` line is done when the fight is; the runner holds meanwhile
    l = fresh({'_fighter', 'look'})
    B.tickN = 30
    B.runTick(p)
    assert(starts == 1 and l.status == 'running' and l.ended, 'fight line not started as ended')
    settle()
    assert(l.status == 'running', 'runner judged the line during the fight')
    B.fight = nil
    settle()
    assert(l.status == 'done' and B.run.cur == 2, 'fight line not done after the fight')

    -- gap: the runner holds while a bash owns the character
    l = fresh({'_probe'})
    l.status, l.tries = 'running', 1
    B.bash = {}
    settle()
    assert(l.status == 'running', 'runner judged the line during a bash')
    B.bash = nil

    -- gap: a waiting line doesn't start while other actions (a rearm's equip) are queued
    l = fresh({'_probe'})
    ISTimedActionQueue.add(ClaudeBotCall:new(p, 'queued by a reflex', function() end))
    B.tickN = 40
    B.runTick(p)
    assert(starts == 0 and l.status == 'waiting', 'line started over queued reflex actions')
    ISTimedActionQueue.clear(p)
end)
B.cmds._probe, B.cmds._fighter = nil, nil
ISTimedActionQueue.clear(p)
for _, k in ipairs(keys) do B[k] = saved[k] end
B.turnActive = false
R = ok and 'PASS: runner edges (walk blame, clear tick, orphaned task, end marker, fight, bash, queued reflex)' or ('FAIL: ' .. tostring(err))
