--[[
	AntiSaveInstance Security Module
	Prevents SaveInstance exploiters from copying game assets
	Studio-friendly with developer bypass capabilities
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local RunService = game:GetService("RunService")


-- Config for enabling dev bypass and variables 
local Config = {
	-- Enable/Disable the anti-save protection
	Enabled = true,
	
	-- Automatically bypass in Studio mode
	AllowStudio = true,
	
	-- Developer User IDs who can bypass (add your IDs here)
	DeveloperWhitelist = {
		-- Example: 1234567890,
		-- Add trusted developer IDs here
	},
	
	-- Game Owner ID (automatically bypassed)
	GameOwnerId = nil, -- Will be set to game creator on runtime
	
	-- Check interval in seconds
	CheckInterval = 1.5,
	
	-- Maximum crash attempts per detection
	MaxCrashAttempts = 1e5,
	
	-- Log exploitation attempts
	LogAttempts = true,
}
-- detection

local function IsPlayerBypassed(player)
	-- Check if game owner
	if Config.GameOwnerId and player.UserId == Config.GameOwnerId then
		return true
	end
	
	-- Check developer whitelist
	for _, userId in ipairs(Config.DeveloperWhitelist) do
		if player.UserId == userId then
			return true
		end
	end
	
	-- Check if in Studio
	if Config.AllowStudio and RunService:IsStudio() then
		return true
	end
	
	return false
end

local function LogExploitAttempt(player)
	if not Config.LogAttempts then return end
	
	print(string.format(
		"[AntiSave] Exploitation attempt detected from player: %s (ID: %d)",
		player.Name,
		player.UserId
	))
end

local function CrashExploitingClient(player)
	-- Crash the client with invalid HumanoidDescription data
	-- Only executes if player is not bypassed
	
	if IsPlayerBypassed(player) then
		return
	end
	
	LogExploitAttempt(player)
	
	-- Execute crash routine
	for i = 1, Config.MaxCrashAttempts do
		local invalidDescription = Instance.new("HumanoidDescription")
		invalidDescription.FaceAccessory = "0"
		
		pcall(function()
			GuiService:CloseInspectMenu()
			GuiService:InspectPlayerFromHumanoidDescription(
				GuiService,
				invalidDescription,
				string.rep(utf8.char(8203), 1e5)
			)
		end)
	end
end

-- Protection Loop

task.spawn(function()
	-- Set game owner ID on startup
	local gameCreatorId = game.CreatorId
	if gameCreatorId > 0 then
		Config.GameOwnerId = gameCreatorId
	end
	
	-- Main detection loop
	while Config.Enabled do
		task.wait(Config.CheckInterval)
		
		-- Detect UGCValidationService (SaveInstance exploitation indicator)
		if game:FindService("UGCValidationService") then
			-- Check all connected players
			for _, player in ipairs(Players:GetPlayers()) do
				if not IsPlayerBypassed(player) then
					CrashExploitingClient(player)
				end
			end
		end
	end
end)