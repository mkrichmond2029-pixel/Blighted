local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)
local CommonFunctions = RunService:IsServer() and require(game:GetService("ServerScriptService").System.CommonFunctions) or nil
local PlayerSpeedManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSpeedManager) or nil
local PlayerSprintManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSprintManager) or nil

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

-- RoundManager sets this authoritative server flag during InitLMS.
function ElliotState:IsLMS()
	return workspace:GetAttribute("LMS") == true
end

function ElliotState:AddPizza(amount: number)
	local ability = self.CharModule.GameplayConfig.Abilities.PizzaThrow
	ability:ChangeAbilityCharges("Set", math.clamp((ability.UsesLeft or 0) + amount, 0, 2))
end

function ElliotState:CreateTimer(model: Model)
	local gui = Instance.new("BillboardGui")
	gui.Name, gui.Size, gui.StudsOffset, gui.AlwaysOnTop = "PizzaTimer", UDim2.fromOffset(120, 36), Vector3.new(0, 3, 0), true
	gui.Parent = model.PrimaryPart
	local label = Instance.new("TextLabel")
	label.Size, label.BackgroundTransparency, label.TextColor3, label.TextScaled = UDim2.fromScale(1, 1), 0.25, Color3.new(1, 1, 1), true
	label.BackgroundColor3, label.Font, label.Parent = Color3.fromRGB(35, 20, 10), Enum.Font.GothamBold, gui

	task.spawn(function()
		local timer = 20
		while model.Parent do
			if not self:WorkingKitchen() then
				label.Text = model:GetAttribute("Broken") and "BROKEN" or "OFFLINE"
			else
				label.Text = timer > 0 and ("Pizza: " .. timer .. "s") or "Pizza ready!"
				task.wait(1)
				timer -= 1
				if timer <= 0 then self:AddPizza(1); timer = 20 end
			end
			task.wait(timer > 0 and 0 or 1)
		end
	end)
end

function ElliotState:CreateKitchen()
	local model = Instance.new("Model")
	model.Name, model:SetAttribute("Broken", false) = "ElliotKitchen", false
	local counter = Instance.new("Part")
	counter.Name, counter.Size, counter.Anchored, counter.CanCollide = "KitchenCounter", Vector3.new(5, 2, 3), true, true
	counter.Material, counter.Color = Enum.Material.Wood, Color3.fromRGB(190, 120, 55)
	counter.CFrame = self.Character.HumanoidRootPart.CFrame * CFrame.new(0, -2, -5)
	counter.Parent, model.PrimaryPart = model, counter
	local health = Instance.new("Humanoid")
	health.Name, health.MaxHealth, health.Health = "KitchenHealth", 100, 100
	health.DisplayDistanceType, health.Parent = Enum.HumanoidDisplayDistanceType.None, model
	model.Parent, self.Kitchen = self:Folder(), model
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

local function Heal(humanoid: Humanoid)
	if humanoid and humanoid.Health > 0 then
		humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 10)
		task.spawn(function()
			for _ = 1, 5 do
				task.wait(1)
				if humanoid.Parent and humanoid.Health > 0 then humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 3) end
			end
		end)
	end
end

function ElliotState:ClosePizza()
	local used = false
	local hitbox = Hitbox.New(self.Owner, {
		CFrameOffset = CFrame.new(0, 0, -3), Size = Vector3.new(4, 5, 5), Damage = 0, FriendlyFire = true, Time = 0.8,
		Reason = "Elliot Pizza Heal",
		Connections = { Hit = function(_, humanoid: Humanoid)
			local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
			if not used and role and role.Value == "Survivor" then used = true; Heal(humanoid) end
		end },
	})
	Debris:AddItem(hitbox, 1)
end

function ElliotState:ThrowPizza()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local pizza = Instance.new("Part")
	pizza.Name, pizza.Shape, pizza.Size = "ElliotPizza", Enum.PartType.Cylinder, Vector3.new(0.4, 1.8, 1.8)
	pizza.Color, pizza.Material, pizza.CanCollide, pizza.Anchored = Color3.fromRGB(255, 170, 25), Enum.Material.Neon, false, true
	pizza.Parent = self:Folder()
	local position = root.Position + Vector3.new(0, 1, 0) + root.CFrame.LookVector * 2
	local velocity = root.CFrame.LookVector * 48 + Vector3.new(0, 18, 0)
	local hit = false
	local hitbox
	hitbox = Hitbox.New(self.Owner, {
		CFrame = function() return pizza.CFrame end, Size = Vector3.new(3, 3, 3), Damage = 0, FriendlyFire = true, IsProjectile = true, Time = 2.5, Reason = "Pizza Throw",
		Connections = { Hit = function(_, humanoid: Humanoid)
			local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
			if not hit and role and role.Value == "Survivor" then hit = true; Heal(humanoid); hitbox:Cancel(); pizza:Destroy() end
		end },
	})
	local connection
	connection = RunService.Heartbeat:Connect(function(delta)
		if not pizza.Parent then connection:Disconnect(); return end
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
	if self.Riding then self:ExitBike(); return end
	if not self:KitchenNearby() then return end
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if not root or not humanoid then return end
	local bike = Instance.new("Part")
	bike.Name, bike.Size, bike.Color, bike.Material = "ElliotMotorBike", Vector3.new(2.5, 1, 4), Color3.fromRGB(35, 35, 35), Enum.Material.Metal
	bike.CanCollide, bike.Massless, bike.CFrame, bike.Parent = false, true, root.CFrame * CFrame.new(0, -2, 0), self.Character
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1, weld.Parent = root, bike, bike
	self.Riding = true; self.Character:SetAttribute("RidingMotorBike", true); humanoid.AutoRotate = false
	local bikeSpeed = self.CharModule.GameplayConfig.BaseSpeed * self.CharModule.GameplayConfig.SprintSpeedMultiplier * 1.4
	PlayerSpeedManager.AddSpeedFactor(self.Owner, "ElliotMotorBike", bikeSpeed / self.CharModule.GameplayConfig.BaseSpeed)
	PlayerSprintManager.AddStaminaDrain(self.Owner, "ElliotMotorBike", 2)
	ability:AddConnection(RunService.Heartbeat:Connect(function(delta)
		if not self.Riding then return end
		local attrs, stamina = self.Character:FindFirstChild("PlayerAttributes"), nil
		stamina = attrs and attrs:FindFirstChild("Stamina")
		if stamina and stamina:IsA("NumberValue") then stamina.Value = math.max(0, stamina.Value - 12 * delta); if stamina.Value <= 0 then self:ExitBike(); return end end
		local direction = humanoid.MoveDirection.Magnitude > 0 and humanoid.MoveDirection.Unit or root.CFrame.LookVector
		local facing = root.CFrame.LookVector:Lerp(direction, math.clamp(delta * 2.5, 0, 1)).Unit
		root.CFrame = CFrame.lookAt(root.Position, root.Position + facing)
		root.AssemblyLinearVelocity = facing * bikeSpeed + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end))
end

local function PizzaBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end
	local state = self.CharModule.GameplayConfig.Cache.ElliotState
	if state:IsLMS() then Heal(self.Owner.Character:FindFirstChildWhichIsA("Humanoid"))
	elseif state.Riding then state:ThrowPizza()
	else state:ClosePizza() end
end

local function KitchenBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end
	local char, humanoid = self.Owner.Character, self.Owner.Character:FindFirstChildWhichIsA("Humanoid")
	CommonFunctions.ApplyEffect({ TargetHumanoid = humanoid, EffectSettings = { Name = "Helpless", Duration = self.Duration } })
	CommonFunctions.ApplyEffect({ TargetHumanoid = humanoid, EffectSettings = { Name = "Slowness", Level = 3, Duration = self.Duration } })
	self.CharModule.GameplayConfig.Cache.ElliotState:PlaceOrRepairKitchen()
end

local function BikeBehaviour(self: Types.Ability)
	if RunService:IsServer() then self.CharModule.GameplayConfig.Cache.ElliotState:RideBike(self) end
end

local Elliot: Types.Survivor = Character.CreateSurvivor({
	Config = { Name = "Elliot", Quote = "Fresh from the kitchen.", Render = "rbxasset://textures/ui/GuiImagePlaceholder.png" },
	GameplayConfig = {
		Health = 100, BaseSpeed = 10.5, StaminaProperties = { MaxStamina = 100, StaminaDrain = 10, StaminaGain = 20 }, Cache = { Animations = {} },
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
	{ Type = "Text", Text = "Heal a nearby survivor, throw only while riding, or self-heal during the server's LMS flag." },
	{ Type = "Header", Text = "KITCHEN" },
	{ Type = "Text", Text = "Places a kitchen while Elliot is Helpless and Slowed. It produces pizza every 20 seconds and displays a timer." },
	{ Type = "Header", Text = "MOTOR BIKE" },
	{ Type = "Text", Text = "Fixed-speed scooter rush with slow turning, stamina drain, and tap-again exit." },
}

return Elliot
