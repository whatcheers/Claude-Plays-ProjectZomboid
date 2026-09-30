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
