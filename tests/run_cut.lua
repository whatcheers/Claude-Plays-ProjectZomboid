-- Review fixes 1 and 3: an interrupt or `continue` must not re-run a line that already finished;
-- a line cut mid-way re-runs without a retry charge; a failed check step fails its line.
local keys = {'run', 'results', 'reflexLog', 'endTurn', 'turnActive', 'tickN', 'upkeep', 'fight',
    'task', 'fleeing', 'bash', 'setPaused', 'writeFile', 'dumpState', 'turn', 'turnDeadline',
    'turnHealth', 'turnBites', 'turnSeen', 'turnClose'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended, starts = nil, 0
local function fresh(finished)
    ended, starts = nil, 0
    B.results, B.reflexLog, B.turnActive, B.tickN = {}, {}, true, 7
    B.fight, B.task, B.fleeing, B.bash = nil, nil, nil, nil
    B.run = B.newRun({{'_probe', '_probe', {}}, {'look', 'look', {}}})
    local l = B.run.lines[1]
    l.status, l.tries, l.ended = 'running', 1, finished or nil
    return l
end
local function settle() B.run.quietSince = getTimestampMs() - 5000; B.tickN = B.tickN + 1; B.runTick(p) end
local ok, err = pcall(function()
    B.cmds._probe = function() starts = starts + 1; return 'probing' end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.upkeep = function() return false end
    B.setPaused, B.writeFile, B.dumpState = function() end, function() end, function() end
    -- A. a reflex right after the line finished: judged done, not re-run
    local l = fresh(true)
    B.interrupt(p)
    settle()
    assert(l.status == 'done' and B.run.cur == 2 and starts == 0, 'finished line re-run after an interrupt: ' .. l.status)
    -- B. a reflex mid-line: re-run, and the try is given back
    l = fresh(false)
    B.interrupt(p)
    settle()
    assert(l.status == 'waiting' and l.tries == 0, 'cut line not re-queued free: ' .. l.status .. ' tries ' .. l.tries)
    settle()
    assert(starts == 1 and l.status == 'running', 'cut line not restarted')
    ISTimedActionQueue.clear(p)
    -- C. `continue` after a pause that came after the line finished: done, not re-run
    l = fresh(true)
    B.turnActive = false
    B.startTurn(4242, {'continue'})
    settle()
    assert(l.status == 'done' and starts == 0, 'continue re-ran a finished line: ' .. l.status)
    ISTimedActionQueue.clear(p)
    -- D. a failed check step (verifyTaken, put, enter...) fails its line and stops the rest
    l = fresh(false)
    B.stepResult('take', false, 'missing: Axe #1')
    settle()
    assert(l.status == 'failed' and B.run.lines[2].status == 'notrun' and ended == 'done', 'failed check step did not fail its line')
    -- E. but not while a reflex has the line cut (the reflex's own pick-up failing)
    l = fresh(false)
    B.interrupt(p)
    B.stepResult('pick up dropped Axe', false, 'could not get it back')
    assert(not l.failMsg, 'a reflex step failure was pinned on the line')
end)
B.cmds._probe = nil
ISTimedActionQueue.clear(p)
for _, k in ipairs(keys) do B[k] = saved[k] end
B.turnActive = false
R = ok and 'PASS: finished lines are not re-run; cut lines re-run free; failed check steps fail their line' or ('FAIL: ' .. tostring(err))
