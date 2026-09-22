local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)

local CommonFunctions = RunService:IsServer() and require(game:GetService("ServerScriptService").System.CommonFunctions) or nil
local PlayerSpeedManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSpeedManager) or nil
local PlayerSprintManager = RunService:IsServer() and require(game:GetService("ServerScriptService").Managers.PlayerManager.PlayerSprintManager) or nil

-- Kitchen template (Model)
local KitchenTemplate = nil
if RunService:IsServer() then
	local assets = workspace:FindFirstChild("CharacterAssets")
		and workspace.CharacterAssets:FindFirstChild("Elliot")
		and workspace.CharacterAssets.Elliot:FindFirstChild("KitchenModel")
	if assets then
		KitchenTemplate = assets:FindFirstChild("ElliotDefault")
	end
end

local ANIM = {
	Pizza = "rbxassetid://0",
	Kitchen = "rbxassetid://0",
	MotorBike = "rbxassetid://0",
}

local ElliotState = {}
ElliotState.__index = ElliotState

function ElliotState.new(owner: Player, character: Model, module: Types.Survivor)
	return setmetatable({
		Owner = owner,
		Character = character,
		CharModule = module,
		Kitchen = nil,
		Riding = false,
		BikeConnection = nil,
		BikeExpireThread = nil,
	}, ElliotState)
end

function ElliotState:Folder()
	local map = workspace:FindFirstChild("Map")
	return (map and map:FindFirstChild("InGame")) or workspace:FindFirstChild("TempObjectFolders") or workspace
end

function ElliotState:WorkingKitchen()
	local kitchen = self.Kitchen
	local health = kitchen and kitchen:FindFirstChild("KitchenHealth")
	return kitchen
		and kitchen.Parent
		and health
		and health.Health > 0
		and not kitchen:GetAttribute("Broken")
		and kitchen
end

function ElliotState:KitchenNearby()
	local kitchen = self:WorkingKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	return kitchen ~= nil
		and root ~= nil
		and kitchen.PrimaryPart ~= nil
		and (root.Position - kitchen.PrimaryPart.Position).Magnitude <= 18
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

	health.HealthChanged:Connect(function(value)
		fill.Size = UDim2.fromScale(math.clamp(value / health.MaxHealth, 0, 1), 1)
		fill.BackgroundColor3 = value <= 30 and Color3.fromRGB(220, 55, 45) or Color3.fromRGB(55, 210, 75)
	end)

	task.spawn(function()
		local remaining = 20
		while model.Parent do
			if model:GetAttribute("Broken") then
				timer.Text = "BROKEN"
				task.wait(0.25)
			else
				timer.Text = remaining > 0 and ("Pizza in " .. remaining .. "s") or "Pizza ready"
				task.wait(1)
				remaining -= 1
				if remaining <= 0 then
					self:AddPizza(1)
					remaining = 20
				end
			end
		end
	end)
end

function ElliotState:CreateKitchen()
	if not KitchenTemplate then
		warn("[Elliot] KitchenTemplate (ElliotDefault) is missing from CharacterAssets")
		return nil
	end

	local model = KitchenTemplate:Clone()
	model.Name = "ElliotKitchen"
	model:SetAttribute("Broken", false)

	if not model.PrimaryPart then
		local part = model:FindFirstChildWhichIsA("BasePart", true)
		if part then
			model.PrimaryPart = part
		else
			warn("[Elliot] Kitchen model has no BasePart")
			model:Destroy()
			return nil
		end
	end

	-- Place on the ground from the BOTTOM of the model
	local root = self.Character.HumanoidRootPart
	local forward = root.CFrame.LookVector
	local placePos = root.Position + forward * 5

	local rayParams = RaycastParams.new()
	rayParams.FilterDescendantsInstances = { self.Character, model }
	rayParams.FilterType = Enum.RaycastFilterType.Exclude

	local origin = placePos + Vector3.new(0, 8, 0)
	local result = workspace:Raycast(origin, Vector3.new(0, -25, 0), rayParams)

	local groundY = result and result.Position.Y or (placePos.Y - 3)

	-- Use bounding box so the bottom of the model sits on the ground
	local cf, size = model:GetBoundingBox()
	local halfHeight = size.Y / 2

	local finalCFrame = CFrame.new(placePos.X, groundY + halfHeight + 0.05, placePos.Z)
		* CFrame.Angles(0, math.atan2(-forward.X, -forward.Z), 0)

	model:PivotTo(finalCFrame)
	model.Parent = self:Folder()
	self.Kitchen = model

	local health = Instance.new("Humanoid")
	health.Name = "KitchenHealth"
	health.MaxHealth = 100
	health.Health = 100
	health.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	health.Parent = model

	self:CreateKitchenHealthBar(model, health)

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
			if health then
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
		CFrameOffset = CFrame.new(0, 0, -3),
		Size = Vector3.new(4, 5, 5),
		Damage = 0,
		FriendlyFire = true,
		Time = 0.8,
		Reason = "Elliot Pizza Heal",
		Connections = {
			Hit = function(_, humanoid: Humanoid)
				local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
				if not used and role and role.Value == "Survivor" then
					used = true
					Heal(humanoid)
				end
			end,
		},
	})
end

function ElliotState:ThrowPizza()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local pizza = Instance.new("Part")
	pizza.Name = "ElliotPizza"
	pizza.Shape = Enum.PartType.Cylinder
	pizza.Size = Vector3.new(0.4, 1.8, 1.8)
	pizza.Color = Color3.fromRGB(255, 170, 25)
	pizza.Material = Enum.Material.Neon
	pizza.CanCollide = false
	pizza.Anchored = true
	pizza.Parent = self:Folder()

	local throwSpeed = 85
	local position = root.Position + Vector3.new(0, 1.2, 0) + root.CFrame.LookVector * 2.5
	local velocity = root.CFrame.LookVector * throwSpeed + Vector3.new(0, 22, 0)
	local hit = false

	local hitbox = Hitbox.New(self.Owner, {
		CFrame = function()
			return pizza.CFrame
		end,
		Size = Vector3.new(3.2, 3.2, 3.2),
		Damage = 0,
		FriendlyFire = true,
		IsProjectile = true,
		Time = 2.2,
		Reason = "Pizza Throw",
		Connections = {
			Hit = function(_, humanoid: Humanoid)
				local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
				if not hit and role and role.Value == "Survivor" then
					hit = true
					Heal(humanoid)
					hitbox:Cancel()
					if pizza.Parent then
						pizza:Destroy()
					end
				end
			end,
		},
	})

	local connection
	connection = RunService.Heartbeat:Connect(function(delta)
		if not pizza.Parent then
			connection:Disconnect()
			return
		end
		velocity = velocity * math.exp(-0.55 * delta) - Vector3.new(0, 48, 0) * delta
		position += velocity * delta
		pizza.CFrame = CFrame.lookAt(position, position + velocity) * CFrame.Angles(0, math.rad(90), 0)
	end)

	task.delay(2.3, function()
		if connection.Connected then
			connection:Disconnect()
		end
		if pizza.Parent then
			pizza:Destroy()
		end
	end)
end

function ElliotState:ExitBike()
	if not self.Riding then
		return
	end

	self.Riding = false
	self.Character:SetAttribute("RidingMotorBike", false)

	if self.BikeConnection then
		self.BikeConnection:Disconnect()
		self.BikeConnection = nil
	end

	if self.BikeExpireThread then
		task.cancel(self.BikeExpireThread)
		self.BikeExpireThread = nil
	end

	PlayerSpeedManager.RemoveSpeedFactor(self.Owner, "ElliotMotorBike")
	PlayerSprintManager.RemoveStaminaDrain(self.Owner, "ElliotMotorBike")

	-- Destroy the bike prop
	local bike = self.Character:FindFirstChild("ElliotMotorBike")
	if bike then
		bike:Destroy()
	end

	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		humanoid.AutoRotate = true
	end
end

function ElliotState:CreateBike(root: BasePart)
	local bike = Instance.new("Model")
	bike.Name = "ElliotMotorBike"

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Size = Vector3.new(2.5, 0.55, 4)
	body.Color = Color3.fromRGB(35, 35, 35)
	body.Material = Enum.Material.Metal
	body.CanCollide = false
	body.Massless = true
	body.CFrame = root.CFrame * CFrame.new(0, -2, 0)
	body.Parent = bike
	bike.PrimaryPart = body

	for _, z in {-1.35, 1.35} do
		local wheel = Instance.new("Part")
		wheel.Name = "Wheel"
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = Vector3.new(0.35, 1.25, 1.25)
		wheel.Color = Color3.fromRGB(15, 15, 15)
		wheel.Material = Enum.Material.Rubber
		wheel.CanCollide = false
		wheel.Massless = true
		wheel.CFrame = body.CFrame * CFrame.new(0, -0.35, z) * CFrame.Angles(0, 0, math.rad(90))
		wheel.Parent = bike

		local weld = Instance.new("WeldConstraint")
		weld.Part0 = body
		weld.Part1 = wheel
		weld.Parent = wheel
	end

	bike.Parent = self.Character

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = root
	weld.Part1 = body
	weld.Parent = body

	return bike
end

function ElliotState:RideBike(ability: Types.Ability)
	if self.Riding then
		self:ExitBike()
		return
	end

	if not self:KitchenNearby() then
		return
	end

	local root = self.Character:FindFirstChild("HumanoidRootPart")
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if not root or not humanoid then
		return
	end

	self:CreateBike(root)
	self.Riding = true
	self.Character:SetAttribute("RidingMotorBike", true)
	humanoid.AutoRotate = false

	-- Fixed consistent bike speed (no sprint multiplier)
	local bikeSpeed = self.CharModule.GameplayConfig.BaseSpeed * 1.55

	-- Still register a speed factor so other systems know we are overriding speed,
	-- but we force the velocity every frame so sprinting cannot make us faster.
	PlayerSpeedManager.AddSpeedFactor(self.Owner, "ElliotMotorBike", bikeSpeed / self.CharModule.GameplayConfig.BaseSpeed)
	PlayerSprintManager.AddStaminaDrain(self.Owner, "ElliotMotorBike", 2)

	local MAX_TURN_RATE = 2.8

	self.BikeConnection = RunService.Heartbeat:Connect(function(delta)
		if not self.Riding then
			return
		end

		-- Stamina drain
		local attrs = self.Character:FindFirstChild("PlayerAttributes")
		local stamina = attrs and attrs:FindFirstChild("Stamina")
		if stamina and stamina:IsA("NumberValue") then
			stamina.Value = math.max(0, stamina.Value - 12 * delta)
			if stamina.Value <= 0 then
				self:ExitBike()
				return
			end
		end

		-- Desired direction
		local moveDir = humanoid.MoveDirection
		local desiredLook: Vector3

		if moveDir.Magnitude > 0.05 then
			desiredLook = moveDir.Unit
		else
			desiredLook = root.CFrame.LookVector
		end

		-- Shift Lock support
		local camera = workspace.CurrentCamera
		if camera and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			local camLook = camera.CFrame.LookVector
			camLook = Vector3.new(camLook.X, 0, camLook.Z)
			if camLook.Magnitude > 0.1 then
				if moveDir.Magnitude > 0.05 then
					desiredLook = (moveDir.Unit * 0.65 + camLook.Unit * 0.35).Unit
				else
					desiredLook = camLook.Unit
				end
			end
		end

		desiredLook = Vector3.new(desiredLook.X, 0, desiredLook.Z).Unit
		local currentLook = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit

		local dot = math.clamp(currentLook:Dot(desiredLook), -1, 1)
		local angle = math.acos(dot)
		local maxAngleThisFrame = MAX_TURN_RATE * delta

		local newLook: Vector3
		if angle <= maxAngleThisFrame or angle < 0.001 then
			newLook = desiredLook
		else
			local cross = currentLook:Cross(desiredLook)
			local sign = cross.Y >= 0 and 1 or -1
			local rotation = CFrame.fromAxisAngle(Vector3.yAxis, sign * maxAngleThisFrame)
			newLook = (rotation * currentLook).Unit
		end

		-- Force consistent speed every frame (sprinting cannot override this)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + newLook)
		root.AssemblyLinearVelocity = newLook * bikeSpeed + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end)

	-- Auto-exit after ability Duration so the prop disappears
	local duration = ability.Duration or 8
	self.BikeExpireThread = task.delay(duration, function()
		if self.Riding then
			self:ExitBike()
		end
	end)
end

-- Ability Behaviours
local function PizzaBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end
	local state = self.CharModule.GameplayConfig.Cache.ElliotState
	if state:IsLMS() then
		Heal(self.Owner.Character and self.Owner.Character:FindFirstChildWhichIsA("Humanoid"))
	elseif state.Riding then
		state:ThrowPizza()
	else
		state:ClosePizza()
	end
end

local function KitchenBehaviour(self: Types.Ability)
	if not RunService:IsServer() then
		return
	end

	local state = self.CharModule.GameplayConfig.Cache.ElliotState
	if state.Riding then
		return
	end

	local humanoid = self.Owner.Character and self.Owner.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then
		CommonFunctions.ApplyEffect({
			TargetHumanoid = humanoid,
			EffectSettings = { Name = "Helpless", Duration = self.Duration },
		})
		CommonFunctions.ApplyEffect({
			TargetHumanoid = humanoid,
			EffectSettings = { Name = "Slowness", Level = 3, Duration = self.Duration },
		})
	end
	state:PlaceOrRepairKitchen()
end

local function BikeBehaviour(self: Types.Ability)
	if RunService:IsServer() then
		self.CharModule.GameplayConfig.Cache.ElliotState:RideBike(self)
	end
end

local function CreatePizzaHud(player: Player, ability: Types.Ability)
	local gui = Instance.new("ScreenGui")
	gui.Name = "ElliotPizzaHud"
	gui.ResetOnSpawn = false
	gui.Parent = player:WaitForChild("PlayerGui")

	local label = Instance.new("TextLabel")
	label.Name = "PizzaCount"
	label.AnchorPoint = Vector2.new(0.5, 1)
	label.Position = UDim2.fromScale(0.5, 0.94)
	label.Size = UDim2.fromOffset(210, 36)
	label.BackgroundColor3 = Color3.fromRGB(35, 20, 10)
	label.BackgroundTransparency = 0.2
	label.TextColor3 = Color3.fromRGB(255, 220, 100)
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.Parent = gui

	local function update()
		label.Text = "Pizza slices: " .. tostring(math.clamp(ability.UsesLeft or 0, 0, 2)) .. "/2"
	end

	ability.Signals.ChargesChanged:Connect(update)
	update()
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
		StaminaProperties = {
			MaxStamina = 100,
			StaminaDrain = 10,
			StaminaGain = 20,
		},
		Cache = {
			Animations = {},
		},
		Abilities = {
			PizzaThrow = Ability.New({
				Name = "Pizza Throw",
				InputName = "FirstAbility",
				Cooldown = 20,
				Duration = 0.8,
				UseAnimation = ANIM.Pizza,
				UseSettings = {
					InitialUses = 2,
					Limited = true,
				},
				Behaviour = PizzaBehaviour,
			}),
			Kitchen = Ability.New({
				Name = "Kitchen",
				InputName = "SecondAbility",
				Cooldown = 20,
				Duration = 2.5,
				UseAnimation = ANIM.Kitchen,
				UseConditions = function(self: Types.Ability)
					local state = self.CharModule.GameplayConfig.Cache.ElliotState
					return RunService:IsClient() or (state and not state.Riding)
				end,
				Behaviour = KitchenBehaviour,
			}),
			MotorBike = Ability.New({
				Name = "Motor Bike",
				InputName = "ThirdAbility",
				Cooldown = 1,
				Duration = 8,
				UseAnimation = ANIM.MotorBike,
				UseConditions = function(self: Types.Ability)
					return RunService:IsClient()
						or self.CharModule.GameplayConfig.Cache.ElliotState:KitchenNearby()
						or self.CharModule.GameplayConfig.Cache.ElliotState.Riding
				end,
				Behaviour = BikeBehaviour,
			}),
		},
	},
	OnInit = function(self: Types.Survivor, character: Model)
		if RunService:IsServer() then
			self.GameplayConfig.Cache.ElliotState = ElliotState.new(self.Owner, character, self)
		else
			CreatePizzaHud(Players.LocalPlayer, self.GameplayConfig.Abilities.PizzaThrow)
		end
	end,
})

Elliot.Config.Description = {
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "PIZZA THROW" },
	{
		Type = "Text",
		Text = "Heal a nearby survivor, throw only while riding, or self-heal during LMS. The HUD shows Elliot's two-slice inventory.",
	},
	{ Type = "Header", Text = "KITCHEN" },
	{
		Type = "Text",
		Text = "Places a kitchen on the ground with a visible health bar and a 20-second pizza timer. Cannot be used while on the Motor Bike.",
	},
	{ Type = "Header", Text = "MOTOR BIKE" },
	{
		Type = "Text",
		Text = "A visible scooter with fixed consistent speed (sprinting does not make it faster), limited turn rate that respects Shift Lock, and the prop disappears when the ride ends.",
	},
}

return Elliot