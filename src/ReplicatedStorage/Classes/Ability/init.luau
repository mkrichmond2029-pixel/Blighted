local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Types = require(script.Parent.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Network = require(ReplicatedStorage.Modules.Network)
local Sounds = require(ReplicatedStorage.Modules.Sounds)
local Janitor = require(ReplicatedStorage.Packages.Janitor)
local Signal = require(ReplicatedStorage.Utils.Signal)

local AbilityType = {}
AbilityType.__index = AbilityType

function AbilityType.GetDefaultSettings(): Types.Ability
    return setmetatable({
        Name = "Ability",
        RenderImage = "rbxassetid://9759886280",
        UICorner = true,
        Passive = false,

        ExtraInit = nil,
        OnRemove = nil,

        StunnableConnections = {},

        InputName = "FirstAbility",
        Behaviour = nil,

        UseAnimation = "",
        UseAnimationTrack = nil,
        PlayUseAnimationOnUse = true,
        UseAnimationTransitionTime = 0.1,

        Cooldown = 5,
        CooldownTimer = 0,
        OnCooldown = false,
        AutomaticCooldown = true,

        Duration = 0.4,

        DisableOtherAbilitiesOnPerform = true,
        DisableSlashOnPerform = true,

        UsesLeft = 1,

        UseSettings = {
            Limited = false,
            InitialUses = 5,
        },

        Signals = {
            ChargesChanged = Signal.new(),
            Used = Signal.new(),
            CooldownSet = Signal.new(),
        },
    }, AbilityType)
end

function AbilityType.GetDefaultPassiveSettings()
    return setmetatable(Utils.Type.DeepTableOverwrite({
        Passive = true,

        Init = function(self: Types.Ability, charModule: Types.Killer | Types.Survivor, plr: Player)
            self.Owner = plr
            self.CharModule = charModule
            self.UsesLeft = self.UseSettings.InitialUses

            self.Janitor = Janitor.new()
            self.Janitor:LinkToInstance(self.Owner.Character)

            self.Janitor:Add(function()
                self:Destroy()
            end, true)

            if RunService:IsServer() then
                Utils.Misc.Print("Initting "..self.Name.." ability for "..plr.Name)

                self.OwnerProperties = {
                    Character = self.Owner.Character,
                    Humanoid = self.Owner.Character:FindFirstChildWhichIsA("Humanoid"),
                    HRP = Utils.Character.GetRootPart(self.Owner),
                }

                if self.ExtraInit then
                    self:ExtraInit()
                end

                return
            end

            self.OwnerProperties = {
                Character = self.Owner.Character,
                Humanoid = self.Owner.Character:FindFirstChildWhichIsA("Humanoid"),
                HRP = Utils.Character.GetRootPart(self.Owner),
                InputManager = require(self.Owner.PlayerScripts.InputManager),
                FOVManager = require(self.Owner.Character.PlayerAttributeScripts.FOVManager),
                EffectManager = require(self.Owner.Character.PlayerAttributeScripts.EffectManager),
                EmoteManager = require(self.Owner.Character.Miscellaneous.EmoteManager),
                TurnToMoveDirection = require(self.Owner.PlayerScripts.Miscellaneous.TurnToMoveDirection),
            }

            if self.ExtraInit then
                self:ExtraInit()
            end
        end,

        ReloadAnimation = function(self: Types.Ability, id: string)
            warn("Ability \""..self.Name.."\" is a Passive, so no use animation can be assigned to it!")
        end,

        PlayUseAnimation = function(self: Types.Ability)
            warn("Ability \""..self.Name.."\" is a Passive, so no use animation is available!")
        end,

        StopUseAnimation = function(self: Types.Ability)
            warn("Ability \""..self.Name.."\" is a Passive, so no use animation is available!")
        end,

        AttemptUse = function(self: Types.Ability)
            warn("Ability \""..self.Name.."\" is a Passive, so it can't be used through input!")
        end,

        ChangeAbilityCharges = function(self: Types.Ability, _Type: "Add" | "Set" | "Take", _amount: number)
            warn("Ability \""..self.Name.."\" is a Passive, so charges aren't applied!")
        end,

        PlayUseAnimationOnUse = false,
        Cooldown = 0,

        CanUse = function(_self: Types.Ability): boolean
            return true
        end,
        UseConditions = function(_self: Types.Ability): boolean
            return true
        end,

        Duration = 0,
        DisableOtherAbilitiesOnPerform = false,
        DisableSlashOnPerform = false,
        Signals = {},
    }, AbilityType.GetDefaultSettings()), AbilityType)
end

function AbilityType.New(Props: Types.Ability): Types.Ability
    Props = Props or {}

    return Utils.Type.DeepTableOverwrite(
        Props.Passive and
            AbilityType.GetDefaultPassiveSettings() or
            AbilityType.GetDefaultSettings(),

        Props
    )
end

function AbilityType:Init(charModule: Types.Killer | Types.Survivor, plr: Player)
    self.Owner = plr
    self.CharModule = charModule
    self.UsesLeft = self.UseSettings.InitialUses

    self.Janitor = Janitor.new()
    self.Janitor:LinkToInstance(self.Owner.Character)

    self.Janitor:Add(function()
        self:Destroy()
    end, true)

    do
        local Effects = self.Owner.Character:FindFirstChild("Effects")
        if Effects then
            self:AddConnection(Effects.ChildAdded:Connect(function(newChild: Instance)
                if newChild.Name ~= "Stunned" then
                    return
                end

                for _, Connection in self.StunnableConnections do
                    if typeof(Connection) == "thread" then
                        if coroutine.running() ~= Connection then
                            task.cancel(Connection)
                        end
                    else
                        Connection:Disconnect()
                    end
                end
            end))
        end
    end

    if RunService:IsServer() then
        Utils.Misc.Print("Initting "..self.Name.." ability for "..self.Owner.Name)

        self.OwnerProperties = {
            Character = self.Owner.Character,
            Humanoid = self.Owner.Character:FindFirstChildWhichIsA("Humanoid"),
            HRP = Utils.Character.GetRootPart(self.Owner),
        }

        self:AddConnection(Network:SetConnection("UsePlayerAbility", "REMOTE_EVENT", function(player: Player, abilityName: string)
            if player == self.Owner and abilityName == self.Name and self:CanUse() then
                task.defer(function()
                    if self.CharModule.Config.Voicelines and self.CharModule.Config.Voicelines[self.Name] then
                        Sounds.PlayVoiceline(self.Owner.Character, self.CharModule.Config.Voicelines[self.Name])
                    end
                end)

                if self.AutomaticCooldown then
                    self:SetOnCooldown()
                end

                if self.UseSettings.Limited then
                    task.spawn(function()
                        self:ChangeAbilityCharges("Set", self.UsesLeft - 1)
                    end)
                end

                task.spawn(function()
                    self.Signals.Used:Fire()
                end)
                Network:FireClientConnection(self.Owner, "UsePlayerAbility", "REMOTE_EVENT", self.Name)

                task.spawn(function()
                    if self.Behaviour then
                        self:Behaviour()
                    end
                end)
            end
        end))

        if self.ExtraInit then
            self:ExtraInit()
        end

        return
    end

    self.OwnerProperties = {
        Character = self.Owner.Character,
        Humanoid = self.Owner.Character:FindFirstChildWhichIsA("Humanoid"),
        HRP = Utils.Character.GetRootPart(self.Owner),
        InputManager = require(self.Owner.PlayerScripts.InputManager),
        FOVManager = require(self.Owner.Character.PlayerAttributeScripts.FOVManager),
        EffectManager = require(self.Owner.Character.PlayerAttributeScripts.EffectManager),
        EmoteManager = require(self.Owner.Character.Miscellaneous.EmoteManager),
        TurnToMoveDirection = require(self.Owner.PlayerScripts.Miscellaneous.TurnToMoveDirection),
        AnimationManager = require(self.Owner.Character.AnimationManager),
    }

    if #self.UseAnimation > 0 then
        pcall(function()
            local AnimName = self.Name:gsub(" ", "").."UseAnim"
            charModule.GameplayConfig.Cache.Animations[AnimName] = Utils.Character.LoadAnimationFromID(self.Owner.Character, self.UseAnimation)
            self.UseAnimationTrack = charModule.GameplayConfig.Cache.Animations[AnimName]

            if self.UseAnimationTrack then
                self.UseAnimationTrack.Priority = Enum.AnimationPriority.Action
                self.UseAnimationTrack.TimePosition = 0
                self.UseAnimationTrack.Looped = false
            end
        end)
    end

    do
        local InputAction = self.Owner.PlayerScripts.InputManager.InputActions.Default:FindFirstChild(self.InputName)
        if InputAction then
            self:AddConnection(InputAction.Pressed:Connect(function()
                self:AttemptUse()
            end))
        end
    end

    self:AddConnection(Network:SetConnection("UsePlayerAbility", "REMOTE_EVENT", function(abilityName: string)
        if abilityName == self.Name then
            if self.DisableOtherAbilitiesOnPerform then
                self:DisableAllAbilities()
            end

            if self.AutomaticCooldown then
                self:SetOnCooldown()
            end

            task.defer(function()
                if self.PlayUseAnimationOnUse then
                    self:PlayUseAnimation()
                end
            end)

            task.spawn(function()
                self.Signals.Used:Fire()
            end)

            if self.Behaviour then
                self:Behaviour()
            end
        end
    end))

    self:AddConnection(Network:SetConnection("ChangeAbilityCharges", "REMOTE_EVENT", function(abilityName: string, Type: "Set" | "Add" | "Take", amount: number)
        if abilityName == self.Name then
            self:ChangeAbilityCharges(Type, amount)
        end
    end))

    if self.ExtraInit then
        self:ExtraInit()
    end
end

function AbilityType:ReloadAnimation(id: string)
    local track = Utils.Character.LoadAnimationFromID(self.Owner.Character, id)
    local AnimName = self.Name:gsub(" ", "").."UseAnim"
    self.CharModule.GameplayConfig.Cache.Animations[AnimName] = track
    self.UseAnimationTrack = track

    if self.UseAnimationTrack then
        self.UseAnimationTrack.Priority = Enum.AnimationPriority.Action
        self.UseAnimationTrack.TimePosition = 0
        self.UseAnimationTrack.Looped = false
    end
end

function AbilityType:PlayUseAnimation()
    if not self.UseAnimationTrack then
        return
    end

    self.UseAnimationTrack.Priority = Enum.AnimationPriority.Action
    self.UseAnimationTrack.TimePosition = 0
    self.UseAnimationTrack.Looped = false
    self.UseAnimationTrack:Play(self.UseAnimationTransitionTime)

    self.OwnerProperties.TurnToMoveDirection:AddHeadPreventionFactor(self.Name)
end

function AbilityType:StopUseAnimation(transitionTime: number?)
    transitionTime = transitionTime or self.UseAnimationTransitionTime
    if not self.UseAnimationTrack then
        return
    end

    if self.UseAnimationTrack.IsPlaying then
        self.UseAnimationTrack:Stop(transitionTime)
    end

    if self.OwnerProperties and self.OwnerProperties.TurnToMoveDirection then
        self.OwnerProperties.TurnToMoveDirection:RemoveHeadPreventionFactor(self.Name)
    end
end

function AbilityType:Destroy()
    if self.OnRemove then
        self:OnRemove()
    end

    for _, signal in self.Signals do
        signal:DisconnectAll()
    end

    self.CooldownTimer = 0
    self.OnCooldown = false
end

function AbilityType:AttemptUse()
    if RunService:IsServer() then
        return
    end

    if self:CanUse() then
        Network:FireServerConnection("UsePlayerAbility", "REMOTE_EVENT", self.Name)
    end
end

function AbilityType:ChangeAbilityCharges(Type: "Add" | "Set" | "Take", amount: number)
    if Type == "Set" then
        self.UsesLeft = amount
    elseif Type == "Add" then
        self.UsesLeft += amount
    elseif Type == "Take" then
        self.UsesLeft -= amount
    end

    self.Signals.ChargesChanged:Fire(amount)
    if RunService:IsServer() then
        Network:FireClientConnection(self.Owner, "ChangeAbilityCharges", "REMOTE_EVENT", self.Name, Type, amount)
    end
end

function AbilityType:DisableAllAbilities(Duration: number?, DisableSlash: boolean?)
    if RunService:IsServer() then
        return
    end

    Duration = Duration or self.Duration
    if DisableSlash == nil then
        DisableSlash = self.DisableSlashOnPerform
    end
    for _, input in self.Owner.PlayerScripts.InputManager.InputActions.Default:GetChildren() do
        if input.Name:lower():find("ability") or (input.Name:lower():find("slash") and DisableSlash) then
            input.Enabled = false
        end
    end
    if Duration then
        self:AddConnection(task.delay(Duration, function()
            self:EnableAllAbilities()
        end))
    end
end

function AbilityType:EnableAllAbilities()
    for _, input in self.Owner.PlayerScripts.InputManager.InputActions.Default:GetChildren() do
        if input.Name:lower():find("ability") or input.Name:lower():find("slash") then
            input.Enabled = true
        end
    end
end

function AbilityType:SetOnCooldown(duration: number?)
    if not workspace:GetAttribute("CooldownsEnabled") then
        return
    end

    duration = duration or self.Cooldown

    if self.OnCooldown then
        self.CooldownTimer = duration
        return
    end

    self.OnCooldown = true
    self.CooldownTimer = duration

    if RunService:IsServer() then
        self:AddConnection(task.delay(duration, function()
            self.CooldownTimer = 0
            self.OnCooldown = false
        end))
    else
        task.spawn(function()
            while self.CooldownTimer > 0 do
                local WaitAmount = task.wait(0.1)
                WaitAmount = math.floor(WaitAmount * 10) / 10
                self.CooldownTimer -= WaitAmount
            end
            self.CooldownTimer = 0
            self.OnCooldown = false
        end)
    end

    self.Signals.CooldownSet:Fire(duration)
end

function AbilityType:AddConnection<T>(Connection: T & (RBXScriptConnection | thread)): T & (RBXScriptConnection | thread)
    self.Janitor:Add(Connection,
        if typeof(Connection) == "thread" then
            true
        else
            "Disconnect"
    )

    return Connection
end

function AbilityType:AddStunnableConnection<T>(Connection: T & (RBXScriptConnection | thread)): T & (RBXScriptConnection | thread)
    self:AddConnection(Connection)
    table.insert(self.StunnableConnections, Connection)

    return Connection
end

function AbilityType:CanUse(): boolean
    local EnoughUses = true
    if workspace:GetAttribute("ChargesEnabled") and self.UseSettings.Limited then
        EnoughUses = self.UsesLeft > 0
    end

    local OnCooldown = false
    if workspace:GetAttribute("CooldownsEnabled") and self.OnCooldown then
        OnCooldown = true
    end

    local EffectPrevention = false
    if RunService:IsServer() then
        if self.Owner.Character.Effects:FindFirstChild("Stunned") or self.Owner.Character.Effects:FindFirstChild("Helpless") then
            EffectPrevention = true
        end
    else
        if self.OwnerProperties.EffectManager.Effects["Stunned"] or self.OwnerProperties.EffectManager.Effects["Helpless"] then
            EffectPrevention = true
        end
    end

    local Emoting
    if RunService:IsServer() then
        Emoting = self.OwnerProperties.Character:GetAttribute("Emoting") == true
    else
        Emoting = self.OwnerProperties.EmoteManager.CurrentlyPlayingEmote ~= nil
    end

    return EnoughUses
    and self.OwnerProperties.Humanoid.Health > 0
    and not self.OwnerProperties.HRP.Anchored
    and not self.Owner.Character:GetAttribute("Executing")
    and not Emoting
    and not EffectPrevention
    and not OnCooldown
    and self:UseConditions()
end

function AbilityType:UseConditions(): boolean
    return true
end

return AbilityType
