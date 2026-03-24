local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local Players = game:GetService("Players")

local LocalPlayer = Players.LocalPlayer

-- БЕРЕМ ИЗ GENENV
local userId = getgenv().BSS_USER_ID
local secretKey = getgenv().BSS_SECRET_KEY

if not userId or not secretKey then
    warn("Missing USER_ID or SECRET_KEY")
    return
end

local placeId = game.PlaceId

local TELEPORT_COOLDOWN = 40
local CHECK_DELAY = 1
local MIN_SPROUT_SECONDS = 30
local MAX_PLAYERS = 4
local RECENT_LIMIT = 5

getgenv().BSS_VISITED_JOB_IDS = getgenv().BSS_VISITED_JOB_IDS or {}
getgenv().BSS_RECENT_JOB_IDS = getgenv().BSS_RECENT_JOB_IDS or {}
getgenv().BSS_SERVER_JOIN_TIME = getgenv().BSS_SERVER_JOIN_TIME or tick()

getgenv().BSS_CURRENT_SERVER_TYPE = getgenv().BSS_CURRENT_SERVER_TYPE or nil
getgenv().BSS_CURRENT_SERVER_RARITY = getgenv().BSS_CURRENT_SERVER_RARITY or nil
getgenv().BSS_NEXT_TELEPORT_COOLDOWN = getgenv().BSS_NEXT_TELEPORT_COOLDOWN or TELEPORT_COOLDOWN

local VISITED = getgenv().BSS_VISITED_JOB_IDS
local RECENT = getgenv().BSS_RECENT_JOB_IDS

-- UI
local gui = Instance.new("ScreenGui", game.CoreGui)
gui.Name = "BSS_UI"

local frame = Instance.new("Frame", gui)
frame.Size = UDim2.new(0, 260, 0, 320)
frame.Position = UDim2.new(0, 10, 0.5, -160)
frame.BackgroundColor3 = Color3.fromRGB(20,20,20)
frame.BorderSizePixel = 0

local listLayout = Instance.new("UIListLayout", frame)
listLayout.Padding = UDim.new(0, 4)

local function clearUI()
    for _, v in pairs(frame:GetChildren()) do
        if v:IsA("TextLabel") then
            v:Destroy()
        end
    end
end

local function addLabel(text)
    local label = Instance.new("TextLabel")
    label.Size = UDim2.new(1, 0, 0, 24)
    label.BackgroundTransparency = 1
    label.TextColor3 = Color3.fromRGB(255,255,255)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.Font = Enum.Font.Gotham
    label.TextSize = 12
    label.Text = text
    label.Parent = frame
end

-- LOGIC

local function isSprout(server)
    return tostring(server.type or "") == "Sprout"
end

local function isVicious(server)
    return tostring(server.type or "") == "Vicious"
end

local function getRemainingSeconds(server)
    if not server.expiryAt then return math.huge end
    return tonumber(server.expiryAt) - os.time()
end

-- ПРИОРИТЕТЫ
local function getPriority(server)
    local r = tostring(server.rarity or "")

    if isSprout(server) and r == "Supreme" then return 100 end
    if isSprout(server) and r == "Legendary" then return 90 end
    if isSprout(server) and r == "Festive" then return 85 end
    if isVicious(server) and server.gifted then return 80 end
    if isSprout(server) and r == "Gummy" then return 70 end
    if isSprout(server) and r == "Epic" then return 60 end
    if isVicious(server) then return 50 end
    if isSprout(server) and r == "Rare" then return 40 end

    return 0
end

-- КУЛДАУНЫ
local function getCooldownForServer(server)
    if isSprout(server) and server.rarity == "Supreme" then return 60 end
    if isSprout(server) and server.rarity == "Legendary" then return 55 end
    if isVicious(server) and server.gifted then return 45 end
    if isVicious(server) then return 40 end
    return 50
end

-- ФОРС ТЕЛЕПОРТ
local function shouldForceTeleport(best)
    if not best then return false end

    local ct = getgenv().BSS_CURRENT_SERVER_TYPE
    local cr = getgenv().BSS_CURRENT_SERVER_RARITY

    local low =
        (ct == "Sprout" and (cr == "Rare" or cr == "Epic")) or
        (ct == "Vicious")

    local high =
        (isSprout(best) and (best.rarity == "Supreme" or best.rarity == "Legendary"))

    return low and high
end

local function isInRecent(jobId)
    for _, v in ipairs(RECENT) do
        if v == jobId then return true end
    end
    return false
end

local function pushRecent(jobId)
    for i = #RECENT,1,-1 do
        if RECENT[i] == jobId then table.remove(RECENT,i) end
    end
    table.insert(RECENT,1,jobId)
    while #RECENT > RECENT_LIMIT do
        table.remove(RECENT,#RECENT)
    end
end

local function markCurrentServer()
    local id = game.JobId
    if id and id ~= "" then
        VISITED[id] = true
        pushRecent(id)
    end
end

local function hasTooManyPlayers(server)
    return (tonumber(server.playerCount) or 0) > MAX_PLAYERS
end

local function isValidServer(server)
    if not server.jobId then return false end
    if server.jobId == game.JobId then return false end
    if VISITED[server.jobId] then return false end
    if isInRecent(server.jobId) then return false end
    if hasTooManyPlayers(server) then return false end

    if isSprout(server) then
        local rem = getRemainingSeconds(server)
        if rem <= 0 or rem < MIN_SPROUT_SECONDS then return false end
    end

    return getPriority(server) > 0
end

local function fetchValidated()
    local res = request({
        Url = ("https://bss-tools.com/api/workspaces/%s/validated"):format(userId),
        Method = "GET",
        Headers = {["secret-key"] = secretKey}
    })

    if not res or res.StatusCode ~= 200 then return {} end

    local ok,data = pcall(function()
        return HttpService:JSONDecode(res.Body)
    end)

    return ok and data.results or {}
end

local function isBetterServer(a,b)
    if not a then return false end
    if not b then return true end

    local ap = getPriority(a)
    local bp = getPriority(b)

    if ap ~= bp then return ap > bp end

    if isSprout(a) and isSprout(b) then
        return getRemainingSeconds(a) < getRemainingSeconds(b)
    end

    if isVicious(a) and isVicious(b) then
        return (tonumber(a.level) or 0) > (tonumber(b.level) or 0)
    end

    return (tonumber(a.playerCount) or 999) < (tonumber(b.playerCount) or 999)
end

local function pickBestServer(servers)
    local best=nil
    for _,s in ipairs(servers) do
        if isValidServer(s) then
            if isBetterServer(s,best) then
                best=s
            end
        end
    end
    return best
end

markCurrentServer()

while true do
    task.wait(CHECK_DELAY)

    local servers = fetchValidated()
    local best = pickBestServer(servers)

    -- UI
    clearUI()
    for i,s in ipairs(servers) do
        if i > 10 then break end
        addLabel(string.format("%s %s | %d | P:%d",
            s.type or "?",
            s.rarity or "?",
            s.playerCount or 0,
            getPriority(s)
        ))
    end

    local joinedAgo = tick() - getgenv().BSS_SERVER_JOIN_TIME
    local cooldown = getgenv().BSS_NEXT_TELEPORT_COOLDOWN

    if not shouldForceTeleport(best) and joinedAgo < cooldown then
        continue
    end

    if best then
        VISITED[best.jobId] = true
        pushRecent(best.jobId)

        getgenv().BSS_CURRENT_SERVER_TYPE = best.type
        getgenv().BSS_CURRENT_SERVER_RARITY = best.rarity
        getgenv().BSS_NEXT_TELEPORT_COOLDOWN = getCooldownForServer(best)
        getgenv().BSS_SERVER_JOIN_TIME = tick()

        TeleportService:TeleportToPlaceInstance(placeId, best.jobId, LocalPlayer)
    end
end
