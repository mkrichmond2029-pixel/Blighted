--[[
	VFX Presets — keep EmitCount modest; quality scaling multiplies them.
]]

export type Preset = {
	Template: string?,
	Duration: number?,
	EmitCount: number?,
	Sound: string?,
	Color: Color3?,
	Description: string?,
}

local Registry: { [string]: Preset } = {
	MeleeSwing = {
		Template = "MeleeSwing",
		Duration = 0.3,
		EmitCount = 8,
		Color = Color3.fromRGB(255, 240, 180),
	},
	HeavySwing = {
		Template = "HeavySwing",
		Duration = 0.4,
		EmitCount = 12,
		Color = Color3.fromRGB(255, 200, 120),
	},
	HitImpact = {
		Template = "HitImpact",
		Duration = 0.35,
		EmitCount = 10,
		Color = Color3.fromRGB(255, 255, 255),
	},
	HitBlood = {
		Template = "HitBlood",
		Duration = 0.45,
		EmitCount = 12,
		Color = Color3.fromRGB(160, 20, 20),
	},
	KickDust = {
		Template = "KickDust",
		Duration = 0.4,
		EmitCount = 8,
		Color = Color3.fromRGB(180, 170, 150),
	},
	RebarTrail = {
		Template = "RebarTrail",
		Duration = 0.8,
		EmitCount = 4,
		Color = Color3.fromRGB(140, 140, 150),
	},
	RebarImpact = {
		Template = "RebarImpact",
		Duration = 0.4,
		EmitCount = 14,
		Color = Color3.fromRGB(200, 180, 80),
	},
	ChainsawSparks = {
		Template = "ChainsawSparks",
		Duration = 0.35,
		EmitCount = 14,
		Color = Color3.fromRGB(255, 160, 60),
	},
	ChainsawClash = {
		Template = "ChainsawClash",
		Duration = 0.5,
		EmitCount = 18,
		Color = Color3.fromRGB(255, 100, 40),
	},
	BuffAura = {
		Template = "BuffAura",
		Duration = 0.6,
		EmitCount = 6,
		Color = Color3.fromRGB(120, 200, 255),
	},
}

local Presets = {}

function Presets.Get(name: string): Preset?
	return Registry[name]
end

function Presets.Register(name: string, preset: Preset)
	Registry[name] = preset
end

function Presets.GetAll(): { [string]: Preset }
	return Registry
end

return Presets
