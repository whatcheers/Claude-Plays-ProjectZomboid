-- Live regression at the neighboring kitchen, where the frame precedes the window.
local sq = getCell():getGridSquare(8177, 11673, 0)
local window, frame
for i = 0, sq:getObjects():size() - 1 do
    local o = sq:getObjects():get(i)
    if instanceof(o, 'IsoWindow') then window = o end
    if instanceof(o, 'IsoWindowFrame') then frame = o end
end
assert(window and frame, 'fixture needs both a window and frame at 8177,11673')
local oldAdd, oldWalk = ISTimedActionQueue.add, luautils.walkAdjWindowOrDoor
local actions = {}
local ok, err = pcall(function()
    ISTimedActionQueue.add = function(action) actions[#actions + 1] = action end
    luautils.walkAdjWindowOrDoor = function() return true end
    local opposite = window:IsOpen() and 'close' or 'open'
    B.cmds.window(p, {'8177', '11673', opposite})
    assert(#actions == 1 and actions[1].object == window, 'open/close targeted frame instead of working window')
    actions = {}
    B.cmds.window(p, {'8177', '11673', 'climb'})
    assert(#actions == 1 and actions[1].item == window, 'climb bypassed working window via frame')
    actions = {}
    B.cmds.window(p, {'8177', '11673', window:IsOpen() and 'open' or 'close'})
    assert(#actions == 0, 'already-correct window was toggled')
end)
ISTimedActionQueue.add, luautils.walkAdjWindowOrDoor = oldAdd, oldWalk
R = ok and 'PASS: real window selected for actions; open/close are idempotent' or ('FAIL: ' .. tostring(err))
