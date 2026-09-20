local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Projectile = require(ReplicatedStorage.Classes.Projectile)
local Types = require(ReplicatedStorage.Classes.Types)
local PlayerSpeedManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSpeedManager) or nil
local PlayerSprintManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSprintManager) or nil

-- Elliot keeps the small amount of state shared by his abilities in one object.
local ElliotState = {}
ElliotState.__index = ElliotState

function ElliotState.new(owner: Player, character: Model)
	return setmetatable({ Owner = owner, Character = character, Kitchen = nil }, ElliotState)
end

function ElliotState:Folder()
	return workspace:FindFirstChild("Map") and workspace.Map.InGame or workspace.TempObjectFolders
end

function ElliotState:WorkingKitchen()
	local kitchen = self.Kitchen
	return kitchen and kitchen.Parent and not kitchen:GetAttribute("Broken") and kitchen:FindFirstChildWhichIsA("Humanoid")
end

function ElliotState:KitchenNearby()
	local kitchen = self:WorkingKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local pivot = kitchen and kitchen.PrimaryPart
	return kitchen and root and pivot and (root.Position - pivot.Position).Magnitude <= 18
end

function ElliotState:AddPizza(amount: number)
	local pizza = self.CharModule.GameplayConfig.Abilities.PizzaThrow
	pizza:ChangeAbilityCharges("Set", math.clamp((pizza.UsesLeft or 0) + amount, 0, 2))
end

function ElliotState:CreateKitchen()
	local model = Instance.new("Model")
	model.Name = "ElliotKitchen"
	model:SetAttribute("Broken", false)
	model:SetAttribute("Health", 100)

	local counter = Instance.new("Part")
	counter.Name = "Counter"
	counter.Size = Vector3.new(5, 2, 3)
	counter.Anchored = true
	counter.Color = Color3.fromRGB(190, 120, 55)
	counter.CFrame = self.Character.HumanoidRootPart.CFrame * CFrame.new(0, -2, -5)
	counter.Parent = model
	model.PrimaryPart = counter

	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.Parent = model
	local role = Instance.new("StringValue")
	role.Name = "Role"
	role.Value = "Survivor"
	role.Parent = model

	model.Parent = self:Folder()
	humanoid.HealthChanged:Connect(function(health)
		model:SetAttribute("Health", health)
		if health <= 0 then
			model:SetAttribute("Broken", true)
		end
	end)

	-- One loop handles production and keeps the kitchen's behaviour self-contained.
	task.spawn(function()
		while model.Parent do
			task.wait(25)
			if model.Parent and not model:GetAttribute("Broken") then
				self:AddPizza(1)
			end
		end
	end)
	return model
end

function ElliotState:PlaceOrRepairKitchen()
	if self.Kitchen and self.Kitchen.Parent then
		local humanoid = self.Kitchen:FindFirstChildWhichIsA("Humanoid")
		if self.Kitchen:GetAttribute("Broken") then
			self.Kitchen:SetAttribute("Broken", false)
			if humanoid then humanoid.Health = humanoid.MaxHealth end
			return
		end
		return
	end
	self.Kitchen = self:CreateKitchen()
end

function ElliotState:ThrowPizza(ability: Types.Ability)
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end

	local pizza = Instance.new("Part")
	pizza.Name = "ElliotPizza"
	pizza.Shape = Enum.PartType.Cylinder
	pizza.Size = Vector3.new(0.35, 1.6, 1.6)
	pizza.Color = Color3.fromRGB(255, 190, 65)
	pizza.CanCollide = false
	pizza.Anchored = false

	local hit = false
	local projectile = Projectile.New({
		SourcePlayer = self.Owner,
		Model = pizza,
		StartingCFrame = root.CFrame * CFrame.new(0, 1, -2),
		Speed = 70,
		Lifetime = 1.5,
		DestroyOnCollision = true,
		HitboxSettings = {
			Size = Vector3.new(3, 3, 3),
			Damage = 0,
			FriendlyFire = true,
			Reason = "Pizza Throw",
			Connections = {
				Hit = function(_, humanoid: Humanoid)
					local target = humanoid.Parent
					if hit or not target or target:FindFirstChild("Role") == nil or target.Role.Value ~= "Survivor" then return end
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
					projectile:Destroy()
				end,
			},
		},
	})
end

function ElliotState:RideBike(ability: Types.Ability)
	if not self:KitchenNearby() then return end
	local factorName = "ElliotMotorBike"
	local duration = ability.Duration
	self.Character:SetAttribute("RidingMotorBike", true)
	PlayerSpeedManager.AddSpeedFactor(self.Owner, factorName, self.CharModule.GameplayConfig.SprintSpeedMultiplier * 1.4)
	PlayerSprintManager.AddStaminaDrain(self.Owner, factorName, 2)
	self.Connection = RunService.Heartbeat:Connect(function(delta)
		local stamina = self.Character:FindFirstChild("PlayerAttributes") and self.Character.PlayerAttributes:FindFirstChild("Stamina")
		if stamina and stamina:IsA("NumberValue") then
			stamina.Value = math.max(0, stamina.Value - 12 * delta)
			if stamina.Value <= 0 then duration = 0 end
		end
		duration -= delta
		if duration <= 0 then
			self.Connection:Disconnect()
			PlayerSpeedManager.RemoveSpeedFactor(self.Owner, factorName)
			PlayerSprintManager.RemoveStaminaDrain(self.Owner, factorName)
			self.Character:SetAttribute("RidingMotorBike", false)
		end
	end)
	ability:AddConnection(self.Connection)
end

local function PizzaBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		local state = self.CharModule.GameplayConfig.Cache.ElliotState
		state:ThrowPizza(self)
	end
end

local function KitchenBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		self.CharModule.GameplayConfig.Cache.ElliotState:PlaceOrRepairKitchen()
	end
end

local function BikeBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		self.CharModule.GameplayConfig.Cache.ElliotState:RideBike(self)
	end
end

local Elliot: Types.Survivor = Character.CreateSurvivor({
	Config = {
		Name = "Elliot",
		Quote = "Fresh from the kitchen.",
		Render = "rbxasset://textures/ui/GuiImagePlaceholder.png",
	},
	GameplayConfig = {
		Health = 100,
		BaseSpeed = 10.5,
		StaminaProperties = { MaxStamina = 100, StaminaDrain = 10, StaminaGain = 20 },
		Cache = { Animations = {} },
		Abilities = {
			PizzaThrow = Ability.New({
				Name = "Pizza Throw", InputName = "FirstAbility", Cooldown = 2, Duration = 1.5,
				UseAnimation = "", UseSettings = { InitialUses = 2, Limited = true }, Behaviour = PizzaBehaviour,
			}),
			Kitchen = Ability.New({
				Name = "Kitchen", InputName = "SecondAbility", Cooldown = 3, Duration = 1, Behaviour = KitchenBehaviour,
			}),
			MotorBike = Ability.New({
				Name = "Motor Bike", InputName = "ThirdAbility", Cooldown = 12, Duration = 8,
				UseConditions = function(self: Types.Ability)
					return self.CharModule.GameplayConfig.Cache.ElliotState:KitchenNearby()
				end,
				Behaviour = BikeBehaviour,
			}),
		},
	},
	OnInit = function(self: Types.Survivor, character: Model)
		if RunService:IsServer() then
			local state = ElliotState.new(self.Owner, character)
			state.CharModule = self
			self.GameplayConfig.Cache.ElliotState = state
		end
	end,
})

Elliot.Config.Description = {
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "PIZZA THROW" },
	{ Type = "Text", Text = "Throw a pizza to heal a survivor for 10 immediately and 15 over time. Elliot can hold two slices." },
	{ Type = "Header", Text = "KITCHEN" },
	{ Type = "Text", Text = "Place a kitchen that creates one pizza slice every 25 seconds. Killers can damage it; use Kitchen again to repair it." },
	{ Type = "Header", Text = "MOTOR BIKE" },
	{ Type = "Text", Text = "Ride at 1.4x sprint speed while consuming stamina. A working kitchen must be nearby." },
}

return Elliot
