-- A line whose walk fails must not let the next lines run somewhere else.
-- Seen: `go` PATH FAILED, then `loot` ran at the wrong spot; `take` from an unreachable freezer
-- dropped its check line and the turn jumped to `home`. Both came from the one-time auto-resume
-- treating a failure like a harmless queue wipe.
local keys = {'zombies', 'upkeep', 'endTurn', 'turnActive', 'tickN', 'deferred', 'results',
    'fight', 'task', 'fleeing', 'bash', 'pending', 'pendingIdx', 'resumeFrom', 'failedIdx',
    'turnHealth', 'turnBites', 'turnDeadline', 'turnSeen', 'turnClose',
    'hordeWarned', 'wasAsleep', 'reflexLog', 'autoResumed'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local function fresh(lines)
    ended = nil
    B.zombies = function() return {} end
    B.upkeep = function() return false end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.turnActive, B.tickN, B.deferred, B.resumeFrom, B.failedIdx = true, 4, nil, nil, nil
    B.results, B.reflexLog, B.autoResumed = {}, {}, {}
    B.task, B.fight, B.fleeing, B.bash = nil, nil, nil, nil
    B.pending = lines
    B.pendingIdx = 1
    B.turnSeen, B.turnClose = {}, {}
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
    B.turnBites = B.biteCount(p)
    B.turnDeadline = getGameTime():getWorldAgeHours() * 60 + 120
    B.wasAsleep, B.hordeWarned = nil, nil
end
local ok, err = pcall(function()
    assert(#ISTimedActionQueue.getTimedActionQueue(p).queue == 0, 'run this with the game paused and idle')
    -- 1. the running line failed: the rest is reported NOT RUN and the turn ends
    fresh({{'go 8175 11673', 'go', {'8175', '11673'}, 1}, {'loot 8175 11673 rice', 'loot', {}, 2}})
    B.lineFailed('PATH FAILED (no route)')
    B.monitor(p)
    assert(not B.deferred and not B.resumeFrom, 'a failed line let the next one run')
    assert(ended == 'done', 'turn did not end after the failure: ' .. tostring(ended))
    local last = B.results[#B.results]
    assert(last and not last.ok and last.cmd == 'loot 8175 11673 rice' and last.msg:find('NOT RUN'), 'skipped line not reported')
    -- 2. a queue wiped with no failure (window opening, getting up) still resumes once
    fresh({{'window 1 2 open', 'window', {}, 1}, {'look', 'look', {}, 2}})
    B.monitor(p)
    assert(B.deferred and B.deferred[1][1] == 'look', 'a harmless queue wipe no longer resumes')
    assert(not ended, 'turn ended instead of resuming')
    -- 3. a walk that can't find a route reports it against the running line
    fresh({{'take 1 2', 'take', {}, 1}, {'home', 'home', {}, 2}})
    local fake = setmetatable({ character = {
        getPathFindBehavior2 = function() return { update = function() return BehaviorResult.Failed end, cancel = function() end } end,
        setPath2 = function() end,
    }, forceStop = function() end }, { __index = ISWalkToTimedAction })
    ISWalkToTimedAction.update(fake)
    assert(B.failedIdx == 1, 'walk failure was not recorded')
    last = B.results[#B.results]
    assert(last and not last.ok and last.cmd == 'take 1 2', 'walk failure not reported on its line')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: failed lines stop the rest; harmless wipes resume; failed walks are reported' or ('FAIL: ' .. tostring(err))
