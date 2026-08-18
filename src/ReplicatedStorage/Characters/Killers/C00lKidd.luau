local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Projectile = require(ReplicatedStorage.Classes.Projectile)
local Types = require(ReplicatedStorage.Classes.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)


-- NOTE ON THIS FILE

-- Slash uses the same input-based system built for Slasher: which swing you
-- get depends on HOW you press M1 (tap while moving -> Normal, tap after
-- standing still -> Heavy, hold through a windup -> Lunge). See Slasher.lua
-- for the full writeup of why this needed its own input handling and
-- cooldown plumbing instead of the engine's default Behaviour()-on-press
-- model — same reasoning applies here.
--
-- Unlike Slasher, C00lKidd keeps Inject: a thrown projectile that buffs M1
-- damage on a confirmed hit. Two things were fixed on it this pass:
--
--   1. GAPPED HITBOX: Hitbox.New's collision loop runs at a fixed ~40
--      ticks/sec, checking a small box at the projectile's *current*
--      position each tick — not one continuous shape along the flight path.
--      If the projectile travels farther between ticks than the box is
--      wide, there are gaps where nothing gets checked at all, which shows
--      up as the hitbox feeling "spaced out". ProjectileSize is now sized
--      to actually cover the distance traveled per tick at the chosen
--      Speed, so consecutive checks overlap instead of leaving gaps.
--      DestroyOnCollision was also turned on so it stops dead the instant
--      it hits world geometry instead of continuing past it — this needs a
--      "CollisionBox" child on the model (see Projectile.luau's
--      DestroyOnCollision loop), so one was added to the placeholder; carry
--      it over when this gets replaced with real art.
--
--   2. NO ACTIVATION ANIMATION: turns out no custom code was needed — the
--      engine already auto-plays a single UseAnimation on every successful
--      ability use (Ability/init.luau, PlayUseAnimationOnUse defaults to
--      true). That field was just left blank before; it's filled in below
--      with a TODO placeholder ID.

local WINDUP_TIME = 0.5            -- how long you must hold M1 before Lunge fires
local THROW_DURATION = 0.60        -- how long the Lunge throw lasts, direction locked at launch
local STANDSTILL_THRESHOLD = 0.4   -- seconds stationary required for a tap to become Heavy
local LUNGE_COOLDOWN = 5           -- separate, longer cooldown so Lunge specifically can't be spammed
local ANIMATION_WINDUP_DELAY = 0.1 -- how long you must hold before the windup anim starts;
                                    -- keeps quick taps from flashing the windup into the m1 swing

local SwingConfigs = {
	Normal = {
		Name = "Normal",
		-- TODO: give this swing its own animation
		AnimationID = "rbxassetid://94664389390904",
		Damage = 20,
		HitboxSize = Vector3.new(5, 6, 4.5),
	},
	Heavy = {
		Name = "Heavy",
		-- TODO: give this swing its own animation
		AnimationID = "rbxassetid://94664389390904",
		Damage = 28,
		-- Same width/height as Normal, just longer reach.
		HitboxSize = Vector3.new(5, 6, 7.5),
		PostEffect = "Endlag",
		EndlagDuration = 1.4,
	},
	Lunge = {
		Name = "Lunge",
		-- TODO: give this swing its own animation
		AnimationID = "rbxassetid://0",
		-- TODO: give the windup its own animation (played while M1 is held,
		-- before the throw fires)
		WindupAnimationID = "rbxassetid://0",
		Damage = 16,
		HitboxSize = Vector3.new(5, 6, 4.5),
		LungeForce = 110,
		LungeDuration = THROW_DURATION,
	},
}
=

local InjectionProjectileTemplate = Workspace:FindFirstChild("InjectionProjectileTemplate")

-- DestroyOnCollision (see Projectile.luau) shapecasts specifically against a
-- child named "CollisionBox" — without one, DestroyOnCollision is a silent
-- no-op. Carry this child over when the placeholder gets replaced with real art.
local InjectionCollisionBox = InjectionProjectileTemplate:Clone()
InjectionCollisionBox.Name = "CollisionBox"
InjectionCollisionBox.Parent = InjectionProjectileTemplate


-- Shared RemoteEvent for Slash — carries which swing a Tap/Hold resolved
-- to. Looked up lazily (see EnsureRemotes below), NOT at module top level:
-- a top-level WaitForChild here yields the instant anything require()s this
-- file, and this module can get required from contexts that can't tolerate
-- a yield (e.g. UI enumerating killers for a shop/select screen).
--============================================================
local Remotes = nil
local RequestAttackRemote = nil

local function EnsureRemotes()
	if RequestAttackRemote then
		return
	end

	if RunService:IsServer() then
		Remotes = ReplicatedStorage:FindFirstChild("C00lKiddRemotes")
		if not Remotes then
			Remotes = Instance.new("Folder")
			Remotes.Name = "C00lKiddRemotes"
			Remotes.Parent = ReplicatedStorage
		end

		RequestAttackRemote = Remotes:FindFirstChild("RequestM1Attack")
		if not RequestAttackRemote then
			RequestAttackRemote = Instance.new("RemoteEvent")
			RequestAttackRemote.Name = "RequestM1Attack"
			RequestAttackRemote.Parent = Remotes
		end
	else
		Remotes = ReplicatedStorage:WaitForChild("C00lKiddRemotes")
		RequestAttackRemote = Remotes:WaitForChild("RequestM1Attack")
	end
end


-- Server: standstill tracking

local function TrackStandstill(self: Types.Ability)
	local Humanoid = self.OwnerProperties.Character:FindFirstChildOfClass("Humanoid")
	if not Humanoid then
		return
	end

	self.StandStillSince = os.clock()
	self:AddConnection(RunService.Heartbeat:Connect(function()
		if Humanoid.MoveDirection.Magnitude > 0.05 then
			self.StandStillSince = os.clock()
		end
	end))
end


-- Server: forward throw. Direction is captured once at launch and held for
-- the whole throw — no steering mid-dash.
local function ApplyThrow(self: Types.Ability, Force: number, Duration: number)
	local HRP = self.OwnerProperties.HRP
	local LaunchLookVector = HRP.CFrame.LookVector
	local StartTime = os.clock()

	local Connection
	Connection = RunService.Heartbeat:Connect(function()
		if not HRP or not HRP.Parent then
			if Connection then
				Connection:Disconnect()
			end
			return
		end

		local Elapsed = os.clock() - StartTime
		if Elapsed >= Duration then
			Connection:Disconnect()
			return
		end

		local CurrentVelocity = HRP.AssemblyLinearVelocity
		HRP.AssemblyLinearVelocity = Vector3.new(LaunchLookVector.X * Force, CurrentVelocity.Y, LaunchLookVector.Z * Force)
	end)

	self:AddConnection(Connection)
end


-- Server: actually run a resolved swing (damage, hitbox, effects)

local function ExecuteSwing(self: Types.Ability, SwingData)
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP

	Sounds.PlaySound(self.UseSound, {Parent = HRP})

	task.delay(self.Delay, function()
		-- Inject buff: while "Injected" is active, every swing hits harder.
		local Damage = SwingData.Damage
		if Character:GetAttribute("Injected") then
			Damage += self.InjectedDamageBonus
		end

		-- Hitbox.New tracks Root.CFrame live for its whole Time window by
		-- default — correct here, since the Lunge is a dash attack that
		-- should hit whoever's in the path as the character travels through
		-- them, not just at the launch point.
		Hitbox.New(self.Owner, {
			CFrameOffset = self.HitboxOffset,
			Size = SwingData.HitboxSize or self.HitboxSize,
			Time = self.Duration,
			Damage = Damage,
			Reason = "Slash Attack ("..SwingData.Name..")",
			ExecuteOnKill = true,
		})

		if SwingData.LungeForce and SwingData.LungeForce > 0 then
			ApplyThrow(self, SwingData.LungeForce, SwingData.LungeDuration or 0.15)
		end
	end)

	if SwingData.PostEffect == "Endlag" then
		Character:SetAttribute("C00lKiddEndlag", true)
		self:AddConnection(task.delay(SwingData.EndlagDuration, function()
			Character:SetAttribute("C00lKiddEndlag", false)
		end))
	end
end

--============================================================
-- Server: resolve what the client asked for ("Tap" or "Hold") into a swing
--============================================================
local function HandleAttackRequest(self: Types.Ability, RequestType: string)
	-- Deliberately NOT checking self:CanUse()/self.OnCooldown here — the
	-- press that led to this resolution already put the ability on cooldown
	-- via the engine's native AttemptUse() pipeline (fires at press-time),
	-- so re-checking it now would always incorrectly fail. Only re-validate
	-- state that can change *during* the windup itself.
	local Character = self.OwnerProperties.Character
	if Character:GetAttribute("C00lKiddEndlag") then
		return -- still locked out from a previous Heavy's endlag
	end

	local Now = os.clock()
	local StillDuration = Now - (self.StandStillSince or Now)

	if RequestType == "Hold" then
		if self.NextLungeAllowedAt and Now < self.NextLungeAllowedAt then
			-- Lunge specifically is still cooling down — fall back to a
			-- normal tap-resolved swing rather than doing nothing.
			if StillDuration >= STANDSTILL_THRESHOLD then
				ExecuteSwing(self, SwingConfigs.Heavy)
			else
				ExecuteSwing(self, SwingConfigs.Normal)
			end
			return
		end

		self.NextLungeAllowedAt = Now + LUNGE_COOLDOWN
		ExecuteSwing(self, SwingConfigs.Lunge)
		return
	end

	if StillDuration >= STANDSTILL_THRESHOLD then
		ExecuteSwing(self, SwingConfigs.Heavy)
	else
		ExecuteSwing(self, SwingConfigs.Normal)
	end
end


-- Client: input handling via the real "Slash" InputAction (Pressed/
-- Released), falling back to raw mouse input if that can't be found.

local function PlayAnimation(self: Types.Ability, SwingData)
	local Track = self.SwingTracks and self.SwingTracks[SwingData.Name]
	if not Track then
		return
	end

	if self.UseAnimationTrack and self.UseAnimationTrack.IsPlaying then
		self.UseAnimationTrack:Stop()
	end

	self.UseAnimationTrack = Track
	Track:Play()
end

local function LoadNonLoopingTrack(Character: Model, AnimationID: string): AnimationTrack?
	local ok, Track = pcall(Utils.Character.LoadAnimationFromID, Character, AnimationID)
	if not ok then
		return nil
	end

	-- Force this regardless of how the underlying Animation asset was
	-- authored, so a looping asset can't keep replaying after the swing
	-- finishes and fight with the walk/idle animation.
	Track.Looped = false
	return Track
end

local function ClientInputInit(self: Types.Ability)
	self.SwingTracks = {}
	for Name, SwingData in SwingConfigs do
		self.SwingTracks[Name] = LoadNonLoopingTrack(self.Owner.Character, SwingData.AnimationID)
	end

	self.WindupTrack = LoadNonLoopingTrack(self.Owner.Character, SwingConfigs.Lunge.WindupAnimationID)

	local HoldStartTime = nil
	local WindupAnimThread = nil
	local WindupThread = nil

	local function OnPress()
		if HoldStartTime then
			return -- already tracking a press
		end
		if not self:CanUse() then
			return -- on cooldown, endlagged, dead, stunned, etc. — ignore the press entirely
		end

		HoldStartTime = os.clock()

		WindupAnimThread = task.delay(ANIMATION_WINDUP_DELAY, function()
			if HoldStartTime and self.WindupTrack then
				self.WindupTrack:Play()
			end
		end)

		WindupThread = task.delay(WINDUP_TIME, function()
			if not HoldStartTime then
				return -- released before windup finished; already handled below
			end

			HoldStartTime = nil
			if self.WindupTrack then
				self.WindupTrack:Stop()
			end
			PlayAnimation(self, SwingConfigs.Lunge)
			RequestAttackRemote:FireServer("Hold")
		end)
	end

	local function OnRelease()
		if not HoldStartTime then
			return -- either nothing tracked, or it already resolved into a Hold
		end

		if WindupAnimThread then
			task.cancel(WindupAnimThread)
			WindupAnimThread = nil
		end
		if WindupThread then
			task.cancel(WindupThread)
			WindupThread = nil
		end
		HoldStartTime = nil
		if self.WindupTrack then
			self.WindupTrack:Stop()
		end

		-- Client-side guess for which local animation to play immediately;
		-- the server independently re-checks standstill time for the actual
		-- damage/effects, so a 1-frame mismatch here is cosmetic only.
		local StillDuration = os.clock() - (self.StandStillSince or os.clock())
		if StillDuration >= STANDSTILL_THRESHOLD then
			PlayAnimation(self, SwingConfigs.Heavy)
		else
			PlayAnimation(self, SwingConfigs.Normal)
		end

		RequestAttackRemote:FireServer("Tap")
	end

	-- Prefer the real "Slash" InputAction (works correctly across keyboard/
	-- gamepad/mobile), but if it can't be found for any reason, fall back to
	-- raw mouse input instead of silently disabling M1 entirely.
	local SlashInputAction = self.OwnerProperties.InputManager:GetInputAction("Default.Slash")
	if SlashInputAction then
		self:AddConnection(SlashInputAction.Pressed:Connect(OnPress))
		self:AddConnection(SlashInputAction.Released:Connect(OnRelease))
	else
		warn("[C00lKidd] Couldn't find the Default.Slash InputAction — falling back to raw mouse input (keyboard only).")
		local UserInputService = game:GetService("UserInputService")
		self:AddConnection(UserInputService.InputBegan:Connect(function(Input, GameProcessed)
			if GameProcessed or Input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			OnPress()
		end))
		self:AddConnection(UserInputService.InputEnded:Connect(function(Input)
			if Input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			OnRelease()
		end))
	end
end


-- Slash ability plumbing

local function SlashExtraInit(self: Types.Ability)
	EnsureRemotes()

	if RunService:IsServer() then
		TrackStandstill(self)
		self:AddConnection(RequestAttackRemote.OnServerEvent:Connect(function(Player, RequestType)
			if Player ~= self.Owner then
				return
			end
			HandleAttackRequest(self, RequestType)
		end))
	else
		-- Client tracks its own standstill time too, purely so the local
		-- animation guess above has something to compare against.
		local Humanoid = self.Owner.Character and self.Owner.Character:FindFirstChildOfClass("Humanoid")
		self.StandStillSince = os.clock()
		if Humanoid then
			self:AddConnection(RunService.Heartbeat:Connect(function()
				if Humanoid.MoveDirection.Magnitude > 0.05 then
					self.StandStillSince = os.clock()
				end
			end))
		end

		ClientInputInit(self)
	end
end

-- Folded into CanUse() (via the engine's own UseConditions hook), so the
-- native press-time gate AND our own client Pressed check both
-- automatically respect Heavy's endlag without a separate manual check.
local function SlashUseConditions(self: Types.Ability): boolean
	return not self.OwnerProperties.Character:GetAttribute("C00lKiddEndlag")
end

local function SlashBehaviour(_self: Types.Ability)
	-- Intentionally empty. The engine calls this automatically on every M1
	-- press purely to run its own cooldown/signal bookkeeping — all the
	-- actual attack logic lives in HandleAttackRequest (server) and
	-- ClientInputInit (client), driven by the Slash InputAction's Pressed/
	-- Released signals instead.
end

-- Inject (4th ability) — thrown projectile, buffs M1 damage on hit
-- Server-only: uses the engine's own Projectile class. The buff is applied
-- from the underlying Hitbox's `Connections.Hit` callback, so it only
-- triggers on a confirmed hit against a survivor, never on a miss.
--
-- NOTE: Projectile.lua currently has a bug where HitboxSettings.HitMultiple
-- always resolves to true regardless of what's passed in (Lua's
-- `x ~= nil and x or true` idiom breaks for x == false). Until that's fixed
-- upstream, the `Triggered` guard below stops the buff/model from
-- triggering more than once per throw, even though the underlying hitbox
-- may still register (and chip-damage) more than one nearby survivor.
local function LaunchInjectionProjectile(self: Types.Ability)
	local HRP = self.OwnerProperties.HRP
	local Character = self.OwnerProperties.Character

	local Triggered = false
	local ProjectileInstance: Types.ProjectileDetails
	ProjectileInstance = Projectile.New({
		SourcePlayer = self.Owner,
		Model = self.ProjectileModel,
		StartingCFrame = HRP.CFrame * self.ProjectileOffset,
		Speed = self.ProjectileSpeed,
		Lifetime = self.ProjectileLifetime,
		ThrowType = "Forward",
		DestroyOnCollision = true,
		HitboxSettings = {
			Size = self.ProjectileSize,
			Shape = Enum.PartType.Ball,
			Damage = self.ProjectileDamage,
			HitMultiple = false, -- see NOTE above: currently a no-op upstream
			Reason = "Script Injection",
			Connections = {
				Hit = function()
					if Triggered then
						return
					end
					Triggered = true

					self:ApplyInjectedBuff(Character)
					if ProjectileInstance then
						ProjectileInstance:Destroy()
					end
				end,
			},
		},
	})
end

local function ApplyInjectedBuff(self: Types.Ability, Character: Model)
	Character:SetAttribute("Injected", true)

	-- Token guards against a refreshed buff getting cut short by an earlier
	-- expiry timer if Inject lands twice in a row.
	local Token = (Character:GetAttribute("InjectedToken") or 0) + 1
	Character:SetAttribute("InjectedToken", Token)

	self:AddConnection(task.delay(self.BuffDuration, function()
		if Character:GetAttribute("InjectedToken") == Token then
			Character:SetAttribute("Injected", false)
		end
	end))
end

local function InjectBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end

	LaunchInjectionProjectile(self)
end

--Character Definition
local C00lKidd: Types.Killer = Character.CreateKiller({
	Config = {
		Name = "C00lKidd",
		Quote = "Quote",
		Render = "rbxassetid://73281933925265",
		Price = -1, -- FREE in shop (Price > 0 is the only case that shows a dollar amount)

		Origin = {
			TooltipText = "C00lkidd:)",
			Icon = "rbxassetid://118316894840539",
		},

		-- TODO: give C00lKidd his own movement animations, or he'll use the engine defaults.
		AnimationIDs = {
			IdleAnimation = "rbxassetid://73546288362576",
			WalkAnimation = "rbxassetid://115621394601470",
			RunAnimation = "rbxassetid://102981744469535",
		},

		-- TeleporterPrefab intentionally omitted — DataAnchor ability removed until
		-- a teleport prop object is added as a child of this script.
	},

	GameplayConfig = {
		Abilities = {

			--Slash (input-based: tap while moving = Normal, tap after standing
			--still = Heavy, hold through a windup = Lunge — see the note block
			--at the top of the file)
			Slash = Ability.New({
				Name = "Slash",
				InputName = "Slash",
				Cooldown = 2,
				Duration = 0.4,
				RenderImage = "rbxassetid://11218451110",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				Delay = 0.1,
				HitboxSize = Vector3.new(5, 6, 4.5),
				HitboxOffset = CFrame.new(0, 0, -2.5),
				PlayUseAnimationOnUse = false, -- animations are now played manually, see ClientInputInit

				InjectedDamageBonus = 8, -- flat bonus per swing while "Injected" is active (e.g. 20 -> 28 on Normal)
				ExtraInit = SlashExtraInit,
				UseConditions = SlashUseConditions,
				Behaviour = SlashBehaviour,
			}),

			-- Inject: throws "Script Injection", a small projectile. On a confirmed
			-- hit against a survivor, C00lKidd gets buffed M1 damage for a limited
			-- time. NOTE: CallbackPing/Overcharge were removed as placeholders —
			-- two more abilities are planned for later.
			Inject = Ability.New({
				Name = "Inject",
				InputName = "FourthAbility",
				Cooldown = 20,
				Duration = 0.5,
				UseSound = "rbxassetid://0", -- TODO
				-- TODO: swap for the real throw animation once it exists.
				-- PlayUseAnimationOnUse defaults to true, so as soon as this
				-- has a real ID, it'll auto-play on every use with no other
				-- code changes needed.
				UseAnimation = "rbxassetid://0",

				ProjectileModel = InjectionProjectileTemplate,
				-- Reverted the speed/lifetime change from last pass — that
				-- targeted the wrong thing. Hitbox.New's collision loop runs
				-- at a fixed ~40 ticks/sec (see Hitbox.luau's
				-- `task.wait(1/40)`), checking a small box at the
				-- projectile's *current* position each tick. Doubling Speed
				-- to 180 meant the projectile covered 4.5 studs between
				-- checks — with a 1x1x1 box, that left ~3.5 stud gaps where
				-- nothing was checked at all, which is what showed up as
				-- hitboxes "spaced out from each other". Back to the
				-- original 90 studs/sec (2.25 studs traveled per tick), and
				-- ProjectileSize increased so each check box actually
				-- overlaps the next one instead of leaving gaps — sized a
				-- bit larger along Z (the travel axis) for margin.
				ProjectileSpeed = 90, -- studs/sec
				ProjectileLifetime = 0.7, -- seconds of flight (~63 studs of range at this speed)
				ProjectileSize = Vector3.new(2, 2, 3),
				ProjectileOffset = CFrame.new(0, 1, -2),
				ProjectileDamage = 5, -- small chip damage on top of the buff; set to 0 for buff-only
				BuffDuration = 12, -- seconds "Injected" stays active after a hit

				ApplyInjectedBuff = ApplyInjectedBuff,
				Behaviour = InjectBehaviour,
			}),
		},
	},
})

--Description (plain Type/Text array — this is the real schema `Types.luau` and
--every other killer file use; there's no DescriptionBuilder module in the
--actual engine source, so building it any other way will error on require)
local NameLabel = '<font color="rgb(0, 255, 0)">' .. C00lKidd.Config.Name .. "</font>"

C00lKidd.Config.Description = {
	{
		Type = "Separator",
		Text = "GENERAL INFO",
	},
	{
		Type = "Header",
		Text = C00lKidd.Config.Name:upper(),
	},
	{
		Type = "Quote",
		Text = '"' .. C00lKidd.Config.Quote .. '"',
	},
	{
		Type = "Text",
		Text = "TODO: write C00lKidd's lore paragraph here.",
	},
	{
		Type = "Separator",
		Text = "ABILITIES",
	},
	{
		Type = "Header",
		Text = C00lKidd.GameplayConfig.Abilities.Slash.Name:upper(),
	},
	{
		Type = "Text",
		Text = NameLabel.." attacks differently depending on how you use M1: tapping while moving deals "..
			tostring(SwingConfigs.Normal.Damage).." damage, tapping after standing still for a moment deals "..
			tostring(SwingConfigs.Heavy.Damage).." damage but leaves him briefly unable to attack again, and holding "..
			"M1 winds up a forward throw dealing "..tostring(SwingConfigs.Lunge.Damage)..
			" damage in a straight line.",
		Image = "rbxassetid://9759886280",
	},
	{
		Type = "Header",
		Text = C00lKidd.GameplayConfig.Abilities.Inject.Name:upper(),
	},
	{
		Type = "Text",
		Text = NameLabel.." throws a Script Injection at a survivor. On a hit, his systems overclock: his slashes hit "..
			tostring(C00lKidd.GameplayConfig.Abilities.Slash.InjectedDamageBonus).." harder for "..
			tostring(C00lKidd.GameplayConfig.Abilities.Inject.BuffDuration).." seconds.",
	},
}

return C00lKidd