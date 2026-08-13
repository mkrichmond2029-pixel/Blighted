local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GameModeManager = require(ServerScriptService.Managers.GameModeManager)
local MapManager = require(ServerScriptService.Managers.MapManager)
local ServerCharacterManager = require(ServerScriptService.Managers.ServerCharacterManager)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Network = require(ReplicatedStorage.Modules.Network)
local Sounds = require(ReplicatedStorage.Modules.Sounds)
local TimeManager = require(ServerScriptService.Managers.TimeManager)
local CommonFunctions = require(ServerScriptService.System.CommonFunctions)

local RoundState: StringValue = ReplicatedStorage.RoundInfo.CurrentState
local PlayersRemaining: Folder = ReplicatedStorage.RoundInfo.PlayersRemaining

local RoundManager = {
	Utils = {},
	Callables = {},
	Threads = {},
	PlayerConnections = {},
	CurrentRound = {
		PlayersAccepted = {},
		PlayersRemaining = {},
		Killers = {},
		KillerIndex = {},
		StartedLMS = false,
		ModeId = "Normal",
	},
	StopLoop = false,
	CanSpawnKiller = true,
	CanInitLMS = true,
}

function RoundManager:Init()
	RoundManager.CurrentRound.Killers = {}

	GameModeManager:Init()
	GameModeManager.CaptureDefaults(TimeManager)

	GameModeManager.Register({
		Id = "DoubleTrouble",
		DisplayName = "Double Trouble",
		IsSpecial = true,
		KillersAllowed = 2,
		RoundTime = 240,
	})

	GameModeManager.Register({
		Id = "Dienation",
		DisplayName = "Dienation",
		IsSpecial = true,
		KillersAllowed = 9,
		RoundTime = 240,
	})

	TimeManager.OnTimerEnd = function()
		RoundManager.StartRound()
	end
end

function RoundManager.StartRound()
	local LoadedPlayers = Utils.Player.GetLoadedPlayers(false)
	Utils.Player.Fade(LoadedPlayers, "In", 0.6, true)

	-- Pick Classic or a special (every 2–3 rounds)
	local mode = GameModeManager.SelectNextMode()
	GameModeManager.ApplyToRound(RoundManager, TimeManager)
	RoundManager.CurrentRound.ModeId = mode.Id
	Utils.Misc.Print("[GameMode]", mode.DisplayName)

	RoundManager.CurrentRound.PlayersAccepted = Utils.Type.ShuffleTable(LoadedPlayers)

	local PlayersOrderedByMalice = RoundManager.CurrentRound.PlayersAccepted
	table.sort(PlayersOrderedByMalice, function(a, b)
		return Utils.PlayerData.GetPlayerStat(a, "General.Malice") > Utils.PlayerData.GetPlayerStat(b, "General.Malice")
	end)

	MapManager.GetRandomMap()

	-- Never request more killers than players in the server
	local killersWanted = workspace:GetAttribute("KillersAllowed") or 1
	local killersToSpawn = math.clamp(killersWanted, 0, math.max(#PlayersOrderedByMalice, 0))
	if not RoundManager.CanSpawnKiller then
		killersToSpawn = 0
	end
	workspace:SetAttribute("KillersAllowed", math.max(killersToSpawn, 1)) -- keep attr sensible for other systems; loop uses killersToSpawn

	RoundManager.CurrentRound.Killers = {}
	RoundManager.CurrentRound.KillerIndex = {}

	for killerIndex = 1, killersToSpawn do
		local killerPlayer = PlayersOrderedByMalice[killerIndex]
		if not killerPlayer then
			break
		end
		RoundManager.CurrentRound.Killers[killerIndex] = {
			Player = killerPlayer,
			Character = nil,
		}
		RoundManager.CurrentRound.KillerIndex[killerPlayer] = killerIndex
	end

	RoundManager.CurrentRound.PlayersRemaining = {}

	for index, Player: Player in PlayersOrderedByMalice do
		local IsKiller = index <= killersToSpawn
		RoundManager.Utils.SetupPlayer(Player, IsKiller and index or nil)

		if RoundManager.CanSpawnKiller and IsKiller then
			continue
		end

		RoundManager.CurrentRound.PlayersRemaining[Player.UserId] = Player
	end

	Utils.Misc.Print(RoundManager.CurrentRound.PlayersRemaining)

	RoundState.Value = "InRound"
	TimeManager.SetTime(TimeManager.Config.RoundTime)
	TimeManager.OnTimerEnd = function()
		RoundManager.Callables.EndRound("Survivors")
	end
	workspace:SetAttribute("LMS", false)

	task.defer(function()
		while task.wait(1) do
			if RoundManager.StopLoop then
				RoundManager.StopLoop = false
				break
			end
			RoundManager.Utils.CheckForKillerWin()
		end
	end)

	if mode.OnRoundStart then
		mode:OnRoundStart({
			Players = RoundManager.CurrentRound.PlayersAccepted,
			Killers = RoundManager.CurrentRound.Killers,
		})
	end

	RoundManager.Callables.PlayIntro()
end

function RoundManager.Callables.PlayIntro()
	local function clearFadeAndUnanchor()
		Utils.Player.Fade(Utils.Player.GetLoadedPlayers(false), "Out", 0.6, false)
		TimeManager.CanDecreaseTime = true
		for _, player: Player in RoundManager.CurrentRound.PlayersAccepted do
			local hrp = Utils.Character.GetRootPart(player)
			if hrp then
				hrp.Anchored = false
			end
		end
	end

	if not RoundManager.CanSpawnKiller or #(RoundManager.CurrentRound.Killers) == 0 then
		clearFadeAndUnanchor()
		return
	end

	-- Always fade out after intro window (prevents permanent black screen)
	RoundManager.Threads["IntroEndingThread"] = task.delay(3, clearFadeAndUnanchor)
end

function RoundManager.Callables.InitLMS(LastMan: Player)
	if not RoundManager.CanInitLMS or RoundManager.CurrentRound.StartedLMS or not RoundManager.CurrentRound.Killers[1] or not RoundManager.CurrentRound.Killers[1].Character then
		return
	end

	RoundManager.CurrentRound.StartedLMS = true
	workspace:SetAttribute("LMS", true)

	for _, Killer in RoundManager.CurrentRound.Killers do
		if Killer.Player then
			Utils.Player.RevealPlayerAuraTo(Killer.Player, LastMan, 10)
			Utils.Player.RevealPlayerAuraTo(LastMan, Killer.Player, 10)
		end
	end

	TimeManager.SetTime(TimeManager.Config.LastManStandingTime)
	Network:FireConnection("LMSVoiceline", LastMan)

	local killerChar = RoundManager.CurrentRound.Killers[1].Character
	local Mod = require(Utils.Instance.GetCharacterModule(
		"Killer",
		killerChar:GetAttribute("CharacterName"),
		killerChar:GetAttribute("CharacterSkinName")
	))
	local SpecialLMS = Mod.Config.SpecialLastManStandings
	local Specials = SpecialLMS and SpecialLMS[LastMan.Character:GetAttribute("CharacterName")]

	local Theme = Specials
			and (Specials[LastMan.Character:GetAttribute("CharacterSkinName")] or Specials["Default"] or Mod.Config.LastManStandingTheme)
		or Mod.Config.LastManStandingTheme
	Sounds.PlayTheme(Theme, { Name = "LMS", Priority = 999999, TweenTime = 0, Volume = 1, TimePosition = 0 })
end

function RoundManager.Callables.EndRound(winner: "Survivors" | "Killer")
	RoundManager.StopLoop = true
	for _, Thread in RoundManager.Threads do
		task.cancel(Thread)
	end
	table.clear(RoundManager.Threads)
	Sounds.StopTheme("LMS", 0)
	workspace:SetAttribute("LMS", false)

	for _, Connections: { RBXScriptConnection } in RoundManager.PlayerConnections do
		for _, Connection in Connections do
			Connection:Disconnect()
		end
	end
	table.clear(RoundManager.PlayerConnections)

	local mode = GameModeManager.GetCurrent()
	if mode and mode.OnRoundEnd then
		mode:OnRoundEnd(winner)
	end

	if winner == "Killer" then
		for _, Killer in RoundManager.CurrentRound.Killers do
			if Killer.Player then
				CommonFunctions.UpdatePlayerStat(Killer.Player, "KillerStats.KillerWins", 1)
				CommonFunctions.GrantRewardToPlayer(Killer.Player, {
					Money = 120,
					EXP = 180,
					Reason = "winning a match as Killer",
				})
			end
		end
		Utils.Misc.Print("killer wins")
	elseif winner == "Survivors" then
		for _, Killer in RoundManager.CurrentRound.Killers do
			if Killer.Player then
				CommonFunctions.UpdatePlayerStat(Killer.Player, "KillerStats.KillerLosses", 1)
			end
		end
		for _, Player: Player in RoundManager.CurrentRound.PlayersRemaining do
			CommonFunctions.UpdatePlayerStat(Player, "SurvivorStats.SurvivorWins", 1)
			CommonFunctions.GrantRewardToPlayer(Player, {
				Money = 70,
				EXP = 110,
				Reason = "winning a match as Survivor",
			})
		end
		Utils.Misc.Print("survivors win")
	else
		Utils.Misc.Print("NO ONE WON!!1!")
	end

	Utils.Player.Fade(Utils.Player.GetLoadedPlayers(), "In", 0.7, true)
	TimeManager.SetTime(TimeManager.Config.LobbyTime)

	-- Respawn EVERYONE (including dead) as Spectator so SideBar comes back
	local accepted = table.clone(RoundManager.CurrentRound.PlayersAccepted)
	for _, Player: Player in accepted do
		if Player and Player.Parent then
			pcall(function()
				ServerCharacterManager.SetupCharacter(Player)
			end)
		end
	end

	RoundManager.CurrentRound = {
		Killers = {},
		KillerIndex = {},
		PlayersAccepted = {},
		PlayersRemaining = {},
		StartedLMS = false,
		ModeId = "Normal",
	}

	task.defer(function()
		MapManager.DestroyCurrentMap()
	end)

	-- Restore classic defaults so next lobby / next mode starts clean
	GameModeManager.RestoreDefaults(TimeManager)
	RoundManager.CanSpawnKiller = true
	RoundManager.CanInitLMS = true

	RoundState.Value = "Lobby"
	Utils.Player.Fade(Utils.Player.GetLoadedPlayers(), "Out", 0.7, false)
	task.delay(1, function()
		Utils.Player.Fade(Utils.Player.GetLoadedPlayers(), "Out", 0.35, false)
	end)

	TimeManager.OnTimerEnd = function()
		RoundManager.StartRound()
	end
	TimeManager.CanDecreaseTime = true
end

function RoundManager.Callables._OnPlayerDeath(dead: Player, wasKiller: boolean?)
	wasKiller = wasKiller or false

	local conns = RoundManager.PlayerConnections[dead.UserId]
	if conns then
		for _, Connection in conns do
			Connection:Disconnect()
		end
		RoundManager.PlayerConnections[dead.UserId] = nil
	end

	if wasKiller then
		CommonFunctions.UpdatePlayerStat(dead, "KillerStats.KillerLosses", 1)
		local idx = RoundManager.CurrentRound.KillerIndex[dead]
		if idx then
			RoundManager.CurrentRound.Killers[idx] = nil
			RoundManager.CurrentRound.KillerIndex[dead] = nil
		end
		table.clear(RoundManager.CurrentRound.KillerIndex)
		local NewTable = {}
		for _, killer in ipairs(RoundManager.CurrentRound.Killers) do
			if killer then
				table.insert(NewTable, killer)
			end
		end
		for index, killer in ipairs(NewTable) do
			RoundManager.CurrentRound.KillerIndex[killer.Player] = index
		end
		RoundManager.CurrentRound.Killers = NewTable
	else
		RoundManager.CurrentRound.PlayersRemaining[dead.UserId] = nil
	end

	local DeadRemainingValue = PlayersRemaining:FindFirstChild(tostring(dead.UserId))
	if DeadRemainingValue then
		DeadRemainingValue:Destroy()
	end

	RoundManager.Utils.CheckForKillerWin()
end

function RoundManager.Utils.CheckForKillerWin()
	local Count = Utils.Character.GetCharactersWithRoles()
	local Survivors = #Count.Survivor

	if RoundManager.CanSpawnKiller then
		if #Count.Killer <= 0 then
			RoundManager.Callables.EndRound("Survivors")
		elseif Survivors == 1 then
			RoundManager.Callables.InitLMS(Players:GetPlayerFromCharacter(Count.Survivor[1]))
		elseif #RoundManager.CurrentRound.PlayersAccepted > 1 and Survivors <= 0 then
			RoundManager.Callables.EndRound("Killer")
		end
	elseif Survivors <= 0 then
		RoundManager.Callables.EndRound("Killer")
	end
end

function RoundManager.Utils.GetCharacterModule(player: Player, charType: "Killer" | "Survivor")
	local EquippedCharacter = Utils.PlayerData.GetPlayerEquipped(player, charType)
	local EquippedSkin = Utils.PlayerData.GetPlayerEquipped(player, "Skins." .. EquippedCharacter)
	return Utils.Instance.GetCharacterModule(charType, EquippedCharacter, EquippedSkin)
end

function RoundManager.Utils.SetupPlayer(Player: Player, KillerIndex: number?)
	local Char
	local spawnCF

	if KillerIndex and RoundManager.CanSpawnKiller then
		Utils.PlayerData.GetPlayerStat(Player, "General.Malice", false).Value = 1

		local EquippedKillerName = Utils.PlayerData.GetPlayerEquipped(Player, "Killer")

		Char, spawnCF = ServerCharacterManager.SetupCharacter(
			Player,
			EquippedKillerName,
			"Killer",
			Utils.PlayerData.GetPlayerEquipped(Player, "Skins." .. EquippedKillerName)
		)

		RoundManager.PlayerConnections[Player.UserId] = {
			Player.CharacterRemoving:Connect(function()
				RoundManager.Callables._OnPlayerDeath(Player, true)
			end),
			Char.Humanoid.Died:Connect(function()
				RoundManager.Callables._OnPlayerDeath(Player, true)
			end),
		}

		if RoundManager.CurrentRound.Killers[KillerIndex] then
			RoundManager.CurrentRound.Killers[KillerIndex].Character = Char
		end
	else
		CommonFunctions.UpdatePlayerStat(Player, "General.Malice", 1)

		local EquippedSurvivorName = Utils.PlayerData.GetPlayerEquipped(Player, "Survivor")

		Char, spawnCF = ServerCharacterManager.SetupCharacter(
			Player,
			EquippedSurvivorName,
			"Survivor",
			Utils.PlayerData.GetPlayerEquipped(Player, "Skins." .. EquippedSurvivorName)
		)

		RoundManager.PlayerConnections[Player.UserId] = {
			Player.CharacterRemoving:Connect(function()
				RoundManager.Callables._OnPlayerDeath(Player)
			end),
			Char.Humanoid.Died:Connect(function()
				CommonFunctions.UpdatePlayerStat(Player, "SurvivorStats.SurvivorLosses", 1)
				RoundManager.Callables._OnPlayerDeath(Player)
			end),
		}
	end

	task.wait()
	if spawnCF and Char then
		if not Char.PrimaryPart then
			Char.PrimaryPart = Utils.Character.GetRootPart(Char)
		end
		Char:SetAttribute("ServerTeleport", true)
		Char:PivotTo(spawnCF)
		task.defer(function()
			Char:SetAttribute("ServerTeleport", false)
		end)
	end
	local root = Char and Utils.Character.GetRootPart(Char)
	if root then
		root.Anchored = true
	end
end

return RoundManager
