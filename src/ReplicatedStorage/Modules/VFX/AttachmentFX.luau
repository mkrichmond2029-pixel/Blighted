--[[
	AttachmentFX — enable/disable continuous emitters on character or item

	Expects hierarchy:
	  Host
	  └── Effects (Folder)
	      └── <EffectName> (Folder or Attachment)
	          └── ParticleEmitter / Trail / Beam ...
]]

local Debris = game:GetService("Debris")

local AttachmentFX = {}

local function qualityAllows(): boolean
	local q = workspace:GetAttribute("VFXQuality")
	return q ~= "Off" and q ~= "Low" -- tweak if you want Low to still show auras
end

local function setDescendants(root: Instance, enabled: boolean, rateWhenOn: number?)
	for _, d in root:GetDescendants() do
		if d:IsA("ParticleEmitter") then
			if enabled then
				d.Enabled = true
				if rateWhenOn then
					d.Rate = rateWhenOn
				end
			else
				d.Enabled = false
				d.Rate = 0
				d:Clear()
			end
		elseif d:IsA("Trail") or d:IsA("Beam") then
			d.Enabled = enabled
		end
	end
end

--- Find Effects/<name> under host (character or tool)
local function findEffect(host: Instance, effectName: string): Instance?
	local effects = host:FindFirstChild("Effects")
	if not effects then
		-- also search one level deeper (e.g. Handle.Effects)
		for _, child in host:GetChildren() do
			local sub = child:FindFirstChild("Effects")
			if sub then
				effects = sub
				break
			end
		end
	end
	if not effects then return nil end
	return effects:FindFirstChild(effectName)
end

--- Start a continuous effect that already lives on the model
function AttachmentFX.Start(host: Instance, effectName: string, rateWhenOn: number?): boolean
	if not qualityAllows() then return false end
	local node = findEffect(host, effectName)
	if not node then
		warn("[AttachmentFX] Missing Effects." .. effectName .. " on", host:GetFullName())
		return false
	end
	setDescendants(node, true, rateWhenOn)
	return true
end

function AttachmentFX.Stop(host: Instance, effectName: string)
	local node = findEffect(host, effectName)
	if node then
		setDescendants(node, false)
	end
end

function AttachmentFX.StopAll(host: Instance)
	local effects = host:FindFirstChild("Effects")
	if not effects then
		for _, child in host:GetChildren() do
			local sub = child:FindFirstChild("Effects")
			if sub then effects = sub break end
		end
	end
	if effects then
		setDescendants(effects, false)
	end
end

return AttachmentFX

