local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")
local CoreGui = game:GetService("CoreGui")
local UserInputService = game:GetService("UserInputService")

local LocalPlayer = Players.LocalPlayer

local userId = getgenv().BSS_USER_ID
local secretKey = getgenv().BSS_SECRET_KEY

if not userId or not secretKey then
    warn("Missing USER_ID or SECRET_KEY")
    return
end

local placeId = game.PlaceId

local TELEPORT_COOLDOWN = 55
local CHECK_DELAY = 1
local MIN_SPROUT_SECONDS = 40
local MAX_PLAYERS = 4
local RECENT_LIMIT = 5
local VISITED_LIMIT = 100

getgenv().BSS_VISITED_JOB_IDS = getgenv().BSS_VISITED_JOB_IDS or {}
getgenv().BSS_RECENT_JOB_IDS = getgenv().BSS_RECENT_JOB_IDS or {}
getgenv().BSS_SERVER_JOIN_TIME = getgenv().BSS_SERVER_JOIN_TIME or tick()

getgenv().BSS_CURRENT_SERVER_TYPE = getgenv().BSS_CURRENT_SERVER_TYPE or nil
getgenv().BSS_CURRENT_SERVER_RARITY = getgenv().BSS_CURRENT_SERVER_RARITY or nil
getgenv().BSS_NEXT_TELEPORT_COOLDOWN = getgenv().BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN
getgenv().BSS_UI_COLLAPSED = getgenv().BSS_UI_COLLAPSED or false
getgenv().BSS_CURRENT_SERVER_JOB_ID = getgenv().BSS_CURRENT_SERVER_JOB_ID or game.JobId
getgenv().BSS_CURRENT_SERVER_FIELD = getgenv().BSS_CURRENT_SERVER_FIELD or nil

local VISITED = getgenv().BSS_VISITED_JOB_IDS
local RECENT = getgenv().BSS_RECENT_JOB_IDS
local pendingTeleport = nil

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
    elseif isSprout(server) and rarity == "Festive" then
        return 85
    elseif isVicious(server) and server.gifted == true then
        return 80
    elseif isSprout(server) and rarity == "Gummy" then
        return 70
    elseif isSprout(server) and rarity == "Epic" then
        return 60
    elseif isVicious(server) then
        return 50
    elseif isSprout(server) and rarity == "Rare" then
        return 40
    end

    return 0
end

local function getCooldownForServer(server)
    if isSprout(server) and server.rarity == "Supreme" then
        return 60
    elseif isSprout(server) and server.rarity == "Legendary" then
        return 55
    elseif isVicious(server) and server.gifted == true then
        return 45
    elseif isVicious(server) then
        return 40
    end

    return 50
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
        warn("API request failed")
        return {}
    end

    if not res or res.StatusCode ~= 200 then
        warn("API error:", res and res.Body or "no response")
        return {}
    end

    local ok, data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)

    if not ok or not data then
        warn("JSON decode error")
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
frame.Size = UDim2.new(0, 340, 0, getgenv().BSS_UI_COLLAPSED and 44 or 420)
frame.Position = UDim2.new(1, -355, 0.5, getgenv().BSS_UI_COLLAPSED and -22 or -210)
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

local targetLabel = Instance.new("TextLabel")
targetLabel.Parent = frame
targetLabel.BackgroundTransparency = 1
targetLabel.Position = UDim2.new(0, 14, 0, 98)
targetLabel.Size = UDim2.new(1, -28, 0, 38)
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
listHeader.Position = UDim2.new(0, 14, 0, 142)
listHeader.Size = UDim2.new(1, -28, 0, 20)
listHeader.Font = Enum.Font.GothamBold
listHeader.TextSize = 13
listHeader.TextColor3 = Color3.fromRGB(255, 255, 255)
listHeader.TextXAlignment = Enum.TextXAlignment.Left
listHeader.Text = "Servers"

local listContainer = Instance.new("Frame")
listContainer.Parent = frame
listContainer.Position = UDim2.new(0, 12, 0, 168)
listContainer.Size = UDim2.new(1, -24, 1, -180)
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
    targetLabel.Visible = not collapsed
    listHeader.Visible = not collapsed
    listContainer.Visible = not collapsed

    frame.Size = UDim2.new(0, 340, 0, collapsed and 44 or 420)
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
        shown = shown + 1
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
        return string.format("Current: %s | Field: %s", currentName, tostring(currentField))
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
        elseif isVicious(best) then
            extra = " | Level: " .. tostring(best.level or "?")
            if best.gifted then
                extra = extra .. " | Gifted"
            end
        end

        targetLabel.Text = string.format(
            "%s\nNext server: %s | Field: %s | Players: %s%s",
            getCurrentServerText(),
            nameText,
            tostring(best.field or "?"),
            tostring(best.playerCount or "?"),
            extra
        )
    else
        targetLabel.Text = getCurrentServerText()
    end
end

TeleportService.TeleportInitFailed:Connect(function(player, result, errorMessage, placeIdValue, jobId)
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
        pendingTeleport = nil
    end

    warn("Teleport failed:", tostring(result), tostring(errorMessage or ""))
end)

markCurrentServer()

while true do
    task.wait(CHECK_DELAY)

    local servers = fetchValidated()
    local best = pickBestServer(servers)

    local joinedAgo = tick() - getgenv().BSS_SERVER_JOIN_TIME
    local dynamicCooldown = getgenv().BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN
    local force = shouldForceTeleport(best)

    updateTopInfo(best, force, joinedAgo, dynamicCooldown)
    updateServerList(servers, best)

    if not force and joinedAgo < dynamicCooldown then
        print("[JOIN COOLDOWN]", math.ceil(dynamicCooldown - joinedAgo), "sec left")
        continue
    end

    if best then
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
        }

        addVisited(best.jobId)
        pushRecent(best.jobId)

        if isVicious(best) and best.gifted == true then
            getgenv().BSS_CURRENT_SERVER_RARITY = "Gifted"
        else
            getgenv().BSS_CURRENT_SERVER_RARITY = best.rarity
        end

        getgenv().BSS_CURRENT_SERVER_TYPE = best.type
        getgenv().BSS_CURRENT_SERVER_FIELD = best.field
        getgenv().BSS_CURRENT_SERVER_JOB_ID = best.jobId
        getgenv().BSS_NEXT_TELEPORT_COOLDOWN = getCooldownForServer(best)
        getgenv().BSS_SERVER_JOIN_TIME = tick()

        local okTeleport, teleportError = pcall(function()
            TeleportService:TeleportToPlaceInstance(placeId, best.jobId, LocalPlayer)
        end)

        if not okTeleport then
            warn("Teleport call failed:", tostring(teleportError))
            VISITED[best.jobId] = nil
            removeRecent(best.jobId)

            if pendingTeleport then
                getgenv().BSS_CURRENT_SERVER_TYPE = pendingTeleport.previousType
                getgenv().BSS_CURRENT_SERVER_RARITY = pendingTeleport.previousRarity
                getgenv().BSS_CURRENT_SERVER_FIELD = pendingTeleport.previousField
                getgenv().BSS_CURRENT_SERVER_JOB_ID = pendingTeleport.previousJobId
                getgenv().BSS_NEXT_TELEPORT_COOLDOWN = pendingTeleport.previousCooldown
                getgenv().BSS_SERVER_JOIN_TIME = pendingTeleport.previousJoinTime
                pendingTeleport = nil
            end
        else
            task.wait(3)
        end
    else
        print("[SCAN] Нет подходящих validated серверов")
    end
end
