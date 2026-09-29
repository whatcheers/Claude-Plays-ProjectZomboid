-- Deferred actions must not bypass the injury pause.
local keys = {'endTurn', 'biteCount', 'turnActive', 'turnBites', 'turnHealth',
    'deferred', 'tickN', 'swingSince'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local oldAdd, ended = ISTimedActionQueue.add, nil
local ok, err = pcall(function()
    ISTimedActionQueue.add = function() end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.biteCount = function() return 1 end
    B.turnActive, B.turnBites = true, 0
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth()
    B.deferred = {{'look', 'look', {}, 1}}
    B.monitor(p)
    assert(ended and ended:find('BITTEN', 1, true), 'deferred work bypassed new-bite pause')
    ended = nil
    B.turnActive, B.turnBites = true, 1
    B.turnHealth = p:getBodyDamage():getOverallBodyHealth() + B.hurtPause + 1
    B.deferred = {{'look', 'look', {}, 1}}
    B.monitor(p)
    assert(ended and ended:find('hurt', 1, true), 'deferred work bypassed health-loss pause')
end)
ISTimedActionQueue.add = oldAdd
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: bites and health loss pause before deferred actions' or ('FAIL: ' .. tostring(err))
