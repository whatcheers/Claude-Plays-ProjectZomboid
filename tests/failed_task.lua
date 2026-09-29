-- A failed trip must not run subsequent lock/stash commands at another location.
local keys = {'task', 'pending', 'pendingIdx', 'resumeFrom', 'deferred',
    'results', 'reflexLog', 'turnActive', 'endTurn', 'setSpeedRaw'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local ok, err = pcall(function()
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.setSpeedRaw = function() end
    B.results, B.reflexLog = {}, {}
    B.pending = {{'home', 'home', {}, 1}, {'lock 8153 11676', 'lock', {'8153', '11676'}, 2}}
    B.pendingIdx, B.resumeFrom, B.deferred, B.turnActive = 1, nil, nil, true
    B.task = {line = 'home', resumeFrom = 2}
    B.finishTask(false, 'STUCK: regression fixture')
    assert(ended and not B.turnActive, 'failed trip did not pause')
    assert(not B.deferred and not B.resumeFrom and #B.pending == 0, 'failed trip left dependent actions runnable')
    assert(#B.results == 2 and not B.results[2].ok, 'skipped dependent command was not reported')
    -- Successful arrival still resumes the rest of the command batch.
    ended = nil
    B.pending = {{'home', 'home', {}, 1}, {'look', 'look', {}, 2}}
    B.task, B.turnActive = {line = 'home', resumeFrom = 2}, true
    B.finishTask(true, 'arrived')
    assert(not ended and B.deferred and B.deferred[1][1] == 'look', 'successful trip did not resume following command')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: failed tasks stop dependent commands; successful tasks resume them' or ('FAIL: ' .. tostring(err))
