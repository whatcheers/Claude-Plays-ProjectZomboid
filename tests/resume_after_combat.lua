-- Run through pz.py eval in a paused, safe singleplayer world.
-- Exercise the real monitor/endFight/resumePending sequence; isolate enemy sensing.
local keys = {'zombies', 'upkeep', 'endTurn', 'turnActive', 'tickN', 'deferred',
    'fight', 'task', 'fleeing', 'bash', 'pending', 'pendingIdx', 'resumeFrom',
    'turnHealth', 'turnBites', 'turnDeadline', 'turnSeen', 'turnClose',
    'hordeWarned', 'wasAsleep', 'kills', 'reflexLog', 'autoResumed'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local ok, err = pcall(function()
    B.zombies = function() return {} end
    B.upkeep = function() return false end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.turnActive, B.tickN, B.deferred = true, 4, nil
    B.reflexLog = {}
    B.task, B.fleeing, B.bash = nil, nil, nil
    B.pending = {{'go 8173 11671', 'go', {'8173', '11671'}, 1}}
    B.pendingIdx, B.resumeFrom = 1, 1
    B.turnSeen, B.turnClose = {}, {}
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
    B.turnBites = B.biteCount(p)
    B.turnDeadline = getGameTime():getWorldAgeHours() * 60 + 120
    B.wasAsleep, B.hordeWarned = nil, nil
    B.fight = {untilMin = B.turnDeadline, reflex = true, targets = {}}
    B.monitor(p)
    assert(B.deferred and #B.deferred == 1, 'combat must schedule interrupted movement')
    assert(not ended and B.turnActive, 'turn ended before deferred movement ran: ' .. tostring(ended))
    -- An empty queue really should finish once no deferred work remains.
    B.deferred, B.tickN = nil, 4
    B.monitor(p)
    assert(ended == 'done' and not B.turnActive, 'ordinary completed turn did not end')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: combat resume stays active; ordinary empty turn ends' or ('FAIL: ' .. tostring(err))

