--[[
	Modular Trail controller
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Debris = game:GetService("Debris")

export type TrailPreset = {
	Template: string?,
	Color: ColorSequence?,
	Transparency: NumberSequence?,
	Lifetime: number?,
	MinLength: number?,
	WidthScale: NumberSequence?,
	LightEmission: number?,
	FaceCamera: boolean?,
	Offset0: CFrame?,
	Offset1: CFrame?,
	MaxDuration: number?,
	QualityMin: ("Low" | "Medium" | "High")?,
}

local Registry: { [string]: TrailPreset } = {
	MeleeTrail = {
		Color = ColorSequence.new(Color3.fromRGB(255, 240, 180)),
		Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(1, 1),
		}),
		Lifetime = 0.25,
		MinLength = 0.1,
		WidthScale = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.6),
			NumberSequenceKeypoint.new(1, 0),
		}),
		LightEmission = 0.4,
		Offset0 = CFrame.new(0, 0, 0),
		Offset1 = CFrame.new(0, 0, -2.2),
		MaxDuration = 0.45,
		QualityMin = "Low",
	},
	HeavyTrail = {
		Color = ColorSequence.new(Color3.fromRGB(255, 180, 80)),
		Transparency = NumberSequence.new(0.15, 1),
		Lifetime = 0.35,
		WidthScale = NumberSequence.new(0.9, 0),
		LightEmission = 0.55,
		Offset1 = CFrame.new(0, 0, -3),
		MaxDuration = 0.55,
		QualityMin = "Medium",
	},
	LungeTrail = {
		Color = ColorSequence.new(Color3.fromRGB(200, 220, 255)),
		Transparency = NumberSequence.new(0.1, 1),
		Lifetime = 0.4,
		WidthScale = NumberSequence.new(0.7, 0),
		LightEmission = 0.5,
		Offset1 = CFrame.new(0, 0, -2.8),
		MaxDuration = 0.7,
		QualityMin = "Low",
	},
	ItemHeldTrail = {
		Color = ColorSequence.new(Color3.fromRGB(120, 200, 255)),
		Lifetime = 0.4,
		WidthScale = NumberSequence.new(0.35, 0),
		Offset1 = CFrame.new(0, 0, -1.2),
		MaxDuration = nil,
		QualityMin = "Low",
	},
	ChainsawTrail = {
		Template = "ChainsawTrail",
		MaxDuration = nil,
		QualityMin = "Medium",
	},
}

local active: { [string]: {
	trail: Trail,
	a0: Attachment,
	a1: Attachment,
	host: Instance,
	stopAt: number?,
} } = {}

local Trails = {}

local function qualityOk(min: string?): boolean
	local q = workspace:GetAttribute("VFXQuality") or "High"
	if q == "Off" then return false end
	if not min then return true end
	local rank = { Off = 0, Low = 1, Medium = 2, High = 3 }
	return (rank[q] or 3) >= (rank[min] or 1)
end

local function getTemplate(name: string): Instance?
	local assets = ReplicatedStorage:FindFirstChild("Assets")
	local vfx = assets and assets:FindFirstChild("VFX")
	local folder = vfx and vfx:FindFirstChild("Trails")
	return folder and folder:FindFirstChild(name)
end

local function applyPreset(trail: Trail, preset: TrailPreset)
	if preset.Color then trail.Color = preset.Color end
	if preset.Transparency then trail.Transparency = preset.Transparency end
	if preset.Lifetime then trail.Lifetime = preset.Lifetime end
	if preset.MinLength then trail.MinLength = preset.MinLength end
	if preset.WidthScale then trail.WidthScale = preset.WidthScale end
	if preset.LightEmission then trail.LightEmission = preset.LightEmission end
	if preset.FaceCamera ~= nil then trail.FaceCamera = preset.FaceCamera end
end

local function resolvePart(host: Instance): BasePart?
	if host:IsA("BasePart") then return host end
	if host:IsA("Model") then
		return host:FindFirstChild("HumanoidRootPart") :: BasePart?
			or host.PrimaryPart
			or host:FindFirstChildWhichIsA("BasePart")
	end
	if host:IsA("Tool") then
		return host:FindFirstChild("Handle") :: BasePart?
	end
	return nil
end

function Trails.Start(presetName: string, host: Instance, opts: { Duration: number?, Id: string? }?): string?
	local preset = Registry[presetName]
	if not preset then
		warn("[Trails] Unknown preset:", presetName)
		return nil
	end
	if not qualityOk(preset.QualityMin) then
		return nil
	end

	local part = resolvePart(host)
	if not part then
		warn("[Trails] No BasePart on host")
		return nil
	end

	local id = (opts and opts.Id) or (`{presetName}_{os.clock()}`)
	Trails.Stop(id)

	local a0: Attachment
	local a1: Attachment
	local trail: Trail

	local template = preset.Template and getTemplate(preset.Template)
	if template then
		local clone = template:Clone()
		trail = clone:FindFirstChildWhichIsA("Trail", true) :: Trail
		a0 = (clone:FindFirstChild("A0", true) or clone:FindFirstChildWhichIsA("Attachment", true)) :: Attachment
		a1 = clone:FindFirstChild("A1", true) :: Attachment
		if not (trail and a0 and a1) then
			clone:Destroy()
			warn("[Trails] Bad template:", preset.Template)
			return nil
		end
		a0.Parent = part
		a1.Parent = part
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Parent = part
		clone:Destroy()
	else
		a0 = Instance.new("Attachment")
		a1 = Instance.new("Attachment")
		a0.Name = "TrailA0_" .. id
		a1.Name = "TrailA1_" .. id
		a0.CFrame = preset.Offset0 or CFrame.new()
		a1.CFrame = preset.Offset1 or CFrame.new(0, 0, -1.5)
		a0.Parent = part
		a1.Parent = part

		trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		applyPreset(trail, preset)
		trail.Parent = part
	end

	trail.Enabled = true

	local duration = (opts and opts.Duration) or preset.MaxDuration
	local stopAt = if duration then os.clock() + duration else nil

	active[id] = {
		trail = trail,
		a0 = a0,
		a1 = a1,
		host = host,
		stopAt = stopAt,
	}

	if duration then
		task.delay(duration, function()
			Trails.Stop(id)
		end)
	end

	return id
end

function Trails.Stop(id: string)
	local entry = active[id]
	if not entry then return end
	active[id] = nil

	if entry.trail then
		entry.trail.Enabled = false
		Debris:AddItem(entry.trail, entry.trail.Lifetime or 0.3)
	end
	if entry.a0 then Debris:AddItem(entry.a0, 0.35) end
	if entry.a1 then Debris:AddItem(entry.a1, 0.35) end
end

function Trails.StopAllOn(host: Instance)
	for id, entry in active do
		if entry.host == host or entry.host:IsDescendantOf(host) then
			Trails.Stop(id)
		end
	end
end

function Trails.Register(name: string, preset: TrailPreset)
	Registry[name] = preset
end

function Trails.GetPreset(name: string): TrailPreset?
	return Registry[name]
end

return Trails

