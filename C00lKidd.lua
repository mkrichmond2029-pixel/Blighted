local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Projectile = require(ReplicatedStorage.Classes.Projectile)
local Types = require(ReplicatedStorage.Classes.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)

-- ============================================================
-- CONFIG (tweak these freely)
-- ============================================================
local InjectedDamageBonus = 8
local InjectedBuffDuration = 12

local ProjectileSpeed = 90
local ProjectileLifetime = 0.7
local ProjectileDamage = 5
local ProjectileOffset = CFrame.new(0, 1, -2)
local ProjectileHitboxSize = Vector3.new(2.5, 2.5, 5)

local SlashWindupDuration = 0.01
local InjectWindupDuration = 0.5

-- Passive #1
local CorruptionMaxStacks = 3
local CorruptionWeaknessBase = 0.05
local CorruptionWeaknessPerStack = 0.05
local CorruptionDuration = 15

-- Passive #2 (M1 → Follow-up auto-trigger)
local FollowUpAutoDelay = 0.35              -- Delay before auto-triggering follow-up after M1
local FollowUpSprintMultiplier = 2.5        -- How much to multiply sprint speed during lunge
local FollowUpDuration = 0.5                -- How long the lunge lasts
local FollowUpDamage = 8
local FollowUpBurningDamage = 7
local FollowUpSlownessHitDuration = 3
local FollowUpSlownessHitLevel = 2
local FollowUpSlownessMissDuration = 2
local FollowUpSlownessMissLevel = 3
local FollowUpHitboxSize = Vector3.new(2, 2, 3.5)
local FollowUpHitboxOffset = CFrame.new(0, 0, -2)

-- ============================================================
-- PROJECTILE MODEL (EASIEST PLACE TO SWAP)
-- ============================================================
-- Just replace the entire contents of this function with any Model you want.
-- Keep the name "ScriptInjection" if you like, or change it.
local function CreateInjectionProjectileTemplate(): Model
	local model = Instance.new("Model")
	model.Name = "ScriptInjection"

	local ball = Instance.new("Part")
	ball.Name = "Ball"
	ball.Shape = Enum.PartType.Ball
	ball.Size = Vector3.new(1, 1, 1)
	ball.Material = Enum.Material.Neon
	ball.BrickColor = BrickColor.new("Lime green")
	ball.CanCollide = false
	ball.CanQuery = false
	ball.CanTouch = false
	ball.CastShadow = false
	ball.Anchored = true
	ball.Parent = model

	-- Optional collision / visual box (many systems use this)
	local collisionBox = Instance.new("Part")
	collisionBox.Name = "CollisionBox"
	collisionBox.Size = Vector3.new(1.5, 1.5, 3)
	collisionBox.Transparency = 1
	collisionBox.CanCollide = false
	collisionBox.CanQuery = false
	collisionBox.CanTouch = false
	collisionBox.Massless = true
	collisionBox.Parent = model

	model.PrimaryPart = ball
	return model
end

-- ============================================================
-- HELPERS
-- ============================================================
local function ApplyCorruption(TargetCharacter: Model)
	local CurrentStacks = (TargetCharacter:GetAttribute("CorruptionStacks") or 0)
	local NewStacks = math.min(CurrentStacks + 1, CorruptionMaxStacks)
	TargetCharacter:SetAttribute("CorruptionStacks", NewStacks)
	TargetCharacter:SetAttribute("CorruptionActive", true)

	local Token = (TargetCharacter:GetAttribute("CorruptionToken") or 0) + 1
	TargetCharacter:SetAttribute("CorruptionToken", Token)

	task.delay(CorruptionDuration, function()
		if TargetCharacter.Parent and TargetCharacter:GetAttribute("CorruptionToken") == Token then
			TargetCharacter:SetAttribute("CorruptionStacks", 0)
			TargetCharacter:SetAttribute("CorruptionActive", false)
		end
	end)
end

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

-- ============================================================
-- FOLLOW-UP LUNGE (Sprint-based movement)
-- ============================================================
local function ExecuteFollowUp(self: Types.Ability, CharacterModel: Model)
	if not RunService:IsServer() then return end

	print("[FollowUp] ExecuteFollowUp triggered!")

	local HitOccurred = false
	local CharacterStats = CharacterModel:FindFirstChild("Stats")
	
	if not CharacterStats then
		print("[FollowUp] WARNING: Stats not found on character. Checking for alternative...")
		-- Debug: print all children of the character
		for _, child in ipairs(CharacterModel:GetChildren()) do
			print("[FollowUp] Character child:", child.Name)
		end
		return
	end

	print("[FollowUp] Stats found, applying sprint multiplier")

	-- Get the original sprint speed
	local OriginalSprintSpeed = CharacterStats:GetAttribute("SprintSpeed") or 30
	print("[FollowUp] Original sprint speed:", OriginalSprintSpeed)

	-- Apply sprint multiplier for the duration
	local NewSprintSpeed = OriginalSprintSpeed * FollowUpSprintMultiplier
	CharacterStats:SetAttribute("SprintSpeed", NewSprintSpeed)
	print("[FollowUp] Applied new sprint speed:", NewSprintSpeed)

	-- Create hitbox during the lunge
	Hitbox.New(self.Owner, {
		CFrameOffset = FollowUpHitboxOffset,
		Size = FollowUpHitboxSize,
		Time = FollowUpDuration,
		Damage = FollowUpDamage,
		Reason = "Sword Follow-up",
		ExecuteOnKill = true,
		OnHit = function(Hit)
			HitOccurred = true
			print("[FollowUp] Hit detected!")
			local TargetCharacter = Hit.Parent
			if TargetCharacter and TargetCharacter:FindFirstChild("Humanoid") then
				ApplyCorruption(TargetCharacter)

				-- Slowness on hit
				TargetCharacter:SetAttribute("Slowed", true)
				TargetCharacter:SetAttribute("SlowLevel", FollowUpSlownessHitLevel)
				task.delay(FollowUpSlownessHitDuration, function()
					if TargetCharacter.Parent then
						TargetCharacter:SetAttribute("Slowed", false)
					end
				end)

				-- Burning damage
				task.delay(0.1, function()
					if TargetCharacter.Parent and TargetCharacter:FindFirstChild("Humanoid") then
						TargetCharacter.Humanoid:TakeDamage(FollowUpBurningDamage)
					end
				end)
			end
		end,
	})

	-- After lunge duration, restore original sprint speed and apply miss slowness if no hit
	task.delay(FollowUpDuration, function()
		if CharacterModel.Parent and CharacterStats then
			print("[FollowUp] Restoring original sprint speed:", OriginalSprintSpeed)
			CharacterStats:SetAttribute("SprintSpeed", OriginalSprintSpeed)

			-- Miss slowness (applied to the killer if nothing was hit)
			if not HitOccurred then
				print("[FollowUp] No hit occurred, applying miss slowness")
				CharacterModel:SetAttribute("Slowed", true)
				CharacterModel:SetAttribute("SlowLevel", FollowUpSlownessMissLevel)
				task.delay(FollowUpSlownessMissDuration, function()
					if CharacterModel.Parent then
						CharacterModel:SetAttribute("Slowed", false)
					end
				end)
			end
		end
	end)
end

-- ============================================================
-- SLASH
-- ============================================================
local function DefaultSlashBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		local CharacterModel = self.OwnerProperties.Character
		local HRP = self.OwnerProperties.HRP
		local Damage = self.Damage

		if CharacterModel:GetAttribute("Injected") then
			Damage += self.InjectedDamageBonus
			CharacterModel:SetAttribute("Injected", false) -- consume buff
		end

		-- Flag that M1 is active and can trigger follow-up
		CharacterModel:SetAttribute("M1Active", true)
		CharacterModel:SetAttribute("FollowUpTriggered", false)

		Sounds.PlaySound(self.UseSound, { Parent = HRP })

		task.delay(SlashWindupDuration, function()
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
						ApplyCorruption(TargetCharacter)

						local WeaknessMultiplier = GetCorruptionWeakness(TargetCharacter)
						local AdditionalDamage = Damage * (WeaknessMultiplier - 1.0)
						if AdditionalDamage > 0 then
							TargetCharacter.Humanoid:TakeDamage(AdditionalDamage)
						end
					end
				end,
			})
		end)

		-- After M1 connects, automatically trigger follow-up
		task.delay(FollowUpAutoDelay, function()
			print("[Slash] Checking follow-up trigger...")
			if CharacterModel.Parent and not CharacterModel:GetAttribute("FollowUpTriggered") then
				print("[Slash] Follow-up conditions met, triggering!")
				CharacterModel:SetAttribute("FollowUpTriggered", true)
				ExecuteFollowUp(self, CharacterModel)
			else
				print("[Slash] Follow-up not triggered - Parent exists:", CharacterModel.Parent ~= nil, "FollowUpTriggered:", CharacterModel:GetAttribute("FollowUpTriggered"))
			end
		end)

		-- Keep M1Active flag for a short window
		task.delay(0.35, function()
			if CharacterModel.Parent then
				CharacterModel:SetAttribute("M1Active", false)
			end
		end)
	else
		self.OwnerProperties.TurnToMoveDirection:AddHeadPreventionFactor("Slash")
		self:AddConnection(task.delay(0.7, function()
			self.OwnerProperties.TurnToMoveDirection:RemoveHeadPreventionFactor("Slash")
		end))
	end
end

-- ============================================================
-- PROJECTILE LAUNCH
-- ============================================================
local function LaunchInjectionProjectile(self: Types.Ability)
	local RootPart = self.OwnerProperties.HRP
	local CharacterModel = self.OwnerProperties.Character
	if not RootPart or not RootPart.Parent then return end

	local Triggered = false
	local ProjectileInstance

	ProjectileInstance = Projectile.New({
		SourcePlayer = self.Owner,
		Model = self.ProjectileModel,               -- this is now a Model
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
					if Triggered then return end

					local TargetCharacter = Humanoid.Parent
					if not TargetCharacter or not TargetCharacter:IsA("Model") then return end

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

-- ============================================================
-- INJECT (projectile)
-- ============================================================
local function InjectBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end

	local CharacterModel = self.OwnerProperties.Character

	task.delay(InjectWindupDuration, function()
		if not CharacterModel.Parent or self.OwnerProperties.Humanoid.Health <= 0 then
			return
		end

		-- Launch the projectile
		LaunchInjectionProjectile(self)
	end)
end

-- ============================================================
-- ABILITY #3 PLACEHOLDER
-- ============================================================
local function Ability3Behaviour(self: Types.Ability)
	-- TODO: Implement Ability 3
	print("Ability 3 triggered - TODO: implement")
end

-- ============================================================
-- ABILITY #4 PLACEHOLDER
-- ============================================================
local function Ability4Behaviour(self: Types.Ability)
	-- TODO: Implement Ability 4
	print("Ability 4 triggered - TODO: implement")
end

-- ============================================================
-- CHARACTER DEFINITION
-- ============================================================
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
				Cooldown = 2,
				Duration = 2,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://110200320368434",

				-- ★★★ SWAP THE MODEL HERE ★★★
				ProjectileModel = CreateInjectionProjectileTemplate(),  -- or just put any Model
				ProjectileSpeed = ProjectileSpeed,
				ProjectileLifetime = ProjectileLifetime,
				ProjectileSize = ProjectileHitboxSize,
				ProjectileOffset = ProjectileOffset,
				ProjectileDamage = ProjectileDamage,
				BuffDuration = InjectedBuffDuration,
				ApplyInjectedBuff = ApplyInjectedBuff,
				Behaviour = InjectBehaviour,
			}),

			Ability3 = Ability.New({
				Name = "Ability 3",
				InputName = "SecondAbility",
				Cooldown = 8,
				Duration = 1,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://0",
				RenderImage = "rbxassetid://0",
				Behaviour = Ability3Behaviour,
				-- TODO: Add ability-specific config values here
			}),

			Ability4 = Ability.New({
				Name = "Ability 4",
				InputName = "ThirdAbility",
				Cooldown = 10,
				Duration = 1.5,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://0",
				RenderImage = "rbxassetid://0",
				Behaviour = Ability4Behaviour,
				-- TODO: Add ability-specific config values here
			}),
		},
	},
})

-- Description
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
		Text = NameLabel .. " performs a slash with a windup. Injected targets make his M1 attacks deal " .. tostring(InjectedDamageBonus) .. " additional damage.",
	},
	{ Type = "Header", Text = "INJECT" },
	{
		Type = "Text",
		Text = NameLabel .. " throws a projectile with a " .. tostring(InjectWindupDuration) .. "s windup. Hitting with projectile buffs his slashes for " .. tostring(InjectedBuffDuration) .. " seconds.",
	},
	{ Type = "Header", Text = "ABILITY 3" },
	{
		Type = "Text",
		Text = "TODO: Add Ability 3 description.",
	},
	{ Type = "Header", Text = "ABILITY 4" },
	{
		Type = "Text",
		Text = "TODO: Add Ability 4 description.",
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
		Text = "After slashing, a follow-up lunge automatically triggers after " .. tostring(FollowUpAutoDelay) .. "s with " .. tostring(FollowUpDamage) .. " damage + " .. tostring(FollowUpBurningDamage) .. " burning damage. On hit: Slowness " .. tostring(FollowUpSlownessHitLevel) .. " for " .. tostring(FollowUpSlownessHitDuration) .. "s. On miss: Slowness " .. tostring(FollowUpSlownessMissLevel) .. " for " .. tostring(FollowUpSlownessMissDuration) .. "s.",
	},
}

return C00lKidd
