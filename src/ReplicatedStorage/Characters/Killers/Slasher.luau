--[[
	Slasher.luau — machete M1s, chainsaw M1s, close-range Rebar + throw
	Improvements:
	- Players-based survivor lookup (no workspace:GetChildren)
	- Full JumpHeight + WalkSpeed restore in Freeze / dash helpers
	- Stronger ClearSlasherState + death / removing cleanup
	- Unified dash + carry velocity helpers (less duplication)
	- Debris for projectiles, tighter token guards, safer prop visibility
	- Reduced race windows on endlag / finisher / chainsaw mode
	- M1 restored to normal Ability Use()/Behaviour (framework Cooldown applies)
	- Unified standstill tracking (server + client used two copies of the same logic)
	- Removed dead ApplyPropel legacy path, added missing ChainsawLand anim slot
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")
local Debris = game:GetService("Debris")

local CharacterClass = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)
local Ragdoll = require(ReplicatedStorage.Modules.Ragdoll)

local CommonFunctions = RunService:IsServer()
	and require(ServerScriptService.System.CommonFunctions)
	or nil

local PlayerSpeedManager = RunService:IsServer()
	and require(ServerScriptService.Managers.PlayerManager.PlayerSpeedManager)
	or nil

--============================================================
-- TUNABLES
--============================================================
local MacheteWindupTime = 0.5
local MacheteThrowDuration = 0.7
local MacheteStandstillThreshold = 0.4
local MacheteLungeCooldown = 5
local MacheteAnimWindupDelay = 0.1

-- M1 uses the normal Ability Use()/Behaviour path (framework Cooldown applies).
-- Standstill still upgrades a swing to Heavy; hold-to-lunge remote input removed.

local KickStunImmuneTime = 1.1
local KickHelplessDuration = 1.4
local KickDisorientedDuration = 2.0
local KickRagdollDuration = 2.4
local KickLungeSpeed = 42
local KickLungeTime = 0.22
local KickHitDelay = 0.28
local KickHitboxSize = Vector3.new(4.5, 6, 4.5)
local KickHitboxOffset = CFrame.new(0, 0, -2.2)
local KickHitboxTime = 0.25
local KickBaseDamage = 5

local RebarWindup = 0.55
local RebarSlowDuration = 3.5
local RebarRagdollDuration = 2.2
local RebarMarkDuration = 4.0
local RebarThrowSpeed = 95
local RebarThrowLifetime = 1.1
local RebarDamage = 12
local RebarRespawnDelay = 1.25
local RebarCloseRange = 7.0
local RebarCloseRunSpeed = 40
local RebarCloseRunDuration = 1.2
local RebarCloseWallDamage = 10
local RebarCloseThrowForce = 58
local RebarCloseThrowUp = 30
local RebarWallRayDistance = 5.0
local RebarCloseConeDot = 0.30

local FinisherDamage = 28
local FinisherAnimLock = 1.35
local FinisherRagdoll = 2.6
local FinisherBleedTicks = 4
local FinisherBleedDamage = 3
local FinisherBleedInterval = 0.8

local ChainsawM1Windup = 0.75
local ChainsawRushDuration = 2.15
local ChainsawRushTurn = 0.06 -- light steering while locked
local ChainsawRushSpeed = 48
local ChainsawBrushDamage = 6
local ChainsawPropelForward = 42
local ChainsawPropelUp = 52
local ChainsawPropelDuration = 1.15
local ChainsawPropelGravity = 140
local ChainsawLandingRadius = 9
local ChainsawLandingHitTime = 0.3
local ChainsawLandingDamage = 40
local ChainsawExitDamage = 40
local ChainsawModeMax = 20

--[[
	ANIM PLACEHOLDERS — replace rbxassetid://0
]]
local Anim = {
	MacheteNormal = "rbxassetid://135461552803868",
	MacheteHeavy = "rbxassetid://135461552803868",
	MacheteLunge = "rbxassetid://81700860501331",
	MacheteLungeWindup = "rbxassetid://81700860501331",

	ChainsawM1Normal = "rbxassetid://135461552803868",
	ChainsawM1Heavy = "rbxassetid://135461552803868",
	ChainsawM1Lunge = "rbxassetid://81700860501331",
	ChainsawM1LungeWindup = "rbxassetid://81700860501331",

	RebarWindup = "rbxassetid://99509685410235",
	RebarThrow = "rbxassetid://0",
	RebarCloseStab = "rbxassetid://0",
	RebarCloseRun = "rbxassetid://0",
	RebarCloseSlam = "rbxassetid://0",
	RebarCloseVictimStab = "rbxassetid://0",
	RebarCloseVictimRun = "rbxassetid://0",
	RebarCloseVictimSlam = "rbxassetid://0",

	Kick = "rbxassetid://97107959115833",
	Finisher = "rbxassetid://0",
	FinisherVictim = "rbxassetid://0",

	ChainsawEquip = "rbxassetid://0",
	ChainsawRush = "rbxassetid://0",
	ChainsawPropel = "rbxassetid://0",
	ChainsawLand = "rbxassetid://0",
}

local MacheteSwings = {
	Normal = {
		Name = "MacheteNormal",
		AnimationID = Anim.MacheteNormal,
		Damage = 20,
		HitboxSize = Vector3.new(5, 6, 4.5),
	},
	Heavy = {
		Name = "MacheteHeavy",
		AnimationID = Anim.MacheteHeavy,
		Damage = 28,
		HitboxSize = Vector3.new(5, 6, 7.5),
		PostEffect = "Endlag",
		EndlagDuration = 1.4,
	},
	Lunge = {
		Name = "MacheteLunge",
		AnimationID = Anim.MacheteLunge,
		WindupAnimationID = Anim.MacheteLungeWindup,
		Damage = 16,
		HitboxSize = Vector3.new(5, 6, 4.5),
		LungeForce = 130,
		LungeDuration = MacheteThrowDuration,
	},
}

local ChainsawM1Swings = {
	Normal = {
		Name = "ChainsawM1Normal",
		AnimationID = Anim.ChainsawM1Normal,
		Damage = 28,
		HitboxSize = Vector3.new(5.5, 6, 5),
	},
	Heavy = {
		Name = "ChainsawM1Heavy",
		AnimationID = Anim.ChainsawM1Heavy,
		Damage = 36,
		HitboxSize = Vector3.new(5.5, 6, 8),
		PostEffect = "Endlag",
		EndlagDuration = 1.6,
	},
	Lunge = {
		Name = "ChainsawM1Lunge",
		AnimationID = Anim.ChainsawM1Lunge,
		WindupAnimationID = Anim.ChainsawM1LungeWindup,
		Damage = 24,
		HitboxSize = Vector3.new(5.5, 6, 5.5),
		LungeForce = 120,
		LungeDuration = MacheteThrowDuration,
	},
}

--============================================================
-- Remotes / helpers
--============================================================
local PlayAnimRemote: RemoteEvent? = nil

local function EnsureRemotes()
	if PlayAnimRemote then
		return
	end

	if RunService:IsServer() then
		local folder = ReplicatedStorage:FindFirstChild("SlasherRemotes")
		if not folder then
			folder = Instance.new("Folder")
			folder.Name = "SlasherRemotes"
			folder.Parent = ReplicatedStorage
		end
		local r = folder:FindFirstChild("PlaySlasherAnim") :: RemoteEvent?
		if not r then
			r = Instance.new("RemoteEvent")
			r.Name = "PlaySlasherAnim"
			r.Parent = folder
		end
		PlayAnimRemote = r
	else
		local folder = ReplicatedStorage:WaitForChild("SlasherRemotes", 10)
		if folder then
			PlayAnimRemote = folder:WaitForChild("PlaySlasherAnim", 10) :: RemoteEvent?
		end
	end
end

local function FlatRootCFrame(root: BasePart): CFrame
	local pos = root.Position
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		look = Vector3.new(0, 0, -1)
	else
		look = look.Unit
	end
	return CFrame.lookAt(pos, pos + look)
end

local function FlatLook(root: BasePart): Vector3
	local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
	if look.Magnitude < 0.05 then
		return Vector3.new(0, 0, -1)
	end
	return look.Unit
end

local function FlatHitboxCFrame(root: BasePart, offset: CFrame): () -> CFrame
	return function()
		if not root or not root.Parent then
			return CFrame.new()
		end
		return FlatRootCFrame(root) * offset
	end
end

local function IsChainsawMode(character: Model?): boolean
	return character ~= nil and character:GetAttribute("SlasherChainsawMode") == true
end

local function IsRiding(character: Model?): boolean
	return character ~= nil and character:GetAttribute("SlasherChainsawRiding") == true
end

local function IsAlive(character: Model?): boolean
	if not character or not character.Parent then
		return false
	end
	local hum = character:FindFirstChildWhichIsA("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function IsSurvivor(model: Model?): boolean
	if not model then
		return false
	end
	local role = model:FindFirstChild("Role")
	return role ~= nil and role:IsA("StringValue") and role.Value == "Survivor"
end

local function GrantStunImmunity(character: Model, duration: number)
	if not CommonFunctions or not IsAlive(character) then
		return
	end
	local humanoid = character:FindFirstChildWhichIsA("Humanoid")
	if not humanoid then
		return
	end
	CommonFunctions.ApplyEffect({
		TargetHumanoid = humanoid,
		EffectSettings = {
			Name = "SpawnProtection",
			Subfolder = "KillerSpecific",
			Duration = duration,
		},
	})
end

local function ApplyRagdoll(character: Model, duration: number)
	if not character or not character.Parent then
		return
	end
	local token = (character:GetAttribute("SlasherRagdollToken") :: number?) or 0
	token += 1
	character:SetAttribute("SlasherRagdollToken", token)
	if not character:GetAttribute("Ragdolling") then
		Ragdoll.Enable(character, false)
	end
	task.delay(duration, function()
		if character and character.Parent and character:GetAttribute("SlasherRagdollToken") == token then
			Ragdoll.Disable(character)
		end
	end)
end

local function ClearImpaledRebar(target: Model)
	local stuck = target:FindFirstChild("SlasherImpaledRebar")
	if stuck then
		stuck:Destroy()
	end
	target:SetAttribute("SlasherRebarStuck", false)
end

local function HasPenetrated(character: Model?): boolean
	if not character then
		return false
	end
	if character:GetAttribute("Penetrated") == true then
		return true
	end
	if character:GetAttribute("SlasherRebarStuck") == true then
		return true
	end
	if character:FindFirstChild("SlasherImpaledRebar") then
		return true
	end
	local effects = character:FindFirstChild("Effects")
	if effects and effects:FindFirstChild("Penetrated") then
		return true
	end
	return false
end

local function ApplyPenetrated(humanoid: Humanoid, duration: number)
	if CommonFunctions then
		CommonFunctions.ApplyEffect({
			TargetHumanoid = humanoid,
			EffectSettings = { Name = "Penetrated", Duration = duration },
		})
		return
	end
	local char = humanoid.Parent
	if not char then
		return
	end
	local folder = char:FindFirstChild("Effects")
	if not folder then
		return
	end
	local existing = folder:FindFirstChild("Penetrated")
	if existing then
		existing:Destroy()
	end
	local v = Instance.new("NumberValue")
	v.Name = "Penetrated"
	v.Value = 1
	v:SetAttribute("Duration", duration)
	v.Parent = folder
	char:SetAttribute("Penetrated", true)
	task.delay(duration, function()
		if v.Parent then
			v:Destroy()
		end
		if char.Parent then
			char:SetAttribute("Penetrated", false)
		end
	end)
end

local function ClearPenetrated(character: Model)
	ClearImpaledRebar(character)
	character:SetAttribute("Penetrated", false)
	character:SetAttribute("SlasherRebarStuck", false)
	local effects = character:FindFirstChild("Effects")
	local pen = effects and effects:FindFirstChild("Penetrated")
	if pen then
		pen:Destroy()
	end
end

local function GetHandle(model: Model): BasePart?
	local h = model:FindFirstChild("Handle")
	if h and h:IsA("BasePart") then
		return h
	end
	if model.PrimaryPart then
		return model.PrimaryPart
	end
	return model:FindFirstChildWhichIsA("BasePart", true)
end

local function ImpaleRebarInTarget(target: Model, sourceRebarTemplate: Model?)
	ClearImpaledRebar(target)
	local torso = target:FindFirstChild("Torso")
		or target:FindFirstChild("UpperTorso")
		or target:FindFirstChild("HumanoidRootPart")
	if not torso or not torso:IsA("BasePart") then
		return
	end

	local model: Model
	if sourceRebarTemplate then
		model = sourceRebarTemplate:Clone()
	else
		model = Instance.new("Model")
		local bar = Instance.new("Part")
		bar.Name = "Handle"
		bar.Size = Vector3.new(0.25, 0.25, 3.2)
		bar.Material = Enum.Material.CorrodedMetal
		bar.Color = Color3.fromRGB(95, 95, 100)
		bar.CanCollide = false
		bar.Massless = true
		bar.Parent = model
		model.PrimaryPart = bar
	end
	model.Name = "SlasherImpaledRebar"

	for _, d in model:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("LinearVelocity") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			d.CanQuery = false
		end
	end

	local handle = GetHandle(model) or model:FindFirstChildWhichIsA("BasePart", true)
	if not handle then
		model:Destroy()
		return
	end
	model.PrimaryPart = handle
	local offset = CFrame.new(0, 0.15, -0.35) * CFrame.Angles(math.rad(90), 0, math.rad(25))
	model:PivotTo(torso.CFrame * offset)
	model.Parent = target
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = torso
	weld.Part1 = handle
	weld.Parent = handle
	target:SetAttribute("SlasherRebarStuck", true)
end

-- Fully reversible freeze (WalkSpeed + JumpHeight + JumpPower + AutoRotate + Anchor)
local function FreezeCharacter(character: Model, frozen: boolean)
	local hum = character:FindFirstChildOfClass("Humanoid")
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hum then
		if frozen then
			if character:GetAttribute("SlasherPrevWalkSpeedFreeze") == nil then
				character:SetAttribute("SlasherPrevWalkSpeedFreeze", hum.WalkSpeed)
				character:SetAttribute("SlasherPrevJumpHeightFreeze", hum.JumpHeight)
				character:SetAttribute("SlasherPrevJumpPowerFreeze", hum.JumpPower)
			end
			hum.WalkSpeed = 0
			hum.JumpHeight = 0
			hum.JumpPower = 0
			hum.AutoRotate = false
		else
			local prevSpeed = character:GetAttribute("SlasherPrevWalkSpeedFreeze")
			local prevJH = character:GetAttribute("SlasherPrevJumpHeightFreeze")
			local prevJP = character:GetAttribute("SlasherPrevJumpPowerFreeze")
			if typeof(prevSpeed) == "number" then
				hum.WalkSpeed = prevSpeed
			end
			if typeof(prevJH) == "number" then
				hum.JumpHeight = prevJH
			end
			if typeof(prevJP) == "number" then
				hum.JumpPower = prevJP
			end
			character:SetAttribute("SlasherPrevWalkSpeedFreeze", nil)
			character:SetAttribute("SlasherPrevJumpHeightFreeze", nil)
			character:SetAttribute("SlasherPrevJumpPowerFreeze", nil)
			hum.AutoRotate = true
		end
	end
	if hrp then
		hrp.Anchored = frozen
	end
end

local function PlayCharAnim(character: Model, animId: string, fade: number?): AnimationTrack?
	if not animId or animId == "" or animId == "rbxassetid://0" then
		return nil
	end
	if not IsAlive(character) then
		return nil
	end

	local ok, track = pcall(Utils.Character.LoadAnimationFromID, character, animId)
	if not ok or not track then
		warn("[Slasher] Failed to load animation:", animId)
		return nil
	end
	track.Looped = false
	track:Play(fade or 0.1)
	return track
end

local function PlayKillerAnim(self: Types.Ability, animId: string, fade: number?)
	if not animId or animId == "" or animId == "rbxassetid://0" then
		return
	end

	local Character = self.OwnerProperties.Character
	if not Character then
		return
	end

	-- Client plays locally for responsiveness (owner)
	if RunService:IsServer() and PlayAnimRemote then
		PlayAnimRemote:FireClient(self.Owner, animId, fade or 0.1)
	end

	-- Also load on whatever context we're in (server anims still replicate if Animator exists)
	local track = PlayCharAnim(Character, animId, fade)
	if not track then
		-- Retry once after a short wait (Animator sometimes not ready)
		task.defer(function()
			PlayCharAnim(Character, animId, fade)
		end)
	end
end

local function FindProp(character: Model, name: string): Model?
	local direct = character:FindFirstChild(name)
	if direct and direct:IsA("Model") then
		return direct
	end
	local props = character:FindFirstChild("Props")
	if props then
		local p = props:FindFirstChild(name)
		if p and p:IsA("Model") then
			return p
		end
	end
	local deep = character:FindFirstChild(name, true)
	if deep and deep:IsA("Model") then
		return deep
	end
	return nil
end

local function SetModelVisible(model: Model, visible: boolean)
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			if visible then
				local o = d:GetAttribute("SlasherOrigTrans")
				d.Transparency = if o ~= nil then o else 0
			else
				if d:GetAttribute("SlasherOrigTrans") == nil then
					d:SetAttribute("SlasherOrigTrans", d.Transparency)
				end
				d.Transparency = 1
			end
			d.CanCollide = false
			d.Massless = true
		end
	end
end

local function ClearPropWelds(model: Model)
	for _, d in model:GetDescendants() do
		if (d:IsA("WeldConstraint") or d:IsA("Motor6D")) and d:GetAttribute("SlasherPropWeld") then
			d:Destroy()
		end
	end
end

local function GetGripLimb(character: Model): (BasePart?, Attachment?)
	-- Prefer the real tool grip attachment so props sit in the fingers, not the chest.
	for _, name in { "RightHand", "Right Arm", "RightLowerArm" } do
		local limb = character:FindFirstChild(name)
		if limb and limb:IsA("BasePart") then
			local att = limb:FindFirstChild("RightGripAttachment")
				or limb:FindFirstChild("GripAttachment")
				or limb:FindFirstChild("RightArmGripAttachment")
			if att and att:IsA("Attachment") then
				return limb, att
			end
			return limb, nil
		end
	end
	-- Deep search for grip attachment anywhere on the rig
	for _, d in character:GetDescendants() do
		if d:IsA("Attachment") and (d.Name == "RightGripAttachment" or d.Name == "GripAttachment") then
			if d.Parent and d.Parent:IsA("BasePart") then
				return d.Parent, d
			end
		end
	end
	return nil, nil
end

--- Equips prop Handle into the right hand.
--- gripOffset multiplies onto the grip attachment (or default arm offset).
--- gripC1 is the offset ON the handle — use this to fix mesh orientation.
local function EquipPropToHand(model: Model, character: Model, gripOffset: CFrame?, gripC1: CFrame?): boolean
	local handle = GetHandle(model)
	local hand, gripAtt = GetGripLimb(character)
	if not handle then
		warn("[Slasher] EquipPropToHand: no Handle on", model.Name)
		return false
	end
	if not hand then
		warn("[Slasher] EquipPropToHand: no right hand/arm on", character.Name)
		return false
	end

	pcall(function()
		model.PrimaryPart = handle
	end)

	ClearPropWelds(model)
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") or d:IsA("WeldConstraint") or d:IsA("Weld") then
			if d:GetAttribute("SlasherPropWeld") or d.Name == "SlasherPropGrip" or d.Name == "SlasherPropHolster" then
				d:Destroy()
			end
		end
	end

	model.Parent = character

	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
			d.CanQuery = false
			d.CanTouch = false
		end
	end

	-- C0: where on the limb the tool attaches
	local c0: CFrame
	if gripAtt then
		c0 = gripAtt.CFrame * CFrame.Angles(math.rad(-90), 0, 0)
	elseif hand.Name == "RightHand" then
		c0 = CFrame.new(0, -0.15, -0.05) * CFrame.Angles(math.rad(-90), 0, 0)
	else
		c0 = CFrame.new(0, -1, 0) * CFrame.Angles(math.rad(-90), math.rad(-90), 0)
	end
	if gripOffset then
		c0 = c0 * gripOffset
	end

	-- C1: mesh correction on the Handle (user can pass custom)
	local c1 = gripC1 or CFrame.new()

	handle.CFrame = hand.CFrame * c0 * c1:Inverse()

	local motor = Instance.new("Motor6D")
	motor.Name = "SlasherPropGrip"
	motor:SetAttribute("SlasherPropWeld", true)
	motor.Part0 = hand
	motor.Part1 = handle
	motor.C0 = c0
	motor.C1 = c1
	motor.Parent = hand -- parent to limb (more stable than handle)

	SetModelVisible(model, true)
	return true
end

local function UnequipProp(model: Model, character: Model, hide: boolean?)
	ClearPropWelds(model)
	local torso = character:FindFirstChild("Torso")
		or character:FindFirstChild("UpperTorso")
		or Utils.Character.GetRootPart(character)
	local handle = GetHandle(model)
	if torso and torso:IsA("BasePart") and handle then
		local motor = Instance.new("Motor6D")
		motor.Name = "SlasherPropHolster"
		motor:SetAttribute("SlasherPropWeld", true)
		motor.Part0 = torso
		motor.Part1 = handle
		motor.C0 = CFrame.new(0.85, 0.15, 0.35) * CFrame.Angles(0, 0, math.rad(15))
		motor.C1 = CFrame.new()
		motor.Parent = handle
	end
	if hide ~= false then
		SetModelVisible(model, false)
	end
end

local function HolsterAllProps(character: Model)
	for _, name in { "Rebar", "Chainsaw", "Machete" } do
		local prop = FindProp(character, name)
		if prop then
			UnequipProp(prop, character, true)
		end
	end
end

local function ClearAllDashConstraints(hrp: BasePart)
	for _, child in hrp:GetChildren() do
		if child:GetAttribute("SlasherDash")
			or child.Name == "SlasherRushVelocity"
			or child.Name == "SlasherRushAttach"
			or child.Name == "SlasherKickLunge"
			or child.Name == "SlasherKickAttach"
			or child.Name == "SlasherRebarRunVel"
			or child.Name == "SlasherRebarRunAttach"
			or child.Name == "SlasherDashVel"
			or child.Name == "SlasherDashAttach"
		then
			child:Destroy()
		end
	end
end

local function ClearSlasherState(character: Model)
	character:SetAttribute("SlasherChainsawMode", false)
	character:SetAttribute("SlasherChainsawRiding", false)
	character:SetAttribute("SlasherEndlag", false)
	character:SetAttribute("SlasherRebarWinding", false)
	character:SetAttribute("SlasherFinisherBusy", false)
	character:SetAttribute("SlasherPrevWalkSpeed", nil)
	character:SetAttribute("SlasherPrevWalkSpeedFreeze", nil)
	character:SetAttribute("SlasherPrevJumpHeightFreeze", nil)
	character:SetAttribute("SlasherPrevJumpPowerFreeze", nil)
	character:SetAttribute("SlasherChainsawToken", nil)
	character:SetAttribute("SlasherRideToken", nil)
	character:SetAttribute("SlasherEndlagToken", nil)

	local hrp = character:FindFirstChild("HumanoidRootPart")
	if hrp and hrp:IsA("BasePart") then
		ClearAllDashConstraints(hrp)
		hrp.Anchored = false
	end

	local hum = character:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.AutoRotate = true
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		-- best-effort restore if we still have freeze attrs
		local prevSpeed = character:GetAttribute("SlasherPrevWalkSpeedFreeze")
		if typeof(prevSpeed) == "number" then
			hum.WalkSpeed = prevSpeed
		end
	end

	for _, d in character:GetDescendants() do
		if d:GetAttribute("SlasherRebarCarry") or d.Name == "SlasherRebarCarryWeld" then
			d:Destroy()
		end
	end

	HolsterAllProps(character)
end

local function ApplyBleed(humanoid: Humanoid, ticks: number, damage: number, interval: number, sourcePlayer: Player)
	if not CommonFunctions then
		return
	end
	task.spawn(function()
		for _ = 1, ticks do
			if not humanoid.Parent or humanoid.Health <= 0 then
				return
			end
			CommonFunctions.DamagePlayer({
				SourcePlayer = sourcePlayer,
				TargetHumanoid = humanoid,
				Damage = damage,
				Reason = "Slasher Rebar Bleed",
			})
			task.wait(interval)
		end
	end)
end

-- Much cheaper + correct: only check real players with Role = Survivor
local function FindCloseSurvivor(character: Model, range: number): (Model?, Humanoid?)
	local hrp = character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not hrp then
		return nil, nil
	end
	local origin = hrp.Position
	local look = FlatLook(hrp)
	local bestModel: Model? = nil
	local bestHum: Humanoid? = nil
	local bestDist = range

	for _, player in Players:GetPlayers() do
		local inst = player.Character
		if not inst or inst == character then
			continue
		end
		if not IsSurvivor(inst) or not IsAlive(inst) then
			continue
		end
		local th = inst:FindFirstChild("HumanoidRootPart") :: BasePart?
		local hum = inst:FindFirstChildOfClass("Humanoid")
		if not th or not hum then
			continue
		end
		local offset = th.Position - origin
		local dist = offset.Magnitude
		if dist > range or dist < 0.5 then
			continue
		end
		local dir = offset.Unit
		if dir:Dot(look) < RebarCloseConeDot then
			continue
		end
		if dist < bestDist then
			bestDist = dist
			bestModel = inst
			bestHum = hum
		end
	end
	return bestModel, bestHum
end

--============================================================
-- Motion (unified)
--============================================================
local function TrackStandstill(self: Types.Ability)
	local Humanoid = self.OwnerProperties.Character:FindFirstChildOfClass("Humanoid")
	if not Humanoid then
		return
	end
	self.StandStillSince = os.clock()
	self:AddConnection(RunService.Heartbeat:Connect(function()
		if Humanoid.Parent and Humanoid.MoveDirection.Magnitude > 0.05 then
			self.StandStillSince = os.clock()
		end
	end))
end

local function SetLocomotionLock(player: Player?, character: Model, locked: boolean, tag: string)
	local Humanoid = character:FindFirstChildOfClass("Humanoid")
	if locked then
		if PlayerSpeedManager and player then
			PlayerSpeedManager.AddSpeedFactor(player, tag, 0)
		end
		if Humanoid then
			if character:GetAttribute(tag .. "PrevJH") == nil then
				character:SetAttribute(tag .. "PrevJH", Humanoid.JumpHeight)
				character:SetAttribute(tag .. "PrevJP", Humanoid.JumpPower)
			end
			Humanoid.JumpHeight = 0
			Humanoid.JumpPower = 0
			Humanoid.AutoRotate = false
			Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, false)
			if not PlayerSpeedManager then
				Humanoid.WalkSpeed = 0
			end
		end
	else
		if PlayerSpeedManager and player then
			PlayerSpeedManager.RemoveSpeedFactor(player, tag)
		end
		if Humanoid then
			local pjh = character:GetAttribute(tag .. "PrevJH")
			local pjp = character:GetAttribute(tag .. "PrevJP")
			if typeof(pjh) == "number" then
				Humanoid.JumpHeight = pjh
			end
			if typeof(pjp) == "number" then
				Humanoid.JumpPower = pjp
			end
			character:SetAttribute(tag .. "PrevJH", nil)
			character:SetAttribute(tag .. "PrevJP", nil)
			Humanoid.AutoRotate = true
			Humanoid:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		end
	end
end

local function ApplyLockedDash(
	self: Types.Ability,
	force: number,
	duration: number,
	opts: { UpForce: number?, PreserveY: boolean? }?
)
	opts = opts or {}
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
	if not HRP or not Character then
		return
	end

	ClearAllDashConstraints(HRP)

	local look = FlatLook(HRP)
	SetLocomotionLock(self.Owner, Character, true, "SlasherDash")

	local up = opts.UpForce or 0
	local attach = Instance.new("Attachment")
	attach.Name = "SlasherDashAttach"
	attach:SetAttribute("SlasherDash", true)
	attach.Parent = HRP

	local lv = Instance.new("LinearVelocity")
	lv.Name = "SlasherDashVel"
	lv:SetAttribute("SlasherDash", true)
	lv.Attachment0 = attach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	-- Prefer MaxAxesForce so Y stays physics-driven (stops floor clipping)
	if opts.PreserveY or up == 0 then
		lv.MaxAxesForce = Vector3.new(4e4, 0, 4e4)
		lv.VectorVelocity = Vector3.new(look.X * force, 0, look.Z * force)
	else
		lv.MaxAxesForce = Vector3.new(4e4, 2e4, 4e4)
		lv.VectorVelocity = Vector3.new(look.X * force, up, look.Z * force)
	end
	lv.Parent = HRP

	HRP.AssemblyLinearVelocity = Vector3.new(
		look.X * force,
		if up > 0 then up else HRP.AssemblyLinearVelocity.Y,
		look.Z * force
	)

	local start = os.clock()
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not HRP.Parent or os.clock() - start >= duration then
			if conn then
				conn:Disconnect()
			end
			ClearAllDashConstraints(HRP)
			SetLocomotionLock(self.Owner, Character, false, "SlasherDash")
			return
		end
		if lv.Parent then
			if opts.PreserveY or up == 0 then
				lv.VectorVelocity = Vector3.new(look.X * force, 0, look.Z * force)
			elseif (os.clock() - start) < 0.15 then
				lv.VectorVelocity = Vector3.new(look.X * force, up * 0.55, look.Z * force)
			else
				lv.VectorVelocity = Vector3.new(look.X * force, 0, look.Z * force)
			end
		end
	end)
	self:AddConnection(conn)
end

local function ApplyThrow(self: Types.Ability, Force: number, Duration: number)
	ApplyLockedDash(self, Force, math.max(Duration, 0.55), { PreserveY = true })
end

--- Smooth ballistic arc. No combat hitbox while airborne.
--- Calls onLand() once when grounded (or max time elapses).
local function ApplyPropelArc(self: Types.Ability, forwardForce: number, upForce: number, maxDuration: number, onLand: (() -> ())?)
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	local Humanoid = Character and Character:FindFirstChildOfClass("Humanoid")
	if not HRP or not Character then
		return
	end

	ClearAllDashConstraints(HRP)
	SetLocomotionLock(self.Owner, Character, true, "SlasherPropel")

	local look = FlatLook(HRP)
	if Humanoid then
		Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
	end

	-- One-shot impulse only. Continuous LinearVelocity was driving players
	-- through the floor and erasing the arc (overriding collisions).
	local vx = look.X * forwardForce
	local vz = look.Z * forwardForce
	local vy = upForce
	HRP.AssemblyLinearVelocity = Vector3.new(vx, vy, vz)

	-- Soft horizontal assist (low force) so air control isn't zero, but
	-- physics still owns Y / floor collision.
	local attach = Instance.new("Attachment")
	attach.Name = "SlasherPropelAttach"
	attach:SetAttribute("SlasherDash", true)
	attach.Parent = HRP
	local lv = Instance.new("LinearVelocity")
	lv.Name = "SlasherPropelVel"
	lv:SetAttribute("SlasherDash", true)
	lv.Attachment0 = attach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.MaxAxesForce = Vector3.new(12000, 0, 12000) -- XZ only — never fight the floor on Y
	lv.VectorVelocity = Vector3.new(vx, 0, vz)
	lv.Parent = HRP

	local start = os.clock()
	local landed = false
	local leftGround = false
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { Character }

	local function finish()
		if landed then
			return
		end
		landed = true
		ClearAllDashConstraints(HRP)
		-- Clamp so we don't tunnel
		if HRP.Parent then
			local v = HRP.AssemblyLinearVelocity
			HRP.AssemblyLinearVelocity = Vector3.new(v.X * 0.35, math.max(v.Y, -8), v.Z * 0.35)
		end
		SetLocomotionLock(self.Owner, Character, false, "SlasherPropel")
		if onLand then
			task.defer(onLand)
		end
	end

	local conn
	conn = RunService.Heartbeat:Connect(function()
		if not HRP.Parent or not IsAlive(Character) then
			if conn then
				conn:Disconnect()
			end
			finish()
			return
		end

		local elapsed = os.clock() - start

		-- Keep horizontal assist pointed the same way; let gravity handle Y
		if lv.Parent then
			local fade = math.clamp(1 - (elapsed / maxDuration), 0.25, 1)
			lv.VectorVelocity = Vector3.new(vx * fade, 0, vz * fade)
		end

		local floor = workspace:Raycast(HRP.Position + Vector3.new(0, 0.5, 0), Vector3.new(0, -3.8, 0), rayParams)
		local onGround = floor ~= nil and floor.Distance <= 3.0
		if Humanoid and Humanoid.FloorMaterial ~= Enum.Material.Air then
			onGround = true
		end

		if not leftGround and not onGround and elapsed > 0.1 then
			leftGround = true
		end

		if leftGround and onGround and elapsed > 0.2 then
			if conn then
				conn:Disconnect()
			end
			finish()
			return
		end

		-- Safety: if somehow under the map, pop back up
		if floor and floor.Distance < 0.2 and HRP.AssemblyLinearVelocity.Y < -1 then
			HRP.AssemblyLinearVelocity = Vector3.new(HRP.AssemblyLinearVelocity.X, 4, HRP.AssemblyLinearVelocity.Z)
		end

		if elapsed >= maxDuration then
			if conn then
				conn:Disconnect()
			end
			finish()
		end
	end)
	self:AddConnection(conn)
end

--============================================================
-- M1 — Machete (default) / ChainsawM1 (mode)
--============================================================
local function ExecuteSwing(self: Types.Ability, SwingData)
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	if not IsAlive(Character) or not HRP then
		return
	end

	if not IsChainsawMode(Character) then
		local machete = FindProp(Character, "Machete")
		if machete then
			EquipPropToHand(machete, Character, CFrame.new(0, -1, 0) * CFrame.Angles(math.rad(-90), 0, 0))
			task.delay(0.45, function()
				if machete and Character.Parent then
					UnequipProp(machete, Character, true)
				end
			end)
		end
	end

	Sounds.PlaySound(self.UseSound, { Parent = HRP })

	task.delay(self.Delay, function()
		if not IsAlive(Character) or not HRP.Parent then
			return
		end
		Hitbox.New(self.Owner, {
			CFrame = FlatHitboxCFrame(HRP, self.HitboxOffset or CFrame.new(0, 0, -2.5)),
			CFrameOffset = CFrame.new(),
			Size = SwingData.HitboxSize or self.HitboxSize,
			Time = self.Duration,
			Damage = SwingData.Damage,
			Reason = "Slash (" .. SwingData.Name .. ")",
			ExecuteOnKill = true,
		})
		if SwingData.LungeForce and SwingData.LungeForce > 0 then
			ApplyThrow(self, SwingData.LungeForce, SwingData.LungeDuration or 0.7)
		end
	end)

	if SwingData.PostEffect == "Endlag" then
		Character:SetAttribute("SlasherEndlag", true)
		local endlagToken = (Character:GetAttribute("SlasherEndlagToken") :: number?) or 0
		endlagToken += 1
		Character:SetAttribute("SlasherEndlagToken", endlagToken)
		self:AddConnection(task.delay(SwingData.EndlagDuration, function()
			if Character.Parent and Character:GetAttribute("SlasherEndlagToken") == endlagToken then
				Character:SetAttribute("SlasherEndlag", false)
			end
		end))
	end
end

local function PickSwingConfigs(character: Model)
	if IsChainsawMode(character) then
		return ChainsawM1Swings.Normal, ChainsawM1Swings.Heavy, ChainsawM1Swings.Lunge
	end
	return MacheteSwings.Normal, MacheteSwings.Heavy, MacheteSwings.Lunge
end

local ExitChainsawRush: (self: Types.Ability) -> ()

local function PickSwing(self: Types.Ability)
	local Character = self.OwnerProperties.Character
	local normal, heavy = PickSwingConfigs(Character)
	local still = os.clock() - (self.StandStillSince or os.clock())
	if still >= MacheteStandstillThreshold then
		return heavy
	end
	return normal
end

--- Standard Ability Behaviour — runs on Use() so Cooldown / UseConditions apply.
local function SlashBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end

	local Character = self.OwnerProperties.Character
	if not IsAlive(Character) then
		return
	end

	-- M1 while rushing = exit propel
	if IsRiding(Character) then
		ExitChainsawRush(self)
		return
	end

	if Character:GetAttribute("SlasherEndlag") then
		return
	end

	local swing = PickSwing(self)
	PlayKillerAnim(self, swing.AnimationID)
	ExecuteSwing(self, swing)
end

local function SlashExtraInit(self: Types.Ability)
	EnsureRemotes()
	local Character = self.OwnerProperties.Character
	if Character then
		HolsterAllProps(Character)
		local hum = Character:FindFirstChildWhichIsA("Humanoid")
		if hum and RunService:IsServer() then
			self:AddConnection(hum.Died:Connect(function()
				ClearSlasherState(Character)
			end))
			self:AddConnection(Character.AncestryChanged:Connect(function(_, parent)
				if not parent then
					ClearSlasherState(Character)
				end
			end))
		end
	end

	-- Standstill tracking for Heavy upgrade (server decides; client mirror optional)
	TrackStandstill(self)

	if not RunService:IsServer() and PlayAnimRemote then
		self:AddConnection(PlayAnimRemote.OnClientEvent:Connect(function(animId: string, fade: number?)
			local char = self.Owner.Character
			if char then
				PlayCharAnim(char, animId, fade)
			end
		end))
	end
end

local function SlashUseConditions(self: Types.Ability): boolean
	local Character = self.OwnerProperties.Character
	if not IsAlive(Character) then
		return false
	end
	-- Allow Use while riding so M1 can cancel the rush
	if IsRiding(Character) then
		return true
	end
	return not Character:GetAttribute("SlasherEndlag")
end

--============================================================
-- Chainsaw rush / propel
--============================================================
ExitChainsawRush = function(self: Types.Ability)
	local Character = self.OwnerProperties.Character
	if not Character or not IsRiding(Character) then
		return
	end
	Character:SetAttribute("SlasherChainsawRiding", false)
	Character:SetAttribute("SlasherChainsawMode", false)

	local HRP = self.OwnerProperties.HRP
	if HRP then
		ClearAllDashConstraints(HRP)
	end

	SetLocomotionLock(self.Owner, Character, false, "SlasherRush")
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	local prev = Character:GetAttribute("SlasherPrevWalkSpeed")
	if Humanoid and typeof(prev) == "number" then
		-- backup if speed manager not present
		if not PlayerSpeedManager then
			Humanoid.WalkSpeed = prev
		end
		Character:SetAttribute("SlasherPrevWalkSpeed", nil)
	end

	local saw = FindProp(Character, "Chainsaw")
	if saw then
		UnequipProp(saw, Character, true)
	end
	if not IsAlive(Character) or not HRP then
		return
	end

	PlayKillerAnim(self, Anim.ChainsawPropel)

	-- Smooth arc through the air — NO hitbox until landing
	ApplyPropelArc(self, ChainsawPropelForward, ChainsawPropelUp, ChainsawPropelDuration, function()
		if not IsAlive(Character) or not HRP or not HRP.Parent then
			return
		end
		-- Landing impact
		PlayKillerAnim(self, Anim.ChainsawLand)
		-- Radial hitbox centered on landing position (flat cylinder-ish box)
		Hitbox.New(self.Owner, {
			CFrame = function()
				if not HRP.Parent then
					return CFrame.new()
				end
				-- Stay grounded at character, no vertical tilt
				return FlatRootCFrame(HRP)
			end,
			CFrameOffset = CFrame.new(),
			Size = Vector3.new(ChainsawLandingRadius, 4, ChainsawLandingRadius),
			Time = ChainsawLandingHitTime,
			Damage = ChainsawLandingDamage,
			Reason = "Slasher Chainsaw Landing",
			HitMultiple = true,
			ExecuteOnKill = true,
		})
	end)
end

local function StartChainsawRush(self: Types.Ability)
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	local Humanoid = Character:FindFirstChildOfClass("Humanoid")
	if not IsAlive(Character) or not HRP or IsRiding(Character) then
		return
	end

	Character:SetAttribute("SlasherChainsawRiding", true)
	GrantStunImmunity(Character, ChainsawRushDuration + 0.7)
	PlayKillerAnim(self, Anim.ChainsawRush)

	ClearAllDashConstraints(HRP)
	SetLocomotionLock(self.Owner, Character, true, "SlasherRush")

	local rideLook = FlatLook(HRP)
	HRP.CFrame = CFrame.lookAt(HRP.Position, HRP.Position + rideLook)

	local attach = Instance.new("Attachment")
	attach.Name = "SlasherRushAttach"
	attach:SetAttribute("SlasherDash", true)
	attach.Parent = HRP
	local lv = Instance.new("LinearVelocity")
	lv.Name = "SlasherRushVelocity"
	lv:SetAttribute("SlasherDash", true)
	lv.Attachment0 = attach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	-- XZ only so we never push into the floor
	lv.MaxAxesForce = Vector3.new(35000, 0, 35000)
	lv.VectorVelocity = Vector3.new(rideLook.X * ChainsawRushSpeed, 0, rideLook.Z * ChainsawRushSpeed)
	lv.Parent = HRP
	local v0 = HRP.AssemblyLinearVelocity
	HRP.AssemblyLinearVelocity = Vector3.new(rideLook.X * ChainsawRushSpeed, math.clamp(v0.Y, -5, 5), rideLook.Z * ChainsawRushSpeed)

	local rideToken = (Character:GetAttribute("SlasherRideToken") :: number?) or 0
	rideToken += 1
	Character:SetAttribute("SlasherRideToken", rideToken)
	local start = os.clock()
	local turn = ChainsawRushTurn or 0.06
	local conn
	conn = RunService.Heartbeat:Connect(function()
		if Character:GetAttribute("SlasherRideToken") ~= rideToken then
			if conn then
				conn:Disconnect()
			end
			return
		end
		if not HRP.Parent or not IsRiding(Character) or not IsAlive(Character) then
			if conn then
				conn:Disconnect()
			end
			if IsRiding(Character) then
				ExitChainsawRush(self)
			end
			return
		end

		-- Light steering (void-rush with a bit of turn)
		local desired = FlatLook(HRP)
		rideLook = rideLook:Lerp(desired, turn).Unit
		if lv.Parent then
			lv.VectorVelocity = Vector3.new(rideLook.X * ChainsawRushSpeed, 0, rideLook.Z * ChainsawRushSpeed)
		end
		-- Face move direction without full free rotate
		HRP.CFrame = CFrame.lookAt(HRP.Position, HRP.Position + rideLook)

		if os.clock() - start >= ChainsawRushDuration then
			if conn then
				conn:Disconnect()
			end
			ExitChainsawRush(self)
		end
	end)
	self:AddConnection(conn)

	Hitbox.New(self.Owner, {
		CFrame = FlatHitboxCFrame(HRP, CFrame.new(0, 0, -2.5)),
		CFrameOffset = CFrame.new(),
		Size = Vector3.new(4.5, 5, 6),
		Time = ChainsawRushDuration,
		Damage = ChainsawBrushDamage,
		Reason = "Slasher Chainsaw Rush",
		HitMultiple = true,
		ExecuteOnKill = false,
	})
end

--============================================================
-- Finisher (Penetrated + Kick)
--============================================================
local function ExecuteRebarFinisher(self: Types.Ability, TargetCharacter: Model, Humanoid: Humanoid)
	if not IsSurvivor(TargetCharacter) or Humanoid.Health <= 0 then
		return
	end
	if TargetCharacter:GetAttribute("SlasherFinisherBusy") then
		return
	end
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	local targetHRP = TargetCharacter:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not IsAlive(Character) or not HRP or not targetHRP then
		return
	end

	TargetCharacter:SetAttribute("SlasherFinisherBusy", true)
	Character:SetAttribute("SlasherFinisherBusy", true)

	local face = FlatRootCFrame(targetHRP)
	HRP.CFrame = face * CFrame.new(0, 0, -2.4) * CFrame.Angles(0, math.rad(180), 0)
	targetHRP.CFrame = CFrame.lookAt(
		targetHRP.Position,
		Vector3.new(HRP.Position.X, targetHRP.Position.Y, HRP.Position.Z)
	)

	FreezeCharacter(Character, true)
	FreezeCharacter(TargetCharacter, true)
	PlayKillerAnim(self, Anim.Finisher)
	PlayCharAnim(TargetCharacter, Anim.FinisherVictim)

	task.delay(0.45, function()
		if not Humanoid.Parent or Humanoid.Health <= 0 then
			return
		end
		if CommonFunctions then
			CommonFunctions.DamagePlayer({
				SourcePlayer = self.Owner,
				TargetHumanoid = Humanoid,
				Damage = FinisherDamage,
				Reason = "Slasher Nighty Night Finisher",
			})
		else
			Humanoid:TakeDamage(FinisherDamage)
		end
	end)

	task.delay(FinisherAnimLock, function()
		FreezeCharacter(Character, false)
		Character:SetAttribute("SlasherFinisherBusy", false)
		if TargetCharacter.Parent then
			ClearPenetrated(TargetCharacter)
			FreezeCharacter(TargetCharacter, false)
			TargetCharacter:SetAttribute("SlasherFinisherBusy", false)
			ApplyRagdoll(TargetCharacter, FinisherRagdoll)
			if Humanoid.Parent and Humanoid.Health > 0 then
				ApplyBleed(Humanoid, FinisherBleedTicks, FinisherBleedDamage, FinisherBleedInterval, self.Owner)
			end
		end
	end)
end

--============================================================
-- Kick — Nighty Night
--============================================================
local function KickBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	if not IsAlive(Character) or not HRP then
		return
	end
	if Character:GetAttribute("SlasherFinisherBusy") then
		return
	end

	Sounds.PlaySound(self.UseSound, { Parent = HRP })

	if IsChainsawMode(Character) and not IsRiding(Character) then
		StartChainsawRush(self)
		return
	end
	if IsRiding(Character) then
		return
	end

	GrantStunImmunity(Character, KickStunImmuneTime)
	PlayKillerAnim(self, Anim.Kick)

	local look = FlatLook(HRP)
	local hum = Character:FindFirstChildOfClass("Humanoid")
	local prevSpeed = hum and hum.WalkSpeed or 16
	local prevJH = hum and hum.JumpHeight or 7.2
	local prevJP = hum and hum.JumpPower or 50
	if hum then
		hum.WalkSpeed = 0
		hum.JumpHeight = 0
		hum.JumpPower = 0
		hum.AutoRotate = false
	end

	ClearAllDashConstraints(HRP)

	local attach = Instance.new("Attachment")
	attach.Name = "SlasherKickAttach"
	attach.Parent = HRP
	local lv = Instance.new("LinearVelocity")
	lv.Name = "SlasherKickLunge"
	lv.Attachment0 = attach
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.VectorVelocity = look * KickLungeSpeed
	lv.MaxForce = 35000
	lv.Parent = HRP

	task.delay(KickLungeTime, function()
		if lv.Parent then
			lv:Destroy()
		end
		if attach.Parent then
			attach:Destroy()
		end
	end)

	task.delay(KickHitDelay, function()
		if hum and hum.Parent then
			hum.WalkSpeed = prevSpeed
			hum.JumpHeight = prevJH
			hum.JumpPower = prevJP
			hum.AutoRotate = true
		end
		if not IsAlive(Character) or not HRP.Parent then
			return
		end
		Hitbox.New(self.Owner, {
			CFrame = FlatHitboxCFrame(HRP, KickHitboxOffset),
			CFrameOffset = CFrame.new(),
			Size = KickHitboxSize,
			Time = KickHitboxTime,
			Damage = 0,
			Reason = "Kick",
			ExecuteOnKill = false,
			Connections = {
				Hit = function(_Config, Humanoid: Humanoid)
					local TargetCharacter = Humanoid.Parent
					if not TargetCharacter or not TargetCharacter:IsA("Model") then
						return
					end
					if not IsSurvivor(TargetCharacter) or TargetCharacter:GetAttribute("SlasherFinisherBusy") then
						return
					end
					if HasPenetrated(TargetCharacter) then
						ExecuteRebarFinisher(self, TargetCharacter, Humanoid)
						return
					end
					if CommonFunctions then
						CommonFunctions.DamagePlayer({
							SourcePlayer = self.Owner,
							TargetHumanoid = Humanoid,
							Damage = self.Damage or KickBaseDamage,
							Reason = "Slasher Nighty Night",
						})
						CommonFunctions.ApplyEffect({
							TargetHumanoid = Humanoid,
							EffectSettings = { Name = "Helpless", Duration = KickHelplessDuration },
						})
						CommonFunctions.ApplyEffect({
							TargetHumanoid = Humanoid,
							EffectSettings = { Name = "Disoriented", Duration = KickDisorientedDuration },
						})
					end
					ApplyRagdoll(TargetCharacter, self.RagdollDuration or KickRagdollDuration)
				end,
			},
		})
	end)
end

--============================================================
-- Rebar — close stab-run OR far throw
--============================================================
local function EndCloseRebarCarry(
	self: Types.Ability,
	Character: Model,
	Target: Model,
	TargetHum: Humanoid,
	rebar: Model,
	hitWall: boolean
)
	local HRP = self.OwnerProperties.HRP
	local targetHRP = Target:FindFirstChild("HumanoidRootPart") :: BasePart?

	local carry = Character:FindFirstChild("SlasherRebarCarryWeld")
	if carry then
		carry:Destroy()
	end
	for _, d in Character:GetDescendants() do
		if d:GetAttribute("SlasherRebarCarry") then
			d:Destroy()
		end
	end
	if HRP then
		ClearAllDashConstraints(HRP)
	end

	FreezeCharacter(Character, false)
	Character:SetAttribute("SlasherFinisherBusy", false)
	if Target.Parent then
		Target:SetAttribute("SlasherFinisherBusy", false)
	end

	if hitWall then
		PlayKillerAnim(self, Anim.RebarCloseSlam)
		PlayCharAnim(Target, Anim.RebarCloseVictimSlam)
		if CommonFunctions and TargetHum.Parent and TargetHum.Health > 0 then
			CommonFunctions.DamagePlayer({
				SourcePlayer = self.Owner,
				TargetHumanoid = TargetHum,
				Damage = RebarCloseWallDamage,
				Reason = "Slasher Rebar Wall Slam",
			})
		end
		ClearPenetrated(Target)
		FreezeCharacter(Target, false)
		ApplyRagdoll(Target, RebarRagdollDuration)
	else
		PlayKillerAnim(self, Anim.RebarThrow)
		if targetHRP and HRP and targetHRP.Parent then
			local look = FlatLook(HRP)
			targetHRP.AssemblyLinearVelocity = look * RebarCloseThrowForce + Vector3.new(0, RebarCloseThrowUp, 0)
		end
		ImpaleRebarInTarget(Target, rebar)
		if TargetHum.Parent and TargetHum.Health > 0 then
			ApplyPenetrated(TargetHum, RebarMarkDuration)
		end
		FreezeCharacter(Target, false)
		ApplyRagdoll(Target, RebarRagdollDuration)
	end

	UnequipProp(rebar, Character, true)
end

local function StartCloseRebar(self: Types.Ability, Character: Model, Target: Model, TargetHum: Humanoid, rebar: Model)
	local HRP = self.OwnerProperties.HRP
	local targetHRP = Target:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not HRP or not targetHRP then
		return
	end

	Character:SetAttribute("SlasherFinisherBusy", true)
	Target:SetAttribute("SlasherFinisherBusy", true)

	local face = FlatRootCFrame(HRP)
	targetHRP.CFrame = face * CFrame.new(0, 0, -2.2)
	HRP.CFrame = face

	EquipPropToHand(rebar, Character, CFrame.new(), CFrame.new())
	PlayKillerAnim(self, Anim.RebarCloseStab)
	PlayCharAnim(Target, Anim.RebarCloseVictimStab)

	if CommonFunctions then
		CommonFunctions.DamagePlayer({
			SourcePlayer = self.Owner,
			TargetHumanoid = TargetHum,
			Damage = RebarDamage,
			Reason = "Slasher Rebar Close Stab",
		})
	end

	task.delay(0.35, function()
		if not IsAlive(Character) or not Target.Parent or TargetHum.Health <= 0 then
			Character:SetAttribute("SlasherFinisherBusy", false)
			if Target.Parent then
				Target:SetAttribute("SlasherFinisherBusy", false)
			end
			UnequipProp(rebar, Character, true)
			return
		end

		PlayKillerAnim(self, Anim.RebarCloseRun)
		PlayCharAnim(Target, Anim.RebarCloseVictimRun)

		targetHRP.CFrame = FlatRootCFrame(HRP) * CFrame.new(0, 0, -2.1)
		local weld = Instance.new("WeldConstraint")
		weld.Name = "SlasherRebarCarryWeld"
		weld:SetAttribute("SlasherRebarCarry", true)
		weld.Part0 = HRP
		weld.Part1 = targetHRP
		weld.Parent = Character

		local hum = Character:FindFirstChildOfClass("Humanoid")
		local prev = hum and hum.WalkSpeed or 16
		local prevJH = hum and hum.JumpHeight or 7.2
		local prevJP = hum and hum.JumpPower or 50
		if hum then
			hum.WalkSpeed = 0
			hum.JumpHeight = 0
			hum.JumpPower = 0
			hum.AutoRotate = false
		end

		local look = FlatLook(HRP)

		ClearAllDashConstraints(HRP)

		local attach = Instance.new("Attachment")
		attach.Name = "SlasherRebarRunAttach"
		attach:SetAttribute("SlasherRebarCarry", true)
		attach.Parent = HRP
		local lv = Instance.new("LinearVelocity")
		lv.Name = "SlasherRebarRunVel"
		lv:SetAttribute("SlasherRebarCarry", true)
		lv.Attachment0 = attach
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.VectorVelocity = look * RebarCloseRunSpeed
		lv.MaxForce = 45000
		lv.Parent = HRP

		local start = os.clock()
		local hitWall = false
		local params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { Character, Target }

		local conn
		conn = RunService.Heartbeat:Connect(function()
			if not HRP.Parent or not IsAlive(Character) then
				if conn then
					conn:Disconnect()
				end
				EndCloseRebarCarry(self, Character, Target, TargetHum, rebar, false)
				return
			end

			local origin = HRP.Position + Vector3.new(0, 1.5, 0)
			local result = workspace:Raycast(origin, look * RebarWallRayDistance, params)
			if result and result.Instance and not result.Instance:IsDescendantOf(Target) then
				local hitModel = result.Instance:FindFirstAncestorOfClass("Model")
				if not (hitModel and hitModel:FindFirstChildOfClass("Humanoid")) then
					hitWall = true
					if conn then
						conn:Disconnect()
					end
					if lv.Parent then
						lv:Destroy()
					end
					if attach.Parent then
						attach:Destroy()
					end
					if hum then
						hum.WalkSpeed = prev
						hum.JumpHeight = prevJH
						hum.JumpPower = prevJP
						hum.AutoRotate = true
					end
					EndCloseRebarCarry(self, Character, Target, TargetHum, rebar, true)
					return
				end
			end

			if os.clock() - start >= RebarCloseRunDuration then
				if conn then
					conn:Disconnect()
				end
				if lv.Parent then
					lv:Destroy()
				end
				if attach.Parent then
					attach:Destroy()
				end
				if hum then
					hum.WalkSpeed = prev
					hum.JumpHeight = prevJH
					hum.JumpPower = prevJP
					hum.AutoRotate = true
				end
				EndCloseRebarCarry(self, Character, Target, TargetHum, rebar, false)
			end
		end)
		self:AddConnection(conn)
	end)
end

local function StartFarRebarThrow(self: Types.Ability, Character: Model, rebar: Model)
	local HRP = self.OwnerProperties.HRP
	if not HRP then
		return
	end

	ClearPropWelds(rebar)
	SetModelVisible(rebar, false)
	PlayKillerAnim(self, Anim.RebarThrow)

	local thrown = rebar:Clone()
	for _, d in thrown:GetDescendants() do
		if d:IsA("WeldConstraint") or d:IsA("Motor6D") or d:IsA("Weld") or d:IsA("LinearVelocity") then
			d:Destroy()
		elseif d:IsA("BasePart") then
			d.Anchored = false
			d.CanCollide = false
			d.Massless = true
		end
	end
	local handle = GetHandle(thrown) or thrown:FindFirstChildWhichIsA("BasePart", true)
	if not handle then
		thrown:Destroy()
		UnequipProp(rebar, Character, true)
		return
	end
	thrown.PrimaryPart = handle
	thrown.Name = "SlasherRebarProjectile"
	local startCF = FlatRootCFrame(HRP) * CFrame.new(0, 1.4, -4)
	thrown:PivotTo(startCF)
	thrown.Parent = workspace:FindFirstChild("TempObjectFolders") or workspace

	local look = FlatLook(HRP)
	local att = Instance.new("Attachment")
	att.Parent = handle
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = att
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	lv.VectorVelocity = look * RebarThrowSpeed
	lv.MaxForce = math.huge
	lv.Parent = handle

	Hitbox.New(self.Owner, {
		CFrame = function()
			if thrown.Parent and thrown.PrimaryPart then
				return thrown.PrimaryPart.CFrame
			end
			return startCF
		end,
		CFrameOffset = CFrame.new(),
		Size = Vector3.new(1.5, 1.5, 5),
		Time = RebarThrowLifetime,
		Damage = RebarDamage,
		Reason = "Slasher Rebar Throw",
		ExecuteOnKill = false,
		IsProjectile = true,
		PredictVelocity = false,
		Connections = {
			Hit = function(_Config, Humanoid: Humanoid)
				local TargetCharacter = Humanoid.Parent
				if not TargetCharacter or not TargetCharacter:IsA("Model") then
					return
				end
				if TargetCharacter == Character or not IsSurvivor(TargetCharacter) then
					return
				end
				if CommonFunctions then
					CommonFunctions.ApplyEffect({
						TargetHumanoid = Humanoid,
						EffectSettings = { Name = "Slowness", Level = 2, Duration = RebarSlowDuration },
					})
				end
				ImpaleRebarInTarget(TargetCharacter, rebar)
				ApplyPenetrated(Humanoid, RebarMarkDuration)
				ApplyRagdoll(TargetCharacter, RebarRagdollDuration)
				if thrown.Parent then
					thrown:Destroy()
				end
			end,
		},
	})

	Debris:AddItem(thrown, RebarThrowLifetime + 0.1) -- safer than pure task.delay
	task.delay(RebarRespawnDelay, function()
		if Character.Parent and rebar then
			UnequipProp(rebar, Character, true)
		end
	end)
end

local function RebarBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP
	if not IsAlive(Character) or not HRP then
		return
	end
	if Character:GetAttribute("SlasherRebarWinding") or Character:GetAttribute("SlasherFinisherBusy") then
		return
	end

	local rebar = FindProp(Character, "Rebar")
	if not rebar then
		warn("[Slasher] Missing Model 'Rebar' with Handle")
		return
	end

	Character:SetAttribute("SlasherRebarWinding", true)
	EquipPropToHand(rebar, Character, CFrame.new(), CFrame.new())
	PlayKillerAnim(self, Anim.RebarWindup)
	Sounds.PlaySound(self.UseSound, { Parent = HRP })

	task.delay(RebarWindup, function()
		Character:SetAttribute("SlasherRebarWinding", false)
		if not IsAlive(Character) or not rebar.Parent or not HRP.Parent then
			if Character.Parent and rebar then
				UnequipProp(rebar, Character, true)
			end
			return
		end

		local closeTarget, closeHum = FindCloseSurvivor(Character, RebarCloseRange)
		if closeTarget and closeHum then
			StartCloseRebar(self, Character, closeTarget, closeHum, rebar)
		else
			StartFarRebarThrow(self, Character, rebar)
		end
	end)
end

--============================================================
-- Chainsaw toggle
--============================================================
local function ChainsawBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end
	local Character = self.OwnerProperties.Character
	if not IsAlive(Character) or IsRiding(Character) then
		return
	end

	local on = not IsChainsawMode(Character)
	Character:SetAttribute("SlasherChainsawMode", on)
	local saw = FindProp(Character, "Chainsaw")
	if not saw then
		warn("[Slasher] Missing Model 'Chainsaw' with Handle")
	end
	Sounds.PlaySound(self.UseSound, { Parent = self.OwnerProperties.HRP })

	if on then
		PlayKillerAnim(self, Anim.ChainsawEquip)
		if saw then
			EquipPropToHand(saw, Character, CFrame.new(), CFrame.new()) -- tweak gripC1 if mesh is rotated
		end
		local token = os.clock()
		Character:SetAttribute("SlasherChainsawToken", token)
		task.delay(ChainsawModeMax, function()
			if
				Character.Parent
				and Character:GetAttribute("SlasherChainsawToken") == token
				and not IsRiding(Character)
			then
				Character:SetAttribute("SlasherChainsawMode", false)
				if saw then
					UnequipProp(saw, Character, true)
				end
			end
		end)
	elseif saw then
		UnequipProp(saw, Character, true)
	end
end

--============================================================
-- Character def
--============================================================
local Slasher: Types.Killer = CharacterClass.CreateKiller({
	Config = {
		Name = "Slasher",
		Quote = "Quote",
		Render = "rbxassetid://117474558453942",
		Price = -1,
		Origin = {
			TooltipText = "Slasher:)",
			Icon = "rbxassetid://118316894840539",
		},
		AnimationIDs = {
			HurtAnimation = "rbxassetid://86171516254413",
			IdleAnimation = "rbxassetid://73546288362576",
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
				RenderImage = "rbxassetid://118481213644629",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				Delay = 0.1,
				HitboxSize = Vector3.new(5, 6, 4.5),
				HitboxOffset = CFrame.new(0, 0, -2.5),
				-- Normal Ability path: InputManager → Use() → Behaviour (cooldown enforced)
				PlayUseAnimationOnUse = false, -- we play Normal/Heavy anim inside Behaviour
				DisableOtherAbilitiesOnPerform = false,
				DisableSlashOnPerform = false,
				ExtraInit = SlashExtraInit,
				UseConditions = SlashUseConditions,
				Behaviour = SlashBehaviour,
			}),
			Rebar = Ability.New({
				Name = "Rebar",
				InputName = "FirstAbility",
				Cooldown = 18,
				Duration = RebarWindup + 0.25,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://0",
				UICorner = true,
				Damage = RebarDamage,
				Behaviour = RebarBehaviour,
			}),
			Kick = Ability.New({
				Name = "Kick",
				InputName = "SecondAbility",
				Cooldown = 15,
				Duration = 0.4,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://0",
				UICorner = true,
				Delay = 0.15,
				HitboxSize = KickHitboxSize,
				HitboxOffset = KickHitboxOffset,
				Damage = KickBaseDamage,
				RagdollDuration = KickRagdollDuration,
				Behaviour = KickBehaviour,
			}),
			Chainsaw = Ability.New({
				Name = "Chainsaw",
				InputName = "ThirdAbility",
				Cooldown = 4,
				Duration = 0.3,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://0",
				UICorner = true,
				Behaviour = ChainsawBehaviour,
			}),
		},
	},
})

local NameLabel = '<font color="rgb(0, 255, 0)">' .. Slasher.Config.Name .. "</font>"
Slasher.Config.Description = {
	{ Type = "Separator", Text = "GENERAL INFO" },
	{ Type = "Header", Text = Slasher.Config.Name:upper() },
	{ Type = "Quote", Text = '"' .. Slasher.Config.Quote .. '"' },
	{ Type = "Text", Text = "TODO: lore." },
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "SLASH (MACHETE / CHAINSAW)" },
	{
		Type = "Text",
		Text = NameLabel
			.. " uses standard M1 swings (Heavy after standing still). Chainsaw mode swaps to heavier M1s.",
	},
	{ Type = "Header", Text = "REBAR" },
	{
		Type = "Text",
		Text = "Close range: stab and drag the survivor — throw them with Penetrated, or slam a wall for bonus damage without Penetrated. Far: projectile throw that applies Penetrated.",
	},
	{ Type = "Header", Text = "KICK" },
	{
		Type = "Text",
		Text = "Nighty Night lunge. On a Penetrated survivor: dual finisher. Chainsaw mode: Void Rush into Propel.",
	},
	{ Type = "Header", Text = "CHAINSAW" },
	{
		Type = "Text",
		Text = "Equip the saw, power up M1s, and unlock Chainsaw Rush on Kick.",
	},
}

return Slasher
