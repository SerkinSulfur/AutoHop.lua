local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local userId = getgenv().BSS_USER_ID
local secretKey = getgenv().BSS_SECRET_KEY

if not userId or not secretKey then
    warn("[AUTOHOP] Missing BSS_USER_ID or BSS_SECRET_KEY")
    return
end

if typeof(request) ~= "function" then
    warn("[AUTOHOP] request(...) is not available in this executor")
    return
end

local placeId = game.PlaceId

local TELEPORT_COOLDOWN = 55
local CHECK_DELAY = 1
local MIN_SPROUT_SECONDS = 40
local MAX_PLAYERS = 4
local RECENT_LIMIT = 5
local VISITED_LIMIT = 100

local WAIT_AFTER_SPROUT_DESPAWN = 30
local WORLD_LOAD_DELAY = 5

getgenv().BSS_VISITED_JOB_IDS = getgenv().BSS_VISITED_JOB_IDS or {}
getgenv().BSS_RECENT_JOB_IDS = getgenv().BSS_RECENT_JOB_IDS or {}
getgenv().BSS_SERVER_JOIN_TIME = getgenv().BSS_SERVER_JOIN_TIME or tick()

getgenv().BSS_CURRENT_SERVER_TYPE = getgenv().BSS_CURRENT_SERVER_TYPE or nil
getgenv().BSS_CURRENT_SERVER_RARITY = getgenv().BSS_CURRENT_SERVER_RARITY or nil
getgenv().BSS_NEXT_TELEPORT_COOLDOWN = getgenv().BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN
getgenv().BSS_UI_COLLAPSED = getgenv().BSS_UI_COLLAPSED or false
getgenv().BSS_CURRENT_SERVER_JOB_ID = getgenv().BSS_CURRENT_SERVER_JOB_ID or game.JobId
getgenv().BSS_CURRENT_SERVER_FIELD = getgenv().BSS_CURRENT_SERVER_FIELD or nil
getgenv().BSS_IGNORE_CURRENT_JOB_ID = getgenv().BSS_IGNORE_CURRENT_JOB_ID or nil

local VISITED = getgenv().BSS_VISITED_JOB_IDS
local RECENT = getgenv().BSS_RECENT_JOB_IDS
local pendingTeleport = nil

local isProcessingSprout = false
local worldReadyAt = tick() + WORLD_LOAD_DELAY

local targetSprout = nil
local farmedAt = nil
local sproutConn = nil

local function safeDestroyGui()
    local old = CoreGui:FindFirstChild("BSS_UI")
    if old then
        old:Destroy()
    end
end

local function isSprout(server)
    return tostring(server.type or "") == "Sprout"
end

local function isVicious(server)
    return tostring(server.type or "") == "Vicious"
end

local function getServerColor(server)
    if isVicious(server) and server.gifted == true then
        return "#f5ce0a"
    end

    if isVicious(server) then
        return "#85C5FF"
    end

    local rarity = tostring(server.rarity or "")

    if rarity == "Supreme" then
        return "#7DEC66"
    elseif rarity == "Legendary" then
        return "#3AD5EA"
    elseif rarity == "Epic" then
        return "#BEC459"
    elseif rarity == "Rare" then
        return "#BBB9BC"
    elseif rarity == "Gummy" then
        return "#6E324E"
    elseif rarity == "Festive" then
        return "#6B273D"
    end

    return "#FFFFFF"
end

local function getRemainingSeconds(server)
    if not server.expiryAt then
        return math.huge
    end

    local expiry = tonumber(server.expiryAt)
    if not expiry then
        return math.huge
    end

    return expiry - os.time()
end

local function getPriority(server)
    local rarity = tostring(server.rarity or "")

    if isSprout(server) and rarity == "Supreme" then
        return 100
    elseif isSprout(server) and rarity == "Legendary" then
        return 90
    elseif isVicious(server) and server.gifted == true then
        return 80
    elseif isSprout(server) and rarity == "Festive" then
        return 70
    elseif isSprout(server) and rarity == "Gummy" then
        return 60
    elseif isSprout(server) and rarity == "Epic" then
        return 50
    elseif isSprout(server) and rarity == "Rare" then
        return 40
    elseif isVicious(server) then
        return 30
    end

    return 0
end

local function getCooldownForServer(server)
    if isSprout(server) and server.rarity == "Supreme" then
        return 60
    elseif isSprout(server) and server.rarity == "Legendary" then
        return 55
    elseif isVicious(server) and server.gifted == true then
        return 55
    elseif isVicious(server) then
        return 40
    end

    return 50
end

local function hasKnownCurrentServer()
    local currentType = getgenv().BSS_CURRENT_SERVER_TYPE
    if currentType == nil then
        return false
    end

    local normalized = tostring(currentType):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return normalized ~= "" and normalized ~= "none" and normalized ~= "unknown"
end

local function hydrateCurrentServerFromList(servers)
    local ignoredJobId = getgenv().BSS_IGNORE_CURRENT_JOB_ID
    if ignoredJobId and ignoredJobId == game.JobId then
        return false
    end

    if hasKnownCurrentServer() then
        return true
    end

    for _, server in ipairs(servers) do
        if server.jobId == game.JobId then
            if isVicious(server) and server.gifted == true then
                getgenv().BSS_CURRENT_SERVER_RARITY = "Gifted"
            else
                getgenv().BSS_CURRENT_SERVER_RARITY = server.rarity
            end

            getgenv().BSS_CURRENT_SERVER_TYPE = server.type
            getgenv().BSS_CURRENT_SERVER_FIELD = server.field
            getgenv().BSS_CURRENT_SERVER_JOB_ID = server.jobId
            return true
        end
    end

    return false
end

local function shouldForceTeleport(best)
    if not best then
        return false
    end

    local currentType = getgenv().BSS_CURRENT_SERVER_TYPE
    local currentRarity = getgenv().BSS_CURRENT_SERVER_RARITY

    local isCurrentLow =
        (currentType == "Sprout" and (currentRarity == "Rare" or currentRarity == "Epic")) or
        (currentType == "Vicious")

    local isTargetHigh =
        (isSprout(best) and (best.rarity == "Supreme" or best.rarity == "Legendary"))

    return isCurrentLow and isTargetHigh
end

local function isInRecent(jobId)
    for _, v in ipairs(RECENT) do
        if v == jobId then
            return true
        end
    end
    return false
end

local function pushRecent(jobId)
    if not jobId or jobId == "" then
        return
    end

    for i = #RECENT, 1, -1 do
        if RECENT[i] == jobId then
            table.remove(RECENT, i)
        end
    end

    table.insert(RECENT, 1, jobId)

    while #RECENT > RECENT_LIMIT do
        table.remove(RECENT, #RECENT)
    end
end

local function countVisited()
    local total = 0
    for _ in pairs(VISITED) do
        total += 1
    end
    return total
end

local function trimVisited()
    if countVisited() <= VISITED_LIMIT then
        return
    end

    local keep = {}
    for _, jobId in ipairs(RECENT) do
        keep[jobId] = true
    end
    keep[game.JobId] = true

    for jobId in pairs(VISITED) do
        if not keep[jobId] then
            VISITED[jobId] = nil
            if countVisited() <= VISITED_LIMIT then
                break
            end
        end
    end
end

local function addVisited(jobId)
    if not jobId or jobId == "" then
        return
    end

    VISITED[jobId] = true
    trimVisited()
end

local function removeRecent(jobId)
    if not jobId or jobId == "" then
        return
    end

    for i = #RECENT, 1, -1 do
        if RECENT[i] == jobId then
            table.remove(RECENT, i)
        end
    end
end

local function markCurrentServer()
    local currentJobId = game.JobId
    if currentJobId and currentJobId ~= "" then
        addVisited(currentJobId)
        pushRecent(currentJobId)
        getgenv().BSS_CURRENT_SERVER_JOB_ID = currentJobId
    end
end

local function hasTooManyPlayers(server)
    local players = tonumber(server.playerCount) or 0
    return players > MAX_PLAYERS
end

local function isValidServer(server)
    if not server.jobId then
        return false
    end

    if server.jobId == game.JobId then
        return false
    end

    if VISITED[server.jobId] then
        return false
    end

    if isInRecent(server.jobId) then
        return false
    end

    if hasTooManyPlayers(server) then
        return false
    end

    if isSprout(server) then
        local remaining = getRemainingSeconds(server)

        if remaining <= 0 then
            return false
        end

        if remaining < MIN_SPROUT_SECONDS then
            return false
        end
    end

    return getPriority(server) > 0
end

local function fetchValidated()
    local url = ("https://bss-tools.com/api/workspaces/%s/validated"):format(userId)

    local okRequest, res = pcall(function()
        return request({
            Url = url,
            Method = "GET",
            Headers = {
                ["secret-key"] = secretKey
            }
        })
    end)

    if not okRequest then
        warn("[AUTOHOP] API request failed")
        return {}
    end

    if not res or res.StatusCode ~= 200 then
        warn("[AUTOHOP] API error:", res and res.Body or "no response")
        return {}
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)

    if not ok or not data then
        warn("[AUTOHOP] JSON decode error")
        return {}
    end

    return data.results or {}
end

local function isBetterServer(candidate, best)
    if not candidate then
        return false
    end

    if not best then
        return true
    end

    local cp = getPriority(candidate)
    local bp = getPriority(best)

    if cp > bp then
        return true
    elseif cp < bp then
        return false
    end

    if isSprout(candidate) and isSprout(best) then
        local cr = getRemainingSeconds(candidate)
        local br = getRemainingSeconds(best)

        if cr < br then
            return true
        elseif cr > br then
            return false
        end
    end

    if isVicious(candidate) and isVicious(best) then
        local cl = tonumber(candidate.level) or 0
        local bl = tonumber(best.level) or 0

        if cl > bl then
            return true
        elseif cl < bl then
            return false
        end
    end

    local cPlayers = tonumber(candidate.playerCount) or 999
    local bPlayers = tonumber(best.playerCount) or 999

    return cPlayers < bPlayers
end

local function pickBestServer(servers)
    local best = nil

    for _, server in ipairs(servers) do
        if isValidServer(server) then
            if isBetterServer(server, best) then
                best = server
            end
        end
    end

    return best
end

local function sortServersForUi(servers)
    local copy = {}

    for _, server in ipairs(servers) do
        if isValidServer(server) then
            table.insert(copy, server)
        end
    end

    table.sort(copy, function(a, b)
        return isBetterServer(a, b)
    end)

    return copy
end

safeDestroyGui()

local gui = Instance.new("ScreenGui")
gui.Name = "BSS_UI"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = CoreGui

local frame = Instance.new("Frame")
frame.Parent = gui
frame.Size = UDim2.new(0, 360, 0, getgenv().BSS_UI_COLLAPSED and 44 or 470)
frame.Position = UDim2.new(1, -375, 0.5, getgenv().BSS_UI_COLLAPSED and -22 or -235)
frame.BackgroundColor3 = Color3.fromRGB(18, 18, 22)
frame.BorderSizePixel = 0

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = frame

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(45, 45, 55)
stroke.Thickness = 1
stroke.Parent = frame

local header = Instance.new("Frame")
header.Parent = frame
header.Size = UDim2.new(1, 0, 0, 44)
header.BackgroundColor3 = Color3.fromRGB(24, 24, 30)
header.BorderSizePixel = 0

local headerCorner = Instance.new("UICorner")
headerCorner.CornerRadius = UDim.new(0, 10)
headerCorner.Parent = header

local headerFix = Instance.new("Frame")
headerFix.Parent = header
headerFix.Position = UDim2.new(0, 0, 1, -10)
headerFix.Size = UDim2.new(1, 0, 0, 10)
headerFix.BackgroundColor3 = header.BackgroundColor3
headerFix.BorderSizePixel = 0

local title = Instance.new("TextLabel")
title.Parent = header
title.BackgroundTransparency = 1
title.Position = UDim2.new(0, 14, 0, 0)
title.Size = UDim2.new(1, -70, 1, 0)
title.Font = Enum.Font.GothamBold
title.TextSize = 16
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextXAlignment = Enum.TextXAlignment.Left
title.Text = "AutoHop Sprout Check"

local collapseButton = Instance.new("TextButton")
collapseButton.Parent = header
collapseButton.Size = UDim2.new(0, 32, 0, 24)
collapseButton.Position = UDim2.new(1, -40, 0.5, -12)
collapseButton.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
collapseButton.BorderSizePixel = 0
collapseButton.Font = Enum.Font.GothamBold
collapseButton.TextSize = 16
collapseButton.TextColor3 = Color3.fromRGB(230, 230, 235)
collapseButton.Text = getgenv().BSS_UI_COLLAPSED and "+" or "—"

local collapseCorner = Instance.new("UICorner")
collapseCorner.CornerRadius = UDim.new(0, 6)
collapseCorner.Parent = collapseButton

local statusLabel = Instance.new("TextLabel")
statusLabel.Parent = frame
statusLabel.BackgroundTransparency = 1
statusLabel.Position = UDim2.new(0, 14, 0, 54)
statusLabel.Size = UDim2.new(1, -28, 0, 20)
statusLabel.Font = Enum.Font.Gotham
statusLabel.TextSize = 13
statusLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
statusLabel.TextXAlignment = Enum.TextXAlignment.Left
statusLabel.Text = "Status: Initializing..."

local cooldownLabel = Instance.new("TextLabel")
cooldownLabel.Parent = frame
cooldownLabel.BackgroundTransparency = 1
cooldownLabel.Position = UDim2.new(0, 14, 0, 76)
cooldownLabel.Size = UDim2.new(1, -28, 0, 20)
cooldownLabel.Font = Enum.Font.Gotham
cooldownLabel.TextSize = 13
cooldownLabel.TextColor3 = Color3.fromRGB(190, 190, 200)
cooldownLabel.TextXAlignment = Enum.TextXAlignment.Left
cooldownLabel.Text = "Cooldown: 0s"

local sproutStatusLabel = Instance.new("TextLabel")
sproutStatusLabel.Parent = frame
sproutStatusLabel.BackgroundTransparency = 1
sproutStatusLabel.Position = UDim2.new(0, 14, 0, 98)
sproutStatusLabel.Size = UDim2.new(1, -28, 0, 40)
sproutStatusLabel.Font = Enum.Font.Gotham
sproutStatusLabel.TextSize = 13
sproutStatusLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
sproutStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
sproutStatusLabel.TextWrapped = true
sproutStatusLabel.Text = "🌱 Sprout: idle"

local targetLabel = Instance.new("TextLabel")
targetLabel.Parent = frame
targetLabel.BackgroundTransparency = 1
targetLabel.Position = UDim2.new(0, 14, 0, 142)
targetLabel.Size = UDim2.new(1, -28, 0, 54)
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextSize = 13
targetLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.TextYAlignment = Enum.TextYAlignment.Top
targetLabel.TextWrapped = true
targetLabel.RichText = true
targetLabel.Text = "Current: none"

local listHeader = Instance.new("TextLabel")
listHeader.Parent = frame
listHeader.BackgroundTransparency = 1
listHeader.Position = UDim2.new(0, 14, 0, 202)
listHeader.Size = UDim2.new(1, -28, 0, 20)
listHeader.Font = Enum.Font.GothamBold
listHeader.TextSize = 13
listHeader.TextColor3 = Color3.fromRGB(255, 255, 255)
listHeader.TextXAlignment = Enum.TextXAlignment.Left
listHeader.Text = "Servers"

local listContainer = Instance.new("Frame")
listContainer.Parent = frame
listContainer.Position = UDim2.new(0, 12, 0, 228)
listContainer.Size = UDim2.new(1, -24, 1, -240)
listContainer.BackgroundColor3 = Color3.fromRGB(23, 23, 28)
listContainer.BorderSizePixel = 0

local listCorner = Instance.new("UICorner")
listCorner.CornerRadius = UDim.new(0, 8)
listCorner.Parent = listContainer

local listStroke = Instance.new("UIStroke")
listStroke.Color = Color3.fromRGB(40, 40, 50)
listStroke.Thickness = 1
listStroke.Parent = listContainer

local scrolling = Instance.new("ScrollingFrame")
scrolling.Parent = listContainer
scrolling.BackgroundTransparency = 1
scrolling.BorderSizePixel = 0
scrolling.Position = UDim2.new(0, 8, 0, 8)
scrolling.Size = UDim2.new(1, -16, 1, -16)
scrolling.CanvasSize = UDim2.new(0, 0, 0, 0)
scrolling.ScrollBarThickness = 4
scrolling.AutomaticCanvasSize = Enum.AutomaticSize.None

local layout = Instance.new("UIListLayout")
layout.Parent = scrolling
layout.Padding = UDim.new(0, 6)
layout.SortOrder = Enum.SortOrder.LayoutOrder

local function setCollapsed(collapsed)
    getgenv().BSS_UI_COLLAPSED = collapsed
    collapseButton.Text = collapsed and "+" or "—"

    statusLabel.Visible = not collapsed
    cooldownLabel.Visible = not collapsed
    sproutStatusLabel.Visible = not collapsed
    targetLabel.Visible = not collapsed
    listHeader.Visible = not collapsed
    listContainer.Visible = not collapsed

    frame.Size = UDim2.new(0, 360, 0, collapsed and 44 or 470)
end

collapseButton.MouseButton1Click:Connect(function()
    setCollapsed(not getgenv().BSS_UI_COLLAPSED)
end)

setCollapsed(getgenv().BSS_UI_COLLAPSED)

local dragging = false
local dragStart
local startPos

header.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = input.Position
        startPos = frame.Position

        input.Changed:Connect(function()
            if input.UserInputState == Enum.UserInputState.End then
                dragging = false
            end
        end)
    end
end)

UserInputService.InputChanged:Connect(function(input)
    if dragging and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = input.Position - dragStart
        frame.Position = UDim2.new(
            startPos.X.Scale,
            startPos.X.Offset + delta.X,
            startPos.Y.Scale,
            startPos.Y.Offset + delta.Y
        )
    end
end)

local function updateSproutStatusUI(text, color)
    sproutStatusLabel.Text = text
    if color then
        sproutStatusLabel.TextColor3 = color
    end
end

local function clearServerList()
    for _, child in ipairs(scrolling:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end
end

local function formatServerLine(server)
    local serverType = tostring(server.type or "?")
    local rarity = tostring(server.rarity or "")
    local players = tonumber(server.playerCount) or 0
    local remaining = getRemainingSeconds(server)
    local color = getServerColor(server)

    local nameText
    if isVicious(server) then
        if server.gifted == true then
            nameText = string.format('<font color="%s">Gifted %s</font>', color, serverType)
        else
            nameText = string.format('<font color="%s">%s</font>', color, serverType)
        end
    else
        nameText = string.format('<font color="%s">%s %s</font>', color, rarity, serverType)
    end

    local extra = ""
    if isSprout(server) then
        extra = " | " .. (remaining == math.huge and "INF" or tostring(math.max(0, remaining)) .. "s")
        if server.field then
            extra = extra .. " | " .. tostring(server.field)
        end
    elseif isVicious(server) then
        extra = " | Lv." .. tostring(server.level or "?")
        if server.gifted then
            extra = extra .. " | Gifted"
        end
    end

    return string.format("%s | %dP%s", nameText, players, extra)
end

local function updateServerList(servers, best)
    clearServerList()

    local sorted = sortServersForUi(servers)
    local shown = 0

    for _, server in ipairs(sorted) do
        shown += 1
        if shown > 12 then
            break
        end

        local item = Instance.new("Frame")
        item.Parent = scrolling
        item.Size = UDim2.new(1, 0, 0, 34)
        item.BackgroundColor3 = (best and server.jobId == best.jobId)
            and Color3.fromRGB(36, 58, 44)
            or Color3.fromRGB(28, 28, 34)
        item.BorderSizePixel = 0
        item.LayoutOrder = shown

        local itemCorner = Instance.new("UICorner")
        itemCorner.CornerRadius = UDim.new(0, 6)
        itemCorner.Parent = item

        local itemText = Instance.new("TextLabel")
        itemText.Parent = item
        itemText.BackgroundTransparency = 1
        itemText.Position = UDim2.new(0, 10, 0, 0)
        itemText.Size = UDim2.new(1, -20, 1, 0)
        itemText.Font = Enum.Font.Gotham
        itemText.TextSize = 12
        itemText.TextColor3 = Color3.fromRGB(235, 235, 240)
        itemText.TextXAlignment = Enum.TextXAlignment.Left
        itemText.RichText = true
        itemText.Text = formatServerLine(server)
    end

    if shown == 0 then
        local item = Instance.new("Frame")
        item.Parent = scrolling
        item.Size = UDim2.new(1, 0, 0, 34)
        item.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
        item.BorderSizePixel = 0

        local itemCorner = Instance.new("UICorner")
        itemCorner.CornerRadius = UDim.new(0, 6)
        itemCorner.Parent = item

        local itemText = Instance.new("TextLabel")
        itemText.Parent = item
        itemText.BackgroundTransparency = 1
        itemText.Position = UDim2.new(0, 10, 0, 0)
        itemText.Size = UDim2.new(1, -20, 1, 0)
        itemText.Font = Enum.Font.Gotham
        itemText.TextSize = 12
        itemText.TextColor3 = Color3.fromRGB(170, 170, 180)
        itemText.TextXAlignment = Enum.TextXAlignment.Left
        itemText.Text = "No suitable servers in list"
    end

    task.wait()
    scrolling.CanvasSize = UDim2.new(0, 0, 0, layout.AbsoluteContentSize.Y)
end

local function getCurrentServerText()
    local currentType = getgenv().BSS_CURRENT_SERVER_TYPE
    local currentRarity = getgenv().BSS_CURRENT_SERVER_RARITY
    local currentField = getgenv().BSS_CURRENT_SERVER_FIELD

    if not currentType or currentType == "" then
        return "Current: none"
    end

    local currentName = currentType
    if currentType == "Sprout" and currentRarity then
        currentName = string.format("%s %s", currentRarity, currentType)
    elseif currentType == "Vicious" and currentRarity == "Gifted" then
        currentName = "Gifted Vicious"
    end

    if currentField and currentField ~= "" then
        return string.format("Current: %s | API Field: %s", currentName, tostring(currentField))
    end

    return string.format("Current: %s", currentName)
end

local function updateTopInfo(best, force, joinedAgo, cooldown)
    local remainingCooldown = math.max(0, math.ceil(cooldown - joinedAgo))

    if force and best then
        statusLabel.Text = "Status: Force teleport"
        cooldownLabel.Text = "Cooldown: bypassed"
    else
        if remainingCooldown > 0 then
            statusLabel.Text = "Status: Waiting"
            cooldownLabel.Text = "Cooldown: " .. tostring(remainingCooldown) .. "s"
        else
            statusLabel.Text = "Status: Ready"
            cooldownLabel.Text = "Cooldown: 0s"
        end
    end

    if best then
        local color = getServerColor(best)
        local remaining = getRemainingSeconds(best)

        local nameText
        if isVicious(best) then
            if best.gifted == true then
                nameText = string.format('<font color="%s">Gifted %s</font>', color, tostring(best.type or "?"))
            else
                nameText = string.format('<font color="%s">%s</font>', color, tostring(best.type or "?"))
            end
        else
            nameText = string.format('<font color="%s">%s %s</font>', color, tostring(best.rarity or "?"), tostring(best.type or "?"))
        end

        local extra = ""
        if isSprout(best) then
            extra = " | Remaining: " .. (remaining == math.huge and "INF" or tostring(math.max(0, remaining)) .. "s")
            if best.field then
                extra = extra .. " | API Field: " .. tostring(best.field)
            end
        elseif isVicious(best) then
            extra = " | Level: " .. tostring(best.level or "?")
            if best.gifted then
                extra = extra .. " | Gifted"
            end
        end

        targetLabel.Text = string.format(
            "%s\nNext server: %s | Players: %s%s",
            getCurrentServerText(),
            nameText,
            tostring(best.playerCount or "?"),
            extra
        )
    else
        targetLabel.Text = getCurrentServerText()
    end
end

local function disconnectSproutConn()
    if sproutConn then
        sproutConn:Disconnect()
        sproutConn = nil
    end
end

local function findSproutModel()
    local sproutsFolder = workspace:FindFirstChild("Sprouts")
    if sproutsFolder then
        local exact = sproutsFolder:FindFirstChild("Sprout")
        if exact and exact:IsA("Model") then
            return exact
        end

        for _, child in ipairs(sproutsFolder:GetChildren()) do
            if child:IsA("Model") and child.Name:lower():find("sprout") then
                return child
            end
        end
    end

    local fallback = workspace:FindFirstChild("Sprout")
    if fallback and fallback:IsA("Model") then
        return fallback
    end

    for _, child in ipairs(workspace:GetChildren()) do
        if child:IsA("Model") and child.Name:lower():find("sprout") then
            return child
        end
    end

    return nil
end

local function bindTargetSprout()
    disconnectSproutConn()
    targetSprout = findSproutModel()
    farmedAt = nil

    if targetSprout then
        sproutConn = targetSprout.AncestryChanged:Connect(function(_, parent)
            if parent == nil and not farmedAt then
                farmedAt = tick()
                disconnectSproutConn()
            end
        end)
        return true
    end

    return false
end

local function hasRealSprout()
    if targetSprout and targetSprout.Parent ~= nil then
        return true
    end

    targetSprout = nil
    return bindTargetSprout()
end

local function waitForSproutDespawn()
    print("[SPROUT] Real Sprout found, tracking AncestryChanged...")
    updateSproutStatusUI("🌱 Росток найден: отслеживаю исчезновение...", Color3.fromRGB(120, 255, 120))

    while true do
        if not targetSprout or targetSprout.Parent == nil then
            targetSprout = nil
            if farmedAt and (tick() - farmedAt) > WAIT_AFTER_SPROUT_DESPAWN then
                break
            end
        else
            -- здесь можно выполнять фарм, пока росток существует
        end

        if farmedAt then
            local elapsed = tick() - farmedAt
            local left = math.max(0, math.ceil(WAIT_AFTER_SPROUT_DESPAWN - elapsed))
            updateSproutStatusUI("⏳ После исчезновения: " .. tostring(left) .. " сек", Color3.fromRGB(255, 210, 120))
        end

        task.wait()
    end

    targetSprout = nil
    farmedAt = nil
    disconnectSproutConn()
end

local function invalidateCurrentServer()
    local currentJobId = game.JobId
    if currentJobId and currentJobId ~= "" then
        addVisited(currentJobId)
        pushRecent(currentJobId)
        getgenv().BSS_IGNORE_CURRENT_JOB_ID = currentJobId
    end

    targetSprout = nil
    farmedAt = nil
    disconnectSproutConn()

    getgenv().BSS_CURRENT_SERVER_TYPE = nil
    getgenv().BSS_CURRENT_SERVER_RARITY = nil
    getgenv().BSS_CURRENT_SERVER_FIELD = nil
    getgenv().BSS_CURRENT_SERVER_JOB_ID = nil
    getgenv().BSS_NEXT_TELEPORT_COOLDOWN = 0
    getgenv().BSS_SERVER_JOIN_TIME = tick() - 60
end

local function applyServerIdentity(server)
    if isVicious(server) and server.gifted == true then
        getgenv().BSS_CURRENT_SERVER_RARITY = "Gifted"
    else
        getgenv().BSS_CURRENT_SERVER_RARITY = server.rarity
    end

    getgenv().BSS_CURRENT_SERVER_TYPE = server.type
    getgenv().BSS_CURRENT_SERVER_FIELD = server.field
    getgenv().BSS_CURRENT_SERVER_JOB_ID = server.jobId
end

local function teleportToServer(best)
    local remaining = getRemainingSeconds(best)

    print("========== SELECTED ==========")
    print("Type:", best.type)
    print("Rarity:", best.rarity)
    print("Field:", best.field)
    print("Players:", best.playerCount)
    print("Gifted:", best.gifted)
    print("Level:", best.level)
    print("Priority:", getPriority(best))
    print("Remaining:", remaining == math.huge and "INF" or remaining)
    print("JobId:", best.jobId)
    print("==============================")

    pendingTeleport = {
        jobId = best.jobId,
        previousType = getgenv().BSS_CURRENT_SERVER_TYPE,
        previousRarity = getgenv().BSS_CURRENT_SERVER_RARITY,
        previousJobId = getgenv().BSS_CURRENT_SERVER_JOB_ID,
        previousField = getgenv().BSS_CURRENT_SERVER_FIELD,
        previousCooldown = getgenv().BSS_NEXT_TELEPORT_COOLDOWN,
        previousJoinTime = getgenv().BSS_SERVER_JOIN_TIME,
        previousIgnoreJobId = getgenv().BSS_IGNORE_CURRENT_JOB_ID,
    }

    addVisited(best.jobId)
    pushRecent(best.jobId)
    applyServerIdentity(best)
    getgenv().BSS_NEXT_TELEPORT_COOLDOWN = getCooldownForServer(best)
    getgenv().BSS_SERVER_JOIN_TIME = tick()
    getgenv().BSS_IGNORE_CURRENT_JOB_ID = nil
    targetSprout = nil
    farmedAt = nil
    disconnectSproutConn()

    local okTeleport, teleportError = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, best.jobId, LocalPlayer)
    end)

    if not okTeleport then
        warn("[AUTOHOP] Teleport call failed:", tostring(teleportError))
        VISITED[best.jobId] = nil
        removeRecent(best.jobId)

        if pendingTeleport then
            getgenv().BSS_CURRENT_SERVER_TYPE = pendingTeleport.previousType
            getgenv().BSS_CURRENT_SERVER_RARITY = pendingTeleport.previousRarity
            getgenv().BSS_CURRENT_SERVER_FIELD = pendingTeleport.previousField
            getgenv().BSS_CURRENT_SERVER_JOB_ID = pendingTeleport.previousJobId
            getgenv().BSS_NEXT_TELEPORT_COOLDOWN = pendingTeleport.previousCooldown
            getgenv().BSS_SERVER_JOIN_TIME = pendingTeleport.previousJoinTime
            getgenv().BSS_IGNORE_CURRENT_JOB_ID = pendingTeleport.previousIgnoreJobId
            pendingTeleport = nil
        end

        return false
    end

    worldReadyAt = tick() + WORLD_LOAD_DELAY
    task.wait(3)
    return true
end

local function teleportToNextBestServer(servers)
    local best = pickBestServer(servers)
    if not best then
        return false
    end
    return teleportToServer(best)
end

local function processCurrentSproutServer(servers)
    if isProcessingSprout then
        return
    end

    if getgenv().BSS_CURRENT_SERVER_TYPE ~= "Sprout" then
        return
    end

    if tick() < worldReadyAt then
        updateSproutStatusUI("🌱 Ожидание загрузки мира...", Color3.fromRGB(180, 180, 200))
        return
    end

    isProcessingSprout = true

    if bindTargetSprout() then
        print("[SPROUT] Real Sprout confirmed on server. Tracking targetSprout.")
        updateSproutStatusUI("✅ На сервере есть реальный Sprout", Color3.fromRGB(100, 255, 100))
        waitForSproutDespawn()
        updateSproutStatusUI("➡️ Переход на следующий сервер...", Color3.fromRGB(100, 255, 100))
        invalidateCurrentServer()
    else
        print("[SPROUT] API says Sprout, but no real Sprout found in workspace.")
        updateSproutStatusUI("❌ На сервере нет реального Sprout", Color3.fromRGB(255, 100, 100))

        invalidateCurrentServer()
        task.wait(0.2)

        if servers and #servers > 0 then
            teleportToNextBestServer(servers)
        end
    end

    isProcessingSprout = false
end

TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage, _, jobId)
    if player ~= LocalPlayer then
        return
    end

    local failedJobId = jobId or (pendingTeleport and pendingTeleport.jobId)
    if failedJobId and failedJobId ~= "" then
        VISITED[failedJobId] = nil
        removeRecent(failedJobId)
    end

    if pendingTeleport and failedJobId == pendingTeleport.jobId then
        getgenv().BSS_CURRENT_SERVER_TYPE = pendingTeleport.previousType
        getgenv().BSS_CURRENT_SERVER_RARITY = pendingTeleport.previousRarity
        getgenv().BSS_CURRENT_SERVER_FIELD = pendingTeleport.previousField
        getgenv().BSS_CURRENT_SERVER_JOB_ID = pendingTeleport.previousJobId
        getgenv().BSS_NEXT_TELEPORT_COOLDOWN = pendingTeleport.previousCooldown
        getgenv().BSS_SERVER_JOIN_TIME = pendingTeleport.previousJoinTime
        getgenv().BSS_IGNORE_CURRENT_JOB_ID = pendingTeleport.previousIgnoreJobId
        pendingTeleport = nil
    end

    warn("[AUTOHOP] Teleport failed:", tostring(result), tostring(errorMessage or ""))
end)

getgenv().checkCurrentSprout = function()
    local exists = hasRealSprout()
    print("[MANUAL] real sprout exists =", exists)
    return exists
end

getgenv().setWaitAfterDespawn = function(seconds)
    seconds = tonumber(seconds) or 30
    WAIT_AFTER_SPROUT_DESPAWN = math.max(1, math.min(120, seconds))
    print("[SETTINGS] Wait after Sprout despawn set to", WAIT_AFTER_SPROUT_DESPAWN, "seconds")
    return WAIT_AFTER_SPROUT_DESPAWN
end

markCurrentServer()

print("=== AutoHop Sprout Check Listener ===")
print("Используется targetSprout + AncestryChanged для отслеживания исчезновения.")
print("Gifted Vicious cooldown увеличен до 55 секунд.")
print("Поле не проверяется.")
print("checkCurrentSprout() - проверить, есть ли реальный Sprout")
print("setWaitAfterDespawn(сек) - изменить задержку после исчезновения")

while true do
    task.wait(CHECK_DELAY)

    if isProcessingSprout then
        continue
    end

    local servers = fetchValidated()
    local hasCurrentServer = hydrateCurrentServerFromList(servers)

    local joinedAgo = tick() - getgenv().BSS_SERVER_JOIN_TIME
    local dynamicCooldown = getgenv().BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN

    if hasCurrentServer and getgenv().BSS_CURRENT_SERVER_TYPE == "Sprout" then
        updateTopInfo(nil, false, joinedAgo, dynamicCooldown)
        updateServerList(servers, nil)
        processCurrentSproutServer(servers)
        continue
    else
        updateSproutStatusUI("🌱 Sprout: idle", Color3.fromRGB(150, 150, 160))
    end

    local best = pickBestServer(servers)
    local force = shouldForceTeleport(best)
    local bypassCooldown = force or (not hasCurrentServer and best ~= nil)

    updateTopInfo(best, force, joinedAgo, dynamicCooldown)
    updateServerList(servers, best)

    if hasCurrentServer and not bypassCooldown and joinedAgo < dynamicCooldown then
        continue
    end

    if best then
        teleportToServer(best)
    end
end
