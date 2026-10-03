-- Road tile classification (B.tileKind) from sprite names, and B.roadAt on whatever is loaded
-- under the player. Read-only: no movement, no keys.
local ok, err = pcall(function()
    assert(B.tileKind('blends_street_01_5') == 'road', 'asphalt')
    assert(B.tileKind('floors_exterior_street_01_12') == 'road', 'paving')
    assert(B.tileKind('street_trafficlines_01_3') == 'road', 'lines')
    assert(B.tileKind('blends_natural_01_7') == 'dirt', 'gravel (Sand 0-15)')
    assert(B.tileKind('blends_natural_01_70') == 'dirt', 'Dirt 64-79')
    assert(B.tileKind('blends_natural_01_20') == nil, 'grass is not road')
    assert(B.tileKind('blends_natural_01_100') == nil, 'clay is not road')
    assert(B.tileKind(nil) == nil, 'nil')
    -- roadAt answers for the player's own tile without erroring and caches the answer
    B.roadCache = {}
    local k = B.roadAt(p:getX(), p:getY())
    assert(k == nil or k == 'road' or k == 'dirt', 'roadAt kind')
    assert(B.roadCache[math.floor(p:getX()) * 100000 + math.floor(p:getY())] ~= nil, 'cached')
end)
B.roadCache = {}
R = ok and ('PASS road tiles (here: ' .. tostring(B.roadAt(p:getX(), p:getY())) .. ')') or ('FAIL ' .. tostring(err))
