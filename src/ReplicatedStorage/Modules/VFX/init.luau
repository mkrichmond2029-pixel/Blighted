--[[
	VFX Module — server-orchestrated, performance-oriented
	Place: ReplicatedStorage/Modules/VFX/init.luau

	Perf features:
	  • Instance pool (reuse instead of Clone/Destroy spam)
	  • Max concurrent effects (global + per-preset)
	  • Distance culling for network polish (sounds/extra emit)
	  • Quality tier (workspace attribute VFXQuality: High|Medium|Low|Off)
	  • Emit-only particles (Rate=0) — no continuous simulation
	  • Short lifetimes + forced cleanup
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

local Network = require(ReplicatedStorage.Modules.Network)
local Presets = require(script.Presets)


-- Perf knobs

local maxConcurrent = 24 -- hard cap of live world VFX
local maxPerPreset = 6
local poolSizePerTemplate = 8
local defaultRange = 180 -- studs for client polish remote
local minEmitInterval = 0.05 -- same preset+similar place debounce

local QUALITY = {
	High = { emitScale = 1.0, maxConcurrent = 24, range = 220 },
	Medium = { emitScale = 0.55, maxConcurrent = 14, range = 140 },
	Low = { emitScale = 0.3, maxConcurrent = 8, range = 90 },
	Off = { emitScale = 0, maxConcurrent = 0, range = 0 },
}

export type ActiveEffect = {
	Id: string,
	Preset: string,
	Template: string?,
	Position: Vector3,
	Instance: Instance,
	Expires: number,
}

local VFX = {
	_folder = nil :: Folder?,
	_poolFolder = nil :: Folder?,
	_id = 0,
	_active = 0,
	_activeByPreset = {} :: { [string]: number },
	_pool = {} :: { [string]: { Instance } },
	_recent = {} :: { [string]: number }, -- debounce keys
	_activeList = {} :: { ActiveEffect }, -- for farthest-eviction
}

local function getQuality()
	local q = workspace:GetAttribute("VFXQuality")
	if typeof(q) ~= "string" or not QUALITY[q] then
		return QUALITY.High
	end
	return QUALITY[q]
end

local function getWorldFolder(): Folder
	if VFX._folder and VFX._folder.Parent then
		return VFX._folder
	end
	local temp = workspace:FindFirstChild("TempObjectFolders")
	local parent = temp or workspace
	local folder = parent:FindFirstChild("VFX")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "VFX"
		folder.Parent = parent
	end
	VFX._folder = folder
	return folder
end

local function getPoolFolder(): Folder
	if VFX._poolFolder and VFX._poolFolder.Parent then
		return VFX._poolFolder
	end
	local folder = getWorldFolder():FindFirstChild("_Pool")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "_Pool"
		folder.Parent = getWorldFolder()
	end
	VFX._poolFolder = folder
	return folder
end

local function getTemplate(templateName: string): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vfxAssets = assets and assets:FindFirstChild("VFX")
	if vfxAssets then
		return vfxAssets:FindFirstChild(templateName)
	end
	return nil
end

local function resolveCFrame(opts: any): CFrame
	if typeof(opts.CFrame) == "CFrame" then
		return opts.CFrame
	end
	if opts.Position and typeof(opts.Position) == "Vector3" then
		return CFrame.new(opts.Position)
	end
	if opts.Parent and typeof(opts.Parent) == "Instance" then
		if opts.Parent:IsA("Model") then
			return opts.Parent:GetPivot()
		elseif opts.Parent:IsA("BasePart") then
			return opts.Parent.CFrame
		end
	end
	return CFrame.new()
end

local function resolveAttachPart(model: Model, attachmentName: string?): BasePart?
	if attachmentName and attachmentName ~= "" then
		local inst = model:FindFirstChild(attachmentName, true)
		if inst and inst:IsA("BasePart") then
			return inst
		end
		if inst and inst:IsA("Attachment") and inst.Parent and inst.Parent:IsA("BasePart") then
			return inst.Parent
		end
	end
	return model:FindFirstChild("HumanoidRootPart") :: BasePart?
		or model.PrimaryPart
		or model:FindFirstChildWhichIsA("BasePart")
end

local function stripContinuous(root: Instance)
	-- Force emit-only: no ongoing particle simulation cost
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d.Rate = 0
			d.Enabled = false
			d.LockedToPart = false
		elseif d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = false
		end
	end
end

local function emitAll(root: Instance, count: number)
	if count <= 0 then
		return
	end
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d:Emit(count)
		end
	end
	if root:IsA("ParticleEmitter") then
		root:Emit(count)
	end
end

local function createFallbackBurst(cf: CFrame, color: Color3?): Part
	local Part = Instance.new("Part")
	Part.Name = "VFXFallback"
	Part.Anchored = true
	Part.CanCollide = false
	Part.CanQuery = false
	Part.CanTouch = false
	Part.CastShadow = false
	Part.Material = Enum.Material.Neon
	Part.Color = color or Color3.fromRGB(255, 220, 120)
	Part.Size = Vector3.new(0.35, 0.35, 0.35)
	Part.CFrame = cf
	Part.Transparency = 0.35

	local PartEmitter = Instance.new("ParticleEmitter")
	PartEmitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
	PartEmitter.Rate = 0
	PartEmitter.Enabled = false
	PartEmitter.Lifetime = NumberRange.new(0.2, 0.35)
	PartEmitter.Speed = NumberRange.new(3, 9)
	PartEmitter.SpreadAngle = Vector2.new(180, 180)
	PartEmitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.45),
		NumberSequenceKeypoint.new(1, 0),
	})
	PartEmitter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	PartEmitter.LightEmission = 0.5
	PartEmitter.RotSpeed = NumberRange.new(-30, 30)
	PartEmitter.Parent = Part

	return Part
end

local function poolKey(templateName: string?): string
	return templateName or "__fallback"
end

local function acquire(templateName: string?, cf: CFrame, color: Color3?): Instance
	local key = poolKey(templateName)
	local bucket = VFX._pool[key]
	if not bucket then
		bucket = {}
		VFX._pool[key] = bucket
	end

	local inst = table.remove(bucket)
	if inst and inst.Parent then
		-- recycled
	else
		local template = templateName and getTemplate(templateName) or nil
		if template then
			inst = template:Clone()
			stripContinuous(inst)
		else
			inst = createFallbackBurst(cf, color)
		end
	end

	if inst:IsA("Model") then
		inst:PivotTo(cf)
	elseif inst:IsA("BasePart") then
		inst.Anchored = true
		inst.CanCollide = false
		inst.CanQuery = false
		inst.CFrame = cf
	end

	stripContinuous(inst)
	inst.Parent = getWorldFolder()
	return inst
end

local function release(templateName: string?, inst: Instance)
	if not inst then
		return
	end
	-- Disable everything before pooling
	stripContinuous(inst)
	for _, d in inst:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			d:Clear()
		end
	end

	local key = poolKey(templateName)
	local bucket = VFX._pool[key]
	if not bucket then
		bucket = {}
		VFX._pool[key] = bucket
	end

	if #bucket >= POOL_SIZE_PER_TEMPLATE then
		inst:Destroy()
		return
	end

	inst.Parent = getPoolFolder()
	table.insert(bucket, inst)
end

local function nextId(): string
	VFX._id += 1
	return ("vfx_%d"):format(VFX._id)
end

local function debounceKey(presetName: string, cf: CFrame): string
	-- quantize position so spam at same spot is limited
	local Part = cf.Position
	return string.format("%s_%d_%d_%d", presetName, Part.X // 4, Part.Y // 4, Part.Z // 4)
end

local function minDistToPlayers(pos: Vector3, fromPlayer: Player?): number
	-- If a source player is given, measure from that player; else nearest of all.
	if fromPlayer then
		local char = fromPlayer.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			return (hrp.Position - pos).Magnitude
		end
	end
	local best = math.huge
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local d = (hrp.Position - pos).Magnitude
			if d < best then
				best = d
			end
		end
	end
	return if best < math.huge then best else 0
end

local function unregisterActive(id: string)
	for i, entry in VFX._activeList do
		if entry.Id == id then
			table.remove(VFX._activeList, i)
			break
		end
	end
end

local function forceReleaseEntry(entry: ActiveEffect)
	if entry.Instance and entry.Instance.Parent then
		for _, d in entry.Instance:GetDescendants() do
			if d:IsA("Trail") or d:IsA("Beam") then
				d.Enabled = false
			end
		end
		release(entry.Template, entry.Instance)
	end
	unregisterActive(entry.Id)
	VFX._active = math.max(0, VFX._active - 1)
	VFX._activeByPreset[entry.Preset] = math.max(0, (VFX._activeByPreset[entry.Preset] or 1) - 1)
end

--- When at capacity, remove the active effect farthest from the reference player
--- (or farthest from the nearest player if no reference).
local function evictFarthest(fromPlayer: Player?): boolean
	if #VFX._activeList == 0 then
		return false
	end
	local farthestIdx = 1
	local farthestDist = -1
	for i, entry in VFX._activeList do
		local d = minDistToPlayers(entry.Position, fromPlayer)
		if d > farthestDist then
			farthestDist = d
			farthestIdx = i
		end
	end
	local entry = VFX._activeList[farthestIdx]
	if entry then
		forceReleaseEntry(entry)
		return true
	end
	return false
end

local function ensureCapacity(presetName: string, fromPlayer: Player?)
	local q = getQuality()
	local cap = math.min(maxConcurrent, q.maxConcurrent)

	-- Global cap: drop farthest until we have a free slot
	while VFX._active >= cap and VFX._active > 0 do
		if not evictFarthest(fromPlayer) then
			break
		end
	end

	-- Per-preset cap: drop farthest among that preset first
	local per = VFX._activeByPreset[presetName] or 0
	while per >= MAX_PER_PRESET do
		local farthestIdx, farthestDist = nil, -1
		for i, entry in VFX._activeList do
			if entry.Preset == presetName then
				local d = minDistToPlayers(entry.Position, fromPlayer)
				if d > farthestDist then
					farthestDist = d
					farthestIdx = i
				end
			end
		end
		if not farthestIdx then
			break
		end
		forceReleaseEntry(VFX._activeList[farthestIdx])
		per = VFX._activeByPreset[presetName] or 0
	end
end

local function canPlay(presetName: string, cf: CFrame): boolean
	local q = getQuality()
	if q.maxConcurrent <= 0 or q.emitScale <= 0 then
		return false
	end
	local key = debounceKey(presetName, cf)
	local last = VFX._recent[key]
	local now = os.clock()
	if last and now - last < MIN_EMIT_INTERVAL then
		return false
	end
	VFX._recent[key] = now
	return true
end

local function playersInRange(origin: Vector3, range: number): { Player }
	local list = {}
	for _, plr in Players:GetPlayers() do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp and (hrp.Position - origin).Magnitude <= range then
			table.insert(list, plr)
		end
	end
	return list
end

export type PlayOptions = {
	CFrame: CFrame?,
	Position: Vector3?,
	Parent: Instance?,
	Duration: number?,
	EmitCount: number?,
	Scale: number?,
	Color: Color3?,
	Sound: string?,
	Range: number?, -- network polish range
	Replicate: boolean?,
	AttachmentName: string?,
	SourcePlayer: Player?, -- used to decide which far effects to evict
}

function VFX.Play(presetName: string, opts: PlayOptions?)
	opts = opts or {}
	local preset = Presets.Get(presetName)
	if not preset then
		warn("[VFX] Unknown preset:", presetName)
		return nil
	end

	local cf = resolveCFrame(opts)
	local q = getQuality()

	if not RunService:IsServer() then
		-- Ask server so effect is global / server-visible
		Network:FireServerConnection("VFXPlay", "REMOTE_EVENT", presetName, {
			CFrame = { cf:GetComponents() },
			Duration = opts.Duration,
			EmitCount = opts.EmitCount,
			Sound = opts.Sound or preset.Sound,
		})
		return nil
	end

	if not canPlay(presetName, cf) then
		return nil
	end

	-- Free slots by removing effects farthest from the viewer / source player
	ensureCapacity(presetName, opts.SourcePlayer)

	-- If still full (no players / empty list race), bail
	local qCap = getQuality()
	if VFX._active >= math.min(maxConcurrent, qCap.maxConcurrent) then
		return nil
	end

	local duration = opts.Duration or preset.Duration or 0.4
	-- Cap duration for perf
	duration = math.clamp(duration, 0.1, 2.5)

	local baseEmit = opts.EmitCount or preset.EmitCount or 10
	local emitCount = math.max(0, math.floor(baseEmit * q.emitScale + 0.5))
	if emitCount <= 0 then
		return nil
	end

	local id = nextId()
	local templateName = preset.Template
	local inst = acquire(templateName, cf, opts.Color or preset.Color)
	inst.Name = presetName .. "_" .. id
	inst:SetAttribute("VFXPreset", presetName)
	inst:SetAttribute("VFXId", id)
	inst:SetAttribute("VFXTemplate", templateName or "")

	VFX._active += 1
	VFX._activeByPreset[presetName] = (VFX._activeByPreset[presetName] or 0) + 1
	table.insert(VFX._activeList, {
		Id = id,
		Preset = presetName,
		Template = templateName,
		Position = cf.Position,
		Instance = inst,
		Expires = os.clock() + duration,
	})

	emitAll(inst, emitCount)

	-- Brief trail/beam enable if present (still short-lived)
	for _, d in inst:GetDescendants() do
		if d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = true
		end
	end

	task.delay(duration, function()
		-- May already have been force-released by farthest-eviction
		local still = false
		for _, entry in VFX._activeList do
			if entry.Id == id then
				still = true
				break
			end
		end
		if not still then
			return
		end
		if inst and inst.Parent then
			for _, d in inst:GetDescendants() do
				if d:IsA("Trail") or d:IsA("Beam") then
					d.Enabled = false
				end
			end
			release(templateName, inst)
		end
		unregisterActive(id)
		VFX._active = math.max(0, VFX._active - 1)
		VFX._activeByPreset[presetName] = math.max(0, (VFX._activeByPreset[presetName] or 1) - 1)
	end)

	if opts.Replicate ~= false then
		local range = opts.Range or q.range or DEFAULT_RANGE
		local payload = {
			Id = id,
			Preset = presetName,
			Duration = duration,
			EmitCount = emitCount,
			Sound = opts.Sound or preset.Sound,
		}
		for _, plr in playersInRange(cf.Position, range) do
			Network:FireClientConnection(plr, "VFXPlay", "REMOTE_EVENT", payload)
		end
	end

	return id
end

function VFX.PlayOn(target: Model | BasePart, presetName: string, opts: PlayOptions?)
	opts = opts or {}
	local cf: CFrame
	if target:IsA("Model") then
		local part = resolveAttachPart(target, opts.AttachmentName)
		cf = part and part.CFrame or target:GetPivot()
	else
		cf = target.CFrame
	end
	opts.CFrame = cf
	return VFX.Play(presetName, opts)
end

function VFX.SetQuality(level: "High" | "Medium" | "Low" | "Off")
	workspace:SetAttribute("VFXQuality", level)
end

function VFX.GetStats()
	return {
		Active = VFX._active,
		ByPreset = table.clone(VFX._activeByPreset),
		Quality = workspace:GetAttribute("VFXQuality") or "High",
	}
end

function VFX:Init()
	if not RunService:IsServer() then
		return
	end
	getWorldFolder()
	getPoolFolder()
	if workspace:GetAttribute("VFXQuality") == nil then
		workspace:SetAttribute("VFXQuality", "High")
	end

	Network:SetConnection("VFXPlay", "REMOTE_EVENT", function(player: Player, presetName: string, data: any)
		if typeof(presetName) ~= "string" or not Presets.Get(presetName) then
			return
		end
		local comps = data and data.CFrame
		local cf = CFrame.new()
		if typeof(comps) == "table" and #comps >= 12 then
			cf = CFrame.new(table.unpack(comps))
		end
		VFX.Play(presetName, {
			CFrame = cf,
			Duration = typeof(data.Duration) == "number" and data.Duration or nil,
			EmitCount = typeof(data.EmitCount) == "number" and data.EmitCount or nil,
			Sound = typeof(data.Sound) == "string" and data.Sound or nil,
			SourcePlayer = player, -- evict farthest from this player
		})
	end)
end

return VFX
