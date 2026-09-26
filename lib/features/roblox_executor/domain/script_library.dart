class RbxScript {
  const RbxScript({required this.name, required this.category, required this.description, required this.code});
  final String name;
  final String category;
  final String description;
  final String code;
}

const List<RbxScript> builtInScripts = [
  RbxScript(
    name: 'Infinite Jump',
    category: 'Movement',
    description: 'Jump infinitely — press space even in mid-air.',
    code: '''
local UIS = game:GetService("UserInputService")
local plr = game.Players.LocalPlayer

UIS.JumpRequest:Connect(function()
    if plr.Character and plr.Character:FindFirstChild("Humanoid") then
        plr.Character.Humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
    end
end)

print("[J3] Infinite Jump enabled")
''',
  ),
  RbxScript(
    name: 'Speed Hack',
    category: 'Movement',
    description: 'Set WalkSpeed to a custom value.',
    code: '''
local plr = game.Players.LocalPlayer
if plr.Character and plr.Character:FindFirstChild("Humanoid") then
    plr.Character.Humanoid.WalkSpeed = 100
    print("[J3] WalkSpeed set to 100")
end
''',
  ),
  RbxScript(
    name: 'Noclip',
    category: 'Movement',
    description: 'Walk through walls. Toggle with "N" key.',
    code: '''
local noclip = false
local plr = game.Players.LocalPlayer

game:GetService("RunService").Stepped:Connect(function()
    if noclip and plr.Character then
        for _, part in pairs(plr.Character:GetDescendants()) do
            if part:IsA("BasePart") then
                part.CanCollide = false
            end
        end
    end
end)

game:GetService("UserInputService").InputBegan:Connect(function(input)
    if input.KeyCode == Enum.KeyCode.N then
        noclip = not noclip
        print("[J3] Noclip: " .. tostring(noclip))
    end
end)

print("[J3] Noclip loaded — press N to toggle")
''',
  ),
  RbxScript(
    name: 'Fly',
    category: 'Movement',
    description: 'Fly around the map. Press E to toggle.',
    code: '''
local plr = game.Players.LocalPlayer
local UIS = game:GetService("UserInputService")
local flying = false
local speed = 50
local bv, bg

local function startFly()
    local char = plr.Character
    if not char then return end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return end

    bv = Instance.new("BodyVelocity", hrp)
    bv.MaxForce = Vector3.new(math.huge, math.huge, math.huge)
    bv.Velocity = Vector3.new(0, 0, 0)

    bg = Instance.new("BodyGyro", hrp)
    bg.MaxTorque = Vector3.new(math.huge, math.huge, math.huge)
    bg.D = 200

    game:GetService("RunService").RenderStepped:Connect(function()
        if flying and bv and bg then
            local cam = workspace.CurrentCamera
            bg.CFrame = cam.CFrame
            local mv = Vector3.new(0, 0, 0)
            if UIS:IsKeyDown(Enum.KeyCode.W) then mv = mv + cam.CFrame.LookVector end
            if UIS:IsKeyDown(Enum.KeyCode.S) then mv = mv - cam.CFrame.LookVector end
            if UIS:IsKeyDown(Enum.KeyCode.A) then mv = mv - cam.CFrame.RightVector end
            if UIS:IsKeyDown(Enum.KeyCode.D) then mv = mv + cam.CFrame.RightVector end
            if UIS:IsKeyDown(Enum.KeyCode.Space) then mv = mv + Vector3.new(0, 1, 0) end
            if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then mv = mv - Vector3.new(0, 1, 0) end
            bv.Velocity = mv * speed
        end
    end)
end

local function stopFly()
    if bv then bv:Destroy() bv = nil end
    if bg then bg:Destroy() bg = nil end
end

UIS.InputBegan:Connect(function(input, gpe)
    if gpe then return end
    if input.KeyCode == Enum.KeyCode.E then
        flying = not flying
        if flying then startFly() else stopFly() end
        print("[J3] Fly: " .. tostring(flying))
    end
end)

print("[J3] Fly loaded — press E to toggle")
''',
  ),
  RbxScript(
    name: 'ESP / Highlight Players',
    category: 'Visual',
    description: 'Add ESP highlights to all players.',
    code: '''
local plr = game.Players.LocalPlayer

local function addEsp(character, player)
    if player == plr then return end
    local highlight = Instance.new("Highlight")
    highlight.Name = "J3ESP"
    highlight.FillColor = Color3.fromRGB(255, 0, 0)
    highlight.OutlineColor = Color3.fromRGB(255, 255, 255)
    highlight.FillTransparency = 0.5
    highlight.OutlineTransparency = 0
    highlight.Adornee = character
    highlight.Parent = character
end

for _, p in pairs(game.Players:GetPlayers()) do
    if p.Character then addEsp(p.Character, p) end
    p.CharacterAdded:Connect(function(c) addEsp(c, p) end)
end

game.Players.PlayerAdded:Connect(function(p)
    p.CharacterAdded:Connect(function(c) addEsp(c, p) end)
end)

print("[J3] ESP enabled for all players")
''',
  ),
  RbxScript(
    name: 'Fullbright',
    category: 'Visual',
    description: 'Remove all darkness and fog effects.',
    code: '''
local lighting = game:GetService("Lighting")
lighting.Brightness = 2
lighting.ClockTime = 14
lighting.FogEnd = 100000
lighting.GlobalShadows = false
lighting.Ambient = Color3.fromRGB(178, 178, 178)

for _, effect in pairs(lighting:GetChildren()) do
    if effect:IsA("PostEffect") or effect:IsA("Atmosphere") then
        effect:Destroy()
    end
end

print("[J3] Fullbright enabled")
''',
  ),
  RbxScript(
    name: 'Teleport to Player',
    category: 'Utility',
    description: 'Teleport to the nearest player.',
    code: '''
local plr = game.Players.LocalPlayer
local char = plr.Character
if not char then print("[J3] No character") return end

local hrp = char:FindFirstChild("HumanoidRootPart")
if not hrp then print("[J3] No HumanoidRootPart") return end

local closest, dist = nil, math.huge
for _, p in pairs(game.Players:GetPlayers()) do
    if p ~= plr and p.Character and p.Character:FindFirstChild("HumanoidRootPart") then
        local d = (p.Character.HumanoidRootPart.Position - hrp.Position).Magnitude
        if d < dist then closest = p; dist = d end
    end
end

if closest then
    hrp.CFrame = closest.Character.HumanoidRootPart.CFrame
    print("[J3] Teleported to " .. closest.Name)
else
    print("[J3] No other players found")
end
''',
  ),
  RbxScript(
    name: 'Server Info',
    category: 'Utility',
    description: 'Print server and game info to console.',
    code: '''
local plr = game.Players.LocalPlayer
print("[J3] === Server Info ===")
print("[J3] PlaceId: " .. game.PlaceId)
print("[J3] PlaceVersion: " .. game.PlaceVersion)
print("[J3] JobId: " .. game.JobId)
print("[J3] Players: " .. #game.Players:GetPlayers() .. "/" .. game.Players.MaxPlayers)
print("[J3] Your UserId: " .. plr.UserId)
print("[J3] Your Name: " .. plr.Name)
print("[J3] Your DisplayName: " .. plr.DisplayName)
print("[J3] ==================")
''',
  ),
  RbxScript(
    name: 'Click Teleport',
    category: 'Utility',
    description: 'Click anywhere to teleport there.',
    code: '''
local plr = game.Players.LocalPlayer
local mouse = plr:GetMouse()

mouse.Button1Down:Connect(function()
    local char = plr.Character
    if char and char:FindFirstChild("HumanoidRootPart") then
        char.HumanoidRootPart.CFrame = CFrame.new(mouse.Hit.Position + Vector3.new(0, 3, 0))
    end
end)

print("[J3] Click Teleport enabled — click anywhere to TP")
''',
  ),
  RbxScript(
    name: 'Anti-AFK',
    category: 'Utility',
    description: 'Prevent the AFK kick timer.',
    code: '''
local vu = game:GetService("VirtualUser")
game.Players.LocalPlayer.Idled:Connect(function()
    vu:CaptureController()
    vu:ClickButton2(Vector2.new())
    print("[J3] Anti-AFK triggered")
end)

print("[J3] Anti-AFK enabled")
''',
  ),
];

List<String> get scriptCategories => builtInScripts.map((s) => s.category).toSet().toList()..sort();

List<RbxScript> scriptsByCategory(String category) => builtInScripts.where((s) => s.category == category).toList();
