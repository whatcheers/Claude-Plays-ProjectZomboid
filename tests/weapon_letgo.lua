-- A weapon dropped on purpose once, then held again, must be picked back up after a later fall.
-- Seen 2026-09-30: `drop` marked the axe in B.letGo forever, so every later fall lost it.
-- Needs the survivor holding a melee weapon; it's back in hand afterwards.
local keys = {'heldWeapon', 'letGo', 'reflexLog', 'run', 'tickN'}
local saved = {}
for _, k in ipairs(keys) do saved[k] = B[k] end
local w = p:getPrimaryHandItem()
local ok, err = pcall(function()
    assert(w and instanceof(w, 'HandWeapon'), 'hold a melee weapon first')
    B.reflexLog, B.run, B.tickN = {}, nil, 1
    B.letGo = {[w:getID()] = true}       -- it was dropped on purpose once...
    B.heldWeapon = nil
    B.recoverWeapon(p)                   -- ...and is in hand again now
    p:dropHandItems()                    -- then a fall drops it
    B.recoverWeapon(p)
    local log = table.concat(B.reflexLog, '; ')
    assert(log:find('picking it back up', 1, true), 'fell weapon not recovered: [' .. log .. ']')
    ISTimedActionQueue.clear(p)
    -- a deliberate `drop` of the weapon in hand: its mark must survive the ticks before the drop lands
    if w:getWorldItem() then
        local wo = w:getWorldItem(); wo:getSquare():transmitRemoveItemFromSquare(wo); w:setWorldItem(nil); p:getInventory():AddItem(w)
    end
    p:setPrimaryHandItem(w)
    B.heldWeapon = w
    B.letGo = {[w:getID()] = true}
    B.recoverWeapon(p)
    assert(B.letGo[w:getID()], 'a drop mark was cleared while the weapon was still in hand')
end)
ISTimedActionQueue.clear(p)
-- put the weapon straight back in hand so the test leaves the survivor as it found it
if w and w:getWorldItem() then
    local wo = w:getWorldItem()
    wo:getSquare():transmitRemoveItemFromSquare(wo)
    w:setWorldItem(nil)
    p:getInventory():AddItem(w)
end
if w and p:getPrimaryHandItem() ~= w then
    p:setPrimaryHandItem(w)
    if w:isTwoHandWeapon() then p:setSecondaryHandItem(w) end
end
for _, k in ipairs(keys) do B[k] = saved[k] end
R = ok and 'PASS: a weapon held again after a deliberate drop is recovered after a fall' or ('FAIL: ' .. tostring(err))
