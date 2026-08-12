-- Shared server-side cache mapping character Model → initialized module table.
-- Written by ServerCharacterManager, read by CommonFunctions and Hitbox.
-- Has no dependencies to avoid cyclic requires.
-- next add hitbox check for if the hitbox is too far from humanoid where it orginiates is too far to kick for hitbox hacks
-- exclude projectile class so doesnt kick for no check
local CharModuleCache = {}

function CharModuleCache.Set(Char, module)
    CharModuleCache[Char] = module
    Char.AncestryChanged:Connect(function()
        if not Char.Parent then
            CharModuleCache[Char] = nil
        end
    end)
end

function CharModuleCache.Get(Char)
    return CharModuleCache[Char]
end

return CharModuleCache
