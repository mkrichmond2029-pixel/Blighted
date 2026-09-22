local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)

local ServerScriptService = game:GetService("ServerScriptService")
local CommonFunctions = RunService:IsServer() and require(ServerScriptService.System.CommonFunctions) or nil
local PlayerSpeedManager = RunService:IsServer() and require(ServerScriptService.Managers.PlayerManager.PlayerSpeedManager) or nil
local PlayerSprintManager = RunService:IsServer() and require(ServerScriptService.Managers.PlayerManager.PlayerSprintManager) or nil

local function asset(folderName: string, name: string): Model?
	if not RunService:IsServer() then return nil end
	local assets = workspace:FindFirstChild("CharacterAssets")
	local elliot = assets and assets:FindFirstChild("Elliot")
	local folder = elliot and elliot:FindFirstChild(folderName)
	local object = folder and folder:FindFirstChild(name)
	return object and object:IsA("Model") and object or nil
end

local KitchenTemplate = asset("KitchenModel", "ElliotDefault")
local ScooterTemplate = asset("ScooterModel", "ScooterDefault")
local ANIM = { Pizza = "rbxassetid://0", Kitchen = "rbxassetid://0", MotorBike = "rbxassetid://0" }

local KITCHEN_RADIUS = 18
local PIZZA_TIME = 20
local BIKE_SPEED = 1.55
local BIKE_TURN_RATE = 2.8
local BIKE_STAMINA_DRAIN = 12
local BIKE_HIT_RANGE = 7
local BIKE_HIT_COOLDOWN = 1.25

local State = {}
State.__index = State

function State.new(owner: Player, character: Model, module: Types.Survivor)
	return setmetatable({
		Owner = owner, Character = character, CharModule = module, Kitchen = nil,
		KitchenConnection = nil, KitchenPickupHitbox = nil, Riding = false,
		BikeConnection = nil, BikeExpireThread = nil, BikeVelocity = nil,
		BikeAttachment = nil, BikeHitCooldowns = {}, PreviousCanSprint = true,
	}, State)
end

function State:Folder()
	local map = workspace:FindFirstChild("Map")
	return (map and map:FindFirstChild("InGame")) or workspace:FindFirstChild("TempObjectFolders") or workspace
end

function State:WorkingKitchen()
	local kitchen = self.Kitchen
	local health = kitchen and kitchen:FindFirstChild("KitchenHealth")
	return kitchen and kitchen.Parent and health and health:IsA("Humanoid") and health.Health > 0
		and kitchen:GetAttribute("Broken") ~= true and kitchen
end

function State:KitchenNearby()
	local kitchen = self:WorkingKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	return kitchen ~= nil and root ~= nil and kitchen.PrimaryPart ~= nil
		and (root.Position - kitchen.PrimaryPart.Position).Magnitude <= KITCHEN_RADIUS
end

function State:IsLMS()
	return workspace:GetAttribute("LMS") == true
end

function State:AddPizza(amount: number)
	local ability = self.CharModule.GameplayConfig.Abilities.PizzaThrow
	ability:ChangeAbilityCharges("Set", math.clamp((ability.UsesLeft or 0) + amount, 0, 2))
end

function State:CreateKitchenHealthBar(model: Model, health: Humanoid)
	local gui = Instance.new("BillboardGui")
	gui.Name, gui.Size, gui.StudsOffset, gui.AlwaysOnTop = "KitchenHealthBar", UDim2.fromOffset(140, 42), Vector3.new(0, 3.2, 0), true
	gui.Parent = model.PrimaryPart

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency, title.Size, title.Font, title.Text = 1, UDim2.new(1, 0, .42, 0), Enum.Font.GothamBold, "KITCHEN"
	title.TextColor3, title.TextScaled, title.Parent = Color3.new(1, 1, 1), true, gui
	local back = Instance.new("Frame")
	back.Position, back.Size, back.BackgroundColor3, back.BorderSizePixel = UDim2.new(0, 4, .48, 0), UDim2.new(1, -8, .32, 0), Color3.fromRGB(50, 20, 20), 0
	back.Parent = gui
	local fill = Instance.new("Frame")
	fill.Size, fill.BackgroundColor3, fill.BorderSizePixel, fill.Parent = UDim2.fromScale(1, 1), Color3.fromRGB(55, 210, 75), 0, back
	local timer = Instance.new("TextLabel")
	timer.BackgroundTransparency, timer.Position, timer.Size, timer.Font = 1, UDim2.new(0, 0, .78, 0), UDim2.fromScale(1, .3), Enum.Font.Gotham
	timer.TextColor3, timer.TextScaled, timer.Parent = Color3.new(1, 1, 1), true, gui

	model:SetAttribute("PizzaReady", false)
	model:SetAttribute("PizzaTimer", PIZZA_TIME)
	health.HealthChanged:Connect(function(value)
		fill.Size = UDim2.fromScale(math.clamp(value / health.MaxHealth, 0, 1), 1)
		fill.BackgroundColor3 = value <= 30 and Color3.fromRGB(220, 55, 45) or Color3.fromRGB(55, 210, 75)
		model:SetAttribute("KitchenHealth", value)
		model:SetAttribute("Broken", value <= 0)
	end)

	task.spawn(function()
		while model.Parent do
			if model:GetAttribute("Broken") then
				model:SetAttribute("PizzaReady", false)
				model:SetAttribute("PizzaTimer", PIZZA_TIME)
				timer.Text = "BROKEN"
				task.wait(.25)
			elseif model:GetAttribute("PizzaReady") then
				timer.Text = "Pizza ready - enter kitchen"
				task.wait(.25)
			else
				local remaining = model:GetAttribute("PizzaTimer") or PIZZA_TIME
				timer.Text = "Pizza in " .. remaining .. "s"
				task.wait(1)
				remaining = math.max(remaining - 1, 0)
				model:SetAttribute("PizzaTimer", remaining)
				if remaining == 0 then model:SetAttribute("PizzaReady", true) end
			end
		end
	end)
end

function State:StartKitchenPickup(model: Model)
	if self.KitchenConnection then self.KitchenConnection:Disconnect() end
	self.KitchenConnection = RunService.Heartbeat:Connect(function()
		if not model.Parent or model:GetAttribute("Broken") or not model:GetAttribute("PizzaReady") then return end
		if self.KitchenPickupHitbox or not model.PrimaryPart then return end
		local folder = workspace:FindFirstChild("Players")
		if not folder then return end
		for _, character in folder:GetChildren() do
			local role = character:FindFirstChild("Role")
			local root = character:FindFirstChild("HumanoidRootPart")
			if role and role.Value == "Survivor" and root and (root.Position - model.PrimaryPart.Position).Magnitude <= KITCHEN_RADIUS then
				local target = character
				local claimed = false
				self.KitchenPickupHitbox = Hitbox.New(self.Owner, {
					CFrame = model.PrimaryPart.CFrame, Size = Vector3.new(12, 8, 12), Damage = 0,
					FriendlyFire = true, Time = .12, Reason = "Elliot Kitchen Pickup",
					Connections = {
						Hit = function(_, humanoid: Humanoid)
							if not claimed and humanoid.Parent == target then
								claimed = true
								self:AddPizza(1)
								model:SetAttribute("PizzaReady", false)
								model:SetAttribute("PizzaTimer", PIZZA_TIME)
							end
						end,
						Ended = function() self.KitchenPickupHitbox = nil end,
					},
				})
				break
			end
		end
	end)
end

function State:CreateKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not KitchenTemplate or not root then return nil end
	local model = KitchenTemplate:Clone()
	model.Name, model.Parent = "ElliotKitchen", self:Folder()
	model:SetAttribute("Broken", false)
	if not model.PrimaryPart then model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true) end
	if not model.PrimaryPart then model:Destroy(); return nil end

	local forward = root.CFrame.LookVector
	local placePos = root.Position + forward * 5
	local params = RaycastParams.new()
	params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, { self.Character, model }
	local result = workspace:Raycast(placePos + Vector3.new(0, 8, 0), Vector3.new(0, -25, 0), params)
	local _, size = model:GetBoundingBox()
	local groundY = result and result.Position.Y or placePos.Y - 3
	model:PivotTo(CFrame.new(placePos.X, groundY + size.Y / 2 + .05, placePos.Z) * CFrame.Angles(0, math.atan2(-forward.X, -forward.Z), 0))

	local health = Instance.new("Humanoid")
	health.Name, health.MaxHealth, health.Health, health.DisplayDistanceType = "KitchenHealth", 100, 100, Enum.HumanoidDisplayDistanceType.None
	health.Parent = model
	self.Kitchen = model
	self:CreateKitchenHealthBar(model, health)
	self:StartKitchenPickup(model)
	return model
end

function State:PlaceOrRepairKitchen()
	if self.Kitchen and self.Kitchen.Parent then
		if self.Kitchen:GetAttribute("Broken") then
			local health = self.Kitchen:FindFirstChild("KitchenHealth")
			if health and health:IsA("Humanoid") then health.Health = health.MaxHealth end
		end
	else
		self:CreateKitchen()
	end
end

local function Heal(humanoid: Humanoid?)
	if not humanoid or humanoid.Health <= 0 then return end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 10)
	task.spawn(function() for _ = 1, 5 do task.wait(1); if humanoid.Parent and humanoid.Health > 0 then humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 3) end end end)
end

function State:ClosePizza()
	local used = false
	Hitbox.New(self.Owner, { CFrameOffset = CFrame.new(0, 0, -3), Size = Vector3.new(4, 5, 5), Damage = 0, FriendlyFire = true, Time = .8, Reason = "Elliot Pizza Heal", Connections = { Hit = function(_, humanoid: Humanoid)
		local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
		if not used and role and role.Value == "Survivor" then used = true; Heal(humanoid) end
	end } })
end

function State:ThrowPizza()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local pizza = Instance.new("Part")
	pizza.Name, pizza.Shape, pizza.Size, pizza.Color, pizza.Material = "ElliotPizza", Enum.PartType.Cylinder, Vector3.new(.4, 1.8, 1.8), Color3.fromRGB(255, 170, 25), Enum.Material.Neon
	pizza.CanCollide, pizza.Anchored, pizza.Parent = false, true, self:Folder()
	local position = root.Position + Vector3.new(0, 1.2, 0) + root.CFrame.LookVector * 2.5
	local velocity = root.CFrame.LookVector * 85 + Vector3.new(0, 22, 0)
	local hit = false
	local hitbox = Hitbox.New(self.Owner, { CFrame = function() return pizza.CFrame end, Size = Vector3.new(3.2, 3.2, 3.2), Damage = 0, FriendlyFire = true, IsProjectile = true, Time = 2.2, Reason = "Pizza Throw", Connections = { Hit = function(_, humanoid: Humanoid)
		local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
		if not hit and role and role.Value == "Survivor" then hit = true; Heal(humanoid); hitbox:Cancel(); if pizza.Parent then pizza:Destroy() end end
	end } })
	local connection
	connection = RunService.Heartbeat:Connect(function(delta)
		if not pizza.Parent then connection:Disconnect(); return end
		velocity = velocity * math.exp(-.55 * delta) - Vector3.new(0, 48, 0) * delta
		position += velocity * delta
		pizza.CFrame = CFrame.lookAt(position, position + velocity) * CFrame.Angles(0, math.rad(90), 0)
	end)
	task.delay(2.3, function() if connection.Connected then connection:Disconnect() end; if pizza.Parent then pizza:Destroy() end end)
end

function State:CleanupBike()
	if self.BikeConnection then self.BikeConnection:Disconnect(); self.BikeConnection = nil end
	if self.BikeVelocity then self.BikeVelocity:Destroy(); self.BikeVelocity = nil end
	if self.BikeAttachment then self.BikeAttachment:Destroy(); self.BikeAttachment = nil end
	if self.Character then
		for _, child in self.Character:GetChildren() do if child.Name == "ElliotMotorBike" then child:Destroy() end end
	end
end

function State:ExitBike()
	if self.BikeExpireThread then task.cancel(self.BikeExpireThread); self.BikeExpireThread = nil end
	self.Riding = false
	self.Character:SetAttribute("RidingMotorBike", false)
	self:CleanupBike()
	PlayerSpeedManager.RemoveSpeedFactor(self.Owner, "ElliotMotorBike")
	PlayerSprintManager.RemoveStaminaDrain(self.Owner, "ElliotMotorBike")
	local data = PlayerSpeedManager.ManagedPlayers[self.Owner]
	if data then
		data.CanSprint = self.PreviousCanSprint
		data.AttemptingSprint = false
		data.SpeedApplied = false
		data.Factors.Sprint = 1
	end
	local attrs = self.Character:FindFirstChild("PlayerAttributes")
	local sprinting = attrs and attrs:FindFirstChild("Sprinting")
	if sprinting and sprinting:IsA("BoolValue") then sprinting.Value = false end
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then humanoid.AutoRotate = true end
end

function State:CreateBike(root: BasePart)
	local bike = ScooterTemplate and ScooterTemplate:Clone() or Instance.new("Model")
	bike.Name = "ElliotMotorBike"
	if not bike.PrimaryPart then
		local body = Instance.new("Part")
		body.Name, body.Size, body.Parent = "Body", Vector3.new(2.5, .55, 4), bike
		body.Color, body.Material, bike.PrimaryPart = Color3.fromRGB(35, 35, 35), Enum.Material.Metal, body
	end
	for _, part in bike:GetDescendants() do if part:IsA("BasePart") then part.CanCollide = false; part.Massless = true end end
	bike:PivotTo(root.CFrame * CFrame.new(0, -2, 0))
	bike.Parent = self.Character
	local weld = Instance.new("WeldConstraint")
	weld.Part0, weld.Part1, weld.Parent = root, bike.PrimaryPart, bike.PrimaryPart
	return bike
end

function State:BikeAttack(root: BasePart)
	local folder = workspace:FindFirstChild("Players")
	if not folder then return end
	for _, target in folder:GetChildren() do
		local role, targetRoot = target:FindFirstChild("Role"), target:FindFirstChild("HumanoidRootPart")
		local humanoid = target:FindFirstChildWhichIsA("Humanoid")
		if role and role.Value == "Killer" and targetRoot and humanoid and humanoid.Health > 0 then
			local offset = targetRoot.Position - root.Position
			if offset.Magnitude <= BIKE_HIT_RANGE and root.CFrame.LookVector:Dot(offset.Unit) > .1 and (self.BikeHitCooldowns[target] or 0) <= os.clock() then
				self.BikeHitCooldowns[target] = os.clock() + BIKE_HIT_COOLDOWN
				Hitbox.New(self.Owner, { CFrame = root.CFrame, Size = Vector3.new(5, 5, 6), Damage = 0, Knockback = 12, Time = .12, Reason = "Elliot Motor Bike Impact", Connections = { Hit = function(_, hitHumanoid: Humanoid)
					if hitHumanoid.Parent == target and targetRoot.Parent then targetRoot.AssemblyLinearVelocity = root.CFrame.LookVector * 65 + Vector3.new(0, 18, 0) end
				end } })
			end
		end
	end
end

function State:RideBike(ability: Types.Ability)
	if self.Riding then self:ExitBike(); return end
	if not self:KitchenNearby() then return end
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if not root or not humanoid then return end

	self:CreateBike(root)
	self.Riding = true
	self.Character:SetAttribute("RidingMotorBike", true)
	humanoid.AutoRotate = false
	local speed = self.CharModule.GameplayConfig.BaseSpeed * BIKE_SPEED
	local speedData = PlayerSpeedManager.ManagedPlayers[self.Owner]
	if speedData then
		self.PreviousCanSprint = speedData.CanSprint
		speedData.CanSprint = false
		speedData.AttemptingSprint = false
		speedData.SpeedApplied = false
		speedData.Factors.Sprint = 1
	end
	PlayerSpeedManager.AddSpeedFactor(self.Owner, "ElliotMotorBike", BIKE_SPEED)
	PlayerSprintManager.AddStaminaDrain(self.Owner, "ElliotMotorBike", 1)

	self.BikeAttachment = Instance.new("Attachment")
	self.BikeAttachment.Name = "ElliotBikeAttachment"
	self.BikeAttachment.Parent = root
	self.BikeVelocity = Instance.new("LinearVelocity")
	self.BikeVelocity.Name = "ElliotBikeLinearVelocity"
	self.BikeVelocity.Attachment0 = self.BikeAttachment
	self.BikeVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	self.BikeVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	self.BikeVelocity.MaxForce = math.huge
	self.BikeVelocity.Parent = root

	self.BikeConnection = RunService.Heartbeat:Connect(function(delta)
		if not self.Riding or not root.Parent then return end
		local attrs = self.Character:FindFirstChild("PlayerAttributes")
		local stamina = attrs and attrs:FindFirstChild("Stamina")
		local data = PlayerSprintManager.ManagedPlayers[self.Owner]
		local currentStamina = data and data.Stamina or (stamina and stamina:IsA("NumberValue") and stamina.Value)
		if typeof(currentStamina) == "number" then
			currentStamina = math.max(0, currentStamina - BIKE_STAMINA_DRAIN * delta)
			if data then data.Stamina = currentStamina end
			if stamina and stamina:IsA("NumberValue") then stamina.Value = currentStamina end
			if currentStamina <= 0 then self:ExitBike(); return end
		end

		local moveDir = humanoid.MoveDirection
		local desired = moveDir.Magnitude > .05 and moveDir.Unit or root.CFrame.LookVector
		local camera = workspace.CurrentCamera
		if camera and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
			if look.Magnitude > .1 then desired = moveDir.Magnitude > .05 and (moveDir.Unit * .65 + look.Unit * .35).Unit or look.Unit end
		end
		desired = Vector3.new(desired.X, 0, desired.Z)
		if desired.Magnitude < .01 then desired = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end
		desired = desired.Unit
		local current = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
		local angle = math.acos(math.clamp(current:Dot(desired), -1, 1))
		local newLook = desired
		if angle > BIKE_TURN_RATE * delta then
			local sign = current:Cross(desired).Y >= 0 and 1 or -1
			newLook = (CFrame.fromAxisAngle(Vector3.yAxis, sign * BIKE_TURN_RATE * delta) * current).Unit
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + newLook)
		local velocity = newLook * speed
		self.BikeVelocity.VectorVelocity = velocity
		-- Humanoid movement can overwrite a constraint for one simulation step;
		-- keep the server-authoritative horizontal velocity locked to the bike.
		root.AssemblyLinearVelocity = Vector3.new(velocity.X, root.AssemblyLinearVelocity.Y, velocity.Z)
		self:BikeAttack(root)
	end)
	self.BikeExpireThread = task.delay(ability.Duration or 8, function() if self.Riding then self:ExitBike() end end)
end

local function PizzaBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end
	local state = self.CharModule.GameplayConfig.Cache.ElliotState
	if state:IsLMS() then Heal(self.Owner.Character and self.Owner.Character:FindFirstChildWhichIsA("Humanoid")) elseif state.Riding then state:ThrowPizza() else state:ClosePizza() end
end

local function KitchenBehaviour(self: Types.Ability)
	if not RunService:IsServer() then return end
	local state = self.CharModule.GameplayConfig.Cache.ElliotState
	if state.Riding then return end
	local humanoid = self.Owner.Character and self.Owner.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		CommonFunctions.ApplyEffect({ TargetHumanoid = humanoid, EffectSettings = { Name = "Helpless", Duration = self.Duration } })
		CommonFunctions.ApplyEffect({ TargetHumanoid = humanoid, EffectSettings = { Name = "Slowness", Level = 3, Duration = self.Duration } })
	end
	state:PlaceOrRepairKitchen()
end

local function BikeBehaviour(self: Types.Ability)
	if RunService:IsServer() then self.CharModule.GameplayConfig.Cache.ElliotState:RideBike(self) end
end

local function CreatePizzaHud(player: Player, ability: Types.Ability)
	local gui = Instance.new("ScreenGui")
	gui.Name, gui.ResetOnSpawn, gui.Parent = "ElliotPizzaHud", false, player:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel")
	label.Name, label.AnchorPoint, label.Position, label.Size = "PizzaCount", Vector2.new(.5, 1), UDim2.fromScale(.5, .94), UDim2.fromOffset(210, 36)
	label.BackgroundColor3, label.TextColor3, label.Font, label.TextScaled, label.Parent = Color3.fromRGB(35, 20, 10), Color3.fromRGB(255, 220, 100), Enum.Font.GothamBold, true, gui
	local function update() label.Text = "Pizza slices: " .. tostring(math.clamp(ability.UsesLeft or 0, 0, 2)) .. "/2" end
	ability.Signals.ChargesChanged:Connect(update)
	update()
end

local Elliot: Types.Survivor = Character.CreateSurvivor({
	Config = { Name = "Elliot", Quote = "Fresh from the kitchen.", Render = "rbxasset://textures/ui/GuiImagePlaceholder.png" },
	GameplayConfig = {
		Health = 100, BaseSpeed = 10.5,
		StaminaProperties = { MaxStamina = 100, StaminaDrain = 10, StaminaGain = 20 },
		Cache = { Animations = {} },
		Abilities = {
			PizzaThrow = Ability.New({ Name = "Pizza Throw", InputName = "FirstAbility", Cooldown = 20, Duration = .8, UseAnimation = ANIM.Pizza, UseSettings = { InitialUses = 2, Limited = true }, Behaviour = PizzaBehaviour }),
			Kitchen = Ability.New({ Name = "Kitchen", InputName = "SecondAbility", Cooldown = 20, Duration = 2.5, UseAnimation = ANIM.Kitchen, UseConditions = function(self: Types.Ability) local state = self.CharModule.GameplayConfig.Cache.ElliotState return RunService:IsClient() or (state and not state.Riding) end, Behaviour = KitchenBehaviour }),
			MotorBike = Ability.New({ Name = "Motor Bike", InputName = "ThirdAbility", Cooldown = 1, Duration = 8, UseAnimation = ANIM.MotorBike, UseConditions = function(self: Types.Ability) local state = self.CharModule.GameplayConfig.Cache.ElliotState return RunService:IsClient() or state:KitchenNearby() or state.Riding end, Behaviour = BikeBehaviour }),
		},
	},
	OnInit = function(self: Types.Survivor, character: Model)
		if RunService:IsServer() then self.GameplayConfig.Cache.ElliotState = State.new(self.Owner, character, self) else CreatePizzaHud(Players.LocalPlayer, self.GameplayConfig.Abilities.PizzaThrow) end
	end,
})

Elliot.Config.Description = {
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "PIZZA THROW" },
	{ Type = "Text", Text = "Heal a nearby survivor, throw while riding, or self-heal during LMS." },
	{ Type = "Header", Text = "KITCHEN" },
	{ Type = "Text", Text = "A ready kitchen gives one pizza to a survivor who enters its pickup area." },
	{ Type = "Header", Text = "MOTOR BIKE" },
	{ Type = "Text", Text = "Disables sprint, applies linear velocity, drains stamina, limits turning, knocks back killers, and removes its prop when the ride ends." },
}

return Elliot
