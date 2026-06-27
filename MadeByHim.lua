local CONFIG = {
    AUTO_STEAL_ENABLED = true,
    HOLD_MIN = 1.3,
    STEAL_RANGE = 10,
    PRIME_RANGE = 80,
    MIN_GENERATION = 0,
    GUI_VISIBLE = true,
    GUI_X = nil,
    GUI_Y = nil,
    TOGGLE_X = nil,
    TOGGLE_Y = nil,
}

local CONFIG_FILE = "PrivAutoStealConfig.json"

local function saveConfig()
    local data = {
        stealRange = CONFIG.STEAL_RANGE,
        minGeneration = CONFIG.MIN_GENERATION,
        guiX = CONFIG.GUI_X,
        guiY = CONFIG.GUI_Y,
        toggleX = CONFIG.TOGGLE_X,
        toggleY = CONFIG.TOGGLE_Y,
        guiVisible = CONFIG.GUI_VISIBLE,
    }
    local json = game:GetService("HttpService"):JSONEncode(data)
    writefile(CONFIG_FILE, json)
end

local function loadConfig()
    if not isfile(CONFIG_FILE) then return end
    local success, json = pcall(readfile, CONFIG_FILE)
    if not success or not json then return end
    local success2, data = pcall(game:GetService("HttpService").JSONDecode, game:GetService("HttpService"), json)
    if success2 and data then
        if data.stealRange then CONFIG.STEAL_RANGE = data.stealRange end
        if data.minGeneration then CONFIG.MIN_GENERATION = data.minGeneration end
        if data.guiX then CONFIG.GUI_X = data.guiX end
        if data.guiY then CONFIG.GUI_Y = data.guiY end
        if data.toggleX then CONFIG.TOGGLE_X = data.toggleX end
        if data.toggleY then CONFIG.TOGGLE_Y = data.toggleY end
        if data.guiVisible ~= nil then CONFIG.GUI_VISIBLE = data.guiVisible end
    end
end

loadConfig()

local S = {
    Players = game:GetService("Players"),
    ReplicatedStorage = game:GetService("ReplicatedStorage"),
    RunService = game:GetService("RunService"),
    UserInputService = game:GetService("UserInputService"),
    TweenService = game:GetService("TweenService"),
}

local Packages = S.ReplicatedStorage:WaitForChild("Packages")
local Datas = S.ReplicatedStorage:WaitForChild("Datas")
local AnimalsData = require(Datas:WaitForChild("Animals"))

S.LocalPlayer = S.Players.LocalPlayer

local plots = workspace:WaitForChild("Plots")
local debris = workspace:FindFirstChild("Debris")

local syncRemotes = (function()
    local folder = Packages:WaitForChild("Synchronizer")
    return {
        channelFolder = folder:WaitForChild("Channel"),
        routeRemote = folder:WaitForChild("CommunicationRoute"),
        requestData = folder:FindFirstChild("RequestData"),
    }
end)()

local plotAnimalSync = { caches = {}, connections = {} }
local onPlotDataChanged = Instance.new("BindableEvent")

local function splitSyncPath(path)
    if typeof(path) == "table" then return path end
    local out = {}
    for part in string.gmatch(tostring(path), "[^%.]+") do
        table.insert(out, tonumber(part) or part)
    end
    return out
end

local function resolveSyncPath(path, root)
    local current = root
    local parent = nil
    local key = nil
    for _, part in ipairs(splitSyncPath(path)) do
        parent = current
        key = part
        current = current and current[part] or nil
    end
    return current, parent, key
end

local function pathTouchesAnimalList(path)
    local parts = splitSyncPath(path)
    return parts[1] == "AnimalList"
end

local function applyPlotSyncDiff(channelName, packet)
    local cache = plotAnimalSync.caches[channelName]
    if typeof(cache) ~= "table" then return end
    local path, action, a, b = packet[1], packet[2], packet[3], packet[4]
    local current, parent, key = resolveSyncPath(path, cache)
    local relevant = pathTouchesAnimalList(path)

    if action == "Changed" then
        if parent ~= nil then parent[key] = a end
    elseif action == "ArrayInsert" then
        if current ~= nil then table.insert(current, b, a) end
    elseif action == "ArrayRemoved" then
        if current ~= nil then table.remove(current, b) end
    elseif action == "DictionaryInsert" then
        if current ~= nil then current[b] = a end
    elseif action == "DictionaryRemoved" then
        if current ~= nil then current[b] = nil end
    end

    if relevant then
        onPlotDataChanged:Fire()
    end
end

local function attachPlotChannel(remote)
    if plotAnimalSync.connections[remote] then return end
    local channelName = tostring(remote.Name)
    if not plots:FindFirstChild(channelName) then return end
    if syncRemotes.requestData and plotAnimalSync.caches[channelName] == nil then
        local ok, data = pcall(function()
            return syncRemotes.requestData:InvokeServer(channelName)
        end)
        if ok and typeof(data) == "table" then
            plotAnimalSync.caches[channelName] = data
        else
            plotAnimalSync.caches[channelName] = {}
        end
    elseif plotAnimalSync.caches[channelName] == nil then
        plotAnimalSync.caches[channelName] = {}
    end
    plotAnimalSync.connections[remote] = remote.OnClientEvent:Connect(function(queue)
        for _, packet in ipairs(queue) do
            applyPlotSyncDiff(channelName, packet)
        end
    end)
    onPlotDataChanged:Fire()
end

local function detachPlotChannel(channelName)
    for remote, conn in pairs(plotAnimalSync.connections) do
        if tostring(remote.Name) == tostring(channelName) then
            conn:Disconnect()
            plotAnimalSync.connections[remote] = nil
            plotAnimalSync.caches[tostring(channelName)] = nil
            break
        end
    end
end

for _, child in ipairs(syncRemotes.channelFolder:GetChildren()) do
    if child:IsA("RemoteEvent") then
        attachPlotChannel(child)
    end
end

syncRemotes.channelFolder.ChildAdded:Connect(function(child)
    if child:IsA("RemoteEvent") then
        attachPlotChannel(child)
    end
end)

syncRemotes.routeRemote.OnClientEvent:Connect(function(actions)
    for _, action in ipairs(actions) do
        local kind, channelName = action[1], tostring(action[2])
        if not plots:FindFirstChild(channelName) then continue end
        if kind == "ListenerAdded" then
            local remote = syncRemotes.channelFolder:FindFirstChild(channelName)
            if remote and remote:IsA("RemoteEvent") then
                attachPlotChannel(remote)
            end
        elseif kind == "ListenerRemoved" then
            detachPlotChannel(channelName)
        end
    end
end)

local function getPlotChannelData(plotName)
    return plotAnimalSync.caches[plotName]
end

local allAnimalsCache = {}
local PromptMemoryCache = {}
local InternalStealCache = {}
local stealConnection = nil
local scanConnection = nil

local StealGeneration = 0

local StealState = {
    active = false,
    startTime = 0,
    label = "",
    generation = 0,
    lastResult = "",
    lastResultTime = 0,
    totalSteals = 0,
    failedSteals = 0,
    currentUid = nil,
    cooldownUntil = 0,
    holdProgress = 0,
}

local pickCache = { target = nil, position = nil, valid = false }

local function invalidatePickCache()
    pickCache.valid = false
end

local function getPlotOwner(plot)
    local sign = plot:FindFirstChild("PlotSign")
    local frame = sign and sign:FindFirstChild("SurfaceGui") and sign.SurfaceGui:FindFirstChild("Frame")
    local label = frame and frame:FindFirstChild("TextLabel")
    if not label or label.Text == "Empty Base" then
        return nil
    end
    return label.Text:gsub("'s [Bb]ase$", ""):gsub("%s+$", "")
end

local function isMyBaseAnimal(animalData)
    if not animalData or not animalData.plot then return false end
    local plot = plots:FindFirstChild(animalData.plot)
    if not plot then return false end
    return getPlotOwner(plot) == S.LocalPlayer.DisplayName
end

local function stripRichText(s)
    if not s or s == "" then return s end
    return (s:gsub("<[^>]+>", ""):gsub("%s+", " "):match("^%s*(.-)%s*$"))
end

local function getText(obj)
    if not obj then return "" end
    local raw = ""
    if obj:IsA("TextLabel") or obj:IsA("TextBox") or obj:IsA("TextButton") then
        raw = obj.Text or ""
    else
        for _, c in ipairs(obj:GetDescendants()) do
            if (c:IsA("TextLabel") or c:IsA("TextBox")) and c.Text ~= "" then
                raw = c.Text
                break
            end
        end
    end
    return stripRichText(raw)
end

local overheadListCache = {}
local overheadListTime = 0
local OVERHEAD_LIST_TTL = 0.05

local function invalidateOverheadCache()
    overheadListTime = 0
end

local function getOverheadList()
    local now = tick()
    if now - overheadListTime < OVERHEAD_LIST_TTL then
        return overheadListCache
    end
    overheadListTime = now
    overheadListCache = {}
    
    if not debris then
        return overheadListCache
    end
    
    for _, part in ipairs(debris:GetChildren()) do
        if part.Name == "FastOverheadTemplate" and part:IsA("BasePart") then
            local overhead = part:FindFirstChild("AnimalOverhead")
            if overhead then
                local name = getText(overhead:FindFirstChild("DisplayName"))
                local gen = getText(overhead:FindFirstChild("Generation"))
                if name ~= "" and gen ~= "" then
                    table.insert(overheadListCache, {
                        name = name,
                        gen = gen,
                    })
                end
            end
        end
    end
    
    return overheadListCache
end

if debris then
    debris.ChildAdded:Connect(invalidateOverheadCache)
    debris.ChildRemoved:Connect(invalidateOverheadCache)
end

local function parseGenText(text)
    if not text or text == "" then return 0 end
    local clean = text:gsub("[%$]", ""):gsub("/s", ""):gsub("%s+", "")
    local num = tonumber(clean:match("[%d%.]+"))
    if not num or num == 0 then return 0 end
    if clean:find("[Mm]") then return num * 1000000 end
    if clean:find("[Bb]") then return num * 1000000000 end
    if clean:find("[Kk]") then return num * 1000 end
    return num
end

local function parseUserInput(input)
    if not input or input == "" then return 0 end
    input = input:lower():gsub(",", ""):gsub("%s+", "")
    local num = tonumber(input:match("[%d%.]+")) or 0
    if input:find("b$") then return num * 1000000000 end
    if input:find("m$") then return num * 1000000 end
    if input:find("k$") then return num * 1000 end
    return num
end

local function formatNumber(num)
    if num >= 1000000000 then return string.format("%.1fb", num / 1000000000) end
    if num >= 1000000 then return string.format("%.1fm", num / 1000000) end
    if num >= 1000 then return string.format("%.1fk", num / 1000) end
    return tostring(num)
end

local function getAnimalGeneration(animalData)
    if not animalData or not animalData.plot or not animalData.slot then
        return 0
    end
    
    local animalName = animalData.name or ""
    if animalName == "" then
        return 0
    end
    
    local list = getOverheadList()
    if #list == 0 then
        return 0
    end
    
    local animalNameLower = string.lower(animalName)
    for _, entry in ipairs(list) do
        local entryNameLower = string.lower(entry.name or "")
        if entryNameLower == animalNameLower then
            return parseGenText(entry.gen)
        end
    end
    
    for _, entry in ipairs(list) do
        local entryNameLower = string.lower(entry.name or "")
        if entryNameLower:find(animalNameLower, 1, true) or animalNameLower:find(entryNameLower, 1, true) then
            return parseGenText(entry.gen)
        end
    end
    
    return 0
end

local function findProximityPromptForAnimal(animalData)
    if not animalData then return nil end
    local cached = PromptMemoryCache[animalData.uid]
    if cached and cached.Parent then return cached end

    local plot = workspace.Plots:FindFirstChild(animalData.plot)
    if not plot then return nil end
    local podiums = plot:FindFirstChild("AnimalPodiums")
    if not podiums then return nil end
    local podium = podiums:FindFirstChild(animalData.slot)
    if not podium then return nil end
    local base = podium:FindFirstChild("Base")
    if not base then return nil end
    local spawn = base:FindFirstChild("Spawn")
    if not spawn then return nil end
    local attach = spawn:FindFirstChild("PromptAttachment")
    if not attach then return nil end

    for _, p in ipairs(attach:GetChildren()) do
        if p:IsA("ProximityPrompt") then
            PromptMemoryCache[animalData.uid] = p
            return p
        end
    end
    return nil
end

local function getAnimalPosition(animalData)
    local plot = workspace.Plots:FindFirstChild(animalData.plot)
    if not plot then return nil end
    local podiums = plot:FindFirstChild("AnimalPodiums")
    if not podiums then return nil end
    local podium = podiums:FindFirstChild(animalData.slot)
    if not podium then return nil end
    return podium:GetPivot().Position
end

local function distToAnimal(animalData)
    local character = S.LocalPlayer.Character
    if not character then return math.huge end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("UpperTorso")
    if not hrp then return math.huge end
    local pos = getAnimalPosition(animalData)
    if not pos then return math.huge end
    return (hrp.Position - pos).Magnitude
end

local function getCachedClosest()
    local character = S.LocalPlayer.Character
    if not character then return nil end
    local hrp = character:FindFirstChild("HumanoidRootPart") or character:FindFirstChild("UpperTorso")
    if not hrp then return nil end

    local pos = hrp.Position

    if pickCache.valid and pickCache.position then
        local moved = (pos - pickCache.position).Magnitude
        if moved < 4 then
            return pickCache.target
        end
    end

    local best, bestDist = nil, math.huge
    for _, animalData in ipairs(allAnimalsCache) do
        if isMyBaseAnimal(animalData) then
            continue
        end
        
        if CONFIG.MIN_GENERATION > 0 then
            local gen = getAnimalGeneration(animalData)
            if gen < CONFIG.MIN_GENERATION then
                continue
            end
        end
        
        local animalPos = getAnimalPosition(animalData)
        if animalPos then
            local dist = (pos - animalPos).Magnitude
            if dist < CONFIG.PRIME_RANGE and dist < bestDist then
                bestDist = dist
                best = animalData
            end
        end
    end

    pickCache.target = best
    pickCache.position = pos
    pickCache.valid = true

    return best
end

local function buildStealCallbacks(prompt)
    if InternalStealCache[prompt] then return end
    local data = { holdCallbacks = {}, triggerCallbacks = {}, ready = true }

    local ok1, conns1 = pcall(getconnections, prompt.PromptButtonHoldBegan)
    if ok1 and type(conns1) == "table" then
        for _, conn in ipairs(conns1) do
            if type(conn.Function) == "function" then
                table.insert(data.holdCallbacks, conn.Function)
            end
        end
    end

    local ok2, conns2 = pcall(getconnections, prompt.Triggered)
    if ok2 and type(conns2) == "table" then
        for _, conn in ipairs(conns2) do
            if type(conn.Function) == "function" then
                table.insert(data.triggerCallbacks, conn.Function)
            end
        end
    end

    if (#data.holdCallbacks > 0) or (#data.triggerCallbacks > 0) then
        InternalStealCache[prompt] = data
    end
end

local function cancelCurrentSteal()
    StealGeneration = StealGeneration + 1
    StealState.active = false
    StealState.currentUid = nil
    StealState.holdProgress = 0
end

local function executeStealAsync(prompt, animalData, myGeneration)
    local data = InternalStealCache[prompt]
    if not data or not data.ready then return false end
    data.ready = false

    local label = animalData.name or "Animal"
    StealState.active = true
    StealState.startTime = tick()
    StealState.label = label
    StealState.generation = getAnimalGeneration(animalData)
    StealState.currentUid = animalData.uid
    StealState.holdProgress = 0

    task.spawn(function()
        for _, fn in ipairs(data.holdCallbacks) do
            task.spawn(fn)
        end

        local startTime = tick()
        while true do
            local elapsed = tick() - startTime
            StealState.holdProgress = math.min(elapsed / CONFIG.HOLD_MIN, 1)
            
            if elapsed >= CONFIG.HOLD_MIN then
                break
            end
            
            if myGeneration ~= StealGeneration then
                StealState.holdProgress = 0
                data.ready = true
                return
            end
            
            if not prompt.Parent then
                StealState.holdProgress = 0
                data.ready = true
                return
            end
            
            task.wait()
        end

        if myGeneration ~= StealGeneration then
            StealState.holdProgress = 0
            data.ready = true
            return
        end

        local fired = false
        local inRange = false
        
        local rangeCheckStart = tick()
        while true do
            if myGeneration ~= StealGeneration then break end
            if not prompt.Parent then break end
            
            local dist = distToAnimal(animalData)
            if dist <= CONFIG.STEAL_RANGE then
                inRange = true
                break
            end
            
            if tick() - rangeCheckStart > 1 then
                break
            end
            
            task.wait()
        end
        
        if inRange and myGeneration == StealGeneration then
            for _, fn in ipairs(data.triggerCallbacks) do
                task.spawn(fn)
            end
            fired = true
        end

        if myGeneration == StealGeneration then
            if fired then
                StealState.totalSteals = StealState.totalSteals + 1
                StealState.lastResult = "Stole " .. label
            else
                StealState.failedSteals = StealState.failedSteals + 1
                StealState.lastResult = "Missed: " .. label
            end

            StealState.active = false
            StealState.lastResultTime = tick()
            StealState.currentUid = nil
            StealState.holdProgress = 0
            StealState.cooldownUntil = tick() + 0.05
        end

        data.ready = true
    end)
    return true
end

local function attemptSteal(target)
    if tick() < StealState.cooldownUntil then
        return false
    end
    
    if not target or not target.prompt or not target.prompt.Parent then
        return false
    end

    if not InternalStealCache[target.prompt] then
        buildStealCallbacks(target.prompt)
        if not InternalStealCache[target.prompt] then
            return false
        end
    end

    StealGeneration = StealGeneration + 1
    return executeStealAsync(target.prompt, target, StealGeneration)
end

local function scanAllPlots()
    local newCache = {}
    local seenUids = {}
    
    for _, plot in ipairs(plots:GetChildren()) do
        local cache = getPlotChannelData(plot.Name)
        if not cache then continue end
        local animalList = cache.AnimalList
        if typeof(animalList) ~= "table" then continue end
        
        for slot, animalData in pairs(animalList) do
            if type(animalData) == "table" then
                local animalName = animalData.Index
                local animalInfo = AnimalsData[animalName]
                if not animalInfo then continue end
                
                local uid = plot.Name .. "_" .. tostring(slot)
                if seenUids[uid] then continue end
                seenUids[uid] = true
                
                local displayName = animalInfo.DisplayName or animalName
                local entry = {
                    name = displayName,
                    plot = plot.Name,
                    slot = tostring(slot),
                    uid = uid,
                    prompt = nil,
                }
                
                local prompt = findProximityPromptForAnimal(entry)
                if prompt then
                    entry.prompt = prompt
                    buildStealCallbacks(prompt)
                end
                
                table.insert(newCache, entry)
            end
        end
    end
    
    for _, plot in ipairs(plots:GetChildren()) do
        local podiums = plot:FindFirstChild("AnimalPodiums")
        if not podiums then continue end
        
        for slot, podium in pairs(podiums:GetChildren()) do
            for _, child in ipairs(plot:GetChildren()) do
                if child:IsA("Model") and child.Name ~= "AnimalPodiums" and child.Name ~= "PlotSign" then
                    local root = child:FindFirstChild("RootPart") or child:FindFirstChild("FakeRootPart")
                    if root then
                        local uid = plot.Name .. "_" .. tostring(slot)
                        if seenUids[uid] then break end
                        seenUids[uid] = true
                        
                        local entry = {
                            name = child.Name,
                            plot = plot.Name,
                            slot = tostring(slot),
                            uid = uid,
                            prompt = nil,
                        }
                        
                        local prompt = findProximityPromptForAnimal(entry)
                        if prompt then
                            entry.prompt = prompt
                            buildStealCallbacks(prompt)
                        end
                        
                        table.insert(newCache, entry)
                        break
                    end
                end
            end
        end
    end
    
    allAnimalsCache = newCache
    invalidatePickCache()
    return #allAnimalsCache
end

local function startAutoSteal()
    if stealConnection then return end
    stealConnection = S.RunService.Heartbeat:Connect(function()
        if not CONFIG.AUTO_STEAL_ENABLED then return end
        
        if tick() < StealState.cooldownUntil then return end

        local target = getCachedClosest()
        if not target then
            if StealState.active then cancelCurrentSteal() end
            return
        end

        if StealState.active then
            if target.uid ~= StealState.currentUid then
                cancelCurrentSteal()
            else
                return
            end
        end

        if target.prompt and target.prompt.Parent then
            attemptSteal(target)
        else
            local prompt = findProximityPromptForAnimal(target)
            if prompt then
                target.prompt = prompt
                attemptSteal(target)
            end
        end
    end)
end

local function stopAutoSteal()
    if not stealConnection then return end
    stealConnection:Disconnect()
    stealConnection = nil
    cancelCurrentSteal()
end

-- ============================================================
-- CLEAN OCEAN THEME GUI
-- ============================================================

local THEME = {
    bg = Color3.fromRGB(8, 16, 30),
    bg2 = Color3.fromRGB(12, 24, 42),
    surface = Color3.fromRGB(16, 30, 50),
    surfaceLight = Color3.fromRGB(22, 42, 70),
    primary = Color3.fromRGB(50, 180, 255),
    primaryDark = Color3.fromRGB(30, 140, 230),
    primaryLight = Color3.fromRGB(120, 220, 255),
    text = Color3.fromRGB(220, 240, 255),
    textDim = Color3.fromRGB(150, 190, 230),
    textBright = Color3.fromRGB(255, 255, 255),
    success = Color3.fromRGB(80, 240, 160),
    error = Color3.fromRGB(255, 90, 110),
    warning = Color3.fromRGB(255, 210, 60),
    border = Color3.fromRGB(30, 80, 140),
}

local function corner(obj, radius)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, radius or 10)
    c.Parent = obj
end

local function stroke(obj, color, thickness)
    local s = Instance.new("UIStroke")
    s.Color = color or THEME.border
    s.Thickness = thickness or 1
    s.Parent = obj
    return s
end

local function gradient(obj, color1, color2, rotation)
    local g = Instance.new("UIGradient")
    g.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, color1),
        ColorSequenceKeypoint.new(1, color2),
    })
    g.Rotation = rotation or 135
    g.Parent = obj
    return g
end

local function createUI()
    local existing = S.LocalPlayer.PlayerGui:FindFirstChild("PrivAutoSteal")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "PrivAutoSteal"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = S.LocalPlayer:WaitForChild("PlayerGui")

    local vp = workspace.CurrentCamera.ViewportSize
    
    local CARD_WIDTH = 250
    local CARD_HEIGHT = 155
    
    local card = Instance.new("Frame")
    card.Name = "Card"
    card.Size = UDim2.new(0, CARD_WIDTH, 0, CARD_HEIGHT)
    card.Position = UDim2.fromOffset(CONFIG.GUI_X or (vp.X / 2 - CARD_WIDTH/2), CONFIG.GUI_Y or 100)
    card.BackgroundColor3 = THEME.bg
    card.BorderSizePixel = 0
    card.Parent = screenGui
    card.Visible = CONFIG.GUI_VISIBLE
    corner(card, 14)
    stroke(card, THEME.primary, 1.5)
    gradient(card, THEME.bg, THEME.bg2, 135)

    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 34)
    header.BackgroundColor3 = THEME.surface
    header.BackgroundTransparency = 0.2
    header.BorderSizePixel = 0
    header.Parent = card
    corner(header, 14)

    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 1, 0)
    title.BackgroundTransparency = 1
    title.Text = "PRIV AUTO STEAL"
    title.TextColor3 = THEME.textBright
    title.TextSize = 12
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Center
    title.Parent = header

    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.AnchorPoint = Vector2.new(1, 0.5)
    statusDot.Position = UDim2.new(1, -12, 0.5, 0)
    statusDot.BackgroundColor3 = THEME.success
    statusDot.BorderSizePixel = 0
    statusDot.Parent = header
    corner(statusDot, 4)

    local dragData = { dragging = false, startPos = nil, startMouse = nil }

    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragData.dragging = true
            dragData.startMouse = input.Position
            dragData.startPos = card.Position
        end
    end)

    header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragData.dragging = false
        end
    end)

    S.UserInputService.InputChanged:Connect(function(input)
        if not dragData.dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragData.startMouse
            local newX = math.clamp(dragData.startPos.X.Offset + delta.X, 0, workspace.CurrentCamera.ViewportSize.X - CARD_WIDTH)
            local newY = math.clamp(dragData.startPos.Y.Offset + delta.Y, 0, workspace.CurrentCamera.ViewportSize.Y - CARD_HEIGHT)
            card.Position = UDim2.fromOffset(newX, newY)
            CONFIG.GUI_X = newX
            CONFIG.GUI_Y = newY
        end
    end)

    -- Row 1: Auto Steal toggle
    local row1 = Instance.new("Frame")
    row1.Size = UDim2.new(1, -20, 0, 24)
    row1.Position = UDim2.new(0, 10, 0, 40)
    row1.BackgroundTransparency = 1
    row1.Parent = card

    local lbl1 = Instance.new("TextLabel")
    lbl1.Size = UDim2.new(0, 90, 1, 0)
    lbl1.BackgroundTransparency = 1
    lbl1.Text = "Auto Steal"
    lbl1.TextColor3 = THEME.text
    lbl1.TextSize = 11
    lbl1.Font = Enum.Font.GothamSemibold
    lbl1.TextXAlignment = Enum.TextXAlignment.Left
    lbl1.Parent = row1

    local tglBtn = Instance.new("TextButton")
    tglBtn.Size = UDim2.new(0, 38, 0, 18)
    tglBtn.Position = UDim2.new(1, -38, 0.5, -9)
    tglBtn.AutoButtonColor = false
    tglBtn.Text = ""
    tglBtn.BackgroundColor3 = CONFIG.AUTO_STEAL_ENABLED and THEME.primary or Color3.fromRGB(18, 38, 65)
    tglBtn.Parent = row1
    corner(tglBtn, 9)

    local tglKnob = Instance.new("Frame")
    tglKnob.Size = UDim2.new(0, 13, 0, 13)
    tglKnob.Position = CONFIG.AUTO_STEAL_ENABLED and UDim2.new(1, -16, 0.5, -6.5) or UDim2.new(0, 3, 0.5, -6.5)
    tglKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    tglKnob.BorderSizePixel = 0
    tglKnob.Parent = tglBtn
    corner(tglKnob, 7)

    local function updateToggleVisual()
        local on = CONFIG.AUTO_STEAL_ENABLED
        S.TweenService:Create(tglKnob, TweenInfo.new(0.15, Enum.EasingStyle.Quad), {
            Position = on and UDim2.new(1, -16, 0.5, -6.5) or UDim2.new(0, 3, 0.5, -6.5)
        }):Play()
        S.TweenService:Create(tglBtn, TweenInfo.new(0.15), {
            BackgroundColor3 = on and THEME.primary or Color3.fromRGB(18, 38, 65)
        }):Play()
    end

    tglBtn.MouseButton1Click:Connect(function()
        CONFIG.AUTO_STEAL_ENABLED = not CONFIG.AUTO_STEAL_ENABLED
        updateToggleVisual()
        if CONFIG.AUTO_STEAL_ENABLED then startAutoSteal() else stopAutoSteal() end
        saveConfig()
    end)

    -- Row 2: Radius slider
    local row2 = Instance.new("Frame")
    row2.Size = UDim2.new(1, -20, 0, 22)
    row2.Position = UDim2.new(0, 10, 0, 68)
    row2.BackgroundTransparency = 1
    row2.Parent = card

    local lbl2 = Instance.new("TextLabel")
    lbl2.Size = UDim2.new(0, 50, 1, 0)
    lbl2.BackgroundTransparency = 1
    lbl2.Text = "Radius"
    lbl2.TextColor3 = THEME.text
    lbl2.TextSize = 10
    lbl2.Font = Enum.Font.GothamSemibold
    lbl2.TextXAlignment = Enum.TextXAlignment.Left
    lbl2.Parent = row2

    local radVal = Instance.new("TextLabel")
    radVal.Size = UDim2.new(0, 30, 1, 0)
    radVal.Position = UDim2.new(1, -30, 0, 0)
    radVal.BackgroundTransparency = 1
    radVal.Text = tostring(CONFIG.STEAL_RANGE)
    radVal.TextColor3 = THEME.primaryLight
    radVal.TextSize = 10
    radVal.Font = Enum.Font.GothamBold
    radVal.TextXAlignment = Enum.TextXAlignment.Right
    radVal.Parent = row2

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -92, 0, 4)
    track.Position = UDim2.new(0, 55, 0.5, -2)
    track.BackgroundColor3 = Color3.fromRGB(12, 28, 50)
    track.BorderSizePixel = 0
    track.Parent = row2
    corner(track, 2)

    local trackFill = Instance.new("Frame")
    trackFill.Size = UDim2.new(0, 0, 1, 0)
    trackFill.BackgroundColor3 = THEME.primary
    trackFill.BorderSizePixel = 0
    trackFill.Parent = track
    corner(trackFill, 2)
    gradient(trackFill, THEME.primary, THEME.primaryLight, 0)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 10, 0, 10)
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0, 0, 0.5, 0)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 5)
    stroke(knob, THEME.primary, 2)

    local function updateRadius(px)
        local maxW = track.AbsoluteSize.X
        if maxW == 0 then return end
        local clamped = math.clamp(px, 0, maxW)
        local pct = clamped / maxW
        CONFIG.STEAL_RANGE = math.floor(5 + (pct * 95))
        radVal.Text = tostring(CONFIG.STEAL_RANGE)
        trackFill.Size = UDim2.new(0, clamped, 1, 0)
        knob.Position = UDim2.new(0, clamped, 0.5, 0)
        saveConfig()
    end

    task.defer(function()
        task.wait(0.1)
        local maxW = track.AbsoluteSize.X
        if maxW > 0 then
            local pct = (CONFIG.STEAL_RANGE - 5) / 95
            local clamped = pct * maxW
            trackFill.Size = UDim2.new(0, clamped, 1, 0)
            knob.Position = UDim2.new(0, clamped, 0.5, 0)
        end
    end)

    local draggingRad = false
    track.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingRad = true
            updateRadius(input.Position.X - track.AbsolutePosition.X)
        end
    end)
    knob.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingRad = true
        end
    end)
    S.UserInputService.InputChanged:Connect(function(input)
        if draggingRad and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            updateRadius(input.Position.X - track.AbsolutePosition.X)
        end
    end)
    S.UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            draggingRad = false
        end
    end)

    -- Row 3: Min Generation
    local row3 = Instance.new("Frame")
    row3.Size = UDim2.new(1, -20, 0, 22)
    row3.Position = UDim2.new(0, 10, 0, 94)
    row3.BackgroundTransparency = 1
    row3.Parent = card

    local lbl3 = Instance.new("TextLabel")
    lbl3.Size = UDim2.new(0, 50, 1, 0)
    lbl3.BackgroundTransparency = 1
    lbl3.Text = "Min Gen"
    lbl3.TextColor3 = THEME.text
    lbl3.TextSize = 10
    lbl3.Font = Enum.Font.GothamSemibold
    lbl3.TextXAlignment = Enum.TextXAlignment.Left
    lbl3.Parent = row3

    local genBox = Instance.new("TextBox")
    genBox.Size = UDim2.new(0, 80, 1, 0)
    genBox.Position = UDim2.new(0, 55, 0, 0)
    genBox.BackgroundColor3 = Color3.fromRGB(10, 22, 40)
    genBox.BorderSizePixel = 0
    genBox.Text = formatNumber(CONFIG.MIN_GENERATION)
    genBox.TextColor3 = THEME.text
    genBox.TextSize = 10
    genBox.Font = Enum.Font.GothamBold
    genBox.TextXAlignment = Enum.TextXAlignment.Center
    genBox.PlaceholderText = "0"
    genBox.PlaceholderColor3 = THEME.textDim
    genBox.Parent = row3
    corner(genBox, 4)
    stroke(genBox, THEME.border, 1)

    local genLabel = Instance.new("TextLabel")
    genLabel.Size = UDim2.new(0, 18, 1, 0)
    genLabel.Position = UDim2.new(1, -18, 0, 0)
    genLabel.BackgroundTransparency = 1
    genLabel.Text = "/s"
    genLabel.TextColor3 = THEME.textDim
    genLabel.TextSize = 9
    genLabel.Font = Enum.Font.GothamSemibold
    genLabel.TextXAlignment = Enum.TextXAlignment.Left
    genLabel.Parent = row3

    genBox.FocusLost:Connect(function(enterPressed)
        if enterPressed then
            local parsed = parseUserInput(genBox.Text)
            CONFIG.MIN_GENERATION = parsed
            genBox.Text = formatNumber(parsed)
            invalidatePickCache()
            saveConfig()
        end
    end)

    -- Progress bar
    local bar = Instance.new("Frame")
    bar.Size = UDim2.new(1, -20, 0, 24)
    bar.Position = UDim2.new(0, 10, 0, 122)
    bar.BackgroundColor3 = Color3.fromRGB(6, 16, 30)
    bar.BackgroundTransparency = 0.2
    bar.BorderSizePixel = 0
    bar.Parent = card
    corner(bar, 6)
    stroke(bar, Color3.fromRGB(20, 55, 100), 1)

    local innerBar = Instance.new("Frame")
    innerBar.Size = UDim2.new(1, -4, 1, -4)
    innerBar.Position = UDim2.new(0, 2, 0, 2)
    innerBar.BackgroundColor3 = Color3.fromRGB(8, 20, 38)
    innerBar.BackgroundTransparency = 0.15
    innerBar.BorderSizePixel = 0
    innerBar.Parent = bar
    corner(innerBar, 4)
    innerBar.ClipsDescendants = true

    local fill = Instance.new("Frame")
    fill.Size = UDim2.new(0, 0, 1, 0)
    fill.BackgroundColor3 = THEME.primary
    fill.BorderSizePixel = 0
    fill.Parent = innerBar
    corner(fill, 4)
    gradient(fill, THEME.primary, THEME.primaryLight, 0)

    local statusLabel = Instance.new("TextLabel")
    statusLabel.Size = UDim2.new(1, 0, 1, 0)
    statusLabel.BackgroundTransparency = 1
    statusLabel.Text = ""
    statusLabel.TextColor3 = THEME.textBright
    statusLabel.TextSize = 9
    statusLabel.Font = Enum.Font.GothamBold
    statusLabel.TextXAlignment = Enum.TextXAlignment.Center
    statusLabel.ZIndex = 2
    statusLabel.Parent = innerBar

    -- Toggle Button
    local toggleBtn = Instance.new("TextButton")
    toggleBtn.Name = "ToggleBtn"
    toggleBtn.Size = UDim2.new(0, 38, 0, 38)
    toggleBtn.Position = UDim2.fromOffset(CONFIG.TOGGLE_X or (vp.X - 48), CONFIG.TOGGLE_Y or 60)
    toggleBtn.BackgroundColor3 = CONFIG.GUI_VISIBLE and THEME.primary or Color3.fromRGB(12, 32, 55)
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Text = CONFIG.GUI_VISIBLE and "◈" or "◇"
    toggleBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    toggleBtn.TextSize = 14
    toggleBtn.Font = Enum.Font.GothamBold
    toggleBtn.AutoButtonColor = false
    toggleBtn.ZIndex = 1000
    toggleBtn.Parent = screenGui
    corner(toggleBtn, 10)
    stroke(toggleBtn, THEME.primary, 1.5)

    local toggleDrag = { dragging = false, startPos = nil, startMouse = nil }

    toggleBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            toggleDrag.dragging = true
            toggleDrag.startMouse = input.Position
            toggleDrag.startPos = toggleBtn.Position
        end
    end)

    toggleBtn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if toggleDrag.dragging then
                local delta = (input.Position - toggleDrag.startMouse).Magnitude
                if delta < 5 then
                    CONFIG.GUI_VISIBLE = not CONFIG.GUI_VISIBLE
                    card.Visible = CONFIG.GUI_VISIBLE
                    toggleBtn.Text = CONFIG.GUI_VISIBLE and "◈" or "◇"
                    toggleBtn.BackgroundColor3 = CONFIG.GUI_VISIBLE and THEME.primary or Color3.fromRGB(12, 32, 55)
                    saveConfig()
                end
                toggleDrag.dragging = false
            end
        end
    end)

    S.UserInputService.InputChanged:Connect(function(input)
        if not toggleDrag.dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - toggleDrag.startMouse
            local btnSize = 38
            toggleBtn.Position = UDim2.fromOffset(
                math.clamp(toggleDrag.startPos.X.Offset + delta.X, 0, workspace.CurrentCamera.ViewportSize.X - btnSize),
                math.clamp(toggleDrag.startPos.Y.Offset + delta.Y, 0, workspace.CurrentCamera.ViewportSize.Y - btnSize)
            )
            CONFIG.TOGGLE_X = toggleBtn.Position.X.Offset
            CONFIG.TOGGLE_Y = toggleBtn.Position.Y.Offset
        end
    end)

    toggleBtn.MouseEnter:Connect(function()
        S.TweenService:Create(toggleBtn, TweenInfo.new(0.15), {
            Size = UDim2.new(0, 42, 0, 42)
        }):Play()
    end)

    toggleBtn.MouseLeave:Connect(function()
        S.TweenService:Create(toggleBtn, TweenInfo.new(0.15), {
            Size = UDim2.new(0, 38, 0, 38)
        }):Play()
    end)

    -- UI Updates
    local lastFillPct = 0

    S.RunService.RenderStepped:Connect(function(dt)
        local on = CONFIG.AUTO_STEAL_ENABLED
        local active = StealState.active
        local justFinished = StealState.lastResultTime > 0 and (tick() - StealState.lastResultTime) < 1.1
        local success = justFinished and string.find(StealState.lastResult, "Stole") ~= nil

        local targetPct
        if active then
            targetPct = StealState.holdProgress
        elseif justFinished then
            targetPct = 1
        else
            targetPct = 0
        end

        local smoothing = active and dt * 16 or dt * 10
        lastFillPct = lastFillPct + (targetPct - lastFillPct) * math.min(smoothing, 1)
        fill.Size = UDim2.new(math.clamp(lastFillPct, 0, 1), 0, 1, 0)

        local dotColor
        if active then
            dotColor = THEME.warning
        elseif justFinished then
            dotColor = success and THEME.success or THEME.error
        elseif on then
            dotColor = THEME.success
        else
            dotColor = THEME.textDim
        end
        statusDot.BackgroundColor3 = dotColor

        if active then
            local pct = math.floor(lastFillPct * 100)
            local genText = formatNumber(StealState.generation)
            statusLabel.Text = string.upper(StealState.label) .. "  " .. pct .. "%  " .. genText .. "/s"
            statusLabel.TextColor3 = THEME.textBright
            fill.BackgroundColor3 = THEME.primary
        elseif justFinished then
            statusLabel.Text = string.upper(StealState.lastResult)
            statusLabel.TextColor3 = success and THEME.success or THEME.error
            fill.BackgroundColor3 = success and THEME.success or THEME.error
        else
            statusLabel.Text = on and "READY  " .. formatNumber(CONFIG.MIN_GENERATION) .. "/s" or ""
            statusLabel.TextColor3 = THEME.textDim
            fill.BackgroundColor3 = THEME.primary
        end
    end)
end

-- ============================================================
-- BOOT
-- ============================================================

onPlotDataChanged.Event:Connect(function()
    scanAllPlots()
end)

scanConnection = S.RunService.Heartbeat:Connect(function()
    scanAllPlots()
end)

createUI()
scanAllPlots()
if CONFIG.AUTO_STEAL_ENABLED then
    startAutoSteal()
end
