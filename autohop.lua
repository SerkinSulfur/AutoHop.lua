local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer
local ENV = getgenv and getgenv() or _G

local userId = ENV.BSS_USER_ID
local secretKey = ENV.BSS_SECRET_KEY

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
local WAIT_AFTER_SPROUT_DESPAWN = 21
local WORLD_LOAD_DELAY = 5
local MAX_TRACK_TIME = 60
local MAX_HP_STUCK_TIME = 30

ENV.BSS_VISITED_JOB_IDS = ENV.BSS_VISITED_JOB_IDS or {}
ENV.BSS_RECENT_JOB_IDS = ENV.BSS_RECENT_JOB_IDS or {}
ENV.BSS_SERVER_JOIN_TIME = ENV.BSS_SERVER_JOIN_TIME or tick()
ENV.BSS_CURRENT_SERVER_TYPE = ENV.BSS_CURRENT_SERVER_TYPE or nil
ENV.BSS_CURRENT_SERVER_RARITY = ENV.BSS_CURRENT_SERVER_RARITY or nil
ENV.BSS_CURRENT_SERVER_FIELD = ENV.BSS_CURRENT_SERVER_FIELD or nil
ENV.BSS_CURRENT_SERVER_JOB_ID = ENV.BSS_CURRENT_SERVER_JOB_ID or game.JobId
ENV.BSS_NEXT_TELEPORT_COOLDOWN = ENV.BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN
ENV.BSS_UI_COLLAPSED = ENV.BSS_UI_COLLAPSED or false
ENV.BSS_IGNORE_CURRENT_JOB_ID = ENV.BSS_IGNORE_CURRENT_JOB_ID or nil
ENV.BSS_ACTIVE_TAB = ENV.BSS_ACTIVE_TAB or "Servers"
ENV.BSS_PRIORITY_ORDER = ENV.BSS_PRIORITY_ORDER or {
    "Supreme Sprout",
    "Legendary Sprout",
    "Gifted Vicious",
    "Festive Sprout",
    "Epic Sprout",
    "Gummy Sprout",
    "Rare Sprout",
    "Vicious",
}

local VISITED = ENV.BSS_VISITED_JOB_IDS
local RECENT = ENV.BSS_RECENT_JOB_IDS

local pendingTeleport = nil
local isProcessingSpecial = false
local worldReadyAt = tick() + WORLD_LOAD_DELAY

local targetSprout = nil
local farmedAt = nil
local sproutConn = nil

local targetVicious = nil
local viciousGoneAt = nil
local viciousConn = nil
local viciousHumanoidConn = nil

local currentSproutHP = nil
local currentViciousHP = nil

local function log(...)
    print("[AUTOHOP]", ...)
end

local function warnf(...)
    warn("[AUTOHOP]", ...)
end

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

local function getServerLabel(server)
    local rarity = tostring(server.rarity or "")

    if isSprout(server) and rarity == "Supreme" then
        return "Supreme Sprout"
    elseif isSprout(server) and rarity == "Legendary" then
        return "Legendary Sprout"
    elseif isVicious(server) and server.gifted == true then
        return "Gifted Vicious"
    elseif isSprout(server) and rarity == "Festive" then
        return "Festive Sprout"
    elseif isSprout(server) and rarity == "Epic" then
        return "Epic Sprout"
    elseif isSprout(server) and rarity == "Gummy" then
        return "Gummy Sprout"
    elseif isSprout(server) and rarity == "Rare" then
        return "Rare Sprout"
    elseif isVicious(server) then
        return "Vicious"
    end

    return nil
end

local function getPriority(server)
    local label = getServerLabel(server)
    if not label then
        return 0
    end

    for index, value in ipairs(ENV.BSS_PRIORITY_ORDER) do
        if value == label then
            return 100 - index
        end
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
    local currentType = ENV.BSS_CURRENT_SERVER_TYPE
    if currentType == nil then
        return false
    end

    local normalized = tostring(currentType):lower():gsub("^%s+", ""):gsub("%s+$", "")
    return normalized ~= "" and normalized ~= "none" and normalized ~= "unknown"
end

local function hydrateCurrentServerFromList(servers)
    local ignoredJobId = ENV.BSS_IGNORE_CURRENT_JOB_ID
    if ignoredJobId and ignoredJobId == game.JobId then
        return false
    end

    if hasKnownCurrentServer() then
        return true
    end

    for _, server in ipairs(servers) do
        if server.jobId == game.JobId then
            if isVicious(server) and server.gifted == true then
                ENV.BSS_CURRENT_SERVER_RARITY = "Gifted"
            else
                ENV.BSS_CURRENT_SERVER_RARITY = server.rarity
            end

            ENV.BSS_CURRENT_SERVER_TYPE = server.type
            ENV.BSS_CURRENT_SERVER_FIELD = server.field
            ENV.BSS_CURRENT_SERVER_JOB_ID = server.jobId
            return true
        end
    end

    return false
end

local function shouldForceTeleport(best)
    if not best then
        return false
    end

    local currentType = ENV.BSS_CURRENT_SERVER_TYPE
    local currentRarity = ENV.BSS_CURRENT_SERVER_RARITY

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
        ENV.BSS_CURRENT_SERVER_JOB_ID = currentJobId
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
            Headers = {["secret-key"] = secretKey}
        })
    end)

    if not okRequest then
        warnf("API request failed")
        return {}
    end

    if not res or res.StatusCode ~= 200 then
        warnf("API error:", res and res.Body or "no response")
        return {}
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)

    if not ok or not data then
        warnf("JSON decode error")
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
        if isValidServer(server) and isBetterServer(server, best) then
            best = server
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
frame.Size = UDim2.new(0, 380, 0, ENV.BSS_UI_COLLAPSED and 44 or 530)
frame.Position = UDim2.new(1, -395, 0.5, ENV.BSS_UI_COLLAPSED and -22 or -265)
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
title.Text = "AutoHop"

local collapseButton = Instance.new("TextButton")
collapseButton.Parent = header
collapseButton.Size = UDim2.new(0, 32, 0, 24)
collapseButton.Position = UDim2.new(1, -40, 0.5, -12)
collapseButton.BackgroundColor3 = Color3.fromRGB(34, 34, 42)
collapseButton.BorderSizePixel = 0
collapseButton.Font = Enum.Font.GothamBold
collapseButton.TextSize = 16
collapseButton.TextColor3 = Color3.fromRGB(230, 230, 235)
collapseButton.Text = ENV.BSS_UI_COLLAPSED and "+" or "—"

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

local trackerLabel = Instance.new("TextLabel")
trackerLabel.Parent = frame
trackerLabel.BackgroundTransparency = 1
trackerLabel.Position = UDim2.new(0, 14, 0, 98)
trackerLabel.Size = UDim2.new(1, -28, 0, 42)
trackerLabel.Font = Enum.Font.Gotham
trackerLabel.TextSize = 13
trackerLabel.TextColor3 = Color3.fromRGB(150, 150, 160)
trackerLabel.TextXAlignment = Enum.TextXAlignment.Left
trackerLabel.TextWrapped = true
trackerLabel.Text = "Tracker: idle"

local hpLabel = Instance.new("TextLabel")
hpLabel.Parent = frame
hpLabel.BackgroundTransparency = 1
hpLabel.Position = UDim2.new(0, 14, 0, 138)
hpLabel.Size = UDim2.new(1, -28, 0, 22)
hpLabel.Font = Enum.Font.Gotham
hpLabel.TextSize = 13
hpLabel.TextColor3 = Color3.fromRGB(205, 205, 215)
hpLabel.TextXAlignment = Enum.TextXAlignment.Left
hpLabel.Text = "HP: Sprout - | Vicious -"

local targetLabel = Instance.new("TextLabel")
targetLabel.Parent = frame
targetLabel.BackgroundTransparency = 1
targetLabel.Position = UDim2.new(0, 14, 0, 164)
targetLabel.Size = UDim2.new(1, -28, 0, 56)
targetLabel.Font = Enum.Font.Gotham
targetLabel.TextSize = 13
targetLabel.TextColor3 = Color3.fromRGB(220, 220, 230)
targetLabel.TextXAlignment = Enum.TextXAlignment.Left
targetLabel.TextYAlignment = Enum.TextYAlignment.Top
targetLabel.TextWrapped = true
targetLabel.RichText = true
targetLabel.Text = "Current: none"

local tabBar = Instance.new("Frame")
tabBar.Parent = frame
tabBar.Position = UDim2.new(0, 12, 0, 224)
tabBar.Size = UDim2.new(1, -24, 0, 34)
tabBar.BackgroundTransparency = 1

local serversTabButton = Instance.new("TextButton")
serversTabButton.Parent = tabBar
serversTabButton.Size = UDim2.new(0.5, -4, 1, 0)
serversTabButton.Position = UDim2.new(0, 0, 0, 0)
serversTabButton.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
serversTabButton.BorderSizePixel = 0
serversTabButton.Font = Enum.Font.GothamBold
serversTabButton.TextSize = 13
serversTabButton.TextColor3 = Color3.fromRGB(235, 235, 240)
serversTabButton.Text = "Servers"

local settingsTabButton = Instance.new("TextButton")
settingsTabButton.Parent = tabBar
settingsTabButton.Size = UDim2.new(0.5, -4, 1, 0)
settingsTabButton.Position = UDim2.new(0.5, 4, 0, 0)
settingsTabButton.BackgroundColor3 = Color3.fromRGB(35, 35, 42)
settingsTabButton.BorderSizePixel = 0
settingsTabButton.Font = Enum.Font.GothamBold
settingsTabButton.TextSize = 13
settingsTabButton.TextColor3 = Color3.fromRGB(235, 235, 240)
settingsTabButton.Text = "Settings"

for _, button in ipairs({serversTabButton, settingsTabButton}) do
    local c = Instance.new("UICorner")
    c.CornerRadius = UDim.new(0, 8)
    c.Parent = button
end

local contentHolder = Instance.new("Frame")
contentHolder.Parent = frame
contentHolder.Position = UDim2.new(0, 12, 0, 264)
contentHolder.Size = UDim2.new(1, -24, 1, -276)
contentHolder.BackgroundColor3 = Color3.fromRGB(23, 23, 28)
contentHolder.BorderSizePixel = 0

local contentCorner = Instance.new("UICorner")
contentCorner.CornerRadius = UDim.new(0, 8)
contentCorner.Parent = contentHolder

local contentStroke = Instance.new("UIStroke")
contentStroke.Color = Color3.fromRGB(40, 40, 50)
contentStroke.Thickness = 1
contentStroke.Parent = contentHolder

local serversPage = Instance.new("Frame")
serversPage.Parent = contentHolder
serversPage.BackgroundTransparency = 1
serversPage.Size = UDim2.new(1, 0, 1, 0)

local settingsPage = Instance.new("Frame")
settingsPage.Parent = contentHolder
settingsPage.BackgroundTransparency = 1
settingsPage.Size = UDim2.new(1, 0, 1, 0)

local serversScroll = Instance.new("ScrollingFrame")
serversScroll.Parent = serversPage
serversScroll.BackgroundTransparency = 1
serversScroll.BorderSizePixel = 0
serversScroll.Position = UDim2.new(0, 8, 0, 8)
serversScroll.Size = UDim2.new(1, -16, 1, -16)
serversScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
serversScroll.ScrollBarThickness = 4
serversScroll.AutomaticCanvasSize = Enum.AutomaticSize.None

local serversLayout = Instance.new("UIListLayout")
serversLayout.Parent = serversScroll
serversLayout.Padding = UDim.new(0, 6)
serversLayout.SortOrder = Enum.SortOrder.LayoutOrder

local settingsInfo = Instance.new("TextLabel")
settingsInfo.Parent = settingsPage
settingsInfo.BackgroundTransparency = 1
settingsInfo.Position = UDim2.new(0, 8, 0, 8)
settingsInfo.Size = UDim2.new(1, -16, 0, 40)
settingsInfo.Font = Enum.Font.Gotham
settingsInfo.TextSize = 12
settingsInfo.TextColor3 = Color3.fromRGB(180, 180, 190)
settingsInfo.TextXAlignment = Enum.TextXAlignment.Left
settingsInfo.TextWrapped = true
settingsInfo.Text = "Меняй порядок кнопками ▲ и ▼. 1 = самый высокий приоритет."

local settingsScroll = Instance.new("ScrollingFrame")
settingsScroll.Parent = settingsPage
settingsScroll.BackgroundTransparency = 1
settingsScroll.BorderSizePixel = 0
settingsScroll.Position = UDim2.new(0, 8, 0, 52)
settingsScroll.Size = UDim2.new(1, -16, 1, -60)
settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsScroll.ScrollBarThickness = 4
settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.None

local settingsLayout = Instance.new("UIListLayout")
settingsLayout.Parent = settingsScroll
settingsLayout.Padding = UDim.new(0, 6)
settingsLayout.SortOrder = Enum.SortOrder.LayoutOrder

local function setCollapsed(collapsed)
    ENV.BSS_UI_COLLAPSED = collapsed
    collapseButton.Text = collapsed and "+" or "—"

    statusLabel.Visible = not collapsed
    cooldownLabel.Visible = not collapsed
    trackerLabel.Visible = not collapsed
    hpLabel.Visible = not collapsed
    targetLabel.Visible = not collapsed
    tabBar.Visible = not collapsed
    contentHolder.Visible = not collapsed

    frame.Size = UDim2.new(0, 380, 0, collapsed and 44 or 530)
end

local function setActiveTab(tabName)
    ENV.BSS_ACTIVE_TAB = tabName

    local isServers = tabName == "Servers"
    serversPage.Visible = isServers
    settingsPage.Visible = not isServers

    serversTabButton.BackgroundColor3 = isServers and Color3.fromRGB(58, 87, 67) or Color3.fromRGB(35, 35, 42)
    settingsTabButton.BackgroundColor3 = not isServers and Color3.fromRGB(58, 87, 67) or Color3.fromRGB(35, 35, 42)
end

collapseButton.MouseButton1Click:Connect(function()
    setCollapsed(not ENV.BSS_UI_COLLAPSED)
end)

serversTabButton.MouseButton1Click:Connect(function()
    setActiveTab("Servers")
end)

settingsTabButton.MouseButton1Click:Connect(function()
    setActiveTab("Settings")
end)

setCollapsed(ENV.BSS_UI_COLLAPSED)
setActiveTab(ENV.BSS_ACTIVE_TAB)

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

local function updateTrackerUI(text, color)
    trackerLabel.Text = text
    if color then
        trackerLabel.TextColor3 = color
    end
end

local function updateHPUI()
    local sproutText = currentSproutHP and tostring(currentSproutHP) or "-"
    local viciousText = currentViciousHP and tostring(currentViciousHP) or "-"
    hpLabel.Text = "HP: Sprout " .. sproutText .. " | Vicious " .. viciousText
end

local function clearServerList()
    for _, child in ipairs(serversScroll:GetChildren()) do
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
        if shown > 14 then
            break
        end

        local item = Instance.new("Frame")
        item.Parent = serversScroll
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
        item.Parent = serversScroll
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
    serversScroll.CanvasSize = UDim2.new(0, 0, 0, serversLayout.AbsoluteContentSize.Y)
end

local function movePriority(index, direction)
    local newIndex = index + direction
    if newIndex < 1 or newIndex > #ENV.BSS_PRIORITY_ORDER then
        return
    end

    local tmp = ENV.BSS_PRIORITY_ORDER[index]
    ENV.BSS_PRIORITY_ORDER[index] = ENV.BSS_PRIORITY_ORDER[newIndex]
    ENV.BSS_PRIORITY_ORDER[newIndex] = tmp
end

local refreshSettingsList

refreshSettingsList = function()
    for _, child in ipairs(settingsScroll:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    for index, itemName in ipairs(ENV.BSS_PRIORITY_ORDER) do
        local row = Instance.new("Frame")
        row.Parent = settingsScroll
        row.Size = UDim2.new(1, 0, 0, 38)
        row.BackgroundColor3 = Color3.fromRGB(28, 28, 34)
        row.BorderSizePixel = 0
        row.LayoutOrder = index

        local rowCorner = Instance.new("UICorner")
        rowCorner.CornerRadius = UDim.new(0, 6)
        rowCorner.Parent = row

        local rankLabel = Instance.new("TextLabel")
        rankLabel.Parent = row
        rankLabel.BackgroundTransparency = 1
        rankLabel.Position = UDim2.new(0, 10, 0, 0)
        rankLabel.Size = UDim2.new(0, 28, 1, 0)
        rankLabel.Font = Enum.Font.GothamBold
        rankLabel.TextSize = 12
        rankLabel.TextColor3 = Color3.fromRGB(255, 255, 255)
        rankLabel.Text = tostring(index)

        local nameLabel = Instance.new("TextLabel")
        nameLabel.Parent = row
        nameLabel.BackgroundTransparency = 1
        nameLabel.Position = UDim2.new(0, 42, 0, 0)
        nameLabel.Size = UDim2.new(1, -120, 1, 0)
        nameLabel.Font = Enum.Font.Gotham
        nameLabel.TextSize = 12
        nameLabel.TextColor3 = Color3.fromRGB(235, 235, 240)
        nameLabel.TextXAlignment = Enum.TextXAlignment.Left
        nameLabel.Text = itemName

        local upButton = Instance.new("TextButton")
        upButton.Parent = row
        upButton.Size = UDim2.new(0, 28, 0, 24)
        upButton.Position = UDim2.new(1, -68, 0.5, -12)
        upButton.BackgroundColor3 = Color3.fromRGB(44, 65, 51)
        upButton.BorderSizePixel = 0
        upButton.Font = Enum.Font.GothamBold
        upButton.TextSize = 14
        upButton.TextColor3 = Color3.fromRGB(240, 240, 240)
        upButton.Text = "▲"

        local downButton = Instance.new("TextButton")
        downButton.Parent = row
        downButton.Size = UDim2.new(0, 28, 0, 24)
        downButton.Position = UDim2.new(1, -34, 0.5, -12)
        downButton.BackgroundColor3 = Color3.fromRGB(65, 44, 44)
        downButton.BorderSizePixel = 0
        downButton.Font = Enum.Font.GothamBold
        downButton.TextSize = 14
        downButton.TextColor3 = Color3.fromRGB(240, 240, 240)
        downButton.Text = "▼"

        for _, button in ipairs({upButton, downButton}) do
            local bc = Instance.new("UICorner")
            bc.CornerRadius = UDim.new(0, 6)
            bc.Parent = button
        end

        upButton.MouseButton1Click:Connect(function()
            movePriority(index, -1)
            refreshSettingsList()
        end)

        downButton.MouseButton1Click:Connect(function()
            movePriority(index, 1)
            refreshSettingsList()
        end)
    end

    task.wait()
    settingsScroll.CanvasSize = UDim2.new(0, 0, 0, settingsLayout.AbsoluteContentSize.Y)
end

local function getCurrentServerText()
    local currentType = ENV.BSS_CURRENT_SERVER_TYPE
    local currentRarity = ENV.BSS_CURRENT_SERVER_RARITY
    local currentField = ENV.BSS_CURRENT_SERVER_FIELD

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

local function disconnectViciousConn()
    if viciousConn then
        viciousConn:Disconnect()
        viciousConn = nil
    end
    if viciousHumanoidConn then
        viciousHumanoidConn:Disconnect()
        viciousHumanoidConn = nil
    end
end

local function getSproutHP(obj)
    if not obj then
        return nil
    end

    local guiPos = obj:FindFirstChild("GuiPos")
    if not guiPos then
        guiPos = obj:FindFirstChild("GuiPos", true)
    end
    if not guiPos then
        return nil
    end

    local label = guiPos:FindFirstChildWhichIsA("TextLabel", true)
    if not label then
        return nil
    end

    local text = tostring(label.Text or "")
    if text == "" then
        return nil
    end

    local digits = text:gsub("[^%d]", "")
    if digits == "" then
        return nil
    end

    return tonumber(digits)
end

local function isAliveSprout(obj)
    if not obj or obj.Parent == nil then
        return false
    end

    local sproutsFolder = workspace:FindFirstChild("Sprouts")
    if not sproutsFolder then
        return false
    end

    local exact = sproutsFolder:FindFirstChild("Sprout")
    if exact ~= obj then
        return false
    end

    local lowerName = tostring(obj.Name or ""):lower()
    if lowerName ~= "sprout" then
        return false
    end

    local hp = getSproutHP(obj)
    if not hp or hp <= 0 then
        return false
    end

    return true
end

local function findSproutInstance()
    local sproutsFolder = workspace:FindFirstChild("Sprouts")
    if not sproutsFolder then
        return nil
    end

    local exact = sproutsFolder:FindFirstChild("Sprout")
    if exact and isAliveSprout(exact) then
        return exact
    end

    return nil
end

local function bindTargetSprout()
    disconnectSproutConn()
    targetSprout = findSproutInstance()
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

local function getViciousHumanoid(obj)
    if not obj then
        return nil
    end

    if obj:IsA("Model") then
        return obj:FindFirstChildOfClass("Humanoid") or obj:FindFirstChild("Humanoid", true)
    end

    return nil
end

local function getViciousHP(obj)
    local humanoid = getViciousHumanoid(obj)
    if not humanoid then
        return nil
    end

    return math.floor(humanoid.Health + 0.5)
end

local function isAliveVicious(obj)
    if not obj or obj.Parent == nil then
        return false
    end

    local monsters = workspace:FindFirstChild("Monsters")
    if not monsters then
        return false
    end

    if obj.Parent ~= monsters then
        return false
    end

    local lowerName = tostring(obj.Name or ""):lower()
    if not lowerName:find("vicious bee") then
        return false
    end

    if not obj:IsA("Model") then
        return false
    end

    local humanoid = getViciousHumanoid(obj)
    if not humanoid then
        return false
    end

    if humanoid.Health <= 0 then
        return false
    end

    local root = obj.PrimaryPart or obj:FindFirstChild("HumanoidRootPart") or obj:FindFirstChildWhichIsA("BasePart", true)
    if not root then
        return false
    end

    return true
end

local function findViciousInstance()
    local monsters = workspace:FindFirstChild("Monsters")
    if not monsters then
        return nil
    end

    for _, child in ipairs(monsters:GetChildren()) do
        if isAliveVicious(child) then
            return child
        end
    end

    return nil
end

local function bindTargetVicious()
    disconnectViciousConn()
    targetVicious = findViciousInstance()
    viciousGoneAt = nil

    if targetVicious then
        local humanoid = getViciousHumanoid(targetVicious)

        viciousConn = targetVicious.AncestryChanged:Connect(function(_, parent)
            if parent == nil and not viciousGoneAt then
                viciousGoneAt = tick()
                disconnectViciousConn()
            end
        end)

        if humanoid then
            viciousHumanoidConn = humanoid.HealthChanged:Connect(function(health)
                currentViciousHP = math.floor(health + 0.5)
                updateHPUI()
                if health <= 0 and not viciousGoneAt then
                    viciousGoneAt = tick()
                    disconnectViciousConn()
                end
            end)
        end

        return true
    end

    return false
end

local function waitForSproutDespawn()
    log("SPROUT found, tracking alive state...")
    updateTrackerUI("🌱 Sprout найден: отслеживаю исчезновение...", Color3.fromRGB(120, 255, 120))

    local startedAt = tick()
    local lastHP = getSproutHP(targetSprout)
    currentSproutHP = lastHP
    updateHPUI()
    local lastHPChangeAt = tick()

    while true do
        if (tick() - startedAt) >= MAX_TRACK_TIME then
            log("SPROUT timeout reached, hopping next")
            updateTrackerUI("⚠️ Sprout timeout: переход дальше", Color3.fromRGB(255, 170, 90))
            currentSproutHP = nil
            updateHPUI()
            targetSprout = nil
            farmedAt = nil
            disconnectSproutConn()
            return "timeout"
        end

        if not isAliveSprout(targetSprout) then
            if not farmedAt then
                farmedAt = tick()
            end
            currentSproutHP = nil
            updateHPUI()
            targetSprout = nil
        else
            local hp = getSproutHP(targetSprout)
            currentSproutHP = hp
            updateHPUI()

            if hp and hp ~= lastHP then
                lastHP = hp
                lastHPChangeAt = tick()
            end

            if (tick() - lastHPChangeAt) >= MAX_HP_STUCK_TIME then
                log("SPROUT hp stuck reached, hopping next")
                updateTrackerUI("⚠️ Sprout HP не меняется 30 сек", Color3.fromRGB(255, 170, 90))
                currentSproutHP = nil
                updateHPUI()
                targetSprout = nil
                farmedAt = nil
                disconnectSproutConn()
                return "hp_stuck"
            end
        end

        if farmedAt then
            local elapsed = tick() - farmedAt
            local left = math.max(0, math.ceil(WAIT_AFTER_SPROUT_DESPAWN - elapsed))
            updateTrackerUI("⏳ После Sprout: " .. tostring(left) .. " сек", Color3.fromRGB(255, 210, 120))

            if elapsed > WAIT_AFTER_SPROUT_DESPAWN then
                break
            end
        elseif lastHP then
            local liveLeft = math.max(0, math.ceil(MAX_HP_STUCK_TIME - (tick() - lastHPChangeAt)))
            updateTrackerUI("🌱 Sprout HP: " .. tostring(lastHP) .. " | без изменений " .. tostring(liveLeft) .. " сек", Color3.fromRGB(120, 255, 120))
        end

        task.wait(0.2)
    end

    currentSproutHP = nil
    updateHPUI()
    targetSprout = nil
    farmedAt = nil
    disconnectSproutConn()
    return "done"
end

local function waitForViciousDespawn()
    log("VICIOUS found, tracking alive state...")
    updateTrackerUI("🐝 Vicious найден: отслеживаю исчезновение...", Color3.fromRGB(255, 160, 120))

    local startedAt = tick()
    local lastHP = getViciousHP(targetVicious)
    currentViciousHP = lastHP
    updateHPUI()
    local lastHPChangeAt = tick()

    while true do
        if (tick() - startedAt) >= MAX_TRACK_TIME then
            log("VICIOUS timeout reached, hopping next")
            updateTrackerUI("⚠️ Vicious timeout: переход дальше", Color3.fromRGB(255, 170, 90))
            currentViciousHP = nil
            updateHPUI()
            targetVicious = nil
            viciousGoneAt = nil
            disconnectViciousConn()
            return "timeout"
        end

        if not isAliveVicious(targetVicious) then
            if not viciousGoneAt then
                viciousGoneAt = tick()
            end
            currentViciousHP = nil
            updateHPUI()
            break
        else
            local hp = getViciousHP(targetVicious)
            currentViciousHP = hp
            updateHPUI()

            if hp and hp ~= lastHP then
                lastHP = hp
                lastHPChangeAt = tick()
            end

            if (tick() - lastHPChangeAt) >= MAX_HP_STUCK_TIME then
                log("VICIOUS hp stuck reached, hopping next")
                updateTrackerUI("⚠️ Vicious HP не меняется 30 сек", Color3.fromRGB(255, 170, 90))
                currentViciousHP = nil
                updateHPUI()
                targetVicious = nil
                viciousGoneAt = nil
                disconnectViciousConn()
                return "hp_stuck"
            end

            local liveLeft = math.max(0, math.ceil(MAX_HP_STUCK_TIME - (tick() - lastHPChangeAt)))
            updateTrackerUI("🐝 Vicious HP: " .. tostring(hp or "-") .. " | без изменений " .. tostring(liveLeft) .. " сек", Color3.fromRGB(255, 160, 120))
        end

        task.wait(0.2)
    end

    currentViciousHP = nil
    updateHPUI()
    targetVicious = nil
    viciousGoneAt = nil
    disconnectViciousConn()
    return "done"
end

local function invalidateCurrentServer()
    local currentJobId = game.JobId
    if currentJobId and currentJobId ~= "" then
        addVisited(currentJobId)
        pushRecent(currentJobId)
        ENV.BSS_IGNORE_CURRENT_JOB_ID = currentJobId
    end

    targetSprout = nil
    farmedAt = nil
    disconnectSproutConn()

    targetVicious = nil
    viciousGoneAt = nil
    disconnectViciousConn()

    currentSproutHP = nil
    currentViciousHP = nil
    updateHPUI()

    ENV.BSS_CURRENT_SERVER_TYPE = nil
    ENV.BSS_CURRENT_SERVER_RARITY = nil
    ENV.BSS_CURRENT_SERVER_FIELD = nil
    ENV.BSS_CURRENT_SERVER_JOB_ID = nil
    ENV.BSS_NEXT_TELEPORT_COOLDOWN = 0
    ENV.BSS_SERVER_JOIN_TIME = tick() - 60
end

local function applyServerIdentity(server)
    if isVicious(server) and server.gifted == true then
        ENV.BSS_CURRENT_SERVER_RARITY = "Gifted"
    else
        ENV.BSS_CURRENT_SERVER_RARITY = server.rarity
    end

    ENV.BSS_CURRENT_SERVER_TYPE = server.type
    ENV.BSS_CURRENT_SERVER_FIELD = server.field
    ENV.BSS_CURRENT_SERVER_JOB_ID = server.jobId
end

local function rollbackPendingTeleport(failedJobId)
    if failedJobId and failedJobId ~= "" then
        VISITED[failedJobId] = nil
        removeRecent(failedJobId)
    end

    if pendingTeleport then
        ENV.BSS_CURRENT_SERVER_TYPE = pendingTeleport.previousType
        ENV.BSS_CURRENT_SERVER_RARITY = pendingTeleport.previousRarity
        ENV.BSS_CURRENT_SERVER_FIELD = pendingTeleport.previousField
        ENV.BSS_CURRENT_SERVER_JOB_ID = pendingTeleport.previousJobId
        ENV.BSS_NEXT_TELEPORT_COOLDOWN = pendingTeleport.previousCooldown
        ENV.BSS_SERVER_JOIN_TIME = pendingTeleport.previousJoinTime
        ENV.BSS_IGNORE_CURRENT_JOB_ID = pendingTeleport.previousIgnoreJobId
        pendingTeleport = nil
    end
end

local function teleportToServer(best)
    local remaining = getRemainingSeconds(best)

    log("========== SELECTED ==========")
    log("Type:", best.type)
    log("Rarity:", best.rarity)
    log("Field:", best.field)
    log("Players:", best.playerCount)
    log("Gifted:", best.gifted)
    log("Level:", best.level)
    log("Priority:", getPriority(best))
    log("Remaining:", remaining == math.huge and "INF" or remaining)
    log("JobId:", best.jobId)
    log("==============================")

    pendingTeleport = {
        jobId = best.jobId,
        previousType = ENV.BSS_CURRENT_SERVER_TYPE,
        previousRarity = ENV.BSS_CURRENT_SERVER_RARITY,
        previousJobId = ENV.BSS_CURRENT_SERVER_JOB_ID,
        previousField = ENV.BSS_CURRENT_SERVER_FIELD,
        previousCooldown = ENV.BSS_NEXT_TELEPORT_COOLDOWN,
        previousJoinTime = ENV.BSS_SERVER_JOIN_TIME,
        previousIgnoreJobId = ENV.BSS_IGNORE_CURRENT_JOB_ID,
    }

    addVisited(best.jobId)
    pushRecent(best.jobId)
    applyServerIdentity(best)
    ENV.BSS_NEXT_TELEPORT_COOLDOWN = getCooldownForServer(best)
    ENV.BSS_SERVER_JOIN_TIME = tick()
    ENV.BSS_IGNORE_CURRENT_JOB_ID = nil

    targetSprout = nil
    farmedAt = nil
    disconnectSproutConn()

    targetVicious = nil
    viciousGoneAt = nil
    disconnectViciousConn()

    currentSproutHP = nil
    currentViciousHP = nil
    updateHPUI()

    local okTeleport, teleportError = pcall(function()
        TeleportService:TeleportToPlaceInstance(placeId, best.jobId, LocalPlayer)
    end)

    if not okTeleport then
        warnf("Teleport call failed:", tostring(teleportError))
        rollbackPendingTeleport(best.jobId)
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
    if tick() < worldReadyAt then
        updateTrackerUI("🌱 Ожидание загрузки мира...", Color3.fromRGB(180, 180, 200))
        return
    end

    isProcessingSpecial = true

    if bindTargetSprout() then
        updateTrackerUI("✅ На сервере есть реальный Sprout", Color3.fromRGB(100, 255, 100))
        local result = waitForSproutDespawn()

        if result == "timeout" or result == "hp_stuck" then
            invalidateCurrentServer()
            task.wait(0.2)
            if servers and #servers > 0 then
                teleportToNextBestServer(servers)
            end
            isProcessingSpecial = false
            return
        end

        updateTrackerUI("➡️ Переход на следующий сервер...", Color3.fromRGB(100, 255, 100))
        invalidateCurrentServer()
    else
        updateTrackerUI("❌ На сервере нет реального Sprout", Color3.fromRGB(255, 100, 100))
        invalidateCurrentServer()
        task.wait(0.2)
        if servers and #servers > 0 then
            teleportToNextBestServer(servers)
        end
    end

    isProcessingSpecial = false
end

local function processCurrentViciousServer(servers)
    if tick() < worldReadyAt then
        updateTrackerUI("🐝 Ожидание загрузки мира...", Color3.fromRGB(180, 180, 200))
        return
    end

    isProcessingSpecial = true

    if bindTargetVicious() then
        updateTrackerUI("✅ На сервере есть Vicious", Color3.fromRGB(255, 160, 120))
        local result = waitForViciousDespawn()

        if result == "timeout" or result == "hp_stuck" then
            invalidateCurrentServer()
            task.wait(0.2)
            if servers and #servers > 0 then
                teleportToNextBestServer(servers)
            end
            isProcessingSpecial = false
            return
        end

        updateTrackerUI("➡️ Vicious пропал, хоп...", Color3.fromRGB(255, 160, 120))
        invalidateCurrentServer()
        if servers and #servers > 0 then
            teleportToNextBestServer(servers)
        end
    else
        updateTrackerUI("❌ На сервере нет Vicious", Color3.fromRGB(255, 100, 100))
        invalidateCurrentServer()
        task.wait(0.2)
        if servers and #servers > 0 then
            teleportToNextBestServer(servers)
        end
    end

    isProcessingSpecial = false
end

TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage, _, jobId)
    if player ~= LocalPlayer then
        return
    end

    local failedJobId = jobId or (pendingTeleport and pendingTeleport.jobId)
    rollbackPendingTeleport(failedJobId)
    warnf("Teleport failed:", tostring(result), tostring(errorMessage or ""))
end)

ENV.checkCurrentSprout = function()
    local exists = findSproutInstance() ~= nil
    print("[MANUAL] real sprout exists =", exists)
    return exists
end

ENV.checkCurrentVicious = function()
    local exists = findViciousInstance() ~= nil
    print("[MANUAL] real vicious exists =", exists)
    return exists
end

ENV.setWaitAfterDespawn = function(seconds)
    seconds = tonumber(seconds) or 30
    WAIT_AFTER_SPROUT_DESPAWN = math.max(1, math.min(120, seconds))
    print("[SETTINGS] Wait after Sprout despawn set to", WAIT_AFTER_SPROUT_DESPAWN, "seconds")
    return WAIT_AFTER_SPROUT_DESPAWN
end

markCurrentServer()
refreshSettingsList()
updateHPUI()

log("=== AutoHop HP Watch ===")
log("If Sprout/Vicious HP does not change for 30 sec -> hop next server")
log("HP values are shown in menu")

while true do
    task.wait(CHECK_DELAY)

    if isProcessingSpecial then
        continue
    end

    local servers = fetchValidated()
    local hasCurrentServer = hydrateCurrentServerFromList(servers)

    local joinedAgo = tick() - ENV.BSS_SERVER_JOIN_TIME
    local dynamicCooldown = ENV.BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN

    if hasCurrentServer and ENV.BSS_CURRENT_SERVER_TYPE == "Sprout" then
        updateTopInfo(nil, false, joinedAgo, dynamicCooldown)
        updateServerList(servers, nil)
        processCurrentSproutServer(servers)
        continue
    end

    if hasCurrentServer and ENV.BSS_CURRENT_SERVER_TYPE == "Vicious" then
        updateTopInfo(nil, false, joinedAgo, dynamicCooldown)
        updateServerList(servers, nil)
        processCurrentViciousServer(servers)
        continue
    end

    currentSproutHP = nil
    currentViciousHP = nil
    updateHPUI()
    updateTrackerUI("Tracker: idle", Color3.fromRGB(150, 150, 160))

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
