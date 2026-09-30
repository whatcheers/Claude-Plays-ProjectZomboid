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
