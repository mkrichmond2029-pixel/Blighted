local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Projectile = require(ReplicatedStorage.Classes.Projectile)
local Types = require(ReplicatedStorage.Classes.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)

local InjectedDamageBonus = 8
local InjectedBuffDuration = 12
local ProjectileSpeed = 90
local ProjectileLifetime = 0.7
local ProjectileDamage = 5
local ProjectileOffset = CFrame.new(0, 1, -2)
local ProjectileHitboxSize = Vector3.new(2.5, 2.5, 5)

local InjectionProjectileTemplate = Instance.new("Part")
InjectionProjectileTemplate.Name = "ScriptInjection"
InjectionProjectileTemplate.Shape = Enum.PartType.Ball
InjectionProjectileTemplate.Size = Vector3.new(1, 1, 1)
InjectionProjectileTemplate.Material = Enum.Material.Neon
InjectionProjectileTemplate.BrickColor = BrickColor.new("Lime green")
InjectionProjectileTemplate.CanCollide = false
InjectionProjectileTemplate.CanQuery = false
InjectionProjectileTemplate.CanTouch = false
InjectionProjectileTemplate.CastShadow = false
InjectionProjectileTemplate.Anchored = true

local InjectionCollisionBox = Instance.new("Part")
InjectionCollisionBox.Name = "CollisionBox"
InjectionCollisionBox.Size = Vector3.new(1.5, 1.5, 3)
InjectionCollisionBox.Transparency = 1
InjectionCollisionBox.CanCollide = false
InjectionCollisionBox.CanQuery = false
InjectionCollisionBox.CanTouch = false
InjectionCollisionBox.Massless = true
InjectionCollisionBox.Parent = InjectionProjectileTemplate

local function ApplyInjectedBuff(self: Types.Ability, CharacterModel: Model)
    CharacterModel:SetAttribute("Injected", true)

    local Token = (CharacterModel:GetAttribute("InjectedToken") or 0) + 1
    CharacterModel:SetAttribute("InjectedToken", Token)

    self:AddConnection(task.delay(self.BuffDuration, function()
        if CharacterModel.Parent and CharacterModel:GetAttribute("InjectedToken") == Token then
            CharacterModel:SetAttribute("Injected", false)
        end
    end))
end

local function DefaultSlashBehaviour(self: Types.Ability)
    if RunService:IsServer() then
        local CharacterModel = self.OwnerProperties.Character
        local Damage = self.Damage

        if CharacterModel:GetAttribute("Injected") then
            Damage += self.InjectedDamageBonus
        end

        Sounds.PlaySound(self.UseSound, { Parent = self.OwnerProperties.HRP })

        task.delay(self.Delay, function()
            if not CharacterModel.Parent or self.OwnerProperties.Humanoid.Health <= 0 then
                return
            end

            Hitbox.New(self.Owner, {
                CFrameOffset = self.HitboxOffset,
                Size = self.HitboxSize,
                Time = self.Duration,
                Damage = Damage,
                Reason = "Slash Attack",
                ExecuteOnKill = true,
            })
        end)
    else
        self.OwnerProperties.TurnToMoveDirection:AddHeadPreventionFactor("Slash")
        self:AddConnection(task.delay(0.7, function()
            self.OwnerProperties.TurnToMoveDirection:RemoveHeadPreventionFactor("Slash")
        end))
    end
end

local function LaunchInjectionProjectile(self: Types.Ability)
    local RootPart = self.OwnerProperties.HRP
    local CharacterModel = self.OwnerProperties.Character
    if not RootPart or not RootPart.Parent then
        return
    end

    local Triggered = false
    local ProjectileInstance

    ProjectileInstance = Projectile.New({
        SourcePlayer = self.Owner,
        Model = self.ProjectileModel,
        StartingCFrame = RootPart.CFrame * self.ProjectileOffset,
        Speed = self.ProjectileSpeed,
        Lifetime = self.ProjectileLifetime,
        ThrowType = "Forward",
        DestroyOnCollision = true,
        HitboxSettings = {
            Size = self.ProjectileSize,
            Shape = Enum.PartType.Block,
            Damage = self.ProjectileDamage,
            HitMultiple = false,
            Reason = "Script Injection",
            Connections = {
                Hit = function(_Config, Humanoid: Humanoid)
                    if Triggered then
                        return
                    end

                    local TargetCharacter = Humanoid.Parent
                    if not TargetCharacter or not TargetCharacter:IsA("Model") then
                        return
                    end

                    local Role = TargetCharacter:FindFirstChild("Role")
                    if not Role or not Role:IsA("StringValue") or Role.Value ~= "Survivor" then
                        return
                    end

                    Triggered = true
                    self:ApplyInjectedBuff(CharacterModel)

                    if ProjectileInstance then
                        ProjectileInstance:Destroy()
                    end
                end,
            },
        },
    })
end

local function InjectBehaviour(self: Types.Ability)
    if RunService:IsServer() then
        LaunchInjectionProjectile(self)
    end
end

local C00lKidd: Types.Killer = Character.CreateKiller({
    Config = {
        Name = "C00lKidd",
        Quote = "Quote",
        Render = "rbxassetid://73281933925265",
        Price = -1,
        Origin = {
            TooltipText = "C00lkidd:)",
            Icon = "rbxassetid://118316894840539",
        },
        AnimationIDs = {
            HurtAnimation = "rbxassetid://86171516254413",
            IdleAnimation = "rbxassetid://95646233626111",
            WalkAnimation = "rbxassetid://115621394601470",
            RunAnimation = "rbxassetid://102981744469535",
        },
    },
    GameplayConfig = {
        Abilities = {
            Slash = Ability.New({
                Name = "Slash",
                InputName = "Slash",
                Cooldown = 2,
                Duration = 0.4,
                Damage = 20,
                RenderImage = "rbxassetid://11218451110",
                UseSound = "rbxassetid://12222200",
                UseAnimation = "rbxassetid://94664389390904",
                UICorner = true,
                Delay = 0.1,
                HitboxSize = Vector3.new(5, 6, 4.5),
                HitboxOffset = CFrame.new(0, 0, -2.5),
                InjectedDamageBonus = InjectedDamageBonus,
                Behaviour = DefaultSlashBehaviour,
            }),
            Inject = Ability.New({
                Name = "Inject",
                InputName = "FourthAbility",
                Cooldown = 20,
                Duration = 0.5,
                UseSound = "rbxassetid://0",
                UseAnimation = "rbxassetid://0",
                ProjectileModel = InjectionProjectileTemplate,
                ProjectileSpeed = ProjectileSpeed,
                ProjectileLifetime = ProjectileLifetime,
                ProjectileSize = ProjectileHitboxSize,
                ProjectileOffset = ProjectileOffset,
                ProjectileDamage = ProjectileDamage,
                BuffDuration = InjectedBuffDuration,
                ApplyInjectedBuff = ApplyInjectedBuff,
                Behaviour = InjectBehaviour,
            }),
        },
    },
})

local NameLabel = '<font color="rgb(0, 255, 0)">' .. C00lKidd.Config.Name .. "</font>"
C00lKidd.Config.Description = {
    { Type = "Separator", Text = "GENERAL INFO" },
    { Type = "Header", Text = C00lKidd.Config.Name:upper() },
    { Type = "Quote", Text = '"' .. C00lKidd.Config.Quote .. '"' },
    { Type = "Text", Text = "TODO: write C00lKidd's lore paragraph here." },
    { Type = "Separator", Text = "ABILITIES" },
    { Type = "Header", Text = "SLASH" },
    {
        Type = "Text",
        Text = NameLabel .. " uses the standard Blighted Slash ability. Injected targets make his M1 attacks deal " .. tostring(InjectedDamageBonus) .. " additional damage.",
    },
    { Type = "Header", Text = "INJECT" },
    {
        Type = "Text",
        Text = NameLabel .. " throws a Script Injection projectile. Hitting a Survivor buffs his slashes for " .. tostring(InjectedBuffDuration) .. " seconds.",
    },
}

return C00lKidd
