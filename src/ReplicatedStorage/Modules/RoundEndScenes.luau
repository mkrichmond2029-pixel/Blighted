local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Network = require(ReplicatedStorage.Modules.Network)

local RoundEndScenes = {
    DefaultSurvivorWin = {
        Title = "SURVIVORS WIN",
        Subtitle = "You survived the night.",
        Duration = 6,
        VideoId = "",
    },
    DefaultKillerWin = {
        Title = "KILLER WINS",
        Subtitle = "Nobody escaped.",
        Duration = 6,
        VideoId = "",
    },
    DefaultDeath = {
        Title = "YOU DIED",
        Subtitle = "",
        Duration = 4,
        VideoId = "",
    },
}

local initialized = false
local function sceneFor(config, fallback)
    local scene = config and config.EndingScenes and config.EndingScenes[fallback]
    if typeof(scene) == "table" then
        return scene
    end
    return RoundEndScenes[fallback] or RoundEndScenes.DefaultDeath
end

function RoundEndScenes.Show(player: Player, scene)
    if RunService:IsServer() and player and player.Parent then
        Network:FireClientConnection(player, "RoundEndScene", "REMOTE_EVENT", scene)
    end
end

function RoundEndScenes.ShowDeath(player: Player, character: Model?)
    if not player then return end
    local scene = RoundEndScenes.DefaultDeath
    local moduleScript = character and character:FindFirstChild("PlayerAbilities")
        and character.PlayerAbilities:FindFirstChild("CharacterAbilities")
    local characterModule = moduleScript and require(moduleScript).CharacterModule
    local custom = characterModule and sceneFor(characterModule.Config, "Death")
    RoundEndScenes.Show(player, custom or scene)
end

local function makeClientGui(scene)
    local player = Players.LocalPlayer
    local gui = player:WaitForChild("PlayerGui")
    local old = gui:FindFirstChild("RoundEndScene")
    if old then old:Destroy() end

    local screen = Instance.new("ScreenGui")
    screen.Name = "RoundEndScene"
    screen.ResetOnSpawn = false
    screen.IgnoreGuiInset = true
    screen.Parent = gui

    local frame = Instance.new("Frame")
    frame.Size = UDim2.fromScale(1, 1)
    frame.BackgroundColor3 = Color3.new(0, 0, 0)
    frame.BackgroundTransparency = 0.2
    frame.Parent = screen

    local title = Instance.new("TextLabel")
    title.BackgroundTransparency = 1
    title.Size = UDim2.fromScale(1, 0.18)
    title.Position = UDim2.fromScale(0, 0.36)
    title.Font = Enum.Font.GothamBlack
    title.TextColor3 = Color3.new(1, 1, 1)
    title.TextScaled = true
    title.Text = scene.Title or ""
    title.Parent = frame

    local subtitle = Instance.new("TextLabel")
    subtitle.BackgroundTransparency = 1
    subtitle.Size = UDim2.fromScale(1, 0.08)
    subtitle.Position = UDim2.fromScale(0, 0.55)
    subtitle.Font = Enum.Font.Gotham
    subtitle.TextColor3 = Color3.fromRGB(210, 210, 210)
    subtitle.TextScaled = true
    subtitle.Text = scene.Subtitle or ""
    subtitle.Parent = frame

    task.delay(math.max(scene.Duration or 5, 0.5), function()
        if screen.Parent then screen:Destroy() end
    end)
end

function RoundEndScenes:Init()
    if initialized then return end
    initialized = true

    if RunService:IsClient() then
        Network:SetConnection("RoundEndScene", "REMOTE_EVENT", function(scene)
            if typeof(scene) == "table" then makeClientGui(scene) end
        end)
        return
    end

    local function watchPlayer(player: Player)
        player.CharacterAdded:Connect(function(character)
            local humanoid = character:WaitForChild("Humanoid", 10)
            if humanoid then
                humanoid.Died:Connect(function()
                    RoundEndScenes.ShowDeath(player, character)
                end)
            end
        end)
    end
    Players.PlayerAdded:Connect(watchPlayer)
    for _, player in Players:GetPlayers() do watchPlayer(player) end

    local state = ReplicatedStorage.RoundInfo.CurrentState
    local previous = state.Value
    state.Changed:Connect(function(value)
        if previous == "InRound" and value == "Lobby" then
            local remaining = ReplicatedStorage.RoundInfo:FindFirstChild("PlayersRemaining")
            local winner = remaining and #remaining:GetChildren() > 0 and "Survivors" or "Killer"
            local scene = winner == "Survivors" and RoundEndScenes.DefaultSurvivorWin or RoundEndScenes.DefaultKillerWin
            for _, player in Players:GetPlayers() do RoundEndScenes.Show(player, scene) end
        end
        previous = value
    end)
end

return RoundEndScenes
