local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)


local WINDUP_TIME = 0.5          -- how long you must hold M1 before Lunge fires
local THROW_DURATION = 0.60      -- how long the throw lasts, direction locked at launch
local STANDSTILL_THRESHOLD = 0.4 -- seconds stationary required for a tap to become Heavy
local LUNGE_COOLDOWN = 5         -- separate, longer cooldown so Lunge specifically can't be spammed
local ANIMATION_WINDUP_DELAY = 0.1 -- how long you must hold before the windup anim starts;
-- keeps quick taps from flashing the windup into the m1 swing

local SwingConfigs = {
	Normal = {
		Name = "Normal",
		-- TODO: give this swing its own animation
		AnimationID = "rbxassetid://0",
		Damage = 20,
		HitboxSize = Vector3.new(5, 6, 4.5),
	},
	Heavy = {
		Name = "Heavy",
		-- TODO: give this swing its own animation
		AnimationID = "rbxassetid://0",
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

--============================================================
-- Shared RemoteEvent — carries which swing a Tap/Hold resolved to. Looked
-- up lazily (see EnsureRemotes below), NOT at module top level: a top-level
-- WaitForChild here yields the instant anything require()s this file, and
-- this module can get required from contexts that can't tolerate a yield
-- (e.g. UI enumerating killers for a shop/select screen).
--============================================================
local Remotes = nil
local RequestAttackRemote = nil

local function EnsureRemotes()
	if RequestAttackRemote then
		return
	end

	if RunService:IsServer() then
		Remotes = ReplicatedStorage:FindFirstChild("OneXOneXOneXOneRemotes")
		if not Remotes then
			Remotes = Instance.new("Folder")
			Remotes.Name = "OneXOneXOneXOneRemotes"
			Remotes.Parent = ReplicatedStorage
		end

		RequestAttackRemote = Remotes:FindFirstChild("RequestM1Attack")
		if not RequestAttackRemote then
			RequestAttackRemote = Instance.new("RemoteEvent")
			RequestAttackRemote.Name = "RequestM1Attack"
			RequestAttackRemote.Parent = Remotes
		end
	else
		Remotes = ReplicatedStorage:WaitForChild("OneXOneXOneXOneRemotes")
		RequestAttackRemote = Remotes:WaitForChild("RequestM1Attack")
	end
end

--============================================================
-- Server: standstill tracking
--============================================================
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

--============================================================
-- Server: forward throw. Direction is captured once at launch and held for
-- the whole throw — no steering mid-dash.
--============================================================
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

--============================================================
-- Server: actually run a resolved swing (damage, hitbox, effects)
--============================================================
local function ExecuteSwing(self: Types.Ability, SwingData)
	local Character = self.OwnerProperties.Character
	local HRP = self.OwnerProperties.HRP

	Sounds.PlaySound(self.UseSound, {Parent = HRP})

	task.delay(self.Delay, function()
		-- Hitbox.New tracks Root.CFrame live for its whole Time window by
		-- default — correct here, since the Lunge is a dash attack that
		-- should hit whoever's in the path as the character travels through
		-- them, not just at the launch point.
		Hitbox.New(self.Owner, {
			CFrameOffset = self.HitboxOffset,
			Size = SwingData.HitboxSize or self.HitboxSize,
			Time = self.Duration,
			Damage = SwingData.Damage,
			Reason = "Slash Attack ("..SwingData.Name..")",
			ExecuteOnKill = true,
		})

		if SwingData.LungeForce and SwingData.LungeForce > 0 then
			ApplyThrow(self, SwingData.LungeForce, SwingData.LungeDuration or 0.15)
		end
	end)

	if SwingData.PostEffect == "Endlag" then
		Character:SetAttribute("OneXOneXOneXOneEndlag", true)
		self:AddConnection(task.delay(SwingData.EndlagDuration, function()
			Character:SetAttribute("OneXOneXOneXOneEndlag", false)
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
	if Character:GetAttribute("OneXOneXOneXOneEndlag") then
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

--============================================================
-- Client: input handling via the real "Slash" InputAction (Pressed/
-- Released), falling back to raw mouse input if that can't be found.
--============================================================
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
		warn("[1x1x1x1] Couldn't find the Default.Slash InputAction — falling back to raw mouse input (keyboard only).")
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

--============================================================
-- Ability plumbing
--============================================================
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
	return not self.OwnerProperties.Character:GetAttribute("OneXOneXOneXOneEndlag")
end

local function SlashBehaviour(_self: Types.Ability)
	-- Intentionally empty. The engine calls this automatically on every M1
	-- press (see Ability/init.luau) purely to run its own cooldown/signal
	-- bookkeeping — all the actual attack logic lives in HandleAttackRequest
	-- (server) and ClientInputInit (client), driven by the Slash
	-- InputAction's Pressed/Released signals instead.
end

--Character Definition
local OneXOneXOneXOne: Types.Killer = Character.CreateKiller({
	Config = {
		Name = "1x1x1x1",
		-- TODO: real quote/lore
		Quote = "Quote",
		-- TODO: real render asset
		Render = "rbxassetid://0",
		Price = -1, -- FREE in shop (Price > 0 is the only case that shows a dollar amount)

		Origin = {
			-- TODO: real tooltip text
			TooltipText = "1x1x1x1",
			-- TODO: real icon asset
			Icon = "rbxassetid://0",
		},

		-- TODO: give 1x1x1x1 his own movement animations, or he'll use the engine defaults.
		AnimationIDs = {
			IdleAnimation = "rbxassetid://73546288362576",
			WalkAnimation = "rbxassetid://115621394601470",
			RunAnimation = "rbxassetid://102981744469535",
		},
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
				-- TODO: real render image asset
				RenderImage = "rbxassetid://100297812204834",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				Delay = 0.1,
				HitboxSize = Vector3.new(5, 6, 4.5),
				HitboxOffset = CFrame.new(0, 0, -2.5),
				PlayUseAnimationOnUse = false, -- animations are now played manually, see ClientInputInit

				ExtraInit = SlashExtraInit,
				UseConditions = SlashUseConditions,
				Behaviour = SlashBehaviour,
			}),
		},
	},
})

--Description (plain Type/Text array — this is the real schema `Types.luau` and
--every other killer file use; there's no DescriptionBuilder module in the
--actual engine source, so building it any other way will error on require)
local NameLabel = '<font color="rgb(0, 255, 0)">' .. OneXOneXOneXOne.Config.Name .. "</font>"

OneXOneXOneXOne.Config.Description = {
	{
		Type = "Separator",
		Text = "GENERAL INFO",
	},
	{
		Type = "Header",
		Text = OneXOneXOneXOne.Config.Name:upper(),
	},
	{
		Type = "Quote",
		Text = '"' .. OneXOneXOneXOne.Config.Quote .. '"',
	},
	{
		Type = "Text",
		Text = "TODO: write 1x1x1x1's lore paragraph here.",
	},
	{
		Type = "Separator",
		Text = "ABILITIES",
	},
	{
		Type = "Header",
		Text = OneXOneXOneXOne.GameplayConfig.Abilities.Slash.Name:upper(),
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
}

return OneXOneXOneXOne