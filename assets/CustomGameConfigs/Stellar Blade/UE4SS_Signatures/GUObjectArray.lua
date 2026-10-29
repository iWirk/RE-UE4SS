-- The RIP-relative store addresses the start of FUObjectArray.
function Register()
    return "89 05 ?? ?? ?? ?? 85 DB 7F 36 4C 8D 05 ?? ?? ?? ??"
end

function OnMatchFound(MatchAddress)
    return MatchAddress + 6 + DerefToInt32(MatchAddress + 2)
end
