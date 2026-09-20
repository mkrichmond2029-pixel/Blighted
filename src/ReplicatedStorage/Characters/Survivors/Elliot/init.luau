local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)
local PlayerSpeedManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSpeedManager) or nil
local PlayerSprintManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSprintManager) or nil

local ElliotState = {}
ElliotState.__index = ElliotState

function ElliotState.new(owner: Player, character: Model, charModule: Types.Survivor)
	return setmetatable({ Owner = owner, Character = character, CharModule = charModule, Kitchen = nil }, ElliotState)
end

function ElliotState:Folder()
	local map = workspace:FindFirstChild("Map")
	return (map and map:FindFirstChild("InGame")) or workspace:FindFirstChild("TempObjectFolders") or workspace
end

function ElliotState:WorkingKitchen()
	local kitchen = self.Kitchen
	local health = kitchen and kitchen:FindFirstChild("KitchenHealth")
	return kitchen and kitchen.Parent and health and health.Health > 0 and not kitchen:GetAttribute("Broken") and kitchen
end

function ElliotState:KitchenNearby()
	local kitchen = self:WorkingKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	return kitchen ~= nil and root ~= nil and kitchen.PrimaryPart ~= nil
		and (root.Position - kitchen.PrimaryPart.Position).Magnitude <= 18
end

function ElliotState:AddPizza(amount: number)
	local ability = self.CharModule.GameplayConfig.Abilities.PizzaThrow
	ability:ChangeAbilityCharges("Set", math.clamp((ability.UsesLeft or 0) + amount, 0, 2))
end

function ElliotState:CreateKitchen()
	local model = Instance.new("Model")
	model.Name = "ElliotKitchen"
	model:SetAttribute("Broken", false)

	local counter = Instance.new("Part")
	counter.Name = "KitchenCounter"
	counter.Size = Vector3.new(5, 2, 3)
	counter.Anchored = true
	counter.CanCollide = true
	counter.Material = Enum.Material.Wood
	counter.Color = Color3.fromRGB(190, 120, 55)
	counter.CFrame = self.Character.HumanoidRootPart.CFrame * CFrame.new(0, -2, -5)
	counter.Parent = model
	model.PrimaryPart = counter

	local health = Instance.new("Humanoid")
	health.Name = "KitchenHealth"
	health.MaxHealth = 100
	health.Health = 100
	health.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	health.Parent = model

	model.Parent = self:Folder()
	self.Kitchen = model
	health.HealthChanged:Connect(function(value)
		model:SetAttribute("KitchenHealth", value)
		model:SetAttribute("Broken", value <= 0)
	end)

	task.spawn(function()
		while model.Parent do
			task.wait(25)
			if model.Parent and self:WorkingKitchen() then
				self:AddPizza(1)
			end
		end
	end)
	return model
end

function ElliotState:PlaceOrRepairKitchen()
	if self.Kitchen and self.Kitchen.Parent then
		if self.Kitchen:GetAttribute("Broken") then
			local health = self.Kitchen:FindFirstChild("KitchenHealth")
			if health then health.Health = health.MaxHealth end
		end
		return
	end
	self:CreateKitchen()
end

function ElliotState:ThrowPizza()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local pizza = Instance.new("Part")
	pizza.Name = "ElliotPizza"
	pizza.Shape = Enum.PartType.Cylinder
	pizza.Size = Vector3.new(0.4, 1.8, 1.8)
	pizza.Color = Color3.fromRGB(255, 170, 25)
	pizza.Material = Enum.Material.Neon
	pizza.CanCollide = false
	pizza.CanTouch = false
	pizza.Anchored = true
	pizza.CFrame = root.CFrame * CFrame.new(0, 1, -3) * CFrame.Angles(0, 0, math.rad(90))
	pizza.Parent = self:Folder()

	local hit = false
	local start = pizza.CFrame
	local goal = start * CFrame.new(0, 0, -105)
	local projectileHitbox = Hitbox.New(self.Owner, {
		CFrame = function() return pizza.CFrame end,
		Size = Vector3.new(3, 3, 3),
		Damage = 0,
		FriendlyFire = true,
		IsProjectile = true,
		Reason = "Pizza Throw",
		Time = 1.5,
		Connections = {
			Hit = function(_, humanoid: Humanoid)
				local target = humanoid.Parent
				local role = target and target:FindFirstChild("Role")
				if hit or not role or role.Value ~= "Survivor" then return end
				hit = true
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 10)
				task.spawn(function()
					for _ = 1, 5 do
						task.wait(1)
						if humanoid.Parent and humanoid.Health > 0 then
							humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 3)
						end
					end
				end)
				projectileHitbox:Cancel()
				pizza:Destroy()
			end,
		},
	})

	local tween = TweenService:Create(pizza, TweenInfo.new(1.5, Enum.EasingStyle.Linear), { CFrame = goal })
	tween:Play()
	Debris:AddItem(pizza, 1.6)
end

function ElliotState:RideBike(ability: Types.Ability)
	if not self:KitchenNearby() then return end

	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local bike = Instance.new("Part")
	bike.Name = "ElliotMotorBike"
	bike.Size = Vector3.new(2.5, 1, 4)
	bike.Color = Color3.fromRGB(35, 35, 35)
	bike.Material = Enum.Material.Metal
	bike.CanCollide = false
	bike.Massless = true
	bike.CFrame = root.CFrame * CFrame.new(0, -2, 0)
	bike.Parent = self.Character
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = bike
	weld.Parent = bike

	local factor = "ElliotMotorBike"
	local remaining = ability.Duration
	local active = true
	self.Character:SetAttribute("RidingMotorBike", true)
	PlayerSpeedManager.AddSpeedFactor(self.Owner, factor, self.CharModule.GameplayConfig.SprintSpeedMultiplier * 1.4)
	PlayerSprintManager.AddStaminaDrain(self.Owner, factor, 2)

	ability:AddConnection(RunService.Heartbeat:Connect(function(delta)
		if not active then return end
		local attributes = self.Character:FindFirstChild("PlayerAttributes")
		local stamina = attributes and attributes:FindFirstChild("Stamina")
		remaining -= delta
		if stamina and stamina:IsA("NumberValue") then
			stamina.Value = math.max(0, stamina.Value - 12 * delta)
			if stamina.Value <= 0 then remaining = 0 end
		end
		if remaining <= 0 then
			active = false
			PlayerSpeedManager.RemoveSpeedFactor(self.Owner, factor)
			PlayerSprintManager.RemoveStaminaDrain(self.Owner, factor)
			self.Character:SetAttribute("RidingMotorBike", false)
			bike:Destroy()
		end
	end))
end

local function PizzaBehaviour(self: Types.Ability)
	if RunService:IsServer() then self.CharModule.GameplayConfig.Cache.ElliotState:ThrowPizza() end
end

local function KitchenBehaviour(self: Types.Ability)
	if RunService:IsServer() then self.CharModule.GameplayConfig.Cache.ElliotState:PlaceOrRepairKitchen() end
end

local function BikeBehaviour(self: Types.Ability)
	if RunService:IsServer() then self.CharModule.GameplayConfig.Cache.ElliotState:RideBike(self) end
end

local Elliot: Types.Survivor = Character.CreateSurvivor({
	Config = { Name = "Elliot", Quote = "Fresh from the kitchen.", Render = "rbxasset://textures/ui/GuiImagePlaceholder.png" },
	GameplayConfig = {
		Health = 100,
		BaseSpeed = 10.5,
		StaminaProperties = { MaxStamina = 100, StaminaDrain = 10, StaminaGain = 20 },
		Cache = { Animations = {} },
		Abilities = {
			PizzaThrow = Ability.New({
				Name = "Pizza Throw", InputName = "FirstAbility", Cooldown = 2, Duration = 1.5,
				UseSettings = { InitialUses = 2, Limited = true }, Behaviour = PizzaBehaviour,
			}),
			Kitchen = Ability.New({ Name = "Kitchen", InputName = "SecondAbility", Cooldown = 3, Duration = 1, Behaviour = KitchenBehaviour }),
			MotorBike = Ability.New({
				Name = "Motor Bike", InputName = "ThirdAbility", Cooldown = 12, Duration = 8,
				UseConditions = function(self: Types.Ability)
					return RunService:IsClient() or self.CharModule.GameplayConfig.Cache.ElliotState:KitchenNearby()
				end,
				Behaviour = BikeBehaviour,
			}),
		},
	},
	OnInit = function(self: Types.Survivor, character: Model)
		if RunService:IsServer() then self.GameplayConfig.Cache.ElliotState = ElliotState.new(self.Owner, character, self) end
	end,
})

Elliot.Config.Description = {
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "PIZZA THROW" },
	{ Type = "Text", Text = "Throw a visible pizza projectile to heal a survivor for 10 immediately and 15 over time." },
	{ Type = "Header", Text = "KITCHEN" },
	{ Type = "Text", Text = "Place a visible kitchen that creates a pizza slice every 25 seconds and can be repaired." },
	{ Type = "Header", Text = "MOTOR BIKE" },
	{ Type = "Text", Text = "Ride at 1.4x sprint speed while consuming stamina near a working kitchen." },
}

return Elliot
