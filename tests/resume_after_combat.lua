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
    assert(B.run.lines[1].cut and B.run.lines[1].tries == 0, 'interrupted line not marked cut with its try given back')
    -- the runner holds while the reflex fight owns the character (B.runTick directly: a real
    -- fightTick inside B.monitor would end this stub fight in the same call)
    B.fight = {untilMin = B.turnDeadline, reflex = true, targets = {}}
    B.tickN = 10
    B.runTick(p)
    assert(started == 0, 'line restarted during the fight')
    B.fight = nil
    B.run.quietSince = getTimestampMs() - 5000
    B.tickN = 15
    B.runTick(p)  -- judged: cut and unfinished, so it goes back to waiting
    assert(B.run.lines[1].status == 'waiting', 'cut line not re-queued after the fight')
    B.tickN = 16
    B.runTick(p)
    assert(started == 1 and B.run.lines[1].status == 'running', 'line did not restart after the fight')
    assert(not ended, 'turn ended before the line finished: ' .. tostring(ended))
    ISTimedActionQueue.clear(p)
end)
B.cmds._probe = nil
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: a reflex fight re-runs the interrupted line afterwards' or ('FAIL: ' .. tostring(err))
