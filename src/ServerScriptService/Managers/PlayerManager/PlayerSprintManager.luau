--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local PlayerSpeedManager = require(script.Parent.PlayerSpeedManager)
local Types = require(ReplicatedStorage.Classes.Types)
local Network = require(ReplicatedStorage.Modules.Network)
local Utils = require(ReplicatedStorage.Modules.Utils)

local FactorName = "Sprint"

local PlayerSprintManager = {
	ManagedPlayers = {} :: {[Player]: SprintData},
}

type SprintData = {
	AttemptingSprint: boolean,
	PressingSprintWhileRecovering: boolean,
	Recovering: boolean,
	Exhausted: boolean,
	Stamina: number,
	TweenSpeed: boolean,
	SpeedApplied: boolean,
	SprintMultiplier: number,
	CanGainStamina: boolean,
	RecoverDelay: number,
	RecoverExhaustionDelay: number,
	MaxStamina: NumberValue?,
	StaminaRegenRate: NumberValue?,
	StaminaDrainRate: NumberValue?,
	RecoveryThread: thread?,
	StaminaDrainFactors: {[string]: number},
	_Stop: (self: SprintData, stopExhausted: boolean) -> (),
	_DrainStamina: (self: SprintData, delta: number) -> (),
	_GainStaminaLegally: (self: SprintData, delta: number) -> (),
	_GetEffectiveDrainMultiplier: (self: SprintData) -> number,
}

local SprintModule = {}
SprintModule.__index = SprintModule

-- Public factor API (mirrors PlayerSpeedManager style)


function PlayerSprintManager.AddStaminaDrain(player: Player, name: string, multiplier: number)
	local data = PlayerSprintManager.ManagedPlayers[player]
	if not data then
		return
	end
	data.StaminaDrainFactors[name] = multiplier
end

function PlayerSprintManager.RemoveStaminaDrain(player: Player, name: string)
	local data = PlayerSprintManager.ManagedPlayers[player]
	if not data then
		return
	end
	data.StaminaDrainFactors[name] = nil
end

function PlayerSprintManager.SetStaminaDrain(player: Player, name: string, multiplier: number)
	PlayerSprintManager.AddStaminaDrain(player, name, multiplier)
end


-- Init

function PlayerSprintManager:Init()
	Utils.Player.ObservePlayers(function(player: Player)
		Utils.Character.ObserveCharacter(player, function(character: Model, characterJanitor: Types.Janitor)
			local managed: SprintData = setmetatable({
				AttemptingSprint = false,
				PressingSprintWhileRecovering = false,
				Recovering = false,
				Exhausted = false,
				Stamina = 100,
				TweenSpeed = true,
				SpeedApplied = false,
				SprintMultiplier = 2.66666,
				CanGainStamina = true,
				RecoverDelay = 0.75,
				RecoverExhaustionDelay = 2,
				StaminaDrainFactors = {
					[FactorName] = 1, -- base drain
				},
			}, SprintModule)

			local humanoidRootPart = Utils.Character.GetRootPart(character)
			local humanoid = character:FindFirstChildWhichIsA("Humanoid")
			local role = character:FindFirstChild("Role") :: StringValue?

			local playerAttributes = character:FindFirstChild("PlayerAttributes")
			if not playerAttributes then
				warn(`[PlayerSprintManager] No PlayerAttributes on {player.Name}`)
				return
			end

			local sprintValue = playerAttributes:FindFirstChild("Sprinting") :: BoolValue?
			local staminaValue = playerAttributes:FindFirstChild("Stamina") :: NumberValue?

			managed.MaxStamina = playerAttributes:FindFirstChild("MaxStamina") :: NumberValue?
			managed.StaminaRegenRate = playerAttributes:FindFirstChild("StaminaGain") :: NumberValue?
			managed.StaminaDrainRate = playerAttributes:FindFirstChild("StaminaDrain") :: NumberValue?

			-- Base speed factor
			PlayerSpeedManager.AddSpeedFactor(player, FactorName, 1)

			characterJanitor:Add(RunService.PreSimulation:Connect(function(delta: number)
				if not humanoidRootPart or not humanoid or humanoid.Health <= 0 then
					return
				end

				local directionOfMovement = humanoidRootPart.CFrame:VectorToObjectSpace(humanoidRootPart.AssemblyLinearVelocity)
				local humanoidDirection = Vector3.new(humanoid.MoveDirection.X, 0, humanoid.MoveDirection.Z)
				local moving = not humanoidRootPart.Anchored
					and humanoid.WalkSpeed > 0
					and directionOfMovement.Magnitude > 0.1
					and humanoidDirection.Magnitude > 0

				local speedData = PlayerSpeedManager.ManagedPlayers[player]
				local canSprint = speedData
					and speedData.LastMultiplier >= 0.65
					and speedData.CanSprint

				if moving
					and managed.AttemptingSprint
					and not managed.Exhausted
					and not managed.PressingSprintWhileRecovering
					and canSprint
				then
					managed.SpeedApplied = true

					if managed.RecoveryThread then
						task.cancel(managed.RecoveryThread)
						managed.RecoveryThread = nil
					end

					-- Killers only drain stamina when a Survivor is nearby
					if role and role.Value == "Killer" then
						local foundSurvivor = false
						for _, otherChar in workspace.Players:GetChildren() do
							if otherChar == character then
								continue
							end
							local otherRole = otherChar:FindFirstChild("Role")
							if not otherRole or otherRole.Value ~= "Survivor" then
								continue
							end
							local otherHRP = Utils.Character.GetRootPart(otherChar)
							if otherHRP and (otherHRP.Position - humanoidRootPart.Position).Magnitude <= 110 then
								foundSurvivor = true
								break
							end
						end

						if foundSurvivor then
							managed:_DrainStamina(delta)
						elseif managed.CanGainStamina then
							managed:_GainStaminaLegally(delta)
						end
					else
						managed:_DrainStamina(delta)
					end

					if managed.Stamina <= 0 then
						managed:_Stop(true)
					end
				else
					if managed.SpeedApplied then
						managed:_Stop(false)
						managed.SpeedApplied = false
					end

					if managed.CanGainStamina then
						managed:_GainStaminaLegally(delta)
					end
				end

				-- Apply speed factor (tweened or instant)
				if speedData then
					local target = managed.SpeedApplied and managed.SprintMultiplier or 1
					if managed.TweenSpeed then
						speedData.Factors[FactorName] = math.lerp(
							speedData.Factors[FactorName] or 1,
							target,
							delta * 5.5
						)
					else
						speedData.Factors[FactorName] = target
					end
				end

				-- Sync replicated values
				if staminaValue and staminaValue.Value ~= managed.Stamina then
					staminaValue.Value = managed.Stamina
				end
				if sprintValue and sprintValue.Value ~= managed.SpeedApplied then
					sprintValue.Value = managed.SpeedApplied
				end
			end))

			characterJanitor:Add(Network:SetConnection("ChangeSprintState", "REMOTE_EVENT", function(plr: Player, pressed: boolean)
				if plr ~= player then
					return
				end
				managed.AttemptingSprint = pressed
				managed.PressingSprintWhileRecovering = managed.Exhausted and pressed
			end))

			characterJanitor:Add(function()
				if managed.RecoveryThread then
					task.cancel(managed.RecoveryThread)
				end
				PlayerSprintManager.ManagedPlayers[player] = nil
			end, true)

			PlayerSprintManager.ManagedPlayers[player] = managed
		end)
	end)
end


-- SprintData methods
function SprintModule._GetEffectiveDrainMultiplier(self: SprintData): number
	local mult = 1
	for _, factor in self.StaminaDrainFactors do
		mult *= factor
	end
	return mult
end

function SprintModule._Stop(self: SprintData, stopExhausted: boolean)
	self.Recovering = true

	if stopExhausted then
		self.Stamina = 0
		self.PressingSprintWhileRecovering = true
		self.Exhausted = true
		task.delay(self.RecoverExhaustionDelay, function()
			self.Recovering = false
			self.Exhausted = false
		end)
	else
		self.RecoveryThread = task.delay(self.RecoverDelay, function()
			self.Recovering = false
			self.RecoveryThread = nil
		end)
	end
end

function SprintModule._DrainStamina(self: SprintData, delta: number)
	if not self.StaminaDrainRate then
		return
	end
	local effective = self.StaminaDrainRate.Value * self:_GetEffectiveDrainMultiplier()
	self.Stamina -= effective * delta
end

function SprintModule._GainStaminaLegally(self: SprintData, delta: number)
	if self.Recovering or self.Exhausted then
		return
	end
	if not self.StaminaRegenRate or not self.MaxStamina then
		return
	end
	if self.Stamina >= self.MaxStamina.Value then
		return
	end
	self.Stamina = math.clamp(
		self.Stamina + self.StaminaRegenRate.Value * delta,
		0,
		self.MaxStamina.Value
	)
end

return PlayerSprintManager