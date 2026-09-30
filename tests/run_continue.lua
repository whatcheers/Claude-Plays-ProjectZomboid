-- `continue` keeps the unfinished run, restarts the interrupted line and appends new lines.
-- startTurn resets a lot of turn state; save and restore all of it
local keys = {'run', 'results', 'reflexLog', 'upkeepTried', 'turnActive', 'setPaused', 'writeFile',
    'dumpState', 'turn', 'fight', 'task', 'bash', 'fleeing', 'setSpeedRaw', 'turnHealth', 'turnBites',
    'turnSeen', 'turnClose', 'turnDeadline', 'turnStartReal'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local ok, err = pcall(function()
    B.setPaused, B.writeFile, B.dumpState = function() end, function() end, function() end
    B.setSpeedRaw = function() end
    B.run = B.newRun({{'go 1 2', 'go', {'1', '2'}}, {'look', 'look', {}}})
    B.run.lines[1].status, B.run.lines[1].tries = 'running', 1
    B.startTurn(12345, {'continue', 'say hi'})
    local r = B.run
    assert(r and r.cur == 1 and r.lines[1].cut and r.lines[1].tries == 0, 'interrupted line not marked cut for a re-run')
    assert(#r.lines == 3 and r.lines[3].text == 'say hi', 'new line not appended')
    B.startTurn(12346, {'look'})
    assert(B.run == nil, 'a fresh instant-only turn should drop the old run')
end)
for _, k in ipairs(keys) do B[k] = saved[k] end
B.turnActive = false
R = ok and 'PASS: continue resumes at the interrupted line and appends new ones' or ('FAIL: ' .. tostring(err))
