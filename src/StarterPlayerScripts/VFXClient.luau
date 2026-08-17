--[[
	VFXClient.luau — lightweight polish only
	Place: StarterPlayerScripts/VFXClient.luau

	Server already replicates particles. Client only:
	  - plays sounds for nearby events
	  - optional extra Emit if quality is High
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Debris = game:GetService("Debris")
local SoundService = game:GetService("SoundService")

local Network = require(ReplicatedStorage.Modules.Network)
local Presets = require(ReplicatedStorage.Modules.VFX.Presets)

local Sounds = nil
pcall(function()
	Sounds = require(ReplicatedStorage.Modules.Sounds)
end)

local LocalPlayer = Players.LocalPlayer
local VFXClient = {}

local function qualityScale(): number
	local q = workspace:GetAttribute("VFXQuality")
	if q == "Off" then
		return 0
	elseif q == "Low" then
		return 0
	elseif q == "Medium" then
		return 0.35
	end
	return 0.75 -- High: mild extra emit only
end

local function playSound(soundId: string?)
	if not soundId or soundId == "" or soundId == "rbxassetid://0" then
		return
	end
	if Sounds and Sounds.PlaySound then
		Sounds.PlaySound(soundId, { Volume = 0.65 })
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = soundId
	s.Volume = 0.65
	s.Parent = SoundService
	s:Play()
	Debris:AddItem(s, 2.5)
end

function VFXClient.PlayLocal(presetName: string, opts: any?)
	if qualityScale() <= 0 then
		return
	end
	opts = opts or {}
	local preset = Presets.Get(presetName)
	playSound(opts.Sound or (preset and preset.Sound))
end

function VFXClient:Init()
	Network:SetConnection("VFXPlay", "RemoteEvent", function(payload: any)
		if typeof(payload) ~= "table" then
			return
		end
		local scale = qualityScale()
		if scale <= 0 then
			return
		end

		playSound(payload.Sound)

		-- Extra emit only on High/Medium; particles already exist from server
		if scale < 0.5 then
			return
		end

		local folder = workspace:FindFirstChild("TempObjectFolders")
		local vfxFolder = (folder and folder:FindFirstChild("VFX")) or workspace:FindFirstChild("VFX")
		if not vfxFolder then
			return
		end

		local id = payload.Id
		for _, child in vfxFolder:GetChildren() do
			if child:GetAttribute("VFXId") == id then
				local extra = math.floor((payload.EmitCount or 8) * scale * 0.35)
				if extra > 0 then
					for _, d in child:GetDescendants() do
						if d:IsA("ParticleEmitter") then
							d:Emit(extra)
						end
					end
				end
				break
			end
		end
	end)
end

return VFXClient
