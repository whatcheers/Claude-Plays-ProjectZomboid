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
