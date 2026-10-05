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
-- CONFIG
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

local CorruptionMaxStacks = 3
local CorruptionWeaknessBase = 0.05
local CorruptionWeaknessPerStack = 0.05
local CorruptionDuration = 15

-- Combo window: second M1 after first M1 triggers follow-up
local FollowUpTimeWindow = 0.8
local FollowUpSprintMultiplier = 2.3
local FollowUpDuration = 0.65
local FollowUpDamage = 8
local FollowUpBurningDamage = 7
local FollowUpSlownessHitDuration = 3
local FollowUpSlownessHitLevel = 2
local FollowUpSlownessMissDuration = 2
local FollowUpSlownessMissLevel = 3
local FollowUpHitboxSize = Vector3.new(4, 4, 5.5)
local FollowUpHitboxOffset = CFrame.new(0, 0, -2.5)
local FollowUpAnimation = "rbxassetid://128861543254523"

-- ============================================================
-- PROJECTILE MODEL
-- ============================================================
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

local function CreateSlownessZone(Position: Vector3, Size: Vector3, Duration: number, OwnerCharacter: Model)
	local zone = Instance.new("Part")
	zone.Name = "SlownessZone"
	zone.Anchored = true
	zone.CanCollide = false
	zone.CanTouch = true
	zone.CanQuery = true
	zone.Material = Enum.Material.Neon
	zone.Color = Color3.fromRGB(90, 170, 255)
	zone.Transparency = 0.35
	zone.Size = Size
	zone.CFrame = CFrame.new(Position)
	zone.Parent = workspace

	local touchedConnection = zone.Touched:Connect(function(hit)
		local hitModel = hit.Parent
		if not hitModel then return end
		local Humanoid = hitModel:FindFirstChildOfClass("Humanoid")
		if not Humanoid then return end
		if hitModel == OwnerCharacter then return end
		if hitModel:GetAttribute("Slowed") then return end

		hitModel:SetAttribute("Slowed", true)
		hitModel:SetAttribute("SlowLevel", FollowUpSlownessHitLevel)
		task.delay(2, function()
			if hitModel.Parent then
				hitModel:SetAttribute("Slowed", false)
			end
		end)
	end)

	task.delay(Duration, function()
		if touchedConnection then
			touchedConnection:Disconnect()
		end
		if zone.Parent then
			zone:Destroy()
		end
	end)

	return zone
end

-- ============================================================
-- FOLLOW-UP LUNGE
-- ============================================================
local function ExecuteFollowUp(self: Types.Ability, CharacterModel: Model)
	if not RunService:IsServer() then return end

	local Humanoid = self.OwnerProperties.Humanoid
	local HRP = self.OwnerProperties.HRP
	if not Humanoid or not HRP then return end

	local HitOccurred = false
	local OriginalSpeed = Humanoid.WalkSpeed or 16
	local StartPos = HRP.Position
	local LookDir = HRP.CFrame.LookVector

	if FollowUpAnimation and FollowUpAnimation ~= "rbxassetid://0" then
		local anim = Instance.new("Animation")
		anim.AnimationId = FollowUpAnimation
		local track = Humanoid:LoadAnimation(anim)
		track:Play()
		track.Stopped:Once(function()
			anim:Destroy()
		end)
	end

	Humanoid.WalkSpeed = OriginalSpeed * FollowUpSprintMultiplier

	Hitbox.New(self.Owner, {
		CFrameOffset = FollowUpHitboxOffset,
		Size = FollowUpHitboxSize,
		Time = FollowUpDuration,
		Damage = FollowUpDamage,
		Reason = "Sword Follow-up",
		ExecuteOnKill = true,
		OnHit = function(Hit)
			HitOccurred = true
			local TargetCharacter = Hit.Parent
			if TargetCharacter and TargetCharacter:FindFirstChild("Humanoid") then
				ApplyCorruption(TargetCharacter)

				local ZonePos = TargetCharacter:GetPivot().Position + Vector3.new(0, 0.5, 0)
				CreateSlownessZone(ZonePos, Vector3.new(7, 1, 7), 3.5, CharacterModel)

				TargetCharacter:SetAttribute("Slowed", true)
				TargetCharacter:SetAttribute("SlowLevel", FollowUpSlownessHitLevel)
				task.delay(FollowUpSlownessHitDuration, function()
					if TargetCharacter.Parent then
						TargetCharacter:SetAttribute("Slowed", false)
					end
				end)

				task.delay(0.1, function()
					if TargetCharacter.Parent and TargetCharacter:FindFirstChild("Humanoid") then
						TargetCharacter.Humanoid:TakeDamage(FollowUpBurningDamage)
					end
				end)
			end
		end,
	})

	task.delay(FollowUpDuration, function()
		if CharacterModel.Parent and self.OwnerProperties.Humanoid then
			self.OwnerProperties.Humanoid.WalkSpeed = OriginalSpeed
		end

		if not HitOccurred then
			local EndPos = StartPos + (LookDir * 6)
			CreateSlownessZone(EndPos + Vector3.new(0, 0.5, 0), Vector3.new(7, 1, 7), 3.5, CharacterModel)

			CharacterModel:SetAttribute("Slowed", true)
			CharacterModel:SetAttribute("SlowLevel", FollowUpSlownessMissLevel)
			task.delay(FollowUpSlownessMissDuration, function()
				if CharacterModel.Parent then
					CharacterModel:SetAttribute("Slowed", false)
				end
			end)
		end
	end)
end

-- ============================================================
-- SLASH (M1)
-- ============================================================
local function DefaultSlashBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		local CharacterModel = self.OwnerProperties.Character
		local HRP = self.OwnerProperties.HRP
		local Damage = self.Damage

		if CharacterModel:GetAttribute("Injected") then
			Damage += self.InjectedDamageBonus
			CharacterModel:SetAttribute("Injected", false)
		end

		CharacterModel:SetAttribute("LastM1Time", tick())
		CharacterModel:SetAttribute("M1FollowUpTriggered", false)

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
	end
end

-- ============================================================
-- SCRIPT WAVE (2nd ability)
-- ============================================================
local function ScriptWaveBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end

	local CharacterModel = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	if not CharacterModel or not HRP then return end

	local WavePart = Instance.new("Part")
	WavePart.Name = "ScriptWave"
	WavePart.Anchored = true
	WavePart.CanCollide = false
	WavePart.CanTouch = true
	WavePart.Material = Enum.Material.Neon
	WavePart.Color = Color3.fromRGB(100, 255, 160)
	WavePart.Transparency = 0.35
	WavePart.Size = Vector3.new(8, 1, 2)
	WavePart.CFrame = CFrame.new(HRP.Position + HRP.CFrame.LookVector * 8 + Vector3.new(0, 1, 0), HRP.Position + HRP.CFrame.LookVector * 8 + Vector3.new(0, 1, 0) + HRP.CFrame.LookVector)
	WavePart.Parent = workspace

	local hitSet = {}
	local connection = WavePart.Touched:Connect(function(hit)
		local Model = hit.Parent
		if not Model then return end
		local Humanoid = Model:FindFirstChildOfClass("Humanoid")
		if not Humanoid then return end
		if Model == CharacterModel then return end
		if hitSet[Model] then return end
		hitSet[Model] = true

		Humanoid:TakeDamage(9)
		ApplyCorruption(Model)
		Model:SetAttribute("Slowed", true)
		Model:SetAttribute("SlowLevel", 2)
		task.delay(2.5, function()
			if Model.Parent then
				Model:SetAttribute("Slowed", false)
			end
		end)
	end)

	task.delay(0.6, function()
		if connection then
			connection:Disconnect()
		end
		if WavePart.Parent then
			WavePart:Destroy()
		end
	end)
end

-- ============================================================
-- COOLGUI CREATION (1st ability)
-- ============================================================
local function CoolGUICreationBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end

	local CharacterModel = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	if not CharacterModel or not HRP then return end

	local pulse = Instance.new("Part")
	pulse.Name = "CoolGUI_Pulse"
	pulse.Shape = Enum.PartType.Cylinder
	pulse.Material = Enum.Material.Neon
	pulse.Color = Color3.fromRGB(255, 255, 0)
	pulse.Anchored = true
	pulse.CanCollide = false
	pulse.CanTouch = false
	pulse.Transparency = 0.35
	pulse.Size = Vector3.new(2, 0.5, 2)
	pulse.CFrame = HRP.CFrame * CFrame.new(0, 0, 3)
	pulse.Parent = workspace

	local connection = pulse.Touched:Connect(function(hit)
		local Model = hit.Parent
		if not Model then return end
		local Humanoid = Model:FindFirstChildOfClass("Humanoid")
		if not Humanoid or Model == CharacterModel then return end
		Humanoid:TakeDamage(4)
		ApplyCorruption(Model)
	end)

	task.delay(0.75, function()
		if connection then
			connection:Disconnect()
		end
		if pulse.Parent then
			pulse:Destroy()
		end
	end)
end

-- ============================================================
-- STACK OVERFLOW (4th ability)
-- ============================================================
local function StackOverflowBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end

	local CharacterModel = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	if not CharacterModel or not HRP then return end

	local blast = Instance.new("Part")
	blast.Name = "StackOverflowBlast"
	blast.Anchored = true
	blast.CanCollide = false
	blast.CanTouch = true
	blast.Material = Enum.Material.Neon
	blast.Color = Color3.fromRGB(255, 96, 96)
	blast.Transparency = 0.25
	blast.Size = Vector3.new(10, 10, 10)
	blast.CFrame = HRP.CFrame
	blast.Parent = workspace

	local hitSet = {}
	local connection = blast.Touched:Connect(function(hit)
		local Model = hit.Parent
		if not Model then return end
		local Humanoid = Model:FindFirstChildOfClass("Humanoid")
		if not Humanoid then return end
		if Model == CharacterModel then return end
		if hitSet[Model] then return end
		hitSet[Model] = true

		Humanoid:TakeDamage(18)
		ApplyCorruption(Model)
	end)

	task.delay(0.8, function()
		if connection then
			connection:Disconnect()
		end
		if blast.Parent then
			blast:Destroy()
		end
	end)
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
-- INJECT (3rd ability)
-- ============================================================
local function InjectBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end
	local CharacterModel = self.OwnerProperties.Character

	task.delay(InjectWindupDuration, function()
		if not CharacterModel.Parent or self.OwnerProperties.Humanoid.Health <= 0 then
			return
		end
		LaunchInjectionProjectile(self)
	end)
end

-- ============================================================
-- ABILITY 1 / 2 / 3 / 4 ORDER
-- ============================================================
local function TryFollowUpFromSecondM1(self: Types.Ability)
	if not RunService:IsServer() then return end

	local CharacterModel = self.OwnerProperties.Character
	if not CharacterModel then return end

	local LastM1Time = CharacterModel:GetAttribute("LastM1Time") or 0
	local TimeSinceM1 = tick() - LastM1Time
	if TimeSinceM1 <= FollowUpTimeWindow and not CharacterModel:GetAttribute("M1FollowUpTriggered") then
		CharacterModel:SetAttribute("M1FollowUpTriggered", true)
		CharacterModel:SetAttribute("LastM1Time", 0)
		ExecuteFollowUp(self, CharacterModel)
	end
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
			CoolGUICreation = Ability.New({
				Name = "CoolGUI Creation",
				InputName = "FirstAbility",
				Cooldown = 8,
				Duration = 0.8,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://0",
				RenderImage = "rbxassetid://0",
				Behaviour = CoolGUICreationBehaviour,
			}),

			ScriptWave = Ability.New({
				Name = "ScriptWave",
				InputName = "SecondAbility",
				Cooldown = 8,
				Duration = 1,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://0",
				RenderImage = "rbxassetid://0",
				Behaviour = ScriptWaveBehaviour,
			}),

			Inject = Ability.New({
				Name = "Inject",
				InputName = "ThirdAbility",
				Cooldown = 2,
				Duration = 2,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://110200320368434",
				ProjectileModel = CreateInjectionProjectileTemplate(),
				ProjectileSpeed = ProjectileSpeed,
				ProjectileLifetime = ProjectileLifetime,
				ProjectileSize = ProjectileHitboxSize,
				ProjectileOffset = ProjectileOffset,
				ProjectileDamage = ProjectileDamage,
				BuffDuration = InjectedBuffDuration,
				ApplyInjectedBuff = ApplyInjectedBuff,
				Behaviour = InjectBehaviour,
			}),

			StackOverflow = Ability.New({
				Name = "Stack Overflow",
				InputName = "FourthAbility",
				Cooldown = 12,
				Duration = 1.5,
				UseSound = "rbxassetid://0",
				UseAnimation = "rbxassetid://0",
				RenderImage = "rbxassetid://0",
				Behaviour = StackOverflowBehaviour,
			}),

			Slash = Ability.New({
				Name = "Slash",
				InputName = "Slash",
				Cooldown = 2,
				Duration = 0.4,
				Damage = 12,
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
	{ Type = "Header", Text = "1ST ABILITY - COOLGUI CREATION" },
	{ Type = "Text", Text = "A short pulse that damages enemies in front of C00lKidd and applies corruption." },
	{ Type = "Header", Text = "2ND ABILITY - SCRIPTWAVE" },
	{ Type = "Text", Text = "Launches a fast wave without locking C00lKidd in place while it resolves." },
	{ Type = "Header", Text = "3RD ABILITY - INJECT" },
	{ Type = "Text", Text = "Throws a projectile that buffs slashes for " .. tostring(InjectedBuffDuration) .. " seconds when it hits a survivor." },
	{ Type = "Header", Text = "4TH ABILITY - STACK OVERFLOW" },
	{ Type = "Text", Text = "Creates a burst explosion that deals large damage and applies corruption." },
	{ Type = "Header", Text = "SLASH" },
	{ Type = "Text", Text = NameLabel .. " performs a slash with a windup. Injected targets make his M1 attacks deal " .. tostring(InjectedDamageBonus) .. " additional damage." },
	{ Type = "Header", Text = "SWORD FOLLOW-UP" },
	{ Type = "Text", Text = "Click the second M1 within " .. tostring(FollowUpTimeWindow) .. "s of the first to trigger a follow-up lunge. The lunge creates a slowness zone at the hit location or end position." },
	{ Type = "Separator", Text = "PASSIVES" },
	{ Type = "Header", Text = "SCRIPT INJECTION" },
	{ Type = "Text", Text = "Victims hit by " .. NameLabel .. "'s slashes gain corruption stacks (max " .. tostring(CorruptionMaxStacks) .. "). Each stack grants " .. tostring(math.floor(CorruptionWeaknessBase * 100)) .. "% weakness, scaling up to " .. tostring(math.floor(CorruptionWeaknessBase * 100 * CorruptionMaxStacks)) .. "%." },
}

return C00lKidd
