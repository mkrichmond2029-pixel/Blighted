--!strict
-- ReplicatedStorage/Effects/Speed.luau

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Types = require(ReplicatedStorage.Classes.Types)
local Effect = require(ReplicatedStorage.Classes.Effect)

local PlayerSpeedManager = RunService:IsServer()
	and require(ServerScriptService.Managers.PlayerManager.PlayerSpeedManager)
	or nil

local FactorName = "EnergizedEffect"

return Effect.New({
	Name = "Energized",
	Description = "Slight speed boost with more stamina drain",

	ApplyEffect = function(_own: Types.Effect, level: number, char: Model)
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end

		level = math.max(level or 1, 1)

		if RunService:IsServer() then
			PlayerSpeedManager.AddSpeedFactor(player, FactorName, 1 + 0.26 * level)

			-- StaminaDrain is a NumberValue under PlayerAttributes (no AddStaminaDrain API)
			local attrs = char:FindFirstChild("PlayerAttributes")
			local drain = attrs and attrs:FindFirstChild("StaminaDrain")
			if drain and drain:IsA("NumberValue") then
				if drain:GetAttribute("SpeedEffectBase") == nil then
					drain:SetAttribute("SpeedEffectBase", drain.Value)
				end
				local base = drain:GetAttribute("SpeedEffectBase") :: number
				drain.Value = base * (1 + 0.1 * level)
			end
			return
		end

		-- Client FOV (guard missing scripts)
		local scripts = char:FindFirstChild("PlayerAttributeScripts")
		local fovModule = scripts and scripts:FindFirstChild("FOVManager")
		if fovModule and fovModule:IsA("ModuleScript") then
			local ok, fovManager = pcall(require, fovModule)
			if ok and fovManager and fovManager.AddFOVFactor then
				fovManager:AddFOVFactor(FactorName, math.clamp(1 + 0.07 * level, 1, 1.5))
			end
		end
	end,

	RemoveEffect = function(_own: Types.Effect, char: Model)
		local player = Players:GetPlayerFromCharacter(char)
		if not player then
			return
		end

		if RunService:IsServer() then
			PlayerSpeedManager.RemoveSpeedFactor(player, FactorName)

			local attrs = char:FindFirstChild("PlayerAttributes")
			local drain = attrs and attrs:FindFirstChild("StaminaDrain")
			if drain and drain:IsA("NumberValue") then
				local base = drain:GetAttribute("SpeedEffectBase")
				if typeof(base) == "number" then
					drain.Value = base
					drain:SetAttribute("SpeedEffectBase", nil)
				end
			end
			return
		end

		local scripts = char:FindFirstChild("PlayerAttributeScripts")
		local fovModule = scripts and scripts:FindFirstChild("FOVManager")
		if fovModule and fovModule:IsA("ModuleScript") then
			local ok, fovManager = pcall(require, fovModule)
			if ok and fovManager and fovManager.RemoveFOVFactor then
				fovManager:RemoveFOVFactor(FactorName)
			end
		end
	end,
})