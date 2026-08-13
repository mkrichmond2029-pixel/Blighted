--[[
	GameModeManager.luau

	Picks the next mode before each round.
	- Normal most of the time
	- Special mode every SpecialEveryMin..SPECIAL_EVERY_MAX rounds
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModeManager = {
	RoundsSinceSpecial = 0,
	DefaultKillersAllowed = 1,
	DefaultRoundTime = nil,
	DefaultLMSTime = nil,
	CurrentMode = nil :: any,
	History = {} :: { string },

	-- Special appears after this many normal-ish rounds (inclusive range)
	SpecialEveryMin = 2,
	SpecialEveryMax = 3,
}

export type GameMode = {
	Id: string,
	DisplayName: string,
	Description: string?,
	IsSpecial: boolean?,

	-- Optional overrides applied at round start
	RoundTime: number?, -- seconds; nil = use TimeManager default
	LMSTime: number?,
	KillersAllowed: number?, -- nil = keep workspace attribute
	CanSpawnKiller: boolean?, -- nil = true
	CanInitLMS: boolean?,

	-- Hooks (all optional)
	OnSelected: ((self: GameMode) -> ())?,
	OnRoundStart: ((self: GameMode, context: any) -> ())?,
	OnRoundEnd: ((self: GameMode, winner: string) -> ())?,
	ModifySetup: ((self: GameMode, player: Player, isKiller: boolean) -> ())?,
}

local Modes: { [string]: GameMode } = {}
local SpecialPool: { string } = {}
local NormalId = "Normal"

function GameModeManager.Register(mode: GameMode)
	assert(mode.Id and mode.DisplayName, "GameMode needs Id and DisplayName")
	Modes[mode.Id] = mode
	if mode.IsSpecial then
		if not table.find(SpecialPool, mode.Id) then
			table.insert(SpecialPool, mode.Id)
		end
	end
end

function GameModeManager.Get(id: string): GameMode?
	return Modes[id]
end

function GameModeManager.GetCurrent(): GameMode?
	return GameModeManager.CurrentMode
end

local function pickSpecial(): GameMode
	if #SpecialPool == 0 then
		return Modes[NormalId]
	end
	-- Avoid repeating the last special when possible
	local last = GameModeManager.History[#GameModeManager.History]
	local pool = {}
	for _, id in SpecialPool do
		if id ~= last or #SpecialPool == 1 then
			table.insert(pool, id)
		end
	end
	local id = pool[math.random(1, #pool)]
	return Modes[id]
end

--- Call once at the start of StartRound (before spawning players).
function GameModeManager.SelectNextMode(): GameMode
	GameModeManager.RoundsSinceSpecial += 1

	local threshold = math.random(GameModeManager.SpecialEveryMin, GameModeManager.SPECIAL_EVERY_MAX)
	local useSpecial = GameModeManager.RoundsSinceSpecial >= threshold and #SpecialPool > 0

	local mode: GameMode
	if useSpecial then
		mode = pickSpecial()
		GameModeManager.RoundsSinceSpecial = 0
	else
		mode = Modes[NormalId] or {
			Id = "Normal",
			DisplayName = "Normal",
			IsSpecial = false,
		}
	end

	GameModeManager.CurrentMode = mode
	table.insert(GameModeManager.History, mode.Id)
	if #GameModeManager.History > 20 then
		table.remove(GameModeManager.History, 1)
	end

	if mode.OnSelected then
		mode:OnSelected()
	end

	-- Replicate for UI / clients
	local info = ReplicatedStorage:FindFirstChild("RoundInfo")
	if info then
		local modeValue = info:FindFirstChild("GameMode")
		if not modeValue then
			modeValue = Instance.new("StringValue")
			modeValue.Name = "GameMode"
			modeValue.Parent = info
		end
		modeValue.Value = mode.Id

		local display = info:FindFirstChild("GameModeDisplay")
		if not display then
			display = Instance.new("StringValue")
			display.Name = "GameModeDisplay"
			display.Parent = info
		end
		display.Value = mode.DisplayName
	end

	return mode
end

--- Apply mode overrides (time, killer count, flags) onto RoundManager + TimeManager.
function GameModeManager.ApplyToRound(RoundManager: any, TimeManager: any)
	local mode = GameModeManager.CurrentMode
	if not mode then
		return
	end

	if mode.CanSpawnKiller ~= nil then
		RoundManager.CanSpawnKiller = mode.CanSpawnKiller
	else
		RoundManager.CanSpawnKiller = true
	end

	if mode.CanInitLMS ~= nil then
		RoundManager.CanInitLMS = mode.CanInitLMS
	else
		RoundManager.CanInitLMS = true
	end

	if mode.KillersAllowed ~= nil then
		workspace:SetAttribute("KillersAllowed", mode.KillersAllowed)
	end

	if mode.RoundTime and TimeManager and TimeManager.Config then
		TimeManager.Config.RoundTime = mode.RoundTime
	end
	if mode.LMSTime and TimeManager and TimeManager.Config then
		TimeManager.Config.LastManStandingTime = mode.LMSTime
	end
end


function GameModeManager.CaptureDefaults(TimeManager: any)
	GameModeManager.DefaultKillersAllowed = workspace:GetAttribute("KillersAllowed") or 1
	if TimeManager and TimeManager.Config then
		GameModeManager.DefaultRoundTime = TimeManager.Config.RoundTime
		GameModeManager.DefaultLMSTime = TimeManager.Config.LastManStandingTime
	end
end

function GameModeManager.RestoreDefaults(TimeManager: any)
	workspace:SetAttribute("KillersAllowed", GameModeManager.DefaultKillersAllowed or 1)
	if TimeManager and TimeManager.Config then
		if GameModeManager.DefaultRoundTime then
			TimeManager.Config.RoundTime = GameModeManager.DefaultRoundTime
		end
		if GameModeManager.DefaultLMSTime then
			TimeManager.Config.LastManStandingTime = GameModeManager.DefaultLMSTime
		end
	end
end

function GameModeManager:Init()
	-- Built-in normal mode
	GameModeManager.Register({
		Id = "Normal",
		DisplayName = "Classic",
		Description = "Standard asymmetrical round.",
		IsSpecial = false,
	})
end

return GameModeManager
