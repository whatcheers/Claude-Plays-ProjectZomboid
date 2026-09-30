-- `go x y` / `travel x y` with no floor used your current one, so from upstairs a target
-- outdoors failed with PATH FAILED. The default floor is now the highest one at or below yours
-- with a floor at x,y. Needs the Rosewood houses around 8172-8177,11635-11645 loaded.
local ok, err = pcall(function()
    assert(B.floorFor(8172, 11645, 1) == 0, 'outdoors from upstairs should go to the ground: ' .. tostring(B.floorFor(8172, 11645, 1)))
    assert(B.floorFor(8177, 11635, 1) == 1, 'an upstairs room from upstairs should stay upstairs')
    assert(B.floorFor(8172, 11645, 0) == 0, 'ground to ground stays on the ground')
end)
R = ok and 'PASS: no floor given means the nearest floor at or below you that exists there' or ('FAIL: ' .. tostring(err))
