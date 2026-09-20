local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)
local PlayerSpeedManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSpeedManager) or nil
local PlayerSprintManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSprintManager) or nil

-- Replace these with Elliot's uploaded animation IDs when they are available.
local ANIM = {
	Pizza = "rbxassetid://0",
	Kitchen = "rbxassetid://0",
	MotorBike = "rbxassetid://0",
}

local ElliotState = {}
ElliotState.__index = ElliotState

function ElliotState.new(owner: Player, character: Model, charModule: Types.Survivor)
	return setmetatable({ Owner = owner, Character = character, CharModule = charModule, Kitchen = nil, Riding = false }, ElliotState)
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

function ElliotState:IsLMS()
	return workspace:GetAttribute("LMS") == true
		or workspace:GetAttribute("LastManStanding") == true
		or (workspace:FindFirstChild("RoundInfo") and workspace.RoundInfo:GetAttribute("LMS") == true)
end

function ElliotState:AddPizza(amount: number)
	local ability = self.CharModule.GameplayConfig.Abilities.PizzaThrow
	ability:ChangeAbilityCharges("Set", math.clamp((ability.UsesLeft or 0) + amount, 0, 2))
end

function ElliotState:CreateTimer(model: Model)
	local gui = Instance.new("BillboardGui")
	gui.Name = "PizzaTimer"
	gui.Size = UDim2.fromOffset(120, 36)
	gui.StudsOffset = Vector3.new(0, 3, 0)
	gui.AlwaysOnTop = true
	gui.Parent = model.PrimaryPart

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 0.25
	label.BackgroundColor3 = Color3.fromRGB(35, 20, 10)
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextScaled = true
	label.Font = Enum.Font.GothamBold
	label.Parent = gui

	task.spawn(function()
		local nextPizza = 20
		while model.Parent do
			if not self:WorkingKitchen() then
				label.Text = model:GetAttribute("Broken") and "BROKEN" or "OFFLINE"
				task.wait(1)
			else
				label.Text = nextPizza > 0 and ("Pizza: " .. nextPizza .. "s") or "Pizza ready!"
				task.wait(1)
				nextPizza -= 1
				if nextPizza <= 0 then
					self:AddPizza(1)
					nextPizza = 20
				end
			end
		end
	end)
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
	self:CreateTimer(model)

	health.HealthChanged:Connect(function(value)
		model:SetAttribute("KitchenHealth", value)
		model:SetAttribute("Broken", value <= 0)
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

local function Heal(state, humanoid: Humanoid)
	if humanoid.Health <= 0 then return end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 10)
	task.spawn(function()
		for _ = 1, 5 do
			task.wait(1)
			if humanoid.Parent and humanoid.Health > 0 then
				humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 3)
			end
		end
	end)
end

function ElliotState:ClosePizza()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local used = false
	local hitbox = Hitbox.New(self.Owner, {
		CFrameOffset = CFrame.new(0, 0, -3),
		Size = Vector3.new(4, 5, 5),
		Damage = 0,
		FriendlyFire = true,
		Time = 0.8,
		Reason = "Elliot Pizza Heal",
		Connections = {
			Hit = function(_, humanoid: Humanoid)
				local target = humanoid.Parent
				local role = target and target:FindFirstChild("Role")
				if used or not role or role.Value ~= "Survivor" then return end
				used = true
				Heal(self, humanoid)
			end,
		},
	})
	Debris:AddItem(hitbox, 1)
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
	pizza.Anchored = true
	pizza.Parent = self:Folder()

	local position = root.Position + Vector3.new(0, 1, 0) + root.CFrame.LookVector * 2
	local velocity = root.CFrame.LookVector * 48 + Vector3.new(0, 18, 0)
	local hit = false
	local hitbox
	hitbox = Hitbox.New(self.Owner, {
		CFrame = function() return pizza.CFrame end,
		Size = Vector3.new(3, 3, 3),
		Damage = 0,
		FriendlyFire = true,
		IsProjectile = true,
		Time = 2.5,
		Reason = "Pizza Throw",
		Connections = {
			Hit = function(_, humanoid: Humanoid)
				local target = humanoid.Parent
				local role = target and target:FindFirstChild("Role")
				if hit or not role or role.Value ~= "Survivor" then return end
				hit = true
				Heal(self, humanoid)
				hitbox:Cancel()
				pizza:Destroy()
			end,
		},
	})

	local connection
	connection = RunService.Heartbeat:Connect(function(delta)
		if not pizza.Parent then connection:Disconnect() return end
		velocity = velocity * math.exp(-0.65 * delta) - Vector3.new(0, 40, 0) * delta
		position += velocity * delta
		pizza.CFrame = CFrame.lookAt(position, position + velocity) * CFrame.Angles(0, math.rad(90), 0)
	end)
	Debris:AddItem(pizza, 2.6)
end

function ElliotState:ExitBike()
	if not self.Riding then return end
	self.Riding = false
	self.Character:SetAttribute("RidingMotorBike", false)
	PlayerSpeedManager.RemoveSpeedFactor(self.Owner, "ElliotMotorBike")
	PlayerSprintManager.RemoveStaminaDrain(self.Owner, "ElliotMotorBike")
	local bike = self.Character:FindFirstChild("ElliotMotorBike")
	if bike then bike:Destroy() end
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then humanoid.AutoRotate = true end
end

function ElliotState:RideBike(ability: Types.Ability)
	if self.Riding then self:ExitBike() return end
	if not self:KitchenNearby() then return end
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if not root or not humanoid then return end

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
	weld.Part0, weld.Part1, weld.Parent = root, bike, bike

	self.Riding = true
	self.Character:SetAttribute("RidingMotorBike", true)
	humanoid.AutoRotate = false
	local bikeSpeed = self.CharModule.GameplayConfig.BaseSpeed * self.CharModule.GameplayConfig.SprintSpeedMultiplier * 1.4
	PlayerSpeedManager.AddSpeedFactor(self.Owner, "ElliotMotorBike", bikeSpeed / self.CharModule.GameplayConfig.BaseSpeed)
	PlayerSprintManager.AddStaminaDrain(self.Owner, "ElliotMotorBike", 2)

	ability:AddConnection(RunService.Heartbeat:Connect(function(delta)
		if not self.Riding then return end
		local attrs = self.Character:FindFirstChild("PlayerAttributes")
		local stamina = attrs and attrs:FindFirstChild("Stamina")
		if stamina and stamina:IsA("NumberValue") then
			stamina.Value = math.max(0, stamina.Value - 12 * delta)
			if stamina.Value <= 0 then self:ExitBike() return end
		end
		local direction = humanoid.MoveDirection.Magnitude > 0 and humanoid.MoveDirection.Unit or root.CFrame.LookVector
		local facing = root.CFrame.LookVector:Lerp(direction, math.clamp(delta * 2.5, 0, 1)).Unit
		root.CFrame = CFrame.lookAt(root.Position, root.Position + facing)
		root.AssemblyLinearVelocity = facing * bikeSpeed + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end))
end

local function PizzaBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end
	local state = self.CharModule.GameplayConfig.Cache.ElliotState
	if state:IsLMS() then Heal(state, self.Owner.Character:FindFirstChildWhichIsA("Humanoid"))
	elseif self.Owner.Character:GetAttribute("RidingMotorBike") then state:ThrowPizza()
	else state:ClosePizza() end
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
			PizzaThrow = Ability.New({ Name = "Pizza Throw", InputName = "FirstAbility", Cooldown = 20, Duration = 0.8, UseAnimation = ANIM.Pizza, UseSettings = { InitialUses = 2, Limited = true }, Behaviour = PizzaBehaviour }),
			Kitchen = Ability.New({ Name = "Kitchen", InputName = "SecondAbility", Cooldown = 20, Duration = 2.5, UseAnimation = ANIM.Kitchen, Behaviour = KitchenBehaviour }),
			MotorBike = Ability.New({ Name = "Motor Bike", InputName = "ThirdAbility", Cooldown = 1, Duration = 8, UseAnimation = ANIM.MotorBike, UseConditions = function(self: Types.Ability) return RunService:IsClient() or self.CharModule.GameplayConfig.Cache.ElliotState:KitchenNearby() or self.CharModule.GameplayConfig.Cache.ElliotState.Riding end, Behaviour = BikeBehaviour }),
		},
	},
	OnInit = function(self: Types.Survivor, character: Model)
		if RunService:IsServer() then self.GameplayConfig.Cache.ElliotState = ElliotState.new(self.Owner, character, self) end
	end,
})

Elliot.Config.Description = {
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "PIZZA THROW" },
	{ Type = "Text", Text = "Heal a nearby survivor. While riding the motorbike, this becomes an underhand pizza throw with deceleration and gravity. In LMS, it heals Elliot." },
	{ Type = "Header", Text = "KITCHEN" },
	{ Type = "Text", Text = "Stand still while placing the kitchen. It produces a pizza every 20 seconds and shows a timer above the oven." },
	{ Type = "Header", Text = "MOTOR BIKE" },
	{ Type = "Text", Text = "Requires a nearby working kitchen. It moves at fixed speed, drains stamina, turns slowly, and tapping Motor Bike again exits the ride." },
}

return Elliot
