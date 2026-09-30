-- A failed trip stops the lines after it; a successful one lets them run.
local keys = {'task', 'run', 'results', 'reflexLog', 'turnActive', 'endTurn', 'setSpeedRaw', 'upkeep', 'tickN'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ended
local ok, err = pcall(function()
    B.endTurn = function(reason) ended = reason; B.turnActive = false end
    B.setSpeedRaw = function() end
    B.upkeep = function() return false end
    B.results, B.reflexLog, B.turnActive, B.tickN = {}, {}, true, 4
    local t = {line = 'home'}
    B.run = B.newRun({{'home', 'home', {}}, {'lock 8153 11676', 'lock', {'8153', '11676'}}})
    B.run.lines[1].status, B.run.lines[1].tries, B.run.lines[1].task = 'running', 1, t
    B.task = t
    B.finishTask(false, 'STUCK: regression fixture')
    B.runTick(p)
    assert(ended == 'task failed: home', 'failed trip did not end the turn: ' .. tostring(ended))
    assert(B.run.lines[2].status == 'notrun', 'dependent line still runnable')
    assert(not B.results[#B.results].ok and B.results[#B.results].msg:find('^NOT RUN'), 'skipped line not reported')
    -- success: the trip's line is done and the next one is up
    ended, B.turnActive = nil, true
    t = {line = 'home'}
    B.run = B.newRun({{'home', 'home', {}}, {'look', 'look', {}}})
    B.run.lines[1].status, B.run.lines[1].tries, B.run.lines[1].task = 'running', 1, t
    B.task = t
    B.finishTask(true, 'arrived')
    B.runTick(p)
    assert(not ended and B.run.lines[1].status == 'done' and B.run.cur == 2, 'successful trip did not advance')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: failed tasks stop dependent lines; successful tasks advance' or ('FAIL: ' .. tostring(err))
