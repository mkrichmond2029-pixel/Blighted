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

local function findAsset(folderName: string, assetName: string): Instance?
	if not RunService:IsServer() then return nil end
	local root = workspace:FindFirstChild("CharacterAssets")
	local elliot = root and root:FindFirstChild("Elliot")
	local folder = elliot and elliot:FindFirstChild(folderName)
	return folder and folder:FindFirstChild(assetName)
end

local KitchenTemplate = findAsset("KitchenModel", "ElliotDefault")
local ScooterTemplate = findAsset("ScooterModel", "ScooterDefault")

local ANIM = { Pizza = "rbxassetid://0", Kitchen = "rbxassetid://0", MotorBike = "rbxassetid://0" }
local KITCHEN_RADIUS = 18
local KITCHEN_PIZZA_TIME = 20
local BIKE_HIT_RANGE = 7
local BIKE_HIT_COOLDOWN = 1.25

local ElliotState = {}
ElliotState.__index = ElliotState

function ElliotState.new(owner: Player, character: Model, module: Types.Survivor)
	return setmetatable({
		Owner = owner, Character = character, CharModule = module, Kitchen = nil,
		Riding = false, BikeConnection = nil, BikeExpireThread = nil,
		KitchenConnection = nil, BikeHitCooldowns = {}, PreviousCanSprint = nil,
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
		and not kitchen:GetAttribute("Broken") and kitchen
end

function ElliotState:KitchenNearby()
	local kitchen = self:WorkingKitchen()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	return kitchen and root and kitchen.PrimaryPart
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

	health.HealthChanged:Connect(function(value)
		fill.Size = UDim2.fromScale(math.clamp(value / health.MaxHealth, 0, 1), 1)
		fill.BackgroundColor3 = value <= 30 and Color3.fromRGB(220, 55, 45) or Color3.fromRGB(55, 210, 75)
		model:SetAttribute("KitchenHealth", value)
		model:SetAttribute("Broken", value <= 0)
	end)

	model:SetAttribute("PizzaReady", false)
	model:SetAttribute("PizzaTimer", KITCHEN_PIZZA_TIME)
	task.spawn(function()
		local remaining = KITCHEN_PIZZA_TIME
		while model.Parent do
			if model:GetAttribute("Broken") then
				model:SetAttribute("PizzaReady", false)
				timer.Text = "BROKEN"
				task.wait(.25)
			else
				local ready = model:GetAttribute("PizzaReady") == true
				timer.Text = ready and "Pizza ready - enter kitchen" or ("Pizza in " .. remaining .. "s")
				model:SetAttribute("PizzaTimer", remaining)
				if not ready then
					task.wait(1)
					remaining -= 1
					if remaining <= 0 then
						remaining = 0
						model:SetAttribute("PizzaReady", true)
					end
				else
					task.wait(.25)
				end
			end
		end
	end)
end

function ElliotState:StartKitchenPickup(model: Model)
	-- Do not keep a Hitbox.New loop alive. Only create the short pickup hitbox
	-- after a survivor has entered the kitchen's radius.
	if self.KitchenConnection then self.KitchenConnection:Disconnect() end
	self.KitchenConnection = RunService.Heartbeat:Connect(function()
		if not model.Parent or model:GetAttribute("Broken") then return end
		if model:GetAttribute("PizzaReady") ~= true or not model.PrimaryPart then return end
		for _, character in workspace:FindFirstChild("Players"):GetChildren() do
			local role = character:FindFirstChild("Role")
			local root = character:FindFirstChild("HumanoidRootPart")
			if role and role.Value == "Survivor" and root and (root.Position - model.PrimaryPart.Position).Magnitude <= KITCHEN_RADIUS then
				local player = Players:GetPlayerFromCharacter(character)
				if player then
					local claimed = false
					local pickup = Hitbox.New(self.Owner, {
						CFrame = model.PrimaryPart.CFrame, Size = Vector3.new(12, 7, 12), Damage = 0,
						FriendlyFire = true, HitMultiple = false, Time = 0.12, Reason = "Elliot Kitchen Pickup",
						Connections = { Hit = function(_, humanoid: Humanoid)
							local target = humanoid.Parent
							local targetRole = target and target:FindFirstChild("Role")
							if not claimed and target == character and targetRole and targetRole.Value == "Survivor" then
								claimed = true
								self:AddPizza(1)
								model:SetAttribute("PizzaReady", false)
								model:SetAttribute("PizzaTimer", KITCHEN_PIZZA_TIME)
							end
						end },
					})
					if pickup.Cancelled then pickup:Cancel() end
					break
				end
			end
		end
	end)
end

function ElliotState:CreateKitchen()
	if not KitchenTemplate or not KitchenTemplate:IsA("Model") then
		warn("[Elliot] KitchenModel/ElliotDefault is missing")
		return nil
	end
	local model = KitchenTemplate:Clone()
	model.Name, model.Parent = "ElliotKitchen", self:Folder()
	model:SetAttribute("Broken", false)
	if not model.PrimaryPart then model.PrimaryPart = model:FindFirstChildWhichIsA("BasePart", true) end
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root or not model.PrimaryPart then model:Destroy(); return nil end
	local placePos = root.Position + root.CFrame.LookVector * 5
	local params = RaycastParams.new()
	params.FilterType, params.FilterDescendantsInstances = Enum.RaycastFilterType.Exclude, { self.Character, model }
	local hit = workspace:Raycast(placePos + Vector3.new(0, 8, 0), Vector3.new(0, -25, 0), params)
	local _, size = model:GetBoundingBox()
	model:PivotTo(CFrame.new(placePos.X, (hit and hit.Position.Y or placePos.Y - 3) + size.Y / 2 + .05, placePos.Z) * CFrame.Angles(0, math.atan2(-root.CFrame.LookVector.X, -root.CFrame.LookVector.Z), 0))
	self.Kitchen = model
	local health = Instance.new("Humanoid")
	health.Name, health.MaxHealth, health.Health, health.DisplayDistanceType = "KitchenHealth", 100, 100, Enum.HumanoidDisplayDistanceType.None
	health.Parent = model
	self:CreateKitchenHealthBar(model, health)
	self:StartKitchenPickup(model)
	return model
end

function ElliotState:PlaceOrRepairKitchen()
	if self.Kitchen and self.Kitchen.Parent then
		if self.Kitchen:GetAttribute("Broken") then
			local health = self.Kitchen:FindFirstChild("KitchenHealth")
			if health and health:IsA("Humanoid") then health.Health = health.MaxHealth end
		end
		return
	end
	self:CreateKitchen()
end

local function Heal(humanoid: Humanoid?)
	if not humanoid or humanoid.Health <= 0 then return end
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 10)
	task.spawn(function()
		for _ = 1, 5 do task.wait(1); if humanoid.Parent and humanoid.Health > 0 then humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + 3) end end
	end)
end

function ElliotState:ClosePizza()
	local used = false
	Hitbox.New(self.Owner, { CFrameOffset = CFrame.new(0, 0, -3), Size = Vector3.new(4, 5, 5), Damage = 0, FriendlyFire = true, Time = .8, Reason = "Elliot Pizza Heal", Connections = { Hit = function(_, humanoid: Humanoid)
		local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
		if not used and role and role.Value == "Survivor" then used = true; Heal(humanoid) end
	end } })
end

function ElliotState:ThrowPizza()
	local root = self.Character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	local pizza = Instance.new("Part")
	pizza.Name, pizza.Shape, pizza.Size, pizza.Color, pizza.Material = "ElliotPizza", Enum.PartType.Cylinder, Vector3.new(.4, 1.8, 1.8), Color3.fromRGB(255, 170, 25), Enum.Material.Neon
	pizza.CanCollide, pizza.Anchored, pizza.Parent = false, true, self:Folder()
	local position = root.Position + Vector3.new(0, 1.2, 0) + root.CFrame.LookVector * 2.5
	local velocity, hit = root.CFrame.LookVector * 85 + Vector3.new(0, 22, 0), false
	local hitbox = Hitbox.New(self.Owner, { CFrame = function() return pizza.CFrame end, Size = Vector3.new(3.2, 3.2, 3.2), Damage = 0, FriendlyFire = true, IsProjectile = true, Time = 2.2, Reason = "Pizza Throw", Connections = { Hit = function(_, humanoid: Humanoid)
		local role = humanoid.Parent and humanoid.Parent:FindFirstChild("Role")
		if not hit and role and role.Value == "Survivor" then hit = true; Heal(humanoid); hitbox:Cancel(); pizza:Destroy() end
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

function ElliotState:ExitBike()
	if not self.Riding then return end
	self.Riding = false
	self.Character:SetAttribute("RidingMotorBike", false)
	if self.BikeConnection then self.BikeConnection:Disconnect(); self.BikeConnection = nil end
	if self.BikeExpireThread then task.cancel(self.BikeExpireThread); self.BikeExpireThread = nil end
	PlayerSpeedManager.RemoveSpeedFactor(self.Owner, "ElliotMotorBike")
	PlayerSprintManager.RemoveStaminaDrain(self.Owner, "ElliotMotorBike")
	local speedData = PlayerSpeedManager.ManagedPlayers[self.Owner]
	if speedData then speedData.CanSprint = self.PreviousCanSprint ~= false end
	local attributes = self.Character:FindFirstChild("PlayerAttributes")
	local sprinting = attributes and attributes:FindFirstChild("Sprinting")
	if sprinting and sprinting:IsA("BoolValue") then sprinting.Value = false end
	local bike = self.Character:FindFirstChild("ElliotMotorBike")
	if bike then bike:Destroy() end
	local humanoid = self.Character:FindFirstChildWhichIsA("Humanoid")
	if humanoid then humanoid.AutoRotate = true end
end

function ElliotState:CreateBike(root: BasePart)
	local bike = ScooterTemplate and ScooterTemplate:IsA("Model") and ScooterTemplate:Clone() or Instance.new("Model")
	bike.Name = "ElliotMotorBike"
	if not bike.PrimaryPart then
		local body = Instance.new("Part")
		body.Name, body.Size, body.Color, body.Material = "Body", Vector3.new(2.5, .55, 4), Color3.fromRGB(35, 35, 35), Enum.Material.Metal
		body.Parent, bike.PrimaryPart = bike, body
	end
	for _, part in bike:GetDescendants() do if part:IsA("BasePart") then part.CanCollide = false; part.Massless = true end end
	bike:PivotTo(root.CFrame * CFrame.new(0, -2, 0)); bike.Parent = self.Character
	local weld = Instance.new("WeldConstraint"); weld.Part0, weld.Part1, weld.Parent = root, bike.PrimaryPart, bike.PrimaryPart
	return bike
end

function ElliotState:BikeAttack(root: BasePart)
	for _, target in workspace:FindFirstChild("Players"):GetChildren() do
		local role, targetRoot = target:FindFirstChild("Role"), target:FindFirstChild("HumanoidRootPart")
		local humanoid = target:FindFirstChildWhichIsA("Humanoid")
		if role and role.Value == "Killer" and targetRoot and humanoid and humanoid.Health > 0 then
			local distance = (targetRoot.Position - root.Position).Magnitude
			if distance <= BIKE_HIT_RANGE and (self.BikeHitCooldowns[target] or 0) <= os.clock() then
				self.BikeHitCooldowns[target] = os.clock() + BIKE_HIT_COOLDOWN
				Hitbox.New(self.Owner, { CFrame = root.CFrame, Size = Vector3.new(5, 5, 6), Damage = 0, Knockback = 12, Time = .12, HitMultiple = false, Reason = "Elliot Motor Bike Impact", Connections = { Hit = function(_, hitHumanoid: Humanoid)
					if hitHumanoid.Parent == target then
						local targetRootPart = target:FindFirstChild("HumanoidRootPart")
						if targetRootPart then targetRootPart.AssemblyLinearVelocity = root.CFrame.LookVector * 65 + Vector3.new(0, 18, 0) end
					end
				end } })
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
	self:CreateBike(root); self.Riding = true; self.Character:SetAttribute("RidingMotorBike", true); humanoid.AutoRotate = false
	local speed = self.CharModule.GameplayConfig.BaseSpeed * 1.55
	local speedData = PlayerSpeedManager.ManagedPlayers[self.Owner]
	self.PreviousCanSprint = speedData and speedData.CanSprint
	if speedData then speedData.CanSprint = false; speedData.Factors.Sprint = 1 end
	PlayerSpeedManager.AddSpeedFactor(self.Owner, "ElliotMotorBike", speed / self.CharModule.GameplayConfig.BaseSpeed)
	PlayerSprintManager.AddStaminaDrain(self.Owner, "ElliotMotorBike", 2)
	local maxTurnRate = 2.8
	self.BikeConnection = RunService.Heartbeat:Connect(function(delta)
		if not self.Riding or not root.Parent then return end
		local stamina = self.Character:FindFirstChild("PlayerAttributes") and self.Character.PlayerAttributes:FindFirstChild("Stamina")
		if stamina and stamina:IsA("NumberValue") then stamina.Value = math.max(0, stamina.Value - 12 * delta); if stamina.Value <= 0 then self:ExitBike(); return end end
		local moveDir = humanoid.MoveDirection
		local desired = moveDir.Magnitude > .05 and moveDir.Unit or root.CFrame.LookVector
		local camera = workspace.CurrentCamera
		if camera and UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
			local look = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
			if look.Magnitude > .1 then desired = moveDir.Magnitude > .05 and (moveDir.Unit * .65 + look.Unit * .35).Unit or look.Unit end
		end
		desired = Vector3.new(desired.X, 0, desired.Z).Unit
		local current = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z).Unit
		local angle = math.acos(math.clamp(current:Dot(desired), -1, 1))
		local newLook = desired
		if angle > maxTurnRate * delta then
			local sign = current:Cross(desired).Y >= 0 and 1 or -1
			newLook = (CFrame.fromAxisAngle(Vector3.yAxis, sign * maxTurnRate * delta) * current).Unit
		end
		root.CFrame = CFrame.lookAt(root.Position, root.Position + newLook)
		root.AssemblyLinearVelocity = newLook * speed + Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
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
	local gui = Instance.new("ScreenGui"); gui.Name, gui.ResetOnSpawn, gui.Parent = "ElliotPizzaHud", false, player:WaitForChild("PlayerGui")
	local label = Instance.new("TextLabel"); label.Name, label.AnchorPoint, label.Position, label.Size = "PizzaCount", Vector2.new(.5, 1), UDim2.fromScale(.5, .94), UDim2.fromOffset(210, 36)
	label.BackgroundColor3, label.TextColor3, label.Font, label.TextScaled, label.Parent = Color3.fromRGB(35, 20, 10), Color3.fromRGB(255, 220, 100), Enum.Font.GothamBold, true, gui
	local function update() label.Text = "Pizza slices: " .. tostring(math.clamp(ability.UsesLeft or 0, 0, 2)) .. "/2" end
	ability.Signals.ChargesChanged:Connect(update); update()
end

local Elliot: Types.Survivor = Character.CreateSurvivor({
	Config = { Name = "Elliot", Quote = "Fresh from the kitchen.", Render = "rbxasset://textures/ui/GuiImagePlaceholder.png" },
	GameplayConfig = {
		Health = 100, BaseSpeed = 10.5,
		StaminaProperties = { MaxStamina = 100, StaminaDrain = 10, StaminaGain = 20 },
		Cache = { Animations = {} },
		Abilities = {
			PizzaThrow = Ability.New({ Name = "Pizza Throw", InputName = "FirstAbility", Cooldown = 20, Duration = .8, UseAnimation = ANIM.Pizza, UseSettings = { InitialUses = 2, Limited = true }, Behaviour = PizzaBehaviour }),
			Kitchen = Ability.New({ Name = "Kitchen", InputName = "SecondAbility", Cooldown = 20, Duration = 2.5, UseAnimation = ANIM.Kitchen, UseConditions = function(self: Types.Ability) local state = self.CharModule.GameplayConfig.Cache.ElliotState; return RunService:IsClient() or (state and not state.Riding) end, Behaviour = KitchenBehaviour }),
			MotorBike = Ability.New({ Name = "Motor Bike", InputName = "ThirdAbility", Cooldown = 1, Duration = 8, UseAnimation = ANIM.MotorBike, UseConditions = function(self: Types.Ability) local state = self.CharModule.GameplayConfig.Cache.ElliotState; return RunService:IsClient() or state:KitchenNearby() or state.Riding end, Behaviour = BikeBehaviour }),
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
	{ Type = "Text", Text = "Disables sprint, uses fixed linear velocity, knocks back killers on impact, and destroys its prop when the ride ends." },
}

return Elliot