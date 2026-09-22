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

local function findAsset(folderName: string, assetName: string): Model?
	if not RunService:IsServer() then
		return nil
	end
	local assets = workspace:FindFirstChild("CharacterAssets")
	local elliot = assets and assets:FindFirstChild("Elliot")
	local folder = elliot and elliot:FindFirstChild(folderName)
	local asset = folder and folder:FindFirstChild(assetName)
	return asset and asset:IsA("Model") and asset or nil
end

local KitchenTemplate = findAsset("KitchenModel", "ElliotDefault")
local ScooterTemplate = findAsset("ScooterModel", "ScooterDefault")

local ANIM = {
	Pizza = "rbxassetid://0",
	Kitchen = "rbxassetid://0",
	MotorBike = "rbxassetid://0",
}

local KITCHEN_RADIUS = 18
local KITCHEN_PIZZA_TIME = 20
local BIKE_HIT_RANGE = 7
local BIKE_HIT_COOLDOWN = 1.25
local BIKE_SPEED_MULTIPLIER = 1.55
local BIKE_TURN_RATE = 2.8

local ElliotState = {}
ElliotState.__index = ElliotState

function ElliotState.new(owner: Player, character: Model, module: Types.Survivor)
	return setmetatable({
		Owner = owner,
		Character = character,
		CharModule = module,
		Kitchen = nil,
		KitchenPickupConnection = nil,
		KitchenPickupHitbox = nil,
		Riding = false,
		BikeConnection = nil,
		BikeExpireThread = nil,
		BikeVelocity = nil,
		BikeAttachment = nil,
		BikeHitCooldowns = {},
		PreviousCanSprint = true,
	}, ElliotState)
end

function ElliotState:Folder()
	local map = workspace:FindFirstChild("Map")
	return (map and map:FindFirstChild("InGame")) or workspace:FindFirstChild("TempObjectFolders") or workspace
end

function ElliotState:WorkingKitchen()
	local kitchen = self.Kitchen
	local health = kitchen and kitchen:FindFirstChild("KitchenHealth")
	return kitchen and kitchen.Parent and health and health:IsA("Humanoid") and health.Health > 0
		and kitchen:GetAttribute("Broken") ~= true and kitchen
end

function ElliotState:KitchenNearby()
	local kitchen = self:WorkingKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	return kitchen ~= nil and root ~= nil and kitchen.PrimaryPart ~= nil
		and (root.Position - kitchen.PrimaryPart.Position).Magnitude <= KITCHEN_RADIUS
end

function ElliotState:IsLMS()
	return workspace:GetAttribute("LMS") == true
end

function ElliotState:AddPizza(amount: number)
	local ability = self.CharModule.GameplayConfig.Abilities.PizzaThrow
	ability:ChangeAbilityCharges("Set", math.clamp((ability.UsesLeft or 0) + amount, 0, 2))
end

function ElliotState:CreateKitchenHealthBar(model: Model, health: Humanoid)
	local gui = Instance.new("BillboardGui")
	gui.Name = "KitchenHealthBar"
	gui.Size = UDim2.fromOffset(140, 42)
	gui.StudsOffset = Vector3.new(0, 3.2, 0)
	gui.AlwaysOnTop = true
	gui.Parent = model.PrimaryPart

	local title = Instance.new("TextLabel")
	title.BackgroundTransparency = 1
	title.Size = UDim2.new(1, 0, 0.42, 0)
	title.Font = Enum.Font.GothamBold
	title.Text = "KITCHEN"
	title.TextColor3 = Color3.new(1, 1, 1)
	title.TextScaled = true
	title.Parent = gui

	local back = Instance.new("Frame")
	back.Position = UDim2.new(0, 4, 0.48, 0)
	back.Size = UDim2.new(1, -8, 0.32, 0)
	back.BackgroundColor3 = Color3.fromRGB(50, 20, 20)
	back.BorderSizePixel = 0
	back.Parent = gui

	local fill = Instance.new("Frame")
	fill.Size = UDim2.fromScale(1, 1)
	fill.BackgroundColor3 = Color3.fromRGB(55, 210, 75)
	fill.BorderSizePixel = 0
	fill.Parent = back

	local timer = Instance.new("TextLabel")
	timer.BackgroundTransparency = 1
	timer.Position = UDim2.new(0, 0, 0.78, 0)
	timer.Size = UDim2.fromScale(1, 0.3)
	timer.Font = Enum.Font.Gotham
	timer.TextColor3 = Color3.new(1, 1, 1)
	timer.TextScaled = true
	timer.Parent = gui

	model:SetAttribute("PizzaReady", false)
	model:SetAttribute("PizzaTimer", KITCHEN_PIZZA_TIME)

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
				model:SetAttribute("PizzaTimer", KITCHEN_PIZZA_TIME)
				timer.Text = "BROKEN"
				task.wait(0.25)
			else
				local remaining = model:GetAttribute("PizzaTimer") or KITCHEN_PIZZA_TIME
				if model:GetAttribute("PizzaReady") then
					timer.Text = "Pizza ready - enter kitchen"
					task.wait(0.25)
				else
					timer.Text = "Pizza in " .. math.max(remaining, 0) .. "s"
					task.wait(1)
					remaining = math.max(remaining - 1, 0)
					model:SetAttribute("PizzaTimer", remaining)
					if remaining <= 0 then
						model:SetAttribute("PizzaReady", true)
					end
				end
			end
		end
	end)
end

function ElliotState:StartKitchenPickup(model: Model)
	if self.KitchenPickupConnection then
		self.KitchenPickupConnection:Disconnect()
	end

	self.KitchenPickupConnection = RunService.Heartbeat:Connect(function()
		if not model.Parent or model:GetAttribute("Broken") or not model:GetAttribute("PizzaReady") then
			return
		end
		if self.KitchenPickupHitbox or not model.PrimaryPart then
			return
		end

		local playersFolder = workspace:FindFirstChild("Players")
		if not playersFolder then
			return
		end

		for _, character in playersFolder:GetChildren() do
			local role = character:FindFirstChild("Role")
			local root = character:FindFirstChild("HumanoidRootPart")
			if role and role.Value == "Survivor" and root
				and (root.Position - model.PrimaryPart.Position).Magnitude <= KITCHEN_RADIUS then
				local targetCharacter = character
				local claimed = false
				self.KitchenPickupHitbox = Hitbox.New(self.Owner, {
					CFrame = model.PrimaryPart.CFrame,
					CFrameOffset = CFrame.new(),
					Size = Vector3.new(12, 8, 12),
					Damage = 0,
					FriendlyFire = true,
					HitMultiple = false,
					Time = 0.12,
					Reason = "Elliot Kitchen Pickup",
					Connections = {
						Hit = function(_, humanoid: Humanoid)
							local hitCharacter = humanoid.Parent
							local hitRole = hitCharacter and hitCharacter:FindFirstChild("Role")
							if not claimed and hitCharacter == targetCharacter and hitRole and hitRole.Value == "Survivor" then
								claimed = true
								self:AddPizza(1)
								model:SetAttribute("PizzaReady", false)
								model:SetAttribute("PizzaTimer", KITCHEN_PIZZA_TIME)
							end
						end,
						Ended = function()
							self.KitchenPickupHitbox = nil
						end,
					},
				})
				break
			end
		end
	end)
end

function ElliotState:CreateKitchen()
	if not KitchenTemplate then
		warn("[Elliot] KitchenModel/ElliotDefault is missing")
		return nil
	end

	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end

	local model = KitchenTemplate:Clone()
	model.Name = "ElliotKitchen"
	model:SetAttribute("Broken", false)
	if not model.PrimaryPart then
		model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true)
	end
	if not model.PrimaryPart then
		model:Destroy()
		return nil
	end

	local forward = root.CFrame.LookVector
	local placePos = root.Position + forward * 5
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	rayParams.FilterDescendantsInstances = { self.Character, model }
	local result = workspace:Raycast(placePos + Vector3.new(0, 8, 0), Vector3.new(0, -25, 0), rayParams)
	local _, size = model:GetBoundingBox()
	local groundY = result and result.Position.Y or placePos.Y - 3
	local rotation = math.atan2(-forward.X, -forward.Z)

	model:PivotTo(CFrame.new(placePos.X, groundY + size.Y / 2 + 0.05, placePos.Z) * CFrame.Angles(0, rotation, 0))
	model.Parent = self:Folder()
	self.Kitchen = model

	local health = Instance.new("Humanoid")
	health.Name = "KitchenHealth"
	health.MaxHealth = 100
	health.Health = 100
	health.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	health.Parent = model

	self:CreateKitchenHealthBar(model, health)
	self:StartKitchenPickup(model)
	return model
end

function ElliotState:PlaceOrRepairKitchen()
	if self.Kitchen and self.Kitchen.Parent then
		if self.Kitchen:GetAttribute("Broken") then
			local health = self.Kitchen:FindFirstChild("KitchenHealth")
			if health and health:IsA("Humanoid") then
				health.Health = health.MaxHealth
			end
		end
		return
	end
	self:CreateKitchen()
end

local function Heal(humanoid: Humanoid?)
	if not humanoid or humanoid.Health <= 0 then
		return
	end
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
	local used = false
	Hitbox.New(self.Owner, {
		CFrameOffset = CFrame.new(0, 0, -3), Size = Vector3.new(4, 5, 5), Damage = 0,
		FriendlyFire = true, Time = 0.8, Reason = "Elliot Pizza Heal",
		Connections = { Hit = function(_, humanoid: Humanoid)
			local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
			if not used and role and role.Value == "Survivor" then
				used = true
				Heal(humanoid)
			end
		end },
	})
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

	local position = root.Position + Vector3.new(0, 1.2, 0) + root.CFrame.LookVector * 2.5
	local velocity = root.CFrame.LookVector * 85 + Vector3.new(0, 22, 0)
	local hit = false
	local hitbox = Hitbox.New(self.Owner, {
		CFrame = function() return pizza.CFrame end, Size = Vector3.new(3.2, 3.2, 3.2),
		Damage = 0, FriendlyFire = true, IsProjectile = true, Time = 2.2, Reason = "Pizza Throw",
		Connections = { Hit = function(_, humanoid: Humanoid)
			local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
			if not hit and role and role.Value == "Survivor" then
				hit = true
				Heal(humanoid)
				hitbox:Cancel()
				if pizza.Parent then pizza:Destroy() end
			end
		end },
	})
	local connection
	connection = RunService.Heartbeat:Connect(function(delta)
		if not pizza.Parent then connection:Disconnect(); return end
		velocity = velocity * math.exp(-0.55 * delta) - Vector3.new(0, 48, 0) * delta
		position += velocity * delta
		pizza.CFrame = CFrame.lookAt(position, position + velocity) * CFrame.Angles(0, math.rad(90), 0)
	end)
	task.delay(2.3, function()
		if connection.Connected then connection:Disconnect() end
		if pizza.Parent then pizza:Destroy() end
	end)
end

function ElliotState:CleanupBikeObjects()
	if self.BikeVelocity then self.BikeVelocity:Destroy(); self.BikeVelocity = nil end
	if self.BikeAttachment then self.BikeAttachment:Destroy(); self.BikeAttachment = nil end
	for _, child in self.Character:GetChildren() do
		if child.Name == "ElliotMotorBike" then child:Destroy() end
	end
end

function ElliotState:ExitBike()
	if not self.Riding then
		self:CleanupBikeObjects()
		return
	end
	self.Riding = false
	self.Character:SetAttribute("RidingMotorBike", false)
	if self.BikeConnection then self.BikeConnection:Disconnect(); self.BikeConnection = nil end
	if self.BikeExpireThread then task.cancel(self.BikeExpireThread); self.BikeExpireThread = nil end
	self:CleanupBikeObjects()
	PlayerSpeedManager.RemoveSpeedFactor(self.Owner, "ElliotMotorBike")
	PlayerSprintManager.RemoveStaminaDrain(self.Owner, "ElliotMotorBike")
	local speedData = PlayerSpeedManager.ManagedPlayers[self.Owner]
	if speedData then
		speedData.CanSprint = self.PreviousCanSprint
		speedData.AttemptingSprint = false
		speedData.SpeedApplied = false
		speedData.Factors.Sprint = 1
	end
	local attrs = self.Character:FindFirstChild("PlayerAttributes")
	local sprinting = attrs and attrs:FindFirstChild("Sprinting")
	if sprinting and sprinting:IsA("BoolValue") then sprinting.Value = false end
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then humanoid.AutoRotate = true end
end

function ElliotState:CreateBike(root: BasePart)
	local bike = ScooterTemplate and ScooterTemplate:Clone() or Instance.new("Model")
	bike.Name = "ElliotMotorBike"
	if not bike.PrimaryPart then
		local body = Instance.new("Part")
		body.Name = "Body"
		body.Size = Vector3.new(2.5, 0.55, 4)
		body.Color = Color3.fromRGB(35, 35, 35)
		body.Material = Enum.Material.Metal
		body.Parent = bike
		bike.PrimaryPart = body
	end
	for _, part in bike:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.Massless = true
		end
	end
	bike:PivotTo(root.CFrame * CFrame.new(0, -2, 0))
	bike.Parent = self.Character
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = bike.PrimaryPart
	weld.Parent = bike.PrimaryPart
	return bike
end

function ElliotState:BikeAttack(root: BasePart)
	local playersFolder = workspace:FindFirstChild("Players")
	if not playersFolder then return end
	for _, target in playersFolder:GetChildren() do
		local role = target:FindFirstChild("Role")
		local targetRoot = target:FindFirstChild("HumanoidRootPart")
		local humanoid = target:FindFirstChildWhichIsA("Humanoid")
		if role and role.Value == "Killer" and targetRoot and humanoid and humanoid.Health > 0 then
			local offset = targetRoot.Position - root.Position
			local distance = offset.Magnitude
			local inFront = distance > 0 and root.CFrame.LookVector:Dot(offset.Unit) > 0.1
			if distance <= BIKE_HIT_RANGE and inFront and (self.BikeHitCooldowns[target] or 0) <= os.clock() then
				self.BikeHitCooldowns[target] = os.clock() + BIKE_HIT_COOLDOWN
				Hitbox.New(self.Owner, {
					CFrame = root.CFrame, CFrameOffset = CFrame.new(), Size = Vector3.new(5, 5, 6),
					Damage = 0, Knockback = 12, Time = 0.12, HitMultiple = false,
					Reason = "Elliot Motor Bike Impact",
					Connections = { Hit = function(_, hitHumanoid: Humanoid)
						if hitHumanoid.Parent == target and targetRoot.Parent then
							targetRoot.AssemblyLinearVelocity = root.CFrame.LookVector * 65 + Vector3.new(0, 18, 0)
						end
					end },
				})
			end
		end
	end
end

function ElliotState:RideBike(ability: Types.Ability)
	if self.Riding then self:ExitBike(); return end
	if not self:KitchenNearby() then return end
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if not root or not humanoid then return end

	self:CreateBike(root)
	self.Riding = true
	self.Character:SetAttribute("RidingMotorBike", true)
	humanoid.AutoRotate = false
	local bikeSpeed = self.CharModule.GameplayConfig.BaseSpeed * BIKE_SPEED_MULTIPLIER
	local speedData = PlayerSpeedManager.ManagedPlayers[self.Owner]
	if speedData then
		self.PreviousCanSprint = speedData.CanSprint
		speedData.CanSprint = false
		speedData.AttemptingSprint = false
		speedData.SpeedApplied = false
		speedData.Factors.Sprint = 1
	end
	PlayerSpeedManager.AddSpeedFactor(self.Owner, "ElliotMotorBike", BIKE_SPEED_MULTIPLIER)
	PlayerSprintManager.AddStaminaDrain(self.Owner, "ElliotMotorBike", 1)

	self.BikeAttachment = Instance.new("Attachment")
	self.BikeAttachment.Name = "ElliotBikeVelocityAttachment"
	self.BikeAttachment.Parent = root
	self.BikeVelocity = Instance.new("LinearVelocity")
	self.BikeVelocity.Name = "ElliotBikeVelocity"
	self.BikeVelocity.Attachment0 = self.BikeAttachment
	self.BikeVelocity.RelativeTo = Enum.ActuatorRelativeTo.World
	self.BikeVelocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
	self.BikeVelocity.MaxForce = math.huge
	self.BikeVelocity.Parent = root

	self.BikeConnection = RunService.Heartbeat:Connect(function(delta)
		if not self.Riding or not root.Parent then return end
		local attrs = self.Character:FindFirstChild("PlayerAttributes")
		local staminaValue = attrs and attrs:FindFirstChild("Stamina")
		local sprintData = PlayerSprintManager.ManagedPlayers[self.Owner]
		if sprintData then
			sprintData.Stamina = math.max(0, sprintData.Stamina - 12 * delta)
			if staminaValue and staminaValue:IsA("NumberValue") then staminaValue.Value = sprintData.Stamina end
			if sprintData.Stamina <= 0 then self:ExitBike(); return end
		elseif staminaValue and staminaValue:IsA("NumberValue") then
			staminaValue.Value = math.max(0, staminaValue.Value - 12 * delta)
			if staminaValue.Value <= 0 then self:ExitBike(); return end
		end

		local moveDir = humanoid.MoveDirection
		local desired = moveDir.Magnitude > 0.05 and moveDir.Unit or root.CFrame.LookVector
		local camera = workspace.CurrentCamera
		if camera and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			local camLook = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
			if camLook.Magnitude > 0.1 then
				desired = moveDir.Magnitude > 0.05 and (moveDir.Unit * 0.65 + camLook.Unit * 0.35).Unit or camLook.Unit
			end
		end
		desired = Vector3.new(desired.X, 0, desired.Z)
		if desired.Magnitude < 0.01 then desired = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z) end
		desired = desired.Unit
		local current = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
		local angle = math.acos(math.clamp(current:Dot(desired), -1, 1))
		local newLook = desired
		if angle > BIKE_TURN_RATE * delta then
			local sign = current:Cross(desired).Y >= 0 and 1 or -1
			newLook = (CFrame.fromAxisAngle(Vector3.yAxis, sign * BIKE_TURN_RATE * delta) * current).Unit
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + newLook)
		self.BikeVelocity.VectorVelocity = newLook * bikeSpeed + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
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
	label.Name, label.AnchorPoint, label.Position, label.Size = "PizzaCount", Vector2.new(0.5, 1), UDim2.fromScale(0.5, 0.94), UDim2.fromOffset(210, 36)
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
			PizzaThrow = Ability.New({ Name = "Pizza Throw", InputName = "FirstAbility", Cooldown = 20, Duration = 0.8, UseAnimation = ANIM.Pizza, UseSettings = { InitialUses = 2, Limited = true }, Behaviour = PizzaBehaviour }),
			Kitchen = Ability.New({ Name = "Kitchen", InputName = "SecondAbility", Cooldown = 20, Duration = 2.5, UseAnimation = ANIM.Kitchen, UseConditions = function(self: Types.Ability) local state = self.CharModule.GameplayConfig.Cache.ElliotState return RunService:IsClient() or (state and not state.Riding) end, Behaviour = KitchenBehaviour }),
			MotorBike = Ability.New({ Name = "Motor Bike", InputName = "ThirdAbility", Cooldown = 1, Duration = 8, UseAnimation = ANIM.MotorBike, UseConditions = function(self: Types.Ability) local state = self.CharModule.GameplayConfig.Cache.ElliotState return RunService:IsClient() or state:KitchenNearby() or state.Riding end, Behaviour = BikeBehaviour }),
		},
	},
	OnInit = function(self: Types.Survivor, character: Model)
		if RunService:IsServer() then self.GameplayConfig.Cache.ElliotState = ElliotState.new(self.Owner, character, self) else CreatePizzaHud(Players.LocalPlayer, self.GameplayConfig.Abilities.PizzaThrow) end
	end,
})

Elliot.Config.Description = {
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "PIZZA THROW" },
	{ Type = "Text", Text = "Heal a nearby survivor, throw while riding, or self-heal during LMS." },
	{ Type = "Header", Text = "KITCHEN" },
	{ Type = "Text", Text = "A ready kitchen gives one pizza to a survivor who enters its pickup area." },
	{ Type = "Header", Text = "MOTOR BIKE" },
	{ Type = "Text", Text = "Disables sprint, applies linear velocity, limits turning, knocks back killers, and removes its prop when the ride ends." },
}

return Elliot
