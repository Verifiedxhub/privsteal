local CONFIG = {
    AUTO_STEAL_ENABLED = true,
    HOLD_MIN = 1.3,
    STEAL_RANGE = 10,
    PRIME_RANGE = 80,
    MIN_GENERATION = 0,
    GUI_VISIBLE = true,
    PROGRESS_BAR_VISIBLE = true,
    PROGRESS_BAR_X = 0,
    PROGRESS_BAR_Y = 0,
}

-- Internal timers using Heartbeat
local cooldownTimer = 0
local entryDelayTimer = 0

-- Save/Load functions using file-based JSON
local function parseGenerationInput(input)
    if not input or input == "" then return 0 end
    input = input:lower():gsub(",", ""):gsub("%s+", "")
    
    local num = tonumber(input:match("[%d%.]+")) or 0
    if input:find("b$") then
        return num * 1000000000
    elseif input:find("m$") then
        return num * 1000000
    elseif input:find("k$") then
        return num * 1000
    end
    return num
end

local function formatGeneration(num)
    if num >= 1000000000 then
        return string.format("%.1fb", num / 1000000000)
    elseif num >= 1000000 then
        return string.format("%.1fm", num / 1000000)
    elseif num >= 1000 then
        return string.format("%.1fk", num / 1000)
    end
    return tostring(num)
end

local function saveConfig()
    local data = {
        stealRange = CONFIG.STEAL_RANGE,
        minGeneration = CONFIG.MIN_GENERATION,
        guiX = CONFIG.GUI_X,
        guiY = CONFIG.GUI_Y,
        toggleX = CONFIG.TOGGLE_X,
        toggleY = CONFIG.TOGGLE_Y,
        progressBarX = CONFIG.PROGRESS_BAR_X,
        progressBarY = CONFIG.PROGRESS_BAR_Y,
        progressBarVisible = CONFIG.PROGRESS_BAR_VISIBLE,
    }
    local success = pcall(function()
        writefile("PhantomHub_Config.json", game:GetService("HttpService"):JSONEncode(data))
    end)
end

local function loadConfig()
    local success, content = pcall(function()
        return readfile("PhantomHub_Config.json")
    end)
    if not success or not content then return end
    
    local success2, data = pcall(function()
        return game:GetService("HttpService"):JSONDecode(content)
    end)
    if success2 and data then
        if data.stealRange then CONFIG.STEAL_RANGE = data.stealRange end
        if data.minGeneration then CONFIG.MIN_GENERATION = data.minGeneration end
        if data.guiX then CONFIG.GUI_X = data.guiX end
        if data.guiY then CONFIG.GUI_Y = data.guiY end
        if data.toggleX then CONFIG.TOGGLE_X = data.toggleX end
        if data.toggleY then CONFIG.TOGGLE_Y = data.toggleY end
        if data.progressBarX then CONFIG.PROGRESS_BAR_X = data.progressBarX end
        if data.progressBarY then CONFIG.PROGRESS_BAR_Y = data.progressBarY end
        if data.progressBarVisible ~= nil then CONFIG.PROGRESS_BAR_VISIBLE = data.progressBarVisible end
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

local plotAnimalSync = {
    caches = {},
    connections = {},
}

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
    lastResult = "",
    lastResultTime = 0,
    totalSteals = 0,
    failedSteals = 0,
    currentUid = nil,
    holdProgress = 0,
}

local pickCache = {
    target = nil,
    position = nil,
    valid = false,
}

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

local function parseGenText(text)
    if not text or text == "" then return 0 end
    local cleanText = text:gsub("[^%d.]", "")
    local num = tonumber(cleanText)
    if not num or num == 0 then return 0 end
    if text:find("[Mm]") then
        return num * 1000000
    elseif text:find("[Bb]") then
        return num * 1000000000
    elseif text:find("[Kk]") then
        return num * 1000
    end
    return num
end

local overheadCache = {}
local overheadCacheTime = 0
local OVERHEAD_CACHE_TTL = 0.2

local function refreshOverheadCache()
    local now = tick()
    if now - overheadCacheTime < OVERHEAD_CACHE_TTL then
        return overheadCache
    end
    
    overheadCache = {}
    overheadCacheTime = now
    
    if not debris then return overheadCache end
    
    for _, part in ipairs(debris:GetChildren()) do
        if part.Name == "FastOverheadTemplate" and part:IsA("BasePart") then
            local overhead = part:FindFirstChild("AnimalOverhead")
            if not overhead then continue end
            
            local displayName = ""
            local displayNameLabel = overhead:FindFirstChild("DisplayName")
            if displayNameLabel then
                displayName = stripRichText(displayNameLabel.Text or "")
            end
            
            local genText = ""
            local genValue = 0
            
            local genLabel = overhead:FindFirstChild("Generation")
            if genLabel then
                genText = stripRichText(genLabel.Text or "")
                genValue = parseGenText(genText)
            end
            
            if genValue == 0 then
                local genStroke = overhead:FindFirstChild("Generation")
                if genStroke then
                    for _, child in ipairs(genStroke:GetChildren()) do
                        if child:IsA("TextLabel") then
                            genText = stripRichText(child.Text or "")
                            genValue = parseGenText(genText)
                            break
                        end
                    end
                end
            end
            
            if genValue == 0 then
                for _, child in ipairs(overhead:GetChildren()) do
                    if child:IsA("TextLabel") then
                        local text = stripRichText(child.Text or "")
                        if text:find("[%d]+[kKmMbB]") or text:match("%d+") then
                            genText = text
                            genValue = parseGenText(text)
                            break
                        end
                    end
                end
            end
            
            local mutation = ""
            local mutObj = overhead:FindFirstChild("Mutation")
            if mutObj then
                for _, child in ipairs(mutObj:GetChildren()) do
                    if child:IsA("TextLabel") then
                        mutation = stripRichText(child.Text or "")
                        break
                    end
                end
            end
            
            local pos = part.Position
            table.insert(overheadCache, {
                position = pos,
                displayName = displayName,
                generation = genValue,
                generationText = genText,
                mutation = mutation,
                part = part,
                overhead = overhead,
            })
        end
    end
    
    return overheadCache
end

local function getAnimalGeneration(animalData)
    if not animalData or not animalData.plot or not animalData.slot then
        return 0
    end
    
    local animalName = animalData.name or ""
    if animalName == "" then return 0 end
    
    local pos = getAnimalPosition(animalData)
    if not pos then return 0 end
    
    local cache = refreshOverheadCache()
    if #cache == 0 then return 0 end
    
    local bestMatch = nil
    local bestDist = math.huge
    local animalNameLower = string.lower(animalName)
    
    for _, entry in ipairs(cache) do
        local entryName = string.lower(entry.displayName or "")
        
        local nameMatch = false
        if entryName ~= "" and animalNameLower ~= "" then
            if entryName == animalNameLower then
                nameMatch = true
            elseif entryName:find(animalNameLower, 1, true) or animalNameLower:find(entryName, 1, true) then
                nameMatch = true
            end
        end
        
        local dist = (entry.position - pos).Magnitude
        
        if nameMatch and dist < 50 and dist < bestDist then
            bestMatch = entry
            bestDist = dist
        end
    end
    
    if not bestMatch then
        for _, entry in ipairs(cache) do
            local dist = (entry.position - pos).Magnitude
            if dist < 15 and dist < bestDist then
                bestMatch = entry
                bestDist = dist
            end
        end
    end
    
    if bestMatch then
        return bestMatch.generation
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
    StealState.currentUid = animalData.uid
    StealState.holdProgress = 0

    task.spawn(function()
        for _, fn in ipairs(data.holdCallbacks) do task.spawn(fn) end

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

        -- Entry delay using Heartbeat (just one frame)
        entryDelayTimer = 0
        while entryDelayTimer < 0.016 do
            if myGeneration ~= StealGeneration then
                data.ready = true
                return
            end
            if not prompt.Parent then
                data.ready = true
                return
            end
            task.wait()
        end
        
        if myGeneration == StealGeneration and distToAnimal(animalData) <= CONFIG.STEAL_RANGE then
            for _, fn in ipairs(data.triggerCallbacks) do task.spawn(fn) end
            StealState.active = false
            StealState.totalSteals = StealState.totalSteals + 1
            StealState.lastResult = "Stole " .. label
            StealState.lastResultTime = tick()
            StealState.currentUid = nil
            StealState.holdProgress = 0
            cooldownTimer = 0
            data.ready = true
            return
        end

        local fired = false
        while true do
            if myGeneration ~= StealGeneration then break end
            if not prompt.Parent then break end
            
            if distToAnimal(animalData) <= CONFIG.STEAL_RANGE then
                entryDelayTimer = 0
                while entryDelayTimer < 0.016 do
                    if myGeneration ~= StealGeneration then
                        data.ready = true
                        return
                    end
                    if not prompt.Parent then
                        data.ready = true
                        return
                    end
                    if distToAnimal(animalData) > CONFIG.STEAL_RANGE then
                        data.ready = true
                        return
                    end
                    task.wait()
                end
                
                if myGeneration == StealGeneration then
                    for _, fn in ipairs(data.triggerCallbacks) do task.spawn(fn) end
                    fired = true
                end
                break
            end
            task.wait()
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
            cooldownTimer = 0
        end

        data.ready = true
    end)
    return true
end

local function attemptSteal(target)
    if cooldownTimer < 0.016 then
        return false
    end
    
    if not target or not target.prompt or not target.prompt.Parent then
        return false
    end

    if not InternalStealCache[target.prompt] then
        buildStealCallbacks(target.prompt)
        if not InternalStealCache[target.prompt] then return false end
    end

    StealGeneration = StealGeneration + 1
    return executeStealAsync(target.prompt, target, StealGeneration)
end

local function scanAllPlots()
    local newCache = {}

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
                local displayName = animalInfo.DisplayName or animalName

                local entry = {
                    name = displayName,
                    plot = plot.Name,
                    slot = tostring(slot),
                    uid = uid,
                    data = animalData,
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

    allAnimalsCache = newCache
    invalidatePickCache()
    return #allAnimalsCache
end

local function startAutoSteal()
    if stealConnection then return end
    stealConnection = S.RunService.Heartbeat:Connect(function(deltaTime)
        if not CONFIG.AUTO_STEAL_ENABLED then return end
        
        cooldownTimer = math.min(cooldownTimer + deltaTime, 1)
        entryDelayTimer = math.min(entryDelayTimer + deltaTime, 1)
        
        if cooldownTimer < 0.016 then
            return
        end

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
-- PHANTOM HUB THEME - Dark Gray
-- ============================================================

local THEME = {
    bg = Color3.fromRGB(18, 18, 22),
    bg2 = Color3.fromRGB(26, 26, 32),
    panel = Color3.fromRGB(32, 32, 40),
    accent = Color3.fromRGB(170, 170, 190),
    accent2 = Color3.fromRGB(140, 140, 165),
    glow = Color3.fromRGB(100, 100, 130),
    good = Color3.fromRGB(160, 190, 220),
    bad = Color3.fromRGB(200, 140, 150),
    warn = Color3.fromRGB(220, 190, 140),
    text = Color3.fromRGB(235, 235, 245),
    dim = Color3.fromRGB(150, 150, 170),
    border = Color3.fromRGB(50, 50, 65),
}

local function corner(p, r)
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, r or 8)
    c.Parent = p
end

local function stroke(p, color, t)
    local s = Instance.new("UIStroke")
    s.Color = color or THEME.border
    s.Thickness = t or 1
    s.Transparency = 0.3
    s.Parent = p
    return s
end

-- Improved Toggle Button
local function createToggleButton(screenGui, card, progressBar)
    local vp = workspace.CurrentCamera.ViewportSize
    local btnSize = 44
    
    local toggleBtn = Instance.new("ImageButton")
    toggleBtn.Name = "ToggleBtn"
    toggleBtn.Size = UDim2.new(0, btnSize, 0, btnSize)
    toggleBtn.Position = UDim2.fromOffset(CONFIG.TOGGLE_X or (vp.X - btnSize - 15), CONFIG.TOGGLE_Y or 100)
    toggleBtn.BackgroundColor3 = THEME.panel
    toggleBtn.BorderSizePixel = 0
    toggleBtn.Image = "rbxassetid://7072699412"
    toggleBtn.ImageColor3 = THEME.accent
    toggleBtn.ImageTransparency = 0.2
    toggleBtn.ZIndex = 1000
    toggleBtn.Parent = screenGui
    corner(toggleBtn, 12)
    stroke(toggleBtn, THEME.border, 1.5)

    -- Glow ring
    local glowRing = Instance.new("Frame")
    glowRing.Size = UDim2.new(1, 10, 1, 10)
    glowRing.Position = UDim2.new(0, -5, 0, -5)
    glowRing.BackgroundColor3 = THEME.glow
    glowRing.BackgroundTransparency = 0.9
    glowRing.BorderSizePixel = 0
    glowRing.ZIndex = toggleBtn.ZIndex - 1
    glowRing.Parent = toggleBtn
    corner(glowRing, 14)
    
    -- Icon label (fallback if image doesn't load)
    local iconLabel = Instance.new("TextLabel")
    iconLabel.Size = UDim2.new(1, 0, 1, 0)
    iconLabel.BackgroundTransparency = 1
    iconLabel.Text = "◈"
    iconLabel.TextColor3 = THEME.accent
    iconLabel.TextSize = 22
    iconLabel.Font = Enum.Font.GothamBold
    iconLabel.ZIndex = 2
    iconLabel.Parent = toggleBtn

    local dragData = { dragging = false, startPos = nil, startMouse = nil }

    toggleBtn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragData.dragging = true
            dragData.startMouse = input.Position
            dragData.startPos = toggleBtn.Position
            S.TweenService:Create(toggleBtn, TweenInfo.new(0.15), { 
                ImageColor3 = THEME.text,
                BackgroundColor3 = THEME.bg2 
            }):Play()
            S.TweenService:Create(glowRing, TweenInfo.new(0.15), { BackgroundTransparency = 0.7 }):Play()
        end
    end)

    toggleBtn.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if dragData.dragging then
                local delta = (input.Position - dragData.startMouse).Magnitude
                if delta < 8 then
                    -- Click - toggle GUI
                    CONFIG.GUI_VISIBLE = not CONFIG.GUI_VISIBLE
                    card.Visible = CONFIG.GUI_VISIBLE
                    iconLabel.Text = CONFIG.GUI_VISIBLE and "◈" or "◆"
                    iconLabel.TextColor3 = CONFIG.GUI_VISIBLE and THEME.accent or THEME.dim
                    toggleBtn.ImageColor3 = CONFIG.GUI_VISIBLE and THEME.accent or THEME.dim
                    saveConfig()
                end
                dragData.dragging = false
                S.TweenService:Create(toggleBtn, TweenInfo.new(0.15), { 
                    ImageColor3 = CONFIG.GUI_VISIBLE and THEME.accent or THEME.dim,
                    BackgroundColor3 = THEME.panel 
                }):Play()
                S.TweenService:Create(glowRing, TweenInfo.new(0.15), { BackgroundTransparency = 0.9 }):Play()
            end
        end
    end)

    S.UserInputService.InputChanged:Connect(function(input)
        if not dragData.dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragData.startMouse
            toggleBtn.Position = UDim2.fromOffset(
                math.clamp(dragData.startPos.X.Offset + delta.X, 0, workspace.CurrentCamera.ViewportSize.X - btnSize),
                math.clamp(dragData.startPos.Y.Offset + delta.Y, 0, workspace.CurrentCamera.ViewportSize.Y - btnSize)
            )
            CONFIG.TOGGLE_X = toggleBtn.Position.X.Offset
            CONFIG.TOGGLE_Y = toggleBtn.Position.Y.Offset
        end
    end)

    toggleBtn.MouseEnter:Connect(function()
        S.TweenService:Create(toggleBtn, TweenInfo.new(0.2), { 
            BackgroundColor3 = THEME.bg2,
            ImageColor3 = THEME.text 
        }):Play()
        S.TweenService:Create(glowRing, TweenInfo.new(0.2), { BackgroundTransparency = 0.7 }):Play()
        iconLabel.TextColor3 = THEME.text
    end)

    toggleBtn.MouseLeave:Connect(function()
        local vis = CONFIG.GUI_VISIBLE
        S.TweenService:Create(toggleBtn, TweenInfo.new(0.2), { 
            BackgroundColor3 = THEME.panel,
            ImageColor3 = vis and THEME.accent or THEME.dim
        }):Play()
        S.TweenService:Create(glowRing, TweenInfo.new(0.2), { BackgroundTransparency = 0.9 }):Play()
        iconLabel.TextColor3 = vis and THEME.accent or THEME.dim
    end)

    -- Pulse animation
    task.spawn(function()
        while toggleBtn.Parent do
            for i = 0, 1, 0.03 do
                if not toggleBtn.Parent then break end
                local alpha = 0.9 + 0.1 * math.sin(i * math.pi * 2)
                glowRing.BackgroundTransparency = alpha
                task.wait(0.03)
            end
        end
    end)

    return toggleBtn
end

local function createUI()
    local existing = S.LocalPlayer.PlayerGui:FindFirstChild("PhantomHub")
    if existing then existing:Destroy() end

    local screenGui = Instance.new("ScreenGui")
    screenGui.Name = "PhantomHub"
    screenGui.ResetOnSpawn = false
    screenGui.IgnoreGuiInset = true
    screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
    screenGui.Parent = S.LocalPlayer:WaitForChild("PlayerGui")

    local vp = workspace.CurrentCamera.ViewportSize
    
    -- Main GUI
    local card = Instance.new("Frame")
    card.Name = "Card"
    card.Size = UDim2.new(0, 240, 0, 165)
    card.Position = UDim2.fromOffset(CONFIG.GUI_X or (vp.X / 2 - 120), CONFIG.GUI_Y or 100)
    card.BackgroundColor3 = THEME.bg
    card.BorderSizePixel = 0
    card.Parent = screenGui
    card.Visible = CONFIG.GUI_VISIBLE
    corner(card, 12)
    stroke(card, THEME.border, 1.5)

    -- Header
    local header = Instance.new("Frame")
    header.Name = "Header"
    header.Size = UDim2.new(1, 0, 0, 38)
    header.BackgroundColor3 = THEME.panel
    header.BorderSizePixel = 0
    header.Parent = card
    corner(header, 12)
    stroke(header, THEME.border, 1)
    
    -- Header bottom mask
    local headerMask = Instance.new("Frame")
    headerMask.BackgroundColor3 = header.BackgroundColor3
    headerMask.BorderSizePixel = 0
    headerMask.Size = UDim2.new(1, 0, 0, 12)
    headerMask.Position = UDim2.new(0, 0, 1, -12)
    headerMask.ZIndex = header.ZIndex
    headerMask.Parent = header

    -- Drag functionality
    local dragCard = { dragging = false, startPos = nil, startMouse = nil }
    
    header.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragCard.dragging = true
            dragCard.startMouse = input.Position
            dragCard.startPos = card.Position
        end
    end)

    header.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragCard.dragging = false
        end
    end)

    S.UserInputService.InputChanged:Connect(function(input)
        if not dragCard.dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragCard.startMouse
            local newX = math.clamp(dragCard.startPos.X.Offset + delta.X, 0, workspace.CurrentCamera.ViewportSize.X - 240)
            local newY = math.clamp(dragCard.startPos.Y.Offset + delta.Y, 0, workspace.CurrentCamera.ViewportSize.Y - 165)
            card.Position = UDim2.fromOffset(newX, newY)
            CONFIG.GUI_X = newX
            CONFIG.GUI_Y = newY
        end
    end)

    -- Title
    local title = Instance.new("TextLabel")
    title.Size = UDim2.new(1, 0, 1, 0)
    title.BackgroundTransparency = 1
    title.Text = "PHANTOM HUB"
    title.TextColor3 = THEME.accent
    title.TextSize = 16
    title.Font = Enum.Font.GothamBold
    title.TextXAlignment = Enum.TextXAlignment.Center
    title.ZIndex = 2
    title.Parent = header

    -- Header accent line
    local accentLine = Instance.new("Frame")
    accentLine.Size = UDim2.new(0.25, 0, 0, 2)
    accentLine.Position = UDim2.new(0.375, 0, 1, -2)
    accentLine.BackgroundColor3 = THEME.accent
    accentLine.BackgroundTransparency = 0.4
    accentLine.BorderSizePixel = 0
    accentLine.ZIndex = 2
    accentLine.Parent = header
    corner(accentLine, 1)

    -- Status dot
    local statusDot = Instance.new("Frame")
    statusDot.Size = UDim2.new(0, 7, 0, 7)
    statusDot.AnchorPoint = Vector2.new(0, 0.5)
    statusDot.Position = UDim2.new(0, 12, 0.5, 0)
    statusDot.BackgroundColor3 = THEME.dim
    statusDot.BorderSizePixel = 0
    statusDot.ZIndex = 2
    statusDot.Parent = header
    corner(statusDot, 3.5)
    stroke(statusDot, THEME.border, 0.5)

    -- Divider
    local divider = Instance.new("Frame")
    divider.Size = UDim2.new(1, -20, 0, 1)
    divider.Position = UDim2.new(0, 10, 0, 38)
    divider.BackgroundColor3 = THEME.border
    divider.BackgroundTransparency = 0.4
    divider.BorderSizePixel = 0
    divider.Parent = card

    -- Row 1: Auto Steal
    local row1 = Instance.new("Frame")
    row1.Size = UDim2.new(1, -20, 0, 28)
    row1.Position = UDim2.new(0, 10, 0, 48)
    row1.BackgroundTransparency = 1
    row1.Parent = card

    local lbl1 = Instance.new("TextLabel")
    lbl1.Size = UDim2.new(0, 100, 1, 0)
    lbl1.BackgroundTransparency = 1
    lbl1.Text = "AUTO STEAL"
    lbl1.TextColor3 = THEME.text
    lbl1.TextSize = 11
    lbl1.Font = Enum.Font.GothamBold
    lbl1.TextXAlignment = Enum.TextXAlignment.Left
    lbl1.Parent = row1

    local tglBtn = Instance.new("TextButton")
    tglBtn.Size = UDim2.new(0, 40, 0, 20)
    tglBtn.Position = UDim2.new(1, -40, 0.5, -10)
    tglBtn.AutoButtonColor = false
    tglBtn.Text = ""
    tglBtn.BackgroundColor3 = CONFIG.AUTO_STEAL_ENABLED and THEME.accent or THEME.panel
    tglBtn.Parent = row1
    corner(tglBtn, 10)
    stroke(tglBtn, THEME.border, 1)

    local tglKnob = Instance.new("Frame")
    tglKnob.Size = UDim2.new(0, 14, 0, 14)
    tglKnob.Position = CONFIG.AUTO_STEAL_ENABLED and UDim2.new(1, -18, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    tglKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    tglKnob.BorderSizePixel = 0
    tglKnob.Parent = tglBtn
    corner(tglKnob, 7)

    local function updateToggleVisual()
        local on = CONFIG.AUTO_STEAL_ENABLED
        S.TweenService:Create(tglKnob, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
            Position = on and UDim2.new(1, -18, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        }):Play()
        S.TweenService:Create(tglBtn, TweenInfo.new(0.2), {
            BackgroundColor3 = on and THEME.accent or THEME.panel
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
    row2.Size = UDim2.new(1, -20, 0, 28)
    row2.Position = UDim2.new(0, 10, 0, 80)
    row2.BackgroundTransparency = 1
    row2.Parent = card

    local lbl2 = Instance.new("TextLabel")
    lbl2.Size = UDim2.new(0, 60, 1, 0)
    lbl2.BackgroundTransparency = 1
    lbl2.Text = "RADIUS"
    lbl2.TextColor3 = THEME.text
    lbl2.TextSize = 11
    lbl2.Font = Enum.Font.GothamBold
    lbl2.TextXAlignment = Enum.TextXAlignment.Left
    lbl2.Parent = row2

    local radVal = Instance.new("TextLabel")
    radVal.Size = UDim2.new(0, 30, 1, 0)
    radVal.Position = UDim2.new(1, -30, 0, 0)
    radVal.BackgroundTransparency = 1
    radVal.Text = tostring(CONFIG.STEAL_RANGE)
    radVal.TextColor3 = THEME.accent2
    radVal.TextSize = 11
    radVal.Font = Enum.Font.GothamBold
    radVal.TextXAlignment = Enum.TextXAlignment.Right
    radVal.Parent = row2

    local track = Instance.new("Frame")
    track.Size = UDim2.new(1, -100, 0, 4)
    track.Position = UDim2.new(0, 66, 0.5, -2)
    track.BackgroundColor3 = THEME.bg2
    track.BorderSizePixel = 0
    track.Parent = row2
    corner(track, 100)

    local trackFill = Instance.new("Frame")
    trackFill.Size = UDim2.new(0, 0, 1, 0)
    trackFill.BackgroundColor3 = THEME.accent
    trackFill.BorderSizePixel = 0
    trackFill.Parent = track
    corner(trackFill, 100)

    local knob = Instance.new("Frame")
    knob.Size = UDim2.new(0, 12, 0, 12)
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(0, 0, 0.5, 0)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    knob.Parent = track
    corner(knob, 100)
    stroke(knob, THEME.accent, 1.5)

    local function updateRadius(px)
        local maxW = track.AbsoluteSize.X
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
        local pct = (CONFIG.STEAL_RANGE - 5) / 95
        local clamped = pct * maxW
        trackFill.Size = UDim2.new(0, clamped, 1, 0)
        knob.Position = UDim2.new(0, clamped, 0.5, 0)
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

    -- Row 3: Show Progress Bar Toggle
    local row3 = Instance.new("Frame")
    row3.Size = UDim2.new(1, -20, 0, 28)
    row3.Position = UDim2.new(0, 10, 0, 112)
    row3.BackgroundTransparency = 1
    row3.Parent = card

    local lbl3 = Instance.new("TextLabel")
    lbl3.Size = UDim2.new(0, 140, 1, 0)
    lbl3.BackgroundTransparency = 1
    lbl3.Text = "SHOW PROGRESS BAR"
    lbl3.TextColor3 = THEME.text
    lbl3.TextSize = 11
    lbl3.Font = Enum.Font.GothamBold
    lbl3.TextXAlignment = Enum.TextXAlignment.Left
    lbl3.Parent = row3

    local pbTglBtn = Instance.new("TextButton")
    pbTglBtn.Size = UDim2.new(0, 40, 0, 20)
    pbTglBtn.Position = UDim2.new(1, -40, 0.5, -10)
    pbTglBtn.AutoButtonColor = false
    pbTglBtn.Text = ""
    pbTglBtn.BackgroundColor3 = CONFIG.PROGRESS_BAR_VISIBLE and THEME.accent or THEME.panel
    pbTglBtn.Parent = row3
    corner(pbTglBtn, 10)
    stroke(pbTglBtn, THEME.border, 1)

    local pbTglKnob = Instance.new("Frame")
    pbTglKnob.Size = UDim2.new(0, 14, 0, 14)
    pbTglKnob.Position = CONFIG.PROGRESS_BAR_VISIBLE and UDim2.new(1, -18, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
    pbTglKnob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    pbTglKnob.BorderSizePixel = 0
    pbTglKnob.Parent = pbTglBtn
    corner(pbTglKnob, 7)

    local function updateProgressToggle()
        local on = CONFIG.PROGRESS_BAR_VISIBLE
        S.TweenService:Create(pbTglKnob, TweenInfo.new(0.2, Enum.EasingStyle.Quad), {
            Position = on and UDim2.new(1, -18, 0.5, -7) or UDim2.new(0, 3, 0.5, -7)
        }):Play()
        S.TweenService:Create(pbTglBtn, TweenInfo.new(0.2), {
            BackgroundColor3 = on and THEME.accent or THEME.panel
        }):Play()
        -- Show/hide the progress bar
        if progressBar then
            progressBar.Visible = on
        end
    end

    pbTglBtn.MouseButton1Click:Connect(function()
        CONFIG.PROGRESS_BAR_VISIBLE = not CONFIG.PROGRESS_BAR_VISIBLE
        updateProgressToggle()
        saveConfig()
    end)

    -- Footer
    local footer = Instance.new("Frame")
    footer.Size = UDim2.new(1, 0, 0, 2)
    footer.Position = UDim2.new(0, 0, 1, -2)
    footer.BackgroundColor3 = THEME.accent
    footer.BackgroundTransparency = 0.5
    footer.BorderSizePixel = 0
    footer.Parent = card
    corner(footer, 1)

    -- ============================================================
    -- PROGRESS BAR
    -- ============================================================
    local progressBar = Instance.new("Frame")
    progressBar.Name = "ProgressBar"
    progressBar.Size = UDim2.new(0, 220, 0, 28)
    progressBar.Visible = CONFIG.PROGRESS_BAR_VISIBLE
    
    local defaultX = (vp.X / 2) - 110
    local defaultY = vp.Y - 70
    progressBar.Position = UDim2.fromOffset(
        CONFIG.PROGRESS_BAR_X ~= 0 and CONFIG.PROGRESS_BAR_X or defaultX,
        CONFIG.PROGRESS_BAR_Y ~= 0 and CONFIG.PROGRESS_BAR_Y or defaultY
    )
    progressBar.BackgroundColor3 = THEME.bg
    progressBar.BackgroundTransparency = 0.1
    progressBar.BorderSizePixel = 0
    progressBar.Parent = screenGui
    progressBar.ZIndex = 999
    corner(progressBar, 10)
    stroke(progressBar, THEME.border, 1)
    
    -- Make progress bar draggable
    local dragPb = { dragging = false, startPos = nil, startMouse = nil }
    
    progressBar.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragPb.dragging = true
            dragPb.startMouse = input.Position
            dragPb.startPos = progressBar.Position
            S.TweenService:Create(progressBar, TweenInfo.new(0.15), { BackgroundTransparency = 0.05 }):Play()
        end
    end)
    
    progressBar.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragPb.dragging = false
            S.TweenService:Create(progressBar, TweenInfo.new(0.15), { BackgroundTransparency = 0.1 }):Play()
        end
    end)
    
    S.UserInputService.InputChanged:Connect(function(input)
        if not dragPb.dragging then return end
        if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
            local delta = input.Position - dragPb.startMouse
            local newX = math.clamp(dragPb.startPos.X.Offset + delta.X, 0, workspace.CurrentCamera.ViewportSize.X - 220)
            local newY = math.clamp(dragPb.startPos.Y.Offset + delta.Y, 30, workspace.CurrentCamera.ViewportSize.Y - 35)
            progressBar.Position = UDim2.fromOffset(newX, newY)
            CONFIG.PROGRESS_BAR_X = newX
            CONFIG.PROGRESS_BAR_Y = newY
        end
    end)
    
    -- Inner fill
    local pbInner = Instance.new("Frame")
    pbInner.Size = UDim2.new(1, -8, 1, -6)
    pbInner.Position = UDim2.new(0, 4, 0, 3)
    pbInner.BackgroundColor3 = THEME.bg2
    pbInner.BackgroundTransparency = 0.1
    pbInner.BorderSizePixel = 0
    pbInner.Parent = progressBar
    corner(pbInner, 8)
    pbInner.ClipsDescendants = true
    
    local pbFill = Instance.new("Frame")
    pbFill.Size = UDim2.new(0, 0, 1, 0)
    pbFill.BackgroundColor3 = THEME.accent
    pbFill.BorderSizePixel = 0
    pbFill.Parent = pbInner
    corner(pbFill, 8)
    
    local pbFillGrad = Instance.new("UIGradient")
    pbFillGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, THEME.accent),
        ColorSequenceKeypoint.new(1, THEME.accent2),
    })
    pbFillGrad.Parent = pbFill
    
    local pbSheen = Instance.new("Frame")
    pbSheen.Size = UDim2.new(0, 30, 1, 0)
    pbSheen.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    pbSheen.BackgroundTransparency = 0.85
    pbSheen.BorderSizePixel = 0
    pbSheen.ZIndex = 2
    pbSheen.Parent = pbFill
    corner(pbSheen, 8)
    local pbSheenGrad = Instance.new("UIGradient")
    pbSheenGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 1),
        NumberSequenceKeypoint.new(0.5, 0.4),
        NumberSequenceKeypoint.new(1, 1),
    })
    pbSheenGrad.Parent = pbSheen
    
    local pbDot = Instance.new("Frame")
    pbDot.Size = UDim2.new(0, 5, 0, 5)
    pbDot.AnchorPoint = Vector2.new(0, 0.5)
    pbDot.Position = UDim2.new(0, 6, 0.5, 0)
    pbDot.BackgroundColor3 = THEME.dim
    pbDot.BorderSizePixel = 0
    pbDot.ZIndex = 3
    pbDot.Parent = pbInner
    corner(pbDot, 2.5)
    
    local pbLabel = Instance.new("TextLabel")
    pbLabel.Size = UDim2.new(1, -25, 1, 0)
    pbLabel.Position = UDim2.new(0, 15, 0, 0)
    pbLabel.BackgroundTransparency = 1
    pbLabel.Text = ""
    pbLabel.TextColor3 = THEME.text
    pbLabel.TextSize = 10
    pbLabel.Font = Enum.Font.GothamBold
    pbLabel.TextXAlignment = Enum.TextXAlignment.Center
    pbLabel.ZIndex = 3
    pbLabel.Parent = pbInner
    
    -- Create toggle button
    createToggleButton(screenGui, card, progressBar)
    
    -- Animation
    local pbLastFillPct = 0
    local pbSheenT = 0
    
    S.RunService.RenderStepped:Connect(function(dt)
        local on = CONFIG.AUTO_STEAL_ENABLED
        local active = StealState.active
        local justFinished = StealState.lastResultTime > 0 and (tick() - StealState.lastResultTime) < 1.1
        local success = justFinished and string.find(StealState.lastResult, "Stole") ~= nil
        
        -- Update status dot
        local dotTarget
        if active then
            dotTarget = THEME.warn
        elseif justFinished then
            dotTarget = success and THEME.good or THEME.bad
        elseif on then
            dotTarget = THEME.accent
        else
            dotTarget = THEME.dim
        end
        statusDot.BackgroundColor3 = statusDot.BackgroundColor3:Lerp(dotTarget, math.min(dt * 10, 1))
        
        -- Update progress bar dot
        local pbDotTarget
        if active then
            pbDotTarget = THEME.warn
        elseif justFinished then
            pbDotTarget = success and THEME.good or THEME.bad
        elseif on then
            pbDotTarget = THEME.accent2
        else
            pbDotTarget = THEME.dim
        end
        pbDot.BackgroundColor3 = pbDot.BackgroundColor3:Lerp(pbDotTarget, math.min(dt * 9, 1))
        
        -- Update fill
        local targetPct, targetColor
        if active then
            targetPct = StealState.holdProgress
            targetColor = THEME.warn
        elseif justFinished then
            targetPct = 1
            targetColor = success and THEME.good or THEME.bad
        else
            targetPct = 0
            targetColor = THEME.accent
        end
        
        local smoothing = active and dt * 16 or dt * 10
        pbLastFillPct = pbLastFillPct + (targetPct - pbLastFillPct) * math.min(smoothing, 1)
        pbFill.Size = UDim2.new(math.clamp(pbLastFillPct, 0, 1), 0, 1, 0)
        pbFill.BackgroundColor3 = pbFill.BackgroundColor3:Lerp(targetColor, math.min(dt * 9, 1))
        
        -- Sheen animation
        if active then
            pbSheenT = (pbSheenT + dt * 0.6) % 1.4
            local barWidth = pbInner.AbsoluteSize.X
            pbSheen.Position = UDim2.new(0, -30 + (pbSheenT * (barWidth + 60)), 0, 0)
        end
        
        -- Update label
        if active then
            pbLabel.Text = "◈ " .. string.upper(StealState.label) .. " ◈"
            pbLabel.TextColor3 = THEME.text
            pbLabel.TextTransparency = 0
        elseif justFinished then
            pbLabel.Text = "◆ " .. string.upper(StealState.lastResult) .. " ◆"
            pbLabel.TextColor3 = success and THEME.good or THEME.bad
            pbLabel.TextTransparency = 0
        else
            pbLabel.Text = "PHANTOM HUB"
            pbLabel.TextColor3 = THEME.dim
            pbLabel.TextTransparency = 0.3
        end
    end)
end

-- ============================================================
-- Boot
-- ============================================================

onPlotDataChanged.Event:Connect(function()
    scanAllPlots()
end)

scanConnection = S.RunService.Heartbeat:Connect(function()
    scanAllPlots()
end)

createUI()
scanAllPlots()
if CONFIG.AUTO_STEAL_ENABLED then startAutoSteal() end
