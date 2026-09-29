-- Dressing changes must not turn an existing bite into a newly counted bite.
local exposed, second = false, false
local oldBite = {bitten = function() return exposed end, getBiteTime = function() return 65 end}
local otherPart = {bitten = function() return second end, getBiteTime = function() return second and 80 or 0 end}
local parts = {size = function() return 2 end, get = function(_, i) return i == 0 and oldBite or otherPart end}
local fixture = {getBodyDamage = function() return {getBodyParts = function() return parts end} end}
local ok, err = pcall(function()
    assert(B.biteCount(fixture) == 1, 'covered bite was hidden from baseline')
    exposed = true
    assert(B.biteCount(fixture) == 1, 'uncovering old bite changed count')
    exposed, second = false, true
    assert(B.biteCount(fixture) == 2, 'a genuinely additional bite was missed')
end)
R = ok and 'PASS: covered bites stay counted; new bites still increase count' or ('FAIL: ' .. tostring(err))
