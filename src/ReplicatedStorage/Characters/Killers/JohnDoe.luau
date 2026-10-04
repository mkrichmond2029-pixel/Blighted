local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Character = require(ReplicatedStorage.Classes.Character)
local Ability = require(ReplicatedStorage.Classes.Ability)
local Hitbox = require(ReplicatedStorage.Classes.Hitbox)
local Types = require(ReplicatedStorage.Classes.Types)
local Utils = require(ReplicatedStorage.Modules.Utils)
local Sounds = require(ReplicatedStorage.Modules.Sounds)

--============================================================
-- Config
--============================================================
local JOHN_DOE_CONFIG = {
	M1 = {
		Cooldown = 2.2,
		Damage = 26,
		HitboxSize = Vector3.new(4, 5, 7),
		HitboxOffset = CFrame.new(0, 0, -3.5),
		Delay = 0.1,
		Duration = 0.4,
	},
	Counter = {
		Cooldown = 50,
		FlingForce = 150,
		SearchRadius = 50,
	},
	Trail = {
		Lifetime = 3,
		MinDistance = 3,
		SegmentWidth = 2,
		SegmentThickness = 1,
		SpeedBoost = 1.05,
		CheckInterval = 0.6,
	},
	HulkingForce = {
		Cooldown = 27,
		Delay = 0.15,
		DashForce = 120,
		DashDuration = 0.5,
		InitialLungeDamage = 30,
		InitialLungeForce = 110,
		GrabDuration = 3,
		ThrowForce = 150,
		HitboxSize = Vector3.new(7, 5, 9),
	},
	DigitalFootprint = {
		Cooldown = 6,
		MaxPlacements = 5,
		PartSize = Vector3.new(8, 0.5, 8),
		SlownessDuration = 4,
		SlowAmount = 2,
		Lifetime = 120,
	},
	Error404 = {
		Cooldown = 30,
		HighlightRange = 200,
		GlideDistance = 140,
		GlideSpeed = 50,
		BurstDamage = 10,
	},
}

--============================================================
-- Helpers
--============================================================
local function getHumanoid(model: Model?): Humanoid?
	if not model then return nil end
	return model:FindFirstChildOfClass("Humanoid")
end

local function getRoot(model: Model?): BasePart?
	if not model then return nil end
	return model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
end

local function getGroundPosition(origin: Vector3, filter: {Instance}): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = filter or {}
	local ray = workspace:Raycast(origin + Vector3.new(0, 5, 0), Vector3.new(0, -80, 0), params)
	if ray then
		return ray.Position
	end
	return nil
end

--============================================================
-- Part Pool
--============================================================
local PartPool = {}
PartPool.__index = PartPool

function PartPool.new(initialSize: number?)
	local self = setmetatable({
		_available = {},
		_created = 0,
	}, PartPool)

	initialSize = initialSize or 50
	for _ = 1, initialSize do
		self:_createNew()
	end

	return self
end

function PartPool:_createNew(): BasePart
	local part = Instance.new("Part")
	part.Name = "CorruptTrailSegment"
	part.Shape = Enum.PartType.Block
	part.Material = Enum.Material.Neon
	part.BrickColor = BrickColor.new("Dark indigo")
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = true
	part.CastShadow = false
	part.Anchored = true
	part.Transparency = 1
	part.Parent = nil

	self._created += 1
	table.insert(self._available, part)
	return part
end

function PartPool:Get(): BasePart
	if #self._available == 0 then
		self:_createNew()
	end
	return table.remove(self._available)
end

function PartPool:Return(part: BasePart)
	if not part then return end
	part.Parent = nil
	part.Size = Vector3.new(1, 1, 1)
	part.CFrame = CFrame.new()
	part.Transparency = 1
	table.insert(self._available, part)
end

function PartPool:Destroy()
	for _, part in ipairs(self._available) do
		part:Destroy()
	end
	table.clear(self._available)
end

--============================================================
-- Trail Segment
--============================================================
local TrailSegment = {}
TrailSegment.__index = TrailSegment

function TrailSegment.new(startPos: Vector3, endPos: Vector3, ownerCharacter: Model?, existingSegments: {any}?, pool: any): TrailSegment?
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude

	local filterList = {
		workspace:FindFirstChild("Debris"),
		workspace:FindFirstChild("Effects"),
	}
	if ownerCharacter then
		table.insert(filterList, ownerCharacter)
	end
	if existingSegments then
		for _, seg in ipairs(existingSegments) do
			if seg._part then
				table.insert(filterList, seg._part)
			end
		end
	end
	raycastParams.FilterDescendantsInstances = filterList

	local startRay = workspace:Raycast(startPos + Vector3.new(0, 5, 0), Vector3.new(0, -80, 0), raycastParams)
	local endRay = workspace:Raycast(endPos + Vector3.new(0, 5, 0), Vector3.new(0, -80, 0), raycastParams)

	if not startRay or not endRay then return nil end

	local floorStart = startRay.Position
	local floorEnd = endRay.Position
	local midPoint = (floorStart + floorEnd) / 2
	local dir = floorEnd - floorStart
	local length = dir.Magnitude

	if length < 0.25 then return nil end

	local part = pool:Get()
	if not part then return nil end

	local self = setmetatable({
		_part = part,
		_pool = pool,
		_lifetime = JOHN_DOE_CONFIG.Trail.Lifetime,
		_spawnTime = os.clock(),
		_floorStart = floorStart,
		_floorEnd = floorEnd,
		_alive = true,
	}, TrailSegment)

	self:_configurePart(midPoint, dir, length, startRay.Normal)
	return self
end

function TrailSegment:_configurePart(midPoint: Vector3, direction: Vector3, length: number, floorNormal: Vector3)
	local part = self._part
	part.Size = Vector3.new(JOHN_DOE_CONFIG.Trail.SegmentWidth, JOHN_DOE_CONFIG.Trail.SegmentThickness, length + 0.2)

	local up = floorNormal.Unit
	local forward = direction.Unit
	if math.abs(up:Dot(forward)) > 0.98 then
		forward = Vector3.new(1, 0, 0)
	end
	local right = forward:Cross(up).Unit
	forward = up:Cross(right).Unit

	part.CFrame = CFrame.fromMatrix(
		midPoint + up * (JOHN_DOE_CONFIG.Trail.SegmentThickness * 0.5),
		right,
		up,
		-forward
	)

	part.Transparency = 0.55
	part.Parent = workspace
end

function TrailSegment:isAlive(): boolean
	return self._alive and self._part and self._part.Parent ~= nil and (os.clock() - self._spawnTime) < self._lifetime
end

function TrailSegment:destroy()
	if not self._alive then return end
	self._alive = false
	if self._part and self._pool then
		self._pool:Return(self._part)
	end
	self._part = nil
end

function TrailSegment:getPosition(): Vector3?
	return self._part and self._part.Position or nil
end

function TrailSegment:getFloorEnd(): Vector3?
	return self._floorEnd
end

--============================================================
-- Corrupt Trail
--============================================================
local CorruptTrail = {}
CorruptTrail.__index = CorruptTrail

function CorruptTrail.new(ability: Types.Ability): CorruptTrail
	local self = setmetatable({
		_ability = ability,
		_segments = {},
		_lastFloorPos = nil,
		_lastCheckTime = os.clock(),
		_connections = {},
		_pool = PartPool.new(50),
	}, CorruptTrail)

	if RunService:IsServer() then
		self:_startTrailLoop()
	end
	return self
end

function CorruptTrail:_startTrailLoop()
	local ability = self._ability
	local character = ability.OwnerProperties.Character
	local hrp = ability.OwnerProperties.HRP

	table.insert(self._connections, RunService.Heartbeat:Connect(function()
		if not hrp or not hrp.Parent then return end
		local now = os.clock()
		local currentPos = hrp.Position

		if not self._lastFloorPos then
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.FilterDescendantsInstances = {
				character,
				workspace:FindFirstChild("Debris"),
				workspace:FindFirstChild("Effects"),
			}
			local ray = workspace:Raycast(currentPos + Vector3.new(0, 5, 0), Vector3.new(0, -80, 0), params)
			if ray then
				self._lastFloorPos = ray.Position
			end
		else
			local dist = (currentPos - self._lastFloorPos).Magnitude
			if dist >= JOHN_DOE_CONFIG.Trail.MinDistance then
				local segment = TrailSegment.new(self._lastFloorPos, currentPos, character, self._segments, self._pool)
				if segment then
					table.insert(self._segments, segment)
					self._lastFloorPos = segment:getFloorEnd() or currentPos

					task.delay(JOHN_DOE_CONFIG.Trail.Lifetime, function()
						if segment then
							segment:destroy()
						end
					end)
				end
			end
		end

		if now - self._lastCheckTime >= JOHN_DOE_CONFIG.Trail.CheckInterval then
			self._lastCheckTime = now
			self:_checkSurvivorsInTrail()
		end

		self:_cleanDeadSegments()
	end))
end

function CorruptTrail:_checkSurvivorsInTrail()
	local loadedPlayers = ReplicatedStorage:FindFirstChild("LoadedPlayers")
	if not loadedPlayers then return end

	for _, playerFolder in pairs(loadedPlayers:GetChildren()) do
		local survivorCharacter = playerFolder:FindFirstChild("Character")
		if not survivorCharacter or not survivorCharacter.PrimaryPart then continue end

		for _, segment in pairs(self._segments) do
			if segment:isAlive() then
				self:_checkSurvivorInSegment(survivorCharacter, segment)
			end
		end
	end
end

function CorruptTrail:_checkSurvivorInSegment(survivorCharacter: Model, segment: TrailSegment)
	local segmentPos = segment:getPosition()
	if not segmentPos then return end

	local part = segment._part
	if not part then return end

	local distance = (survivorCharacter.PrimaryPart.Position - segmentPos).Magnitude
	local checkRadius = (part.Size.X + part.Size.Z) / 2 + 1.8

	if distance <= checkRadius and not survivorCharacter:GetAttribute("JohnDoeTrailHighlighted") then
		survivborCharacter:SetAttribute("JohnDoeTrailHighlighted", true)
		task.delay(JOHN_DOE_CONFIG.Trail.Lifetime, function()
			if survivorCharacter and survivorCharacter.Parent then
				survivborCharacter:SetAttribute("JohnDoeTrailHighlighted", false)
			end
		end)
	end
end

function CorruptTrail:_cleanDeadSegments()
	for i = #self._segments, 1, -1 do
		if not self._segments[i]:isAlive() then
			table.remove(self._segments, i)
		end
	end
end

function CorruptTrail:destroy()
	for _, segment in pairs(self._segments) do
		segment:destroy()
	end
	if self._pool then
		self._pool:Destroy()
	end
	for _, connection in pairs(self._connections) do
		connection:Disconnect()
	end
	self._segments = {}
	self._connections = {}
	self._lastFloorPos = nil
end

--============================================================
-- Counter
--============================================================
local CounterAbility = {}
CounterAbility.__index = CounterAbility

function CounterAbility.new(ability: Types.Ability): CounterAbility
	local self = setmetatable({
		_ability = ability,
		_nextAllowedAt = os.clock(),
		_wasStunnedLastFrame = false,
		_connection = nil,
	}, CounterAbility)

	if RunService:IsServer() then
		self:_startCounterLoop()
	end

	return self
end

function CounterAbility:_startCounterLoop()
	local ability = self._ability
	local character = ability.OwnerProperties.Character
	local hrp = ability.OwnerProperties.HRP

	self._connection = RunService.Heartbeat:Connect(function()
		if not hrp or not hrp.Parent then return end
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not humanoid then return end

		local isStunned = humanoid:GetState() == Enum.HumanoidStateType.Stunned
		if isStunned and not self._wasStunnedLastFrame then
			self:_onStunned(character, hrp)
		end
		self._wasStunnedLastFrame = isStunned
	end)
end

function CounterAbility:_onStunned(character: Model, hrp: BasePart)
	local now = os.clock()
	if now < self._nextAllowedAt then return end

	self._nextAllowedAt = now + JOHN_DOE_CONFIG.Counter.Cooldown

	local target = self:_findClosestSurvivor(hrp)
	if target then
		self:_executeFling(character, hrp, target)
	end
end

function CounterAbility:_findClosestSurvivor(hrp: BasePart): Model?
	local loadedPlayers = ReplicatedStorage:FindFirstChild("LoadedPlayers")
	if not loadedPlayers then return nil end

	local closest = nil
	local closestDist = JOHN_DOE_CONFIG.Counter.SearchRadius

	for _, playerFolder in pairs(loadedPlayers:GetChildren()) do
		local survivorCharacter = playerFolder:FindFirstChild("Character")
		if survivorCharacter and survivorCharacter.PrimaryPart then
			local dist = (survivorCharacter.PrimaryPart.Position - hrp.Position).Magnitude
			if dist < closestDist then
				closestDist = dist
				closest = survivorCharacter
			end
		end
	end

	return closest
end

function CounterAbility:_executeFling(johnDoe: Model, hrp: BasePart, survivorCharacter: Model)
	local survivorHrp = survivorCharacter.PrimaryPart
	if not survivorHrp then return end

	if self._ability.CounterAnimationID and self._ability.CounterAnimationID ~= "rbxassetid://0" then
		local track = Utils.Character.LoadAnimationFromID(johnDoe, self._ability.CounterAnimationID)
		if track then
			track:Play()
		end
	end

	local direction = (survivorHrp.Position - hrp.Position).Unit
	surviviorHrp.AssemblyLinearVelocity = direction * JOHN_DOE_CONFIG.Counter.FlingForce + Vector3.new(0, 50, 0)
end

function CounterAbility:destroy()
	if self._connection then
		self._connection:Disconnect()
	end
end

--============================================================
-- Speed Boost Manager
--============================================================
local SpeedBoostManager = {}
SpeedBoostManager.__index = SpeedBoostManager

function SpeedBoostManager.new(ability: Types.Ability): SpeedBoostManager
	local self = setmetatable({
		_ability = ability,
		_connection = nil,
		_baseSpeed = nil,
	}, SpeedBoostManager)

	if RunService:IsServer() then
		self:_startBoostLoop()
	end
	return self
end

function SpeedBoostManager:_startBoostLoop()
	local ability = self._ability
	local character = ability.OwnerProperties.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid then return end

	self._baseSpeed = humanoid.WalkSpeed

	self._connection = RunService.Heartbeat:Connect(function()
		if not humanoid or not humanoid.Parent then return end

		local shouldBoost = self:_shouldApplyBoost()
		if shouldBoost then
			humanoid.WalkSpeed = self._baseSpeed * JOHN_DOE_CONFIG.Trail.SpeedBoost
		else
			humanoid.WalkSpeed = self._baseSpeed
		end
	end)
end

function SpeedBoostManager:_shouldApplyBoost(): boolean
	local loadedPlayers = ReplicatedStorage:FindFirstChild("LoadedPlayers")
	if not loadedPlayers then return false end

	for _, playerFolder in pairs(loadedPlayers:GetChildren()) do
		local survivorCharacter = playerFolder:FindFirstChild("Character")
		if survivorCharacter and survivorCharacter:GetAttribute("JohnDoeTrailHighlighted") then
			return true
		end
	end
	return false
end

function SpeedBoostManager:destroy()
	if self._connection then
		self._connection:Disconnect()
	end
end

--============================================================
-- Digital Footprint
--============================================================
local DigitalFootprintManager = {}
DigitalFootprintManager.__index = DigitalFootprintManager

function DigitalFootprintManager.new(ability: Types.Ability): DigitalFootprintManager
	return setmetatable({
		_ability = ability,
		_placements = {},
		_connections = {},
	}, DigitalFootprintManager)
end

function DigitalFootprintManager:place(position: Vector3, character: Model)
	local ground = getGroundPosition(position, { character, workspace:FindFirstChild("Debris"), workspace:FindFirstChild("Effects")})
	if not ground then return end

	if #self._placements >= JOHN_DOE_CONFIG.DigitalFootprint.MaxPlacements then
		local oldest = table.remove(self._placements, 1)
		if oldest and oldest._part then
			oldest._part:Destroy()
		end
	end

	local part = Instance.new("Part")
	part.Name = "DigitalFootprint"
	part.Shape = Enum.PartType.Block
	part.Size = JOHN_DOE_CONFIG.DigitalFootprint.PartSize
	part.Material = Enum.Material.Neon
	part.BrickColor = BrickColor.new("Dark indigo")
	part.CanCollide = false
	part.CanQuery = true
	part.CanTouch = true
	part.CastShadow = false
	part.Anchored = true
	part.CFrame = CFrame.new(ground + Vector3.new(0, 0.3, 0))
	part.Parent = workspace

	local footprint = {
		_part = part,
		_spawnTime = os.clock(),
		_lifetime = JOHN_DOE_CONFIG.DigitalFootprint.Lifetime,
	}

	table.insert(self._placements, footprint)

	local touchedConn = part.Touched:Connect(function(hit)
		if not hit.Parent then return end
		local humanoid = getHumanoid(hit.Parent)
		if not humanoid then return end

		local survivor = hit.Parent
		if survivor:GetAttribute("JohnDoeFootprintSlowed") then return end

		local originalSpeed = humanoid.WalkSpeed
		survivitor:SetAttribute("JohnDoeFootprintSlowed", true)
		humanoid.WalkSpeed = math.max(originalSpeed - JOHN_DOE_CONFIG.DigitalFootprint.SlowAmount, 0)

		task.delay(JOHN_DOE_CONFIG.DigitalFootprint.SlownessDuration, function()
			if survivor and survivor.Parent then
				survivitor:SetAttribute("JohnDoeFootprintSlowed", false)
				if humanoid and humanoid.Parent then
					humanoid.WalkSpeed = originalSpeed
				end
			end
		end)
	end)

	table.insert(self._connections, touchedConn)

	task.delay(JOHN_DOE_CONFIG.DigitalFootprint.Lifetime, function()
		if part and part.Parent then
			part:Destroy()
		end
		for i = #self._placements, 1, -1 do
			if self._placements[i]._part == part then
				table.remove(self._placements, i)
				break
			end
		end
	end)

	return footprint
end

function DigitalFootprintManager:destroy()
	for _, footprint in ipairs(self._placements) do
		if footprint._part then
			footprint._part:Destroy()
		end
	end
	for _, conn in ipairs(self._connections) do
		conn:Disconnect()
	end
	self._placements = {}
	self._connections = {}
end

--============================================================
-- Error404
--============================================================
local Error404Ability = {}
Error404Ability.__index = Error404Ability

function Error404Ability.new(ability: Types.Ability): Error404Ability
	return setmetatable({
		_ability = ability,
		_glideConnection = nil,
		_isGliding = false,
		_startedAt = 0,
		_startPos = nil,
		_dir = Vector3.zero,
	}, Error404Ability)
end

function Error404Ability:execute()
	local ability = self._ability
	local character = ability.OwnerProperties.Character
	local hrp = ability.OwnerProperties.HRP
	if not character or not hrp then return end

	self:_highlightSurvivors()
	self:_beginGlide()
end

function Error404Ability:_highlightSurvivors()
	local ability = self._ability
	local hrp = ability.OwnerProperties.HRP
	if not hrp then return end

	local loadedPlayers = ReplicatedStorage:FindFirstChild("LoadedPlayers")
	if not loadedPlayers then return end

	for _, playerFolder in pairs(loadedPlayers:GetChildren()) do
		local survivorCharacter = playerFolder:FindFirstChild("Character")
		if survivorCharacter and survivorCharacter.PrimaryPart then
			local distance = (survivorCharacter.PrimaryPart.Position - hrp.Position).Magnitude
			if distance <= JOHN_DOE_CONFIG.Error404.HighlightRange then
				surviviorCharacter:SetAttribute("JohnDoeError404Highlighted", true)
				task.delay(3, function()
					if survivorCharacter and survivorCharacter.Parent then
						surviviorCharacter:SetAttribute("JohnDoeError404Highlighted", false)
					end
				end)
			end
		end
	end
end

function Error404Ability:_beginGlide()
	local ability = self._ability
	local character = ability.OwnerProperties.Character
	local hrp = ability.OwnerProperties.HRP
	if not character or not hrp or self._isGliding then return end

	self._isGliding = true
	self._startedAt = os.clock()
	self._startPos = hrp.Position
	self._dir = (character.PrimaryPart and character.PrimaryPart.CFrame.LookVector or hrp.CFrame.LookVector).Unit

	self._glideConnection = RunService.Heartbeat:Connect(function()
		if not hrp or not hrp.Parent then
			self:_endGlide()
			return
		end

		local elapsed = os.clock() - self._startedAt
		local dist = elapsed * JOHN_DOE_CONFIG.Error404.GlideSpeed
		if dist >= JOHN_DOE_CONFIG.Error404.GlideDistance then
			self:_endGlide()
			return
		end

		local targetPos = self._startPos + self._dir * dist
		local ground = getGroundPosition(targetPos, { character })
		if ground then
			hrp.CFrame = CFrame.new(ground + Vector3.new(0, 2, 0))
		else
			hrp.CFrame = CFrame.new(targetPos + Vector3.new(0, 2, 0))
		end
	end)
end

function Error404Ability:_endGlide()
	if self._glideConnection then
		self._glideConnection:Disconnect()
		self._glideConnection = nil
	end
	self._isGliding = false
end

function Error404Ability:burst()
	local ability = self._ability
	local hrp = ability.OwnerProperties.HRP
	if not hrp then return end

	Hitbox.New(ability.Owner, {
		CFrameOffset = CFrame.new(0, 0, -4),
		Size = Vector3.new(6, 5, 8),
		Time = 0.3,
		Damage = JOHN_DOE_CONFIG.Error404.BurstDamage,
		Reason = "Error404 Burst",
		ExecuteOnKill = true,
	})
end

function Error404Ability:destroy()
	self:_endGlide()
end

--============================================================
-- Hulking Force
--============================================================
local HulkingForceAbility = {}
HulkingForceAbility.__index = HulkingForceAbility

function HulkingForceAbility.new(ability: Types.Ability): HulkingForceAbility
	return setmetatable({
		_ability = ability,
	}, HulkingForceAbility)
end

function HulkingForceAbility:execute()
	local ability = self._ability
	local character = ability.OwnerProperties.Character
	local hrp = ability.OwnerProperties.HRP
	if not character or not hrp then return end

	local dir = (character.PrimaryPart and character.PrimaryPart.CFrame.LookVector or hrp.CFrame.LookVector).Unit
	Sounds.PlaySound(ability.UseSound, { Parent = hrp })

	-- Initial dash startup
	hrp.AssemblyLinearVelocity = dir * JOHN_DOE_CONFIG.HulkingForce.DashForce + Vector3.new(0, 10, 0)

	task.delay(JOHN_DOE_CONFIG.HulkingForce.Delay, function()
		if not hrp or not hrp.Parent then return end
		Hitbox.New(ability.Owner, {
			CFrameOffset = ability.HitboxOffset or CFrame.new(0, 0, -5),
			Size = ability.HitboxSize or JOHN_DOE_CONFIG.HulkingForce.HitboxSize,
			Time = 0.35,
			Damage = JOHN_DOE_CONFIG.HulkingForce.InitialLungeDamage,
			Reason = "Hulking Force",
			ExecuteOnKill = true,
		})
	end)
end

function HulkingForceAbility:destroy() end

--============================================================
-- M1 Attack
--============================================================
local M1Attack = {}
M1Attack.__index = M1Attack

function M1Attack.new(ability: Types.Ability): M1Attack
	return setmetatable({ _ability = ability }, M1Attack)
end

function M1Attack:execute()
	local ability = self._ability
	local hrp = ability.OwnerProperties.HRP
	if hrp then
		Sounds.PlaySound(ability.UseSound, { Parent = hrp })
	end

	task.delay(JOHN_DOE_CONFIG.M1.Delay, function()
		Hitbox.New(ability.Owner, {
			CFrameOffset = ability.HitboxOffset,
			Size = ability.HitboxSize or JOHN_DOE_CONFIG.M1.HitboxSize,
			Time = ability.Duration or JOHN_DOE_CONFIG.M1.Duration,
			Damage = ability.Damage or JOHN_DOE_CONFIG.M1.Damage,
			Reason = "M1 Attack",
			ExecuteOnKill = true,
		})
	end)
end

--============================================================
-- Extra Init
--============================================================
local function M1ExtraInit(ability: Types.Ability)
	if not RunService:IsServer() then return end

	local corruptTrail = CorruptTrail.new(ability)
	local counterAbility = CounterAbility.new(ability)
	local speedBoost = SpeedBoostManager.new(ability)

	ability._johnDoePassives = {
		trail = corruptTrail,
		counter = counterAbility,
		speedBoost = speedBoost,
	}

	ability:AddConnection(function()
		if ability._johnDoePassives then
			corruptTrail:destroy()
			counterAbility:destroy()
			speedBoost:destroy()
		end
	end)
end

local function HulkingForceExtraInit(ability: Types.Ability)
	if not RunService:IsServer() then return end
	ability._hulkingForce = HulkingForceAbility.new(ability)
end

local function DigitalFootprintExtraInit(ability: Types.Ability)
	if not RunService:IsServer() then return end
	ability._digitalFootprint = DigitalFootprintManager.new(ability)
end

local function Error404ExtraInit(ability: Types.Ability)
	if not RunService:IsServer() then return end
	ability._error404 = Error404Ability.new(ability)
end

--============================================================
-- Behaviour functions
--============================================================
local function OnM1Attack(ability: Types.Ability)
	local attack = M1Attack.new(ability)
	attack:execute()
end

local function OnHulkingForceAttack(ability: Types.Ability)
	if ability._hulkingForce then
		ability._hulkingForce:execute()
	end
end

local function OnDigitalFootprintAttack(ability: Types.Ability)
	local character = ability.OwnerProperties.Character
	local hrp = ability.OwnerProperties.HRP
	if not character or not hrp then return end

	local dir = (character.PrimaryPart and character.PrimaryPart.CFrame.LookVector or hrp.CFrame.LookVector).Unit
	local pos = hrp.Position + dir * 4

	if ability._digitalFootprint then
		ability._digitalFootprint:place(pos, character)
	end
end

local function OnError404Attack(ability: Types.Ability)
	if ability._error404 then
		ability._error404:execute()
	end
end

--============================================================
-- Character setup
--============================================================
local JohnDoe: Types.Killer = Character.CreateKiller({
	Config = {
		Name = "John Doe",
		Quote = "Everyone deserves a second chance.",
		Render = "rbxassetid://0",
		Price = 1000,
		Origin = {
			TooltipText = "The Serial Killer",
			Icon = "rbxassetid://0",
		},
		AnimationIDs = {
			IdleAnimation = "rbxassetid://73546288362576",
			WalkAnimation = "rbxassetid://115621394601470",
			RunAnimation = "rbxassetid://102981744469535",
		},
	},
	GameplayConfig = {
		Health = 31815,
		Speed = 1.5,
		Abilities = {
			M1 = Ability.New({
				Name = "M1",
				InputName = "Slash",
				Cooldown = JOHN_DOE_CONFIG.M1.Cooldown,
				Duration = JOHN_DOE_CONFIG.M1.Duration,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				Delay = JOHN_DOE_CONFIG.M1.Delay,
				HitboxSize = JOHN_DOE_CONFIG.M1.HitboxSize,
				HitboxOffset = JOHN_DOE_CONFIG.M1.HitboxOffset,
				ExtraInit = M1ExtraInit,
				Behaviour = OnM1Attack,
			}),
			HulkingForce = Ability.New({
				Name = "Hulking Force",
				InputName = "FirstAbility",
				Cooldown = JOHN_DOE_CONFIG.HulkingForce.Cooldown,
				Duration = 0.5,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				Delay = JOHN_DOE_CONFIG.HulkingForce.Delay,
				HitboxSize = JOHN_DOE_CONFIG.HulkingForce.HitboxSize,
				HitboxOffset = CFrame.new(0, 0, -5),
				ExtraInit = HulkingForceExtraInit,
				Behaviour = OnHulkingForceAttack,
			}),
			DigitalFootprint = Ability.New({
				Name = "Digital Footprint",
				InputName = "SecondAbility",
				Cooldown = JOHN_DOE_CONFIG.DigitalFootprint.Cooldown,
				Duration = 0.5,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				ExtraInit = DigitalFootprintExtraInit,
				Behaviour = OnDigitalFootprintAttack,
			}),
			Error404 = Ability.New({
				Name = "Error404",
				InputName = "ThirdAbility",
				Cooldown = JOHN_DOE_CONFIG.Error404.Cooldown,
				Duration = 3,
				RenderImage = "rbxassetid://0",
				UseSound = "rbxassetid://12222200",
				UICorner = true,
				ExtraInit = Error404ExtraInit,
				Behaviour = OnError404Attack,
			}),
		},
	},
})

--============================================================
-- Description
--============================================================
local NameLabel = '<font color="rgb(255, 0, 0)">' .. JohnDoe.Config.Name .. "</font>"
local M1_DAMAGE = JOHN_DOE_CONFIG.M1.Damage
local M1_COOLDOWN = JOHN_DOE_CONFIG.M1.Cooldown
local COUNTER_COOLDOWN = JOHN_DOE_CONFIG.Counter.Cooldown
local TRAIL_LIFETIME = JOHN_DOE_CONFIG.Trail.Lifetime
local HULKING_COOLDOWN = JOHN_DOE_CONFIG.HulkingForce.Cooldown
local DIGITAL_COOLDOWN = JOHN_DOE_CONFIG.DigitalFootprint.Cooldown
local ERROR404_COOLDOWN = JOHN_DOE_CONFIG.Error404.Cooldown

JohnDoe.Config.Description = {
	{ Type = "Separator", Text = "GENERAL INFO" },
	{ Type = "Header", Text = JohnDoe.Config.Name:upper() },
	{ Type = "Quote", Text = '"' .. JohnDoe.Config.Quote .. '"' },
	{
		Type = "Text",
		Text = "A hulking killer with incredible durability and extended forward reach. His bulky frame comes at the cost of slower attacks, but his corruption leaves few survivors unscathed.",
	},
	{ Type = "Separator", Text = "STATS" },
	{ Type = "Text", Text = "Health: 31,815 | Speed: +1.5 studs | M1 Damage: " .. tostring(M1_DAMAGE) },
	{ Type = "Separator", Text = "PASSIVES" },
	{ Type = "Header", Text = "BULKY ARM" },
	{
		Type = "Text",
		Text = "Extended forward reach on attacks in exchange for increased M1 cooldown (" .. tostring(M1_COOLDOWN) .. "s).",
	},
	{ Type = "Header", Text = "COUNTER" },
	{
		Type = "Text",
		Text = "When stunned during an ability use, " .. NameLabel .. " automatically counters, entering an animation and flinging the stunner away. Cooldown: " .. tostring(COUNTER_COOLDOWN) .. "s.",
	},
	{ Type = "Header", Text = "CORRUPT TRAIL" },
	{
		Type = "Text",
		Text = NameLabel .. " leaves a continuous trail of corruption behind him as he moves. Segments last " .. tostring(TRAIL_LIFETIME) .. "s. Survivors who step in it become highlighted and grant " .. NameLabel .. " a speed boost.",
	},
	{ Type = "Separator", Text = "ABILITIES" },
	{ Type = "Header", Text = "M1 ATTACK" },
	{
		Type = "Text",
		Text = NameLabel .. " swings with devastating forward reach, dealing " .. tostring(M1_DAMAGE) .. " damage.",
	},
	{ Type = "Header", Text = "HULKING FORCE" },
	{
		Type = "Text",
		Text = NameLabel .. " lunges forward and hits with an AOE damage burst. Cooldown: " .. tostring(HULKING_COOLDOWN) .. "s.",
	},
	{ Type = "Header", Text = "DIGITAL FOOTPRINT" },
	{
		Type = "Text",
		Text = NameLabel .. " places a short corruption patch that slows survivors stepping on it. Max 5 active. Cooldown: " .. tostring(DIGITAL_COOLDOWN) .. "s.",
	},
	{ Type = "Header", Text = "ERROR404" },
	{
		Type = "Text",
		Text = NameLabel .. " highlights nearby survivors and glides across the ground for up to 140 studs. Cooldown: " .. tostring(ERROR404_COOLDOWN) .. "s.",
	},
}

return JohnDoe
