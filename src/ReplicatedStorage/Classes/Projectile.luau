local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Utils = require(ReplicatedStorage.Modules.Utils)
local Hitbox = require(script.Parent.Hitbox)
local Types = require(script.Parent.Types)

local Projectile = {
    DefaultConfig = {
        Speed = 50,
        FinalRotation = CFrame.new(),
        Lifetime = 5,
        ThrowType = "Forward",
        HitboxSettings = {},
        DestroyOnCollision = false,
    },
}

function Projectile.New(ProjectileSettings: Types.Projectile): Types.ProjectileDetails
    if not RunService:IsServer() then
        return { Model = nil, Tween = nil, Hitbox = nil, Destroy = function() end }
    end

    if not ProjectileSettings
        or not ProjectileSettings.SourcePlayer
        or not ProjectileSettings.Model
        or not ProjectileSettings.StartingCFrame
        or not ProjectileSettings.HitboxSettings then

        warn("Projectile settings missing crucial fields!")
        return { Model = nil, Tween = nil, Hitbox = nil, Destroy = function() end }
    end

    Utils.Type.DeepTableWrite(ProjectileSettings, Projectile.DefaultConfig)

    local HitboxSettings = ProjectileSettings.HitboxSettings
    HitboxSettings.IsProjectile = true
    HitboxSettings.PredictVelocity = false
    HitboxSettings.HitMultiple = false
    HitboxSettings.Time = ProjectileSettings.Lifetime

    local Cancelled = false
    local ProjectileModel = ProjectileSettings.Model:Clone()

    local ProjectileInstance: Types.ProjectileDetails = {
        Model = ProjectileModel,
        Tween = nil,
        Hitbox = nil,
        Destroy = function(self: Types.ProjectileDetails)
            if Cancelled then
                return
            end

            Cancelled = true

            if ProjectileSettings.OnDestroy then
                ProjectileSettings.OnDestroy(self)
            end

            if self.Model and self.Model.Parent then
                self.Model:Destroy()
            end

            if self.Hitbox then
                self.Hitbox:Cancel()
            end
        end,
    }

    ProjectileModel.Parent = workspace:FindFirstChild("Map")
        and workspace.Map.InGame
        or workspace.TempObjectFolders

    if ProjectileModel:IsA("Model") then
        ProjectileModel:PivotTo(ProjectileSettings.StartingCFrame)
    else
        ProjectileModel.CFrame = ProjectileSettings.StartingCFrame
    end

    local StartCFrame = ProjectileSettings.StartingCFrame
    HitboxSettings.CFrame = HitboxSettings.CFrame or function(): CFrame
        if not ProjectileModel.Parent then
            return StartCFrame
        end

        if ProjectileModel:IsA("Model") then
            return ProjectileModel:GetPivot()
        end

        return ProjectileModel.CFrame
    end

    Debris:AddItem(ProjectileModel, ProjectileSettings.Lifetime + 0.1)

    ProjectileInstance.Hitbox = Hitbox.New(
        ProjectileSettings.SourcePlayer,
        HitboxSettings
    )

    local Goal = StartCFrame * CFrame.new(
        0,
        0,
        -ProjectileSettings.Speed * ProjectileSettings.Lifetime
    )

    if ProjectileSettings.FinalRotation then
        Goal *= ProjectileSettings.FinalRotation
    end

    ProjectileInstance.Tween = TweenService:Create(
        ProjectileModel:IsA("Model") and ProjectileModel.PrimaryPart or ProjectileModel,
        TweenInfo.new(ProjectileSettings.Lifetime, Enum.EasingStyle.Linear),
        { CFrame = Goal }
    )
    ProjectileInstance.Tween:Play()

    local DestroyParams = RaycastParams.new()
    DestroyParams.FilterType = Enum.RaycastFilterType.Exclude
    DestroyParams.FilterDescendantsInstances = {
        ProjectileSettings.SourcePlayer.Character,
        ProjectileModel,
    }
    DestroyParams.RespectCanCollide = true

    if ProjectileSettings.DestroyOnCollision then
        task.defer(function()
            local CollisionBox = ProjectileModel:FindFirstChild("CollisionBox", true)

            if not CollisionBox or not CollisionBox:IsA("BasePart") then
                return
            end

            while not Cancelled and ProjectileModel.Parent do
                local Direction = CollisionBox.CFrame.LookVector
                local Distance = math.max(
                    0.25,
                    ProjectileSettings.Speed * (1 / 60) + 0.5
                )

                local Touching = workspace:Shapecast(
                    CollisionBox,
                    Direction * Distance,
                    DestroyParams
                )

                if Touching and Touching.Instance then
                    local PreventDestruction = ProjectileSettings.OnHitDestroy
                        and ProjectileSettings:OnHitDestroy(ProjectileInstance) == "PreventDestruction"

                    if not PreventDestruction then
                        ProjectileInstance:Destroy()
                    end

                    break
                end

                RunService.Heartbeat:Wait()
            end
        end)
    end

    return ProjectileInstance
end

return Projectile
