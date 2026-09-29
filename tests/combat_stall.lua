-- A downed enemy taking no damage must stop the turn, not restart combat forever.
local keys = {'zombies', 'attack', 'endTurn', 'fight', 'pending', 'resumeFrom',
    'deferred', 'kills', 'reflexLog', 'turnActive', 'task'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended, swings = nil, 0
local enemy = {getHealth = function() return 1 end, isOnFloor = function() return true end,
    isDead = function() return false end}
local ok, err = pcall(function()
    B.zombies = function() return {{z = enemy, d = 0.5, seen = true}} end
    B.attack = function() swings = swings + 1 end
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.pending, B.resumeFrom, B.deferred, B.task = {}, nil, nil, nil
    B.reflexLog, B.turnActive = {}, true
    B.fight = {untilMin = getGameTime():getWorldAgeHours() * 60 + 3, reflex = true}
    for i = 1, 6 do if B.fight then B.fightTick(p) end end
    assert(ended and ended:find('combat stalled', 1, true), 'no-damage combat did not pause for a new decision')
    assert(not B.fight and not B.turnActive, 'stalled combat can restart automatically')
    assert(swings <= 4, 'kept attacking a downed target without dealing damage')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
B.zids[enemy] = nil
R = ok and 'PASS: futile attacks pause the turn after four attempts' or ('FAIL: ' .. tostring(err))
