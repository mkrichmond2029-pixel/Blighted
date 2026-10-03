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

-- Passive #1 Configuration
local CorruptionMaxStacks = 3
local CorruptionWeaknessBase = 0.05 -- 5%
local CorruptionWeaknessPerStack = 0.05 -- 5% per stack (so 3 stacks = 15%)
local CorruptionDuration = 15

-- Passive #2 Configuration
local FollowUpTimeWindow = 0.8
local FollowUpDamage = 8
local FollowUpBurningDamage = 7
local FollowUpSlownessHitDuration = 3
local FollowUpSlownessHitLevel = 2
local FollowUpSlownessMissDuration = 2
local FollowUpSlownessMissLevel = 3
local FollowUpHitboxSize = Vector3.new(2, 2, 3.5) -- Skinny hitbox
local FollowUpHitboxOffset = CFrame.new(0, 0, -2)

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

-- Passive #1: Apply corruption stacking
local function ApplyCorruption(TargetCharacter: Model)
	local CurrentStacks = (TargetCharacter:GetAttribute("CorruptionStacks") or 0)
	local NewStacks = math.min(CurrentStacks + 1, CorruptionMaxStacks)
	
	TargetCharacter:SetAttribute("CorruptionStacks", NewStacks)
	TargetCharacter:SetAttribute("CorruptionActive", true)
	
	-- Reset corruption timer
	local Token = (TargetCharacter:GetAttribute("CorruptionToken") or 0) + 1
	TargetCharacter:SetAttribute("CorruptionToken", Token)
	
	task.delay(CorruptionDuration, function()
		if TargetCharacter.Parent and TargetCharacter:GetAttribute("CorruptionToken") == Token then
			TargetCharacter:SetAttribute("CorruptionStacks", 0)
			TargetCharacter:SetAttribute("CorruptionActive", false)
		end
	end)
end

-- Calculate weakness from corruption
local function GetCorruptionWeakness(TargetCharacter: Model): number
	if not TargetCharacter:GetAttribute("CorruptionActive") then
		return 1.0
	end
	
	local Stacks = TargetCharacter:GetAttribute("CorruptionStacks") or 0
	local WeaknessMultiplier = CorruptionWeaknessBase + (CorruptionWeaknessPerStack * (Stacks - 1))
	return 1.0 + WeaknessMultiplier
end

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

-- Passive #2: Check if follow-up is available and execute
local function ExecuteFollowUp(self: Types.Ability, CharacterModel: Model)
	if RunService:IsServer() then
		local LastM1Time = CharacterModel:GetAttribute("LastM1Time") or 0
		local CurrentTime = tick()
		
		-- Check if M1 was used within the time window
		if CurrentTime - LastM1Time <= FollowUpTimeWindow then
			local FollowUpUsed = CharacterModel:GetAttribute("FollowUpUsed") or false
			
			if not FollowUpUsed then
				CharacterModel:SetAttribute("FollowUpUsed", true)
				
				-- Execute lunge hitbox
				task.delay(0.2, function() -- Small delay for lunge animation
					if not CharacterModel.Parent or self.OwnerProperties.Humanoid.Health <= 0 then
						return
					end
					
					local HitOccurred = false
					
					Hitbox.New(self.Owner, {
						CFrameOffset = FollowUpHitboxOffset,
						Size = FollowUpHitboxSize,
						Time = 0.3,
						Damage = FollowUpDamage,
						Reason = "Sword Follow-up",
						ExecuteOnKill = true,
						OnHit = function(Hit)
							HitOccurred = true
							local TargetCharacter = Hit.Parent
							if TargetCharacter and TargetCharacter:FindFirstChild("Humanoid") then
								-- Apply slowness on hit
								TargetCharacter:SetAttribute("Slowed", true)
								TargetCharacter:SetAttribute("SlowLevel", FollowUpSlownessHitLevel)
								
								task.delay(FollowUpSlownessHitDuration, function()
									if TargetCharacter.Parent then
										TargetCharacter:SetAttribute("Slowed", false)
									end
								end)
								
								-- Apply burning damage
								task.delay(0.5, function()
									if TargetCharacter.Parent and TargetCharacter:FindFirstChild("Humanoid") then
										TargetCharacter.Humanoid:TakeDamage(FollowUpBurningDamage)
									end
								end)
							end
						end,
					})
				end)
			end
		else
			-- Miss case: apply slowness even without hit
			CharacterModel:SetAttribute("Slowed", true)
			CharacterModel:SetAttribute("SlowLevel", FollowUpSlownessMissLevel)
			
			task.delay(FollowUpSlownessMissDuration, function()
				if CharacterModel.Parent then
					CharacterModel:SetAttribute("Slowed", false)
				end
			end)
		end
	end
end

local function DefaultSlashBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		local CharacterModel = self.OwnerProperties.Character
		local Damage = self.Damage

		if CharacterModel:GetAttribute("Injected") then
			Damage += self.InjectedDamageBonus
			-- Remove M1 buff after single use
			CharacterModel:SetAttribute("Injected", false)
		end

		-- Track M1 time for Passive #2
		CharacterModel:SetAttribute("LastM1Time", tick())
		CharacterModel:SetAttribute("FollowUpUsed", false)

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
				OnHit = function(Hit)
					local TargetCharacter = Hit.Parent
					if TargetCharacter and TargetCharacter:FindFirstChild("Humanoid") then
						-- Apply corruption
						ApplyCorruption(TargetCharacter)
						
						-- Apply weakness damage based on corruption stacks
						local WeaknessMultiplier = GetCorruptionWeakness(TargetCharacter)
						local AdditionalDamage = Damage * (WeaknessMultiplier - 1.0)
						if AdditionalDamage > 0 then
							TargetCharacter.Humanoid:TakeDamage(AdditionalDamage)
						end
					end
				end,
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
		-- Windup delay before launching projectile
		task.delay(self.WindupDelay, function()
			if self.OwnerProperties.Character.Parent and self.OwnerProperties.Humanoid.Health > 0 then
				LaunchInjectionProjectile(self)
				-- Trigger follow-up check
				ExecuteFollowUp(self, self.OwnerProperties.Character)
			end
		end)
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
				Duration = 2,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://112246584283940",
				ProjectileModel = InjectionProjectileTemplate,
				ProjectileSpeed = ProjectileSpeed,
				ProjectileLifetime = ProjectileLifetime,
				ProjectileSize = ProjectileHitboxSize,
				ProjectileOffset = ProjectileOffset,
				ProjectileDamage = ProjectileDamage,
				BuffDuration = InjectedBuffDuration,
				WindupDelay = 0.3, -- Windup before projectile launch
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
		Text = NameLabel .. " throws a Script Injection projectile with a " .. tostring(0.3) .. "s windup. Hitting a Survivor buffs his slashes for " .. tostring(InjectedBuffDuration) .. " seconds.",
	},
	{ Type = "Separator", Text = "PASSIVES" },
	{ Type = "Header", Text = "SCRIPT INJECTION" },
	{
		Type = "Text",
		Text = "Victims hit by " .. NameLabel .. "'s slashes gain corruption stacks (max " .. tostring(CorruptionMaxStacks) .. "). Each stack grants " .. tostring(math.floor(CorruptionWeaknessBase * 100)) .. "% weakness, scaling up to " .. tostring(math.floor(CorruptionWeaknessBase * 100 * CorruptionMaxStacks)) .. "%. The M1 buff is removed after a single M1 but corruption persists.",
	},
	{ Type = "Header", Text = "SWORD FOLLOW-UP" },
	{
		Type = "Text",
		Text = "Within " .. tostring(FollowUpTimeWindow) .. "s after an M1, using Inject triggers a lunge with " .. tostring(FollowUpDamage) .. " damage + " .. tostring(FollowUpBurningDamage) .. " burning damage. On hit: Slowness " .. tostring(FollowUpSlownessHitLevel) .. " for " .. tostring(FollowUpSlownessHitDuration) .. "s. On miss: Slowness " .. tostring(FollowUpSlownessMissLevel) .. " for " .. tostring(FollowUpSlownessMissDuration) .. "s.",
	},
}

return C00lKidd
