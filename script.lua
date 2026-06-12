-- [[ XENON HUB ]] --
-- GUI в неоновом xenon-стиле
-- Работает на Delta Executor

print("[XENON]: Загрузка...")

-- Очистка предыдущих экземпляров
if getgenv().FoxHub_Cleanup then
    pcall(getgenv().FoxHub_Cleanup)
end

local cleanupTasks = {}
getgenv().FoxHub_Cleanup = function()
    for _, taskItem in pairs(cleanupTasks) do
        pcall(function()
            if typeof(taskItem) == "RBXScriptConnection" then
                taskItem:Disconnect()
            elseif taskItem and typeof(taskItem) == "thread" then
                task.cancel(taskItem)
            elseif taskItem and taskItem.Parent then
                taskItem:Destroy()
            end
        end)
    end
    table.clear(cleanupTasks)
end

-- Сервисы
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui")

-- Конфигурация
getgenv().FoxHub_Config = {
    HL_ENABLED = true,
    GEN_ESP = true,
    AutoGen = true,
    AutoHeal = true,
    AutoParry = true,
    SpeedBoostEnabled = true,
    SpeedValue = 22,
    FastVaultEnabled = false,
    AutoPalletEnabled = true,
    AutoUnhookEnabled = true,
    AutoExitGateEnabled = true,
    AntiStunEnabled = true,
    FlyPlatformEnabled = false,
    AntiBodyblockEnabled = false,
    DelayMin = 0.15,
    DelayMax = 0.25,
    
    -- Киллер
    ForceKillerRole = false,  -- принудительно считать себя киллером (если автоопределение не работает)
    HitboxExpanderEnabled = false,
    HitboxSize = 10,
    NoCooldownEnabled = false,
    AutoSwingAttackEnabled = false,
    InstantHitDetectionEnabled = false,
    AttackRangeExpanderEnabled = false,
    LungePredictorEnabled = false,
    GuaranteedHitSystemEnabled = false,
    AttackRangeMultiplier = 1.5,
    LungePredictionDistance = 20,
    InstinctRevealEnabled = false,
    InstantPalletBreakEnabled = false,
    StalkerInstantTier3Enabled = false,
    MaskedAutoPowerEnabled = false,
    HiddenAutoLeapEnabled = false,

    -- Майкл Майерс
    InstantTier3Enabled = false,
    InfiniteTier3Enabled = false,
    AutoStalkEnabled = false,
    WallhackStalkEnabled = false,
    
    -- Выживший
    AutoFlashlightBlindEnabled = false,
    FlashlightBlindDistance = 15,
    FlashlightBlindDelay = 0.2,
    HookESP = true,
    ExitGateESP = true,
    HitStarsEnabled = true,
    AttackRangeCircleEnabled = true,
    DangerPulseEnabled = true,
    GeneratorRepairEffectsEnabled = true,
    AutoPalletStunEnabled = false,
    GodModeEnabled = false,
    AutoSelfHealEnabled = false,
    AutoItemUseEnabled = false,

    -- Новые функции
    FlyEnabled = false,
    FlySpeed = 50,
    NoClipEnabled = false,
    FlingEnabled = false,
    FlingPower = 5000,
    InfiniteStaminaEnabled = false,

    -- Камера / ESP
    FOVEnabled = false,
    FOVValue = 90,
    CameraUnlockEnabled = false,
    TracersEnabled = false,
    HealthBarsEnabled = false
}
local Config = getgenv().FoxHub_Config

-- Ремоуты
local Remotes = ReplicatedStorage:WaitForChild("Remotes", 5)
if not Remotes then
    warn("[XENON]: Remotes не найдены!")
    return
end

-- ========================
-- ВЫЗОВ АТАКИ (реальный протокол игры, снято снифером)
-- Клиент НЕ передаёт цель — сервер сам определяет попадание по позиции
-- и направлению киллера. Команда удара: BasicAttack:FireServer(true)
-- ========================
local function fireAttack()
    local Attacks = Remotes:FindFirstChild("Attacks")
    if not Attacks then return end

    local basic = Attacks:FindFirstChild("BasicAttack")
    if basic then
        pcall(function() basic:FireServer(true) end)
    end
end

-- Рывок киллера (Lunge) — тоже без аргументов
local function fireLunge()
    local Attacks = Remotes:FindFirstChild("Attacks")
    if not Attacks then return end
    local lunge = Attacks:FindFirstChild("Lunge")
    if lunge then
        pcall(function() lunge:FireServer() end)
    end
end

-- Переменные
local playerData = {}
local genProgress = {}
local gens = {}
local cachedPallets = {}
local cachedLevers = {}
local cachedHooks = {}
local droppedPalletsDebounce = {}
local searchedModels = {}
local myConnections = {}
local playerHighlights = {}
local platformPart = nil
local platformHeightOffset = -3.25
local originalHitboxSizes = {}
local cachedKillers = {}
local cachedSwingSounds = {}
local cachedTrails = {}

local COLORS = {
    Killer   = Color3.fromRGB(255, 30, 30),
    Survivor = Color3.fromRGB(30, 180, 255),
    Unknown  = Color3.fromRGB(160, 160, 160),
}

-- Определение киллера
local function isCharacterKiller(char)
    if not char then return false end
    
    for _, tag in ipairs({"KillerData", "KillerStats", "PowerBar", "Stunned", "Damage"}) do
        if char:FindFirstChild(tag, true) then
            return true
        end
    end
    
    if char:GetAttribute("Role") == "Killer" or char:GetAttribute("IsKiller") == true then
        return true
    end
    
    for _, child in ipairs(char:GetChildren()) do
        if child:IsA("Tool") then
            local name = child.Name:lower()
            if name:find("knife") or name:find("machete") or name:find("blade") or name:find("axe") then
                return true
            end
        end
    end
    
    return false
end

-- Роли
local function setRole(player, role)
    if not (player and player:IsA("Player")) then return end
    playerData[player.UserId] = playerData[player.UserId] or {}
    
    local currentRole = playerData[player.UserId].role
    if currentRole ~= role then
        playerData[player.UserId].role = role
        local hl = playerHighlights[player]
        if hl and hl.Parent then
            hl.FillColor = COLORS[role] or COLORS.Unknown
        end
    end
end

local function getRole(player)
    if not player then return "Survivor" end

    -- Ручной оверрайд для себя: если автоопределение роли не срабатывает
    if player == localPlayer and Config.ForceKillerRole then
        return "Killer"
    end

    playerData[player.UserId] = playerData[player.UserId] or {}
    local cachedRole = playerData[player.UserId].role
    if cachedRole then return cachedRole end
    
    if player.Team then
        local t = player.Team.Name:lower()
        if t:find("kill") or t:find("jason") or t:find("hunter") then 
            setRole(player, "Killer")
            return "Killer"
        elseif t:find("surv") or t:find("player") then 
            setRole(player, "Survivor")
            return "Survivor" 
        end
    end
    
    local char = player.Character
    if char and isCharacterKiller(char) then
        setRole(player, "Killer")
        return "Killer"
    end
    
    return "Survivor"
end

local function getColor(player) return COLORS[getRole(player)] or COLORS.Unknown end

-- NAMECALL HOOK

if not getgenv().FoxHub_Hooked then
    getgenv().FoxHub_Hooked = true

    local oldNamecall
    oldNamecall = hookmetamethod(game, "__namecall", function(self, ...)
        local method = getnamecallmethod()
        local args = {...}
        local activeConfig = getgenv().FoxHub_Config

        if activeConfig and method == "FireServer" and self then
            local name = self.Name
            local parent = self.Parent
            local p2 = parent and parent.Parent
            
            if p2 and p2.Name == "Remotes" then
                local folderName = parent.Name

                -- Auto Skillcheck (РЕАЛЬНЫЙ протокол этой игры):
                -- результат скилл-чека идёт 2-м аргументом RepairEvent/HealEvent
                -- (boolean: true = попал, false = промах). Подменяем промах на попадание.
                -- Трогаем ТОЛЬКО явный boolean false — иначе ничего не меняем (безопасно).
                if name == "RepairEvent" and folderName == "Generator" and activeConfig.AutoGen then
                    if args[2] == false then
                        args[2] = true
                        return oldNamecall(self, unpack(args))
                    end
                elseif name == "HealEvent" and folderName == "Healing" and activeConfig.AutoHeal then
                    if args[2] == false then
                        args[2] = true
                        return oldNamecall(self, unpack(args))
                    end
                end

                -- Fast Vault - ИСПРАВЛЕНО
                if folderName == "Window" then
                    local vaultRemap = {
                        VaultEvent = true,
                        ["VaultEvent-jason"] = true,
                        VaultAnim = true,
                        ["VaultAnim-jason"] = true,
                        VaultCommit = true,
                        VaultCompleteEvent = true,
                        VaultCompleteEventpart1 = true,
                    }

                    if vaultRemap[name] and activeConfig.FastVaultEnabled then
                        local fastVault = parent:FindFirstChild("fastvault")
                        if fastVault then
                            local survivorFastVault = parent:FindFirstChild("SurvivorFastVault")
                            local vaultBindable = parent:FindFirstChild("Vaultbindable")

                            if survivorFastVault then pcall(function() survivorFastVault:Fire() end) end
                            if vaultBindable then pcall(function() vaultBindable:Fire() end) end
                            pcall(function()
                                fastVault:FireServer(unpack(args))
                            end)
                        end
                    end
                end
            end
            
            -- No Cooldown
            if activeConfig.NoCooldownEnabled and name == "AfterAttack" then
                return nil
            end
        end

        return oldNamecall(self, ...)
    end)
end

-- Не отключаем штатные игровые connections: они нужны для prompt/interact UI.

-- Сниффинг ролей
pcall(function()
    local conn1 = Remotes:WaitForChild("Round").OnClientEvent:Connect(function(a, b, c)
        if typeof(a) == "Instance" and a:IsA("Player") then
            setRole(a, "Killer")
            if typeof(b) == "table" then
                for _, p in pairs(b) do if typeof(p) == "Instance" and p:IsA("Player") then setRole(p, "Survivor") end end
            end
        elseif typeof(a) == "string" and typeof(b) == "Instance" and b:IsA("Player") then
            setRole(b, "Killer")
            if typeof(c) == "table" then for _, p in pairs(c) do setRole(p, "Survivor") end end
        end
    end)
    table.insert(cleanupTasks, conn1)

    local conn2 = Remotes.Carry:WaitForChild("CarrySurvivorEvent").OnClientEvent:Connect(function(a, b)
        if typeof(a) == "Instance" and a:IsA("Player") then setRole(a, "Killer") end
        if typeof(b) == "Instance" and b:IsA("Player") then setRole(b, "Survivor") end
    end)
    table.insert(cleanupTasks, conn2)

    local conn3 = Remotes.Progress:WaitForChild("ProgressUpdateEvent").OnClientEvent:Connect(function(gen, progress)
        if gen and type(progress) == "number" then genProgress[gen] = progress end
    end)
    table.insert(cleanupTasks, conn3)

    local conn4 = Remotes.Generator:WaitForChild("RepairVFX").OnClientEvent:Connect(function(gen, progress)
        if gen and type(progress) == "number" then genProgress[gen] = progress end
    end)
    table.insert(cleanupTasks, conn4)

    local conn5 = Remotes.Generator:WaitForChild("RepairEvent").OnClientEvent:Connect(function(a, gen, progress)
        if typeof(a) == "Instance" and a:IsA("Player") then setRole(a, "Survivor") end
        if gen and type(progress) == "number" then genProgress[gen] = progress end
    end)
    table.insert(cleanupTasks, conn5)
end)

-- Кэширование киллеров
local cacheLoop = task.spawn(function()
    while true do
        task.wait(1)
        
        table.clear(cachedKillers)
        table.clear(cachedSwingSounds)
        table.clear(cachedTrails)
        
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= localPlayer then
                local role = getRole(p)
                if role == "Killer" and p.Character then
                    table.insert(cachedKillers, p.Character)
                end
            end
        end
        
        for _, obj in ipairs(workspace:GetChildren()) do
            if obj:IsA("Model") and obj ~= localPlayer.Character then
                if isCharacterKiller(obj) then
                    local alreadyCached = false
                    for _, cached in ipairs(cachedKillers) do
                        if cached == obj then alreadyCached = true; break end
                    end
                    if not alreadyCached then
                        table.insert(cachedKillers, obj)
                    end
                end
            end
        end
        
        for _, kChar in ipairs(cachedKillers) do
            if kChar and kChar.Parent then
                for _, desc in ipairs(kChar:GetDescendants()) do
                    if desc:IsA("Sound") then
                        local sn = desc.Name:lower()
                        if sn:find("swing") or sn:find("slash") or sn:find("attack") or sn:find("whoosh") then
                            table.insert(cachedSwingSounds, desc)
                        end
                    elseif desc:IsA("Trail") then
                        table.insert(cachedTrails, desc)
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, cacheLoop)

-- AUTO PARRY - ИСПРАВЛЕНО
local lastParryTime = 0
local parryDebounce = 0.22
local parryRemotes = {}
local lastParryRemoteRefresh = 0
local parryRemoteRefreshInterval = 1.5
local parryThreatAttributes = {
    "Attack",
    "Attacking",
    "Slash",
    "Lunge",
    "Swing",
    "InAttack",
    "AttackCooldown",
    "AfterAttack",
    "Active",
}

local function addParryRemote(container, remoteName)
    local remote = container and container:FindFirstChild(remoteName)
    if remote and (remote:IsA("RemoteEvent") or remote:IsA("RemoteFunction") or remote:IsA("BindableEvent")) then
        table.insert(parryRemotes, remote)
    end
end

local function refreshParryRemotes()
    lastParryRemoteRefresh = tick()
    table.clear(parryRemotes)

    local items = Remotes:FindFirstChild("Items")
    local parryingDagger = items and items:FindFirstChild("Parrying Dagger")
    addParryRemote(parryingDagger, "parry")

    if #parryRemotes == 0 then
        local mechanics = Remotes:FindFirstChild("Mechanics")
        addParryRemote(mechanics, "parriedclient")
        addParryRemote(mechanics, "Parriedbindable")
    end

    if #parryRemotes == 0 then
        warn("[XENON]: Auto Parry remotes не найдены")
    end
end

local function fireParryRemote(remote)
    if not (remote and remote.Parent) then return end

    if remote:IsA("RemoteEvent") then
        remote:FireServer()
    elseif remote:IsA("RemoteFunction") then
        remote:InvokeServer()
    elseif remote:IsA("BindableEvent") then
        remote:Fire()
    end
end

local function getWorldPosition(obj)
    if not obj then return nil end

    if obj:IsA("BasePart") then
        return obj.Position
    elseif obj:IsA("Attachment") then
        return obj.WorldPosition
    elseif obj:IsA("Model") then
        return obj:GetPivot().Position
    end

    local parent = obj.Parent
    while parent and parent ~= workspace do
        if parent:IsA("BasePart") then
            return parent.Position
        elseif parent:IsA("Attachment") then
            return parent.WorldPosition
        elseif parent:IsA("Model") then
            return parent:GetPivot().Position
        end
        parent = parent.Parent
    end

    return nil
end

local function isDescendantOf(child, ancestor)
    while child do
        if child == ancestor then
            return true
        end
        child = child.Parent
    end
    return false
end

local function isParryBlocked(myChar)
    if not myChar then return true end

    local hum = myChar:FindFirstChildOfClass("Humanoid")
    if hum and hum.Health <= 0 then
        return true
    end

    for _, attr in ipairs({"Vaulting", "Unhooking", "Carrying", "Hooked", "IsHooked"}) do
        if myChar:GetAttribute(attr) then
            return true
        end
    end

    return false
end

local function killerHasThreatAttribute(killerChar)
    for _, attr in ipairs(parryThreatAttributes) do
        local value = killerChar:GetAttribute(attr)
        if value == true then
            return true
        end
        if type(value) == "number" and value > 0 then
            return true
        end
    end
    return false
end

local function hasKillerSwingCue(myRoot, killerChar)
    for _, sound in ipairs(cachedSwingSounds) do
        if sound and sound.Parent and sound.Playing and isDescendantOf(sound, killerChar) then
            local soundPos = getWorldPosition(sound)
            if soundPos and (soundPos - myRoot.Position).Magnitude <= 24 then
                return true
            end
        end
    end
    return false
end

local function hasKillerTrailCue(myRoot, killerChar)
    for _, trail in ipairs(cachedTrails) do
        if trail and trail.Parent and trail.Enabled and isDescendantOf(trail, killerChar) then
            local trailPos = getWorldPosition(trail)
            if trailPos and (trailPos - myRoot.Position).Magnitude <= 24 then
                return true
            end
        end
    end
    return false
end

local function shouldAutoParryKiller(myRoot, killerChar)
    if not (killerChar and killerChar.Parent) then return false end

    local kRoot = killerChar:FindFirstChild("HumanoidRootPart")
    if not kRoot then return false end

    local offset = myRoot.Position - kRoot.Position
    local dist = offset.Magnitude
    if dist > 24 or dist <= 0.05 then
        return false
    end

    local score = 0
    local strongSignal = false

    if dist <= 16 then
        score = score + 1
    end
    if dist <= 10 then
        score = score + 1
    end

    local toMe = offset.Unit
    local relativeVelocity = (kRoot.AssemblyLinearVelocity - myRoot.AssemblyLinearVelocity)
    local speedTowardsMe = relativeVelocity:Dot(toMe)
    if speedTowardsMe > 4 then
        score = score + 1
    end
    if speedTowardsMe > 10 and dist <= 16 then
        strongSignal = true
    end

    local hasThreatAttribute = killerHasThreatAttribute(killerChar)
    if hasThreatAttribute then
        score = score + 2
        if dist <= 18 then
            strongSignal = true
        end
    end

    local hasSwingCue = hasKillerSwingCue(myRoot, killerChar)
    if hasSwingCue then
        score = score + 2
        strongSignal = true
    end

    local hasTrailCue = hasKillerTrailCue(myRoot, killerChar)
    if hasTrailCue then
        score = score + 1
        if dist <= 14 and speedTowardsMe > 2 then
            strongSignal = true
        end
    end

    -- Надёжный сигнал по позициям (не зависит от угаданных атрибутов):
    -- киллер близко и смотрит на меня → парируем
    if dist <= 12 then
        local kLook = kRoot.CFrame.LookVector
        local towardMe = (myRoot.Position - kRoot.Position).Unit
        if kLook:Dot(towardMe) > 0.5 then
            strongSignal = true
        end
    end

    return strongSignal or score >= 2
end

local function triggerAutoParryDirect()
    local myChar = localPlayer.Character
    if isParryBlocked(myChar) then return end

    local currentTime = tick()
    if currentTime - lastParryTime < parryDebounce then return end
    lastParryTime = currentTime
    
    pcall(function()
        if #parryRemotes == 0 then
            refreshParryRemotes()
        end

        for i = #parryRemotes, 1, -1 do
            local remote = parryRemotes[i]
            if remote and remote.Parent then
                pcall(fireParryRemote, remote)
            else
                table.remove(parryRemotes, i)
            end
        end
    end)
end

local parryRadarConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoParry then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot or isParryBlocked(myChar) then return end

    if #parryRemotes == 0 or tick() - lastParryRemoteRefresh >= parryRemoteRefreshInterval then
        refreshParryRemotes()
    end

    for _, killerChar in ipairs(cachedKillers) do
        if killerChar ~= myChar and shouldAutoParryKiller(myRoot, killerChar) then
            triggerAutoParryDirect()
            return
        end
    end
end)
table.insert(cleanupTasks, parryRadarConn)

-- SPEED BOOST
local speedConnection = RunService.Heartbeat:Connect(function()
    if Config.SpeedBoostEnabled and localPlayer.Character then
        local hum = localPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then 
            hum.WalkSpeed = Config.SpeedValue 
        end
    end
end)
table.insert(cleanupTasks, speedConnection)

local function disableSpeed()
    if localPlayer.Character then
        local hum = localPlayer.Character:FindFirstChildOfClass("Humanoid")
        if hum then hum.WalkSpeed = 16 end
    end
end

-- NO COOLDOWN
local lastCdReset = 0
local cdResetDebounce = 0.05
local attackCdConn = RunService.Heartbeat:Connect(function()
    local myChar = localPlayer.Character
    local isKiller = (getRole(localPlayer) == "Killer")
    
    if Config.NoCooldownEnabled and isKiller and myChar then
        local now = tick()
        if now - lastCdReset < cdResetDebounce then return end
        lastCdReset = now
        
        local myRoot = myChar:FindFirstChild("HumanoidRootPart")
        if not myRoot then return end
        
        for _, attr in ipairs({"Cooldown", "Attacking", "Attack", "Slash", "Lunge", "Active", "Slow", "Slowed", "Swing", "AttackCooldown", "AfterAttack", "InAttack"}) do
            if myChar:GetAttribute(attr) then
                myChar:SetAttribute(attr, false)
            end
        end
        
        local humanoid = myChar:FindFirstChildOfClass("Humanoid")
        if humanoid then
            humanoid.WalkSpeed = Config.SpeedValue or 22
        end
        
        pcall(function()
            local mechanics = Remotes:FindFirstChild("Mechanics")
            if mechanics then
                local cancelaction = mechanics:FindFirstChild("cancelaction")
                if cancelaction then
                    cancelaction:FireServer()
                end
                
                local resetbloodlust = mechanics:FindFirstChild("resetbloodlustremote")
                if resetbloodlust then
                    resetbloodlust:FireServer()
                end
            end
        end)
        
        pcall(function()
            local attacks = Remotes:FindFirstChild("Attacks")
            if attacks then
                local afterAttack = attacks:FindFirstChild("AfterAttack")
                if afterAttack then
                    afterAttack:FireServer()
                end
            end
        end)
    end
end)
table.insert(cleanupTasks, attackCdConn)

-- HITBOX EXPANDER - ИСПРАВЛЕНО
local hitboxConn = RunService.Heartbeat:Connect(function()
    local isKiller = (getRole(localPlayer) == "Killer")
    
    if Config.HitboxExpanderEnabled and isKiller then
        local myChar = localPlayer.Character
        if not myChar then return end
        local myRoot = myChar:FindFirstChild("HumanoidRootPart")
        if not myRoot then return end
        
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
                local char = p.Character
                local pRoot = char:FindFirstChild("HumanoidRootPart")
                
                if pRoot then
                    local dist = (myRoot.Position - pRoot.Position).Magnitude
                    
                    -- Увеличиваем хитбоксы
                    for _, partName in ipairs({"HumanoidRootPart", "Torso", "LowerTorso", "UpperTorso", "Head", "LeftUpperArm", "RightUpperArm", "LeftLowerArm", "RightLowerArm"}) do
                        local part = char:FindFirstChild(partName)
                        if part then
                            if not originalHitboxSizes[part] then
                                originalHitboxSizes[part] = part.Size
                            end
                            
                            -- Увеличиваем размер
                            local expandedSize = originalHitboxSizes[part] * Config.AttackRangeMultiplier
                            part.Size = expandedSize
                            part.CanCollide = false
                            
                            -- Делаем прозрачным для визуализации
                            if partName == "HumanoidRootPart" then
                                part.Transparency = 0.5
                            end
                        end
                    end
                    
                    -- Отправляем хит-события если киллер близко
                    if dist <= 20 then
                        task.spawn(function()
                            fireAttack()
                        end)
                    end
                end
            end
        end
    else
        for part, originalSize in pairs(originalHitboxSizes) do
            pcall(function()
                if part and part.Parent then
                    part.Size = originalSize
                    part.CanCollide = true
                    if part.Name == "HumanoidRootPart" then
                        part.Transparency = 1
                    end
                end
            end)
            originalHitboxSizes[part] = nil
        end
    end
end)
table.insert(cleanupTasks, hitboxConn)

-- ========================

-- ========================
-- CHILL HUB STYLE GUI v12 update
-- ========================
local screenGui = Instance.new("ScreenGui")
screenGui.Name = "XenonGUI"
screenGui.ResetOnSpawn = false
screenGui.IgnoreGuiInset = true
screenGui.DisplayOrder = 999999
screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

-- Надёжный парентинг: gethui() -> CoreGui -> PlayerGui (фолбэк)
local function parentGui(gui)
    local ok = pcall(function()
        if syn and syn.protect_gui then
            syn.protect_gui(gui)
        elseif protect_gui then
            protect_gui(gui)
        end
    end)
    local target
    if gethui then
        local g = pcall(gethui)
        if g then target = gethui() end
    end
    if not target then
        local ok2, cg = pcall(function() return game:GetService("CoreGui") end)
        if ok2 and cg then target = cg end
    end
    if not target then target = playerGui end
    local ok3 = pcall(function() gui.Parent = target end)
    if not ok3 then
        pcall(function() gui.Parent = playerGui end)
    end
end
parentGui(screenGui)
table.insert(cleanupTasks, screenGui)

do
local Theme = {
    Base = Color3.fromRGB(7, 10, 14),
    Panel = Color3.fromRGB(12, 17, 23),
    Panel2 = Color3.fromRGB(16, 22, 30),
    Sidebar = Color3.fromRGB(9, 13, 18),
    Card = Color3.fromRGB(16, 23, 31),
    CardHover = Color3.fromRGB(22, 33, 44),
    Stroke = Color3.fromRGB(34, 70, 80),
    Text = Color3.fromRGB(232, 246, 250),
    Muted = Color3.fromRGB(118, 142, 152),
    Accent = Color3.fromRGB(0, 224, 200),
    Accent2 = Color3.fromRGB(0, 150, 190),
    AccentDim = Color3.fromRGB(10, 46, 52),
    On = Color3.fromRGB(48, 230, 180),
    Danger = Color3.fromRGB(255, 70, 110),
    Off = Color3.fromRGB(30, 40, 48),
}

local ACCENT_LIGHT = Color3.fromRGB(110, 248, 230)

local function addCorner(parent, radius)
    local corner = Instance.new("UICorner", parent)
    corner.CornerRadius = UDim.new(0, radius)
    return corner
end

local function addStroke(parent, color, thickness, transparency)
    local stroke = Instance.new("UIStroke", parent)
    stroke.Color = color
    stroke.Thickness = thickness
    stroke.Transparency = transparency or 0
    return stroke
end

local function addGradient(parent, color1, color2, rotation)
    local gradient = Instance.new("UIGradient", parent)
    gradient.Color = ColorSequence.new(color1, color2)
    gradient.Rotation = rotation or 0
    return gradient
end

local function addPadding(parent, all)
    local pad = Instance.new("UIPadding", parent)
    pad.PaddingTop = UDim.new(0, all)
    pad.PaddingBottom = UDim.new(0, all)
    pad.PaddingLeft = UDim.new(0, all)
    pad.PaddingRight = UDim.new(0, all)
    return pad
end

local TWEEN_FAST = TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local function tween(obj, props, info)
    local t = TweenService:Create(obj, info or TWEEN_FAST, props)
    t:Play()
    return t
end

-- Короткие описания функций (для детализации GUI)
local featureDescriptions = {
    ["Highlight ESP"] = "Подсветка игроков сквозь стены",
    ["Generator ESP"] = "Подсветка всех генераторов",
    ["Auto Skillcheck"] = "Авто-прохождение скилл-чеков",
    ["Speed Boost"] = "Ускорение передвижения",
    ["Speed"] = "Значение скорости движения",
    ["Auto Parry"] = "Авто-парирование атак киллера",
    ["Fast Vault"] = "Мгновенный перепрыг окон",
    ["Auto Pallet Drop"] = "Авто-сброс досок при опасности",
    ["Auto Unhook"] = "Авто-снятие союзников с крюка",
    ["Auto Exit Gate"] = "Авто-открытие ворот выхода",
    ["Anti-Stun"] = "Игнор оглушения",
    ["Anti-Bodyblock"] = "Проход сквозь блокирующих",
    ["Auto Flashlight Blind"] = "Авто-ослепление киллера фонарём",
    ["Infinite Stamina"] = "Бесконечная выносливость",
    ["Auto Pallet Stun"] = "Сброс доски на киллера для оглушения",
    ["God Mode"] = "Держит состояние здоров (рискованно)",
    ["Auto Self-Heal"] = "Авто-лечение когда ранен",
    ["Auto Item Use"] = "Авто-использование предмета при киллере",
    ["Force Killer Role"] = "Считать себя киллером (если функции не активны)",
    ["Hitbox Expander"] = "Увеличение зоны попадания",
    ["Hitbox Size"] = "Размер расширенного хитбокса",
    ["No Cooldown"] = "Сброс задержек способностей",
    ["Auto Swing Attack"] = "Авто-удары по выжившим",
    ["Instant Hit Detection"] = "Мгновенная регистрация попаданий",
    ["Attack Range Expander"] = "Увеличение дальности атаки",
    ["Lunge Predictor"] = "Предсказание рывка",
    ["Guaranteed Hit System"] = "Гарантированное попадание",
    ["Instinct Reveal"] = "Подсветка выживших сквозь стены",
    ["Instant Pallet Break"] = "Мгновенный слом упавших досок",
    ["Stalker Instant Tier 3"] = "Мгновенный сталк (Сталкер)",
    ["Masked Auto Power"] = "Авто-активация способности (Masked)",
    ["Hidden Auto Leap"] = "Авто-прыжок на выжившего (Hidden)",
    ["Instant Tier 3"] = "Мгновенный 3-й тир Майерса",
    ["Infinite Tier 3"] = "Бесконечный 3-й тир",
    ["Auto Stalk"] = "Авто-накопление стелса",
    ["Wallhack Stalk"] = "Сталк сквозь стены",
    ["Fly Platform"] = "Невидимая платформа-полёт",
    ["Hook ESP"] = "Подсветка крюков",
    ["Exit Gate ESP"] = "Подсветка ворот выхода",
    ["Hit Stars"] = "Звёзды при попадании",
    ["Attack Range Circle"] = "Круг радиуса атаки",
    ["Danger Pulse"] = "Пульсация при близости киллера",
    ["Generator Effects"] = "Визуал ремонта генераторов",
    ["Fly"] = "Свободный полёт",
    ["Fly Speed"] = "Скорость полёта",
    ["NoClip"] = "Проход сквозь объекты",
    ["Fling"] = "Отбрасывание игроков",
    ["Fling Power"] = "Сила отбрасывания",
    ["FOV"] = "Расширенный угол обзора",
    ["FOV Value"] = "Значение угла обзора",
    ["Camera Unlock"] = "Свободное отдаление камеры",
    ["Tracers"] = "Линии до игроков",
    ["Health Bars"] = "Полоса здоровья над выжившими",
}

local featureIcons = {
    ["Highlight ESP"] = "◆",
    ["Generator ESP"] = "⚡",
    ["Auto Skillcheck"] = "✔",
    ["Speed Boost"] = "»",
    ["Auto Parry"] = "✦",
    ["Fast Vault"] = "↯",
    ["Auto Pallet Drop"] = "▰",
    ["Auto Unhook"] = "⊕",
    ["Auto Exit Gate"] = "⇥",
    ["Anti-Stun"] = "◇",
    ["Anti-Bodyblock"] = "◌",
    ["Auto Flashlight Blind"] = "☀",
    ["Infinite Stamina"] = "∞",
    ["Auto Pallet Stun"] = "▭",
    ["God Mode"] = "✝",
    ["Auto Self-Heal"] = "✚",
    ["Auto Item Use"] = "⚒",
    ["Force Killer Role"] = "☠",
    ["Hitbox Expander"] = "⬢",
    ["No Cooldown"] = "⌁",
    ["Auto Swing Attack"] = "⚔",
    ["Instant Hit Detection"] = "◎",
    ["Attack Range Expander"] = "⌖",
    ["Lunge Predictor"] = "➤",
    ["Guaranteed Hit System"] = "✹",
    ["Instinct Reveal"] = "◉",
    ["Instant Pallet Break"] = "✲",
    ["Stalker Instant Tier 3"] = "Ⅲ",
    ["Masked Auto Power"] = "◭",
    ["Hidden Auto Leap"] = "⤢",
    ["Instant Tier 3"] = "Ⅲ",
    ["Infinite Tier 3"] = "∞",
    ["Auto Stalk"] = "◉",
    ["Wallhack Stalk"] = "◈",
    ["Fly Platform"] = "▣",
    ["Hook ESP"] = "⛓",
    ["Exit Gate ESP"] = "⇥",
    ["Hit Stars"] = "✦",
    ["Attack Range Circle"] = "◎",
    ["Danger Pulse"] = "!",
    ["Generator Effects"] = "✺",
    ["Fly"] = "↑",
    ["NoClip"] = "◇",
    ["Fling"] = "✧",
    ["FOV"] = "◎",
    ["Camera Unlock"] = "⊙",
    ["Tracers"] = "↗",
    ["Health Bars"] = "❤",
}

local tabIcons = {
    Main = "✧",
    Survivor = "◇",
    Killer = "⬢",
    Myers = "◉",
    Visual = "✦",
    Misc = "⌁",
}

-- ГЛАВНЫЙ ФРЕЙМ
local mainFrame = Instance.new("Frame", screenGui)
mainFrame.Name = "MainFrame"
mainFrame.Size = UDim2.new(0, 640, 0, 448)
mainFrame.Position = UDim2.new(0.5, -320, 0.5, -224)
mainFrame.BackgroundColor3 = Theme.Base
mainFrame.BackgroundTransparency = 0.04
mainFrame.BorderSizePixel = 0
mainFrame.Active = true
mainFrame.Draggable = true
mainFrame.ClipsDescendants = true

addCorner(mainFrame, 18)
addGradient(mainFrame, Color3.fromRGB(42, 46, 52), Color3.fromRGB(14, 16, 20), 125)
local mainStroke = addStroke(mainFrame, Theme.Accent, 1.5, 0.45)

-- Внешнее неоновое свечение (следует за панелью при перетаскивании/масштабе)
local glow = Instance.new("ImageLabel")
glow.Name = "OuterGlow"
glow.BackgroundTransparency = 1
glow.Image = "rbxassetid://6014261993"
glow.ImageColor3 = Theme.Accent
glow.ImageTransparency = 0.55
glow.ScaleType = Enum.ScaleType.Slice
glow.SliceCenter = Rect.new(49, 49, 450, 450)
glow.ZIndex = 0
glow.Parent = screenGui
local function syncGlow()
    local pad = 36
    glow.Size = UDim2.fromOffset(mainFrame.AbsoluteSize.X + pad * 2, mainFrame.AbsoluteSize.Y + pad * 2)
    glow.Position = UDim2.fromOffset(mainFrame.AbsolutePosition.X - pad, mainFrame.AbsolutePosition.Y - pad)
end
mainFrame:GetPropertyChangedSignal("AbsolutePosition"):Connect(syncGlow)
mainFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(syncGlow)
mainFrame:GetPropertyChangedSignal("Visible"):Connect(function() glow.Visible = mainFrame.Visible end)
task.defer(syncGlow)
table.insert(cleanupTasks, glow)

local guiScale = Instance.new("UIScale", mainFrame)
guiScale.Name = "FoxHubScale"
guiScale.Scale = 0.92
table.insert(cleanupTasks, guiScale)

-- Верхняя акцентная линия
local topAccent = Instance.new("Frame", mainFrame)
topAccent.Name = "TopAccent"
topAccent.Size = UDim2.new(1, 0, 0, 3)
topAccent.Position = UDim2.new(0, 0, 0, 0)
topAccent.BackgroundColor3 = Theme.Accent
topAccent.BorderSizePixel = 0
local topGrad = Instance.new("UIGradient", topAccent)
topGrad.Color = ColorSequence.new({
    ColorSequenceKeypoint.new(0, Theme.Accent2),
    ColorSequenceKeypoint.new(0.5, ACCENT_LIGHT),
    ColorSequenceKeypoint.new(1, Theme.Accent2),
})

-- Мягкое акцентное свечение в углу
local glassShard = Instance.new("Frame", mainFrame)
glassShard.Name = "GlowBlob"
glassShard.Size = UDim2.new(0, 220, 0, 220)
glassShard.Position = UDim2.new(1, -150, 0, -110)
glassShard.BackgroundColor3 = Theme.Accent
glassShard.BackgroundTransparency = 0.86
glassShard.BorderSizePixel = 0
glassShard.Rotation = 30
addCorner(glassShard, 110)
addGradient(glassShard, Theme.Accent, Color3.fromRGB(10, 10, 14), 90)

-- ===== Декоративная анимированная катана (сталь) =====
local katana = Instance.new("Frame", mainFrame)
katana.Name = "Katana"
katana.AnchorPoint = Vector2.new(0.5, 0.5)
katana.Size = UDim2.new(0, 150, 0, 18)
katana.Position = UDim2.new(1, -118, 0, 30)
katana.BackgroundTransparency = 1
katana.Rotation = -20
katana.ZIndex = 2

-- Навершие (касира)
local kPommel = Instance.new("Frame", katana)
kPommel.Size = UDim2.new(0, 7, 0, 12)
kPommel.Position = UDim2.new(0, 0, 0.5, -6)
kPommel.BackgroundColor3 = Color3.fromRGB(54, 58, 66)
kPommel.BorderSizePixel = 0
kPommel.ZIndex = 2
addCorner(kPommel, 3)

-- Рукоять (цука)
local kHandle = Instance.new("Frame", katana)
kHandle.Size = UDim2.new(0, 40, 0, 9)
kHandle.Position = UDim2.new(0, 7, 0.5, -4.5)
kHandle.BackgroundColor3 = Color3.fromRGB(26, 28, 33)
kHandle.BorderSizePixel = 0
kHandle.ZIndex = 2
addCorner(kHandle, 4)
addStroke(kHandle, Color3.fromRGB(70, 74, 82), 1, 0.4)

-- Гарда (цуба)
local kGuard = Instance.new("Frame", katana)
kGuard.Size = UDim2.new(0, 7, 0, 18)
kGuard.Position = UDim2.new(0, 47, 0.5, -9)
kGuard.BackgroundColor3 = Color3.fromRGB(150, 140, 90)
kGuard.BorderSizePixel = 0
kGuard.ZIndex = 2
addCorner(kGuard, 2)
addGradient(kGuard, Color3.fromRGB(205, 188, 120), Color3.fromRGB(120, 108, 68), 90)

-- Клинок
local kBlade = Instance.new("Frame", katana)
kBlade.Size = UDim2.new(0, 86, 0, 8)
kBlade.Position = UDim2.new(0, 55, 0.5, -4)
kBlade.BackgroundColor3 = Color3.fromRGB(225, 232, 240)
kBlade.BorderSizePixel = 0
kBlade.ClipsDescendants = true
kBlade.ZIndex = 2
addCorner(kBlade, 3)
addGradient(kBlade, Color3.fromRGB(248, 251, 255), Color3.fromRGB(120, 130, 145), 90)

-- Остриё (ромб-скос на конце клинка)
local kTip = Instance.new("Frame", katana)
kTip.Size = UDim2.new(0, 11, 0, 11)
kTip.AnchorPoint = Vector2.new(0.5, 0.5)
kTip.Position = UDim2.new(0, 143, 0.5, 0)
kTip.Rotation = 45
kTip.BackgroundColor3 = Color3.fromRGB(238, 243, 250)
kTip.BorderSizePixel = 0
kTip.ZIndex = 2
addCorner(kTip, 2)

-- Бегущий блик по клинку
local kSheen = Instance.new("Frame", kBlade)
kSheen.Size = UDim2.new(0, 10, 1, 0)
kSheen.Position = UDim2.new(0, -12, 0, 0)
kSheen.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
kSheen.BackgroundTransparency = 1
kSheen.BorderSizePixel = 0
kSheen.ZIndex = 3

-- HEADER (титульная полоса)
local header = Instance.new("Frame", mainFrame)
header.Name = "Header"
header.Size = UDim2.new(1, 0, 0, 56)
header.Position = UDim2.new(0, 0, 0, 3)
header.BackgroundColor3 = Theme.Panel
header.BackgroundTransparency = 0.25
header.BorderSizePixel = 0
addGradient(header, Color3.fromRGB(36, 40, 46), Color3.fromRGB(18, 20, 24), 0)

-- Разделитель под шапкой
local headerLine = Instance.new("Frame", mainFrame)
headerLine.Name = "HeaderLine"
headerLine.Size = UDim2.new(1, -24, 0, 1)
headerLine.Position = UDim2.new(0, 12, 0, 59)
headerLine.BackgroundColor3 = Theme.Stroke
headerLine.BackgroundTransparency = 0.4
headerLine.BorderSizePixel = 0

-- LOGO BADGE
local logoBadge = Instance.new("TextLabel", header)
logoBadge.Name = "LogoBadge"
logoBadge.Size = UDim2.new(0, 36, 0, 36)
logoBadge.Position = UDim2.new(0, 16, 0.5, -18)
logoBadge.BackgroundColor3 = Theme.Accent
logoBadge.BorderSizePixel = 0
logoBadge.Font = Enum.Font.GothamBold
logoBadge.Text = "X"
logoBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
logoBadge.TextSize = 19
addCorner(logoBadge, 11)
addGradient(logoBadge, ACCENT_LIGHT, Theme.Accent2, 115)
addStroke(logoBadge, ACCENT_LIGHT, 1, 0.4)

-- TITLE
local title = Instance.new("TextLabel", header)
title.Size = UDim2.new(0, 220, 0, 22)
title.Position = UDim2.new(0, 62, 0, 9)
title.BackgroundTransparency = 1
title.Font = Enum.Font.GothamBlack
title.Text = "XENON"
title.TextColor3 = Color3.fromRGB(255, 255, 255)
title.TextSize = 19
title.TextXAlignment = Enum.TextXAlignment.Left
addGradient(title, ACCENT_LIGHT, Theme.Accent, 18)

-- SUBTITLE
local subtitle = Instance.new("TextLabel", header)
subtitle.Size = UDim2.new(0, 220, 0, 14)
subtitle.Position = UDim2.new(0, 62, 0, 31)
subtitle.BackgroundTransparency = 1
subtitle.Font = Enum.Font.Gotham
subtitle.Text = "Neon Hub · DBD"
subtitle.TextColor3 = Theme.Muted
subtitle.TextSize = 11
subtitle.TextXAlignment = Enum.TextXAlignment.Left

-- VERSION PILL
local version = Instance.new("TextLabel", header)
version.Name = "VersionPill"
version.Size = UDim2.new(0, 78, 0, 20)
version.Position = UDim2.new(0, 250, 0.5, -10)
version.BackgroundColor3 = Theme.AccentDim
version.Font = Enum.Font.GothamSemibold
version.Text = "v1.0"
version.TextColor3 = ACCENT_LIGHT
version.TextSize = 11
addCorner(version, 9)
addStroke(version, Theme.Accent, 1, 0.55)

-- CLOSE BUTTON
local closeBtn = Instance.new("TextButton", header)
closeBtn.Size = UDim2.new(0, 32, 0, 32)
closeBtn.Position = UDim2.new(1, -44, 0.5, -16)
closeBtn.BackgroundColor3 = Theme.Danger
closeBtn.Text = "✕"
closeBtn.Font = Enum.Font.GothamBold
closeBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
closeBtn.TextSize = 15
closeBtn.BorderSizePixel = 0
closeBtn.AutoButtonColor = false
addCorner(closeBtn, 9)
addStroke(closeBtn, Color3.fromRGB(255, 160, 170), 1, 0.5)

local scaleDownBtn = Instance.new("TextButton", header)
scaleDownBtn.Size = UDim2.new(0, 32, 0, 32)
scaleDownBtn.Position = UDim2.new(1, -120, 0.5, -16)
scaleDownBtn.BackgroundColor3 = Theme.Card
scaleDownBtn.Text = "−"
scaleDownBtn.Font = Enum.Font.GothamBold
scaleDownBtn.TextColor3 = Theme.Text
scaleDownBtn.TextSize = 18
scaleDownBtn.BorderSizePixel = 0
scaleDownBtn.AutoButtonColor = false
addCorner(scaleDownBtn, 9)
addStroke(scaleDownBtn, Theme.Stroke, 1, 0.5)

local scaleUpBtn = Instance.new("TextButton", header)
scaleUpBtn.Size = UDim2.new(0, 32, 0, 32)
scaleUpBtn.Position = UDim2.new(1, -82, 0.5, -16)
scaleUpBtn.BackgroundColor3 = Theme.Card
scaleUpBtn.Text = "+"
scaleUpBtn.Font = Enum.Font.GothamBold
scaleUpBtn.TextColor3 = Theme.Text
scaleUpBtn.TextSize = 16
scaleUpBtn.BorderSizePixel = 0
scaleUpBtn.AutoButtonColor = false
addCorner(scaleUpBtn, 9)
addStroke(scaleUpBtn, Theme.Stroke, 1, 0.5)

-- Ховер-эффекты кнопок шапки
for _, b in ipairs({closeBtn, scaleDownBtn, scaleUpBtn}) do
    local base = b.BackgroundColor3
    b.MouseEnter:Connect(function() tween(b, {BackgroundColor3 = base:Lerp(Color3.new(1,1,1), 0.18)}) end)
    b.MouseLeave:Connect(function() tween(b, {BackgroundColor3 = base}) end)
end

local function setGuiScale(nextScale)
    guiScale.Scale = math.clamp(nextScale, 0.65, 1.2)
end

scaleDownBtn.MouseButton1Click:Connect(function()
    setGuiScale(guiScale.Scale - 0.08)
end)

scaleUpBtn.MouseButton1Click:Connect(function()
    setGuiScale(guiScale.Scale + 0.08)
end)

-- SIDEBAR (левая панель с вкладками)
local sidebar = Instance.new("Frame", mainFrame)
sidebar.Name = "Sidebar"
sidebar.Size = UDim2.new(0, 150, 1, -116)
sidebar.Position = UDim2.new(0, 12, 0, 68)
sidebar.BackgroundColor3 = Theme.Sidebar
sidebar.BackgroundTransparency = 0.25
sidebar.BorderSizePixel = 0
addCorner(sidebar, 14)
addStroke(sidebar, Theme.Stroke, 1, 0.6)
addGradient(sidebar, Color3.fromRGB(28, 31, 36), Color3.fromRGB(12, 14, 17), 90)

local sidebarTitle = Instance.new("TextLabel", sidebar)
sidebarTitle.Size = UDim2.new(1, -20, 0, 16)
sidebarTitle.Position = UDim2.new(0, 14, 0, 10)
sidebarTitle.BackgroundTransparency = 1
sidebarTitle.Font = Enum.Font.GothamBold
sidebarTitle.Text = "МЕНЮ"
sidebarTitle.TextColor3 = Theme.Muted
sidebarTitle.TextSize = 10
sidebarTitle.TextXAlignment = Enum.TextXAlignment.Left

-- TAB CONTAINER (вертикальный)
local tabContainer = Instance.new("Frame", sidebar)
tabContainer.Name = "TabContainer"
tabContainer.Size = UDim2.new(1, -16, 1, -38)
tabContainer.Position = UDim2.new(0, 8, 0, 32)
tabContainer.BackgroundTransparency = 1

local tabLayout = Instance.new("UIListLayout", tabContainer)
tabLayout.FillDirection = Enum.FillDirection.Vertical
tabLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
tabLayout.Padding = UDim.new(0, 6)

-- CONTENT FRAME (правая область)
local contentFrame = Instance.new("Frame", mainFrame)
contentFrame.Name = "ContentFrame"
contentFrame.Size = UDim2.new(1, -186, 1, -116)
contentFrame.Position = UDim2.new(0, 174, 0, 68)
contentFrame.BackgroundTransparency = 1

-- SCROLL FRAME
local scrollFrame = Instance.new("ScrollingFrame", contentFrame)
scrollFrame.Size = UDim2.new(1, 0, 1, 0)
scrollFrame.BackgroundTransparency = 1
scrollFrame.BorderSizePixel = 0
scrollFrame.ScrollBarThickness = 4
scrollFrame.ScrollBarImageColor3 = Theme.Accent
scrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)

local scrollLayout = Instance.new("UIListLayout", scrollFrame)
scrollLayout.Padding = UDim.new(0, 8)
scrollLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

scrollLayout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(function()
    scrollFrame.CanvasSize = UDim2.new(0, 0, 0, scrollLayout.AbsoluteContentSize.Y + 12)
end)

-- FOOTER (нижняя плашка с инфо)
local footer = Instance.new("Frame", mainFrame)
footer.Name = "Footer"
footer.Size = UDim2.new(1, -24, 0, 32)
footer.Position = UDim2.new(0, 12, 1, -42)
footer.BackgroundColor3 = Theme.Panel
footer.BackgroundTransparency = 0.3
footer.BorderSizePixel = 0
addCorner(footer, 10)
addStroke(footer, Theme.Stroke, 1, 0.65)

local footerDot = Instance.new("Frame", footer)
footerDot.Size = UDim2.new(0, 8, 0, 8)
footerDot.Position = UDim2.new(0, 12, 0.5, -4)
footerDot.BackgroundColor3 = Theme.On
footerDot.BorderSizePixel = 0
addCorner(footerDot, 4)

local footerInfo = Instance.new("TextLabel", footer)
footerInfo.Name = "FooterInfo"
footerInfo.Size = UDim2.new(1, -110, 1, 0)
footerInfo.Position = UDim2.new(0, 28, 0, 0)
footerInfo.BackgroundTransparency = 1
footerInfo.Font = Enum.Font.GothamSemibold
footerInfo.Text = localPlayer.Name
footerInfo.TextColor3 = Theme.Text
footerInfo.TextSize = 11
footerInfo.TextXAlignment = Enum.TextXAlignment.Left

local footerHint = Instance.new("TextLabel", footer)
footerHint.Size = UDim2.new(0, 90, 1, 0)
footerHint.Position = UDim2.new(1, -100, 0, 0)
footerHint.BackgroundTransparency = 1
footerHint.Font = Enum.Font.Gotham
footerHint.Text = "XENON"
footerHint.TextColor3 = Theme.Muted
footerHint.TextSize = 10
footerHint.TextXAlignment = Enum.TextXAlignment.Right

-- Обновление футера (роль + число игроков)
local footerThread = task.spawn(function()
    while true do
        local ok = pcall(function()
            local role = getRole(localPlayer) or "?"
            footerInfo.Text = localPlayer.Name .. "  ·  " .. tostring(role)
            footerHint.Text = "👥 " .. tostring(#Players:GetPlayers())
        end)
        task.wait(1.5)
    end
end)
table.insert(cleanupTasks, footerThread)

-- SHOW BUTTON (когда GUI скрыт)
local showBtn = Instance.new("TextButton", screenGui)
showBtn.Size = UDim2.new(0, 56, 0, 56)
showBtn.Position = UDim2.new(0.02, 0, 0.5, -28)
showBtn.BackgroundColor3 = Theme.Accent
showBtn.Text = "X"
showBtn.Font = Enum.Font.GothamBold
showBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
showBtn.TextSize = 26
showBtn.Visible = false
showBtn.BorderSizePixel = 0
showBtn.Active = true
showBtn.Draggable = true
showBtn.AutoButtonColor = false
addCorner(showBtn, 16)
addStroke(showBtn, ACCENT_LIGHT, 2, 0.2)
addGradient(showBtn, ACCENT_LIGHT, Theme.Accent2, 120)

-- EVENTS
closeBtn.MouseButton1Click:Connect(function()
    local savedScale = guiScale.Scale
    local t = tween(guiScale, {Scale = savedScale * 0.8}, TweenInfo.new(0.16, Enum.EasingStyle.Quad, Enum.EasingDirection.In))
    t.Completed:Connect(function()
        mainFrame.Visible = false
        guiScale.Scale = savedScale
        showBtn.Visible = true
    end)
end)

showBtn.MouseButton1Click:Connect(function()
    showBtn.Visible = false
    mainFrame.Visible = true
    local target = guiScale.Scale
    guiScale.Scale = target * 0.8
    tween(guiScale, {Scale = target}, TweenInfo.new(0.42, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
end)

-- CURRENT TAB
local currentTab = "Main"
local tabButtons = {}
local tabContents = {}

-- Применить визуальное состояние вкладки
local function styleTab(btn, active)
    local labelObj = btn:FindFirstChild("TabLabel")
    local iconObj = btn:FindFirstChild("TabIcon")
    local barObj = btn:FindFirstChild("ActiveBar")
    local strokeObj = btn:FindFirstChildOfClass("UIStroke")
    if active then
        tween(btn, {BackgroundColor3 = Theme.AccentDim, BackgroundTransparency = 0.15})
        if labelObj then labelObj.TextColor3 = Theme.Text end
        if iconObj then
            tween(iconObj, {BackgroundColor3 = Theme.Accent})
            iconObj.TextColor3 = Color3.fromRGB(255, 255, 255)
        end
        if barObj then tween(barObj, {BackgroundTransparency = 0}) end
        if strokeObj then strokeObj.Color = Theme.Accent; strokeObj.Transparency = 0.3 end
    else
        tween(btn, {BackgroundColor3 = Theme.Card, BackgroundTransparency = 0.35})
        if labelObj then labelObj.TextColor3 = Theme.Muted end
        if iconObj then
            tween(iconObj, {BackgroundColor3 = Color3.fromRGB(40, 40, 50)})
            iconObj.TextColor3 = Theme.Muted
        end
        if barObj then tween(barObj, {BackgroundTransparency = 1}) end
        if strokeObj then strokeObj.Color = Theme.Stroke; strokeObj.Transparency = 0.6 end
    end
end

-- Выбрать вкладку
local function selectTab(name)
    currentTab = name
    for tabName, btn in pairs(tabButtons) do
        styleTab(btn, tabName == name)
    end
    for contentName, content in pairs(tabContents) do
        content.Visible = (contentName == name)
    end
end

-- CREATE TAB FUNCTION
local function createTab(name, icon)
    local tabBtn = Instance.new("TextButton", tabContainer)
    tabBtn.Name = name .. "Tab"
    tabBtn.Size = UDim2.new(1, 0, 0, 42)
    tabBtn.BackgroundColor3 = Theme.Card
    tabBtn.BackgroundTransparency = 0.35
    tabBtn.Text = ""
    tabBtn.BorderSizePixel = 0
    tabBtn.AutoButtonColor = false

    addCorner(tabBtn, 10)
    addStroke(tabBtn, Theme.Stroke, 1, 0.6)

    -- Индикатор активной вкладки слева
    local activeBar = Instance.new("Frame", tabBtn)
    activeBar.Name = "ActiveBar"
    activeBar.Size = UDim2.new(0, 3, 0.55, 0)
    activeBar.Position = UDim2.new(0, 0, 0.225, 0)
    activeBar.BackgroundColor3 = Theme.Accent
    activeBar.BackgroundTransparency = 1
    activeBar.BorderSizePixel = 0
    addCorner(activeBar, 2)

    local tabIcon = Instance.new("TextLabel", tabBtn)
    tabIcon.Name = "TabIcon"
    tabIcon.Size = UDim2.new(0, 26, 0, 26)
    tabIcon.Position = UDim2.new(0, 9, 0.5, -13)
    tabIcon.BackgroundColor3 = Color3.fromRGB(40, 40, 50)
    tabIcon.BackgroundTransparency = 0.1
    tabIcon.BorderSizePixel = 0
    tabIcon.Font = Enum.Font.GothamBold
    tabIcon.Text = icon
    tabIcon.TextColor3 = Theme.Muted
    tabIcon.TextSize = 14
    addCorner(tabIcon, 8)

    local tabLabel = Instance.new("TextLabel", tabBtn)
    tabLabel.Name = "TabLabel"
    tabLabel.Size = UDim2.new(1, -46, 1, 0)
    tabLabel.Position = UDim2.new(0, 44, 0, 0)
    tabLabel.BackgroundTransparency = 1
    tabLabel.Font = Enum.Font.GothamBold
    tabLabel.Text = name
    tabLabel.TextColor3 = Theme.Muted
    tabLabel.TextSize = 12
    tabLabel.TextXAlignment = Enum.TextXAlignment.Left

    tabButtons[name] = tabBtn

    tabBtn.MouseEnter:Connect(function()
        if currentTab ~= name then tween(tabBtn, {BackgroundTransparency = 0.15}) end
    end)
    tabBtn.MouseLeave:Connect(function()
        if currentTab ~= name then tween(tabBtn, {BackgroundTransparency = 0.35}) end
    end)
    tabBtn.MouseButton1Click:Connect(function()
        selectTab(name)
    end)

    local tabContent = Instance.new("Frame", scrollFrame)
    tabContent.Name = name .. "Content"
    tabContent.Size = UDim2.new(1, -4, 0, 0)
    tabContent.BackgroundTransparency = 1
    tabContent.Visible = (name == "Main")
    tabContent.AutomaticSize = Enum.AutomaticSize.Y

    local contentLayout = Instance.new("UIListLayout", tabContent)
    contentLayout.Padding = UDim.new(0, 8)
    contentLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center

    tabContents[name] = tabContent

    return tabContent
end

-- CREATE TABS
local mainTab = createTab("Main", tabIcons.Main)
local survivorTab = createTab("Survivor", tabIcons.Survivor)
local killerTab = createTab("Killer", tabIcons.Killer)
local myersTab = createTab("Myers", tabIcons.Myers)
local visualTab = createTab("Visual", tabIcons.Visual)
local miscTab = createTab("Misc", tabIcons.Misc)

-- Set Main tab as active
selectTab("Main")

-- CREATE TOGGLE FUNCTION
local function createToggle(parent, label, configKey, color, callback)
    local desc = featureDescriptions[label]
    local toggleFrame = Instance.new("Frame", parent)
    toggleFrame.Size = UDim2.new(1, 0, 0, desc and 54 or 44)
    toggleFrame.BackgroundColor3 = Theme.Card
    toggleFrame.BackgroundTransparency = 0.15
    toggleFrame.BorderSizePixel = 0

    addCorner(toggleFrame, 11)
    local toggleStroke = addStroke(toggleFrame, Theme.Stroke, 1, 0.7)

    local iconBadge = Instance.new("TextLabel", toggleFrame)
    iconBadge.Size = UDim2.new(0, 30, 0, 30)
    iconBadge.Position = UDim2.new(0, 10, 0.5, -15)
    iconBadge.BackgroundColor3 = Config[configKey] and color or Color3.fromRGB(42, 42, 52)
    iconBadge.BorderSizePixel = 0
    iconBadge.Font = Enum.Font.GothamBold
    iconBadge.Text = featureIcons[label] or "✦"
    iconBadge.TextColor3 = Color3.fromRGB(255, 255, 255)
    iconBadge.TextSize = 14
    addCorner(iconBadge, 9)
    addStroke(iconBadge, Color3.fromRGB(255, 255, 255), 1, 0.85)

    local toggleLabel = Instance.new("TextLabel", toggleFrame)
    toggleLabel.Size = UDim2.new(1, -150, 0, 18)
    toggleLabel.Position = UDim2.new(0, 50, 0, desc and 9 or 0)
    toggleLabel.AnchorPoint = Vector2.new(0, 0)
    toggleLabel.BackgroundTransparency = 1
    toggleLabel.Font = Enum.Font.GothamBold
    toggleLabel.Text = label
    toggleLabel.TextColor3 = Theme.Text
    toggleLabel.TextSize = 12.5
    toggleLabel.TextYAlignment = desc and Enum.TextYAlignment.Center or Enum.TextYAlignment.Center
    toggleLabel.TextXAlignment = Enum.TextXAlignment.Left
    if not desc then toggleLabel.Size = UDim2.new(1, -150, 1, 0) end

    if desc then
        local descLabel = Instance.new("TextLabel", toggleFrame)
        descLabel.Size = UDim2.new(1, -150, 0, 14)
        descLabel.Position = UDim2.new(0, 50, 0, 29)
        descLabel.BackgroundTransparency = 1
        descLabel.Font = Enum.Font.Gotham
        descLabel.Text = desc
        descLabel.TextColor3 = Theme.Muted
        descLabel.TextSize = 10.5
        descLabel.TextXAlignment = Enum.TextXAlignment.Left
        descLabel.TextTruncate = Enum.TextTruncate.AtEnd
    end

    -- Текстовый статус ON/OFF
    local statusText = Instance.new("TextLabel", toggleFrame)
    statusText.Size = UDim2.new(0, 30, 0, 16)
    statusText.Position = UDim2.new(1, -106, 0.5, -8)
    statusText.BackgroundTransparency = 1
    statusText.Font = Enum.Font.GothamBold
    statusText.Text = Config[configKey] and "ON" or "OFF"
    statusText.TextColor3 = Config[configKey] and Theme.On or Theme.Muted
    statusText.TextSize = 11
    statusText.TextXAlignment = Enum.TextXAlignment.Right

    local toggleButton = Instance.new("TextButton", toggleFrame)
    toggleButton.Size = UDim2.new(0, 46, 0, 24)
    toggleButton.Position = UDim2.new(1, -58, 0.5, -12)
    toggleButton.BackgroundColor3 = Config[configKey] and Theme.Accent or Theme.Off
    toggleButton.Text = ""
    toggleButton.BorderSizePixel = 0
    toggleButton.AutoButtonColor = false

    addCorner(toggleButton, 12)
    addStroke(toggleButton, Color3.fromRGB(255, 255, 255), 1, 0.85)

    local toggleCircle = Instance.new("Frame", toggleButton)
    toggleCircle.Size = UDim2.new(0, 18, 0, 18)
    toggleCircle.Position = Config[configKey] and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)
    toggleCircle.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    toggleCircle.BorderSizePixel = 0
    addCorner(toggleCircle, 9)

    toggleButton.MouseButton1Click:Connect(function()
        Config[configKey] = not Config[configKey]
        if callback then callback(Config[configKey]) end

        local on = Config[configKey]
        tween(toggleButton, {BackgroundColor3 = on and Theme.Accent or Theme.Off})
        tween(iconBadge, {BackgroundColor3 = on and color or Color3.fromRGB(42, 42, 52)})
        tween(toggleCircle, {Position = on and UDim2.new(1, -21, 0.5, -9) or UDim2.new(0, 3, 0.5, -9)})
        statusText.Text = on and "ON" or "OFF"
        tween(statusText, {TextColor3 = on and Theme.On or Theme.Muted})
    end)

    toggleFrame.MouseEnter:Connect(function()
        tween(toggleFrame, {BackgroundColor3 = Theme.CardHover})
        toggleStroke.Color = Theme.Accent
        tween(toggleStroke, {Transparency = 0.4})
    end)

    toggleFrame.MouseLeave:Connect(function()
        tween(toggleFrame, {BackgroundColor3 = Theme.Card})
        toggleStroke.Color = Theme.Stroke
        tween(toggleStroke, {Transparency = 0.7})
    end)
end

-- CREATE SLIDER FUNCTION
local function createSlider(parent, label, configKey, minVal, maxVal, callback)
    local desc = featureDescriptions[label]
    local sliderFrame = Instance.new("Frame", parent)
    sliderFrame.Size = UDim2.new(1, 0, 0, desc and 68 or 56)
    sliderFrame.BackgroundColor3 = Theme.Card
    sliderFrame.BackgroundTransparency = 0.15
    sliderFrame.BorderSizePixel = 0

    addCorner(sliderFrame, 11)
    local sliderStroke = addStroke(sliderFrame, Theme.Stroke, 1, 0.7)

    local sliderIcon = Instance.new("TextLabel", sliderFrame)
    sliderIcon.Size = UDim2.new(0, 30, 0, 30)
    sliderIcon.Position = UDim2.new(0, 10, 0, 8)
    sliderIcon.BackgroundColor3 = Theme.Accent
    sliderIcon.BorderSizePixel = 0
    sliderIcon.Font = Enum.Font.GothamBold
    sliderIcon.Text = label:find("Speed") and "»" or "✧"
    sliderIcon.TextColor3 = Color3.fromRGB(255, 255, 255)
    sliderIcon.TextSize = 14
    addCorner(sliderIcon, 9)
    addGradient(sliderIcon, ACCENT_LIGHT, Theme.Accent2, 115)

    local sliderLabel = Instance.new("TextLabel", sliderFrame)
    sliderLabel.Size = UDim2.new(1, -130, 0, 18)
    sliderLabel.Position = UDim2.new(0, 50, 0, 8)
    sliderLabel.BackgroundTransparency = 1
    sliderLabel.Font = Enum.Font.GothamBold
    sliderLabel.Text = label
    sliderLabel.TextColor3 = Theme.Text
    sliderLabel.TextSize = 12.5
    sliderLabel.TextXAlignment = Enum.TextXAlignment.Left

    -- Бэйдж текущего значения
    local valueBadge = Instance.new("TextLabel", sliderFrame)
    valueBadge.Size = UDim2.new(0, 56, 0, 20)
    valueBadge.Position = UDim2.new(1, -66, 0, 8)
    valueBadge.BackgroundColor3 = Theme.AccentDim
    valueBadge.Font = Enum.Font.GothamBold
    valueBadge.Text = tostring(Config[configKey])
    valueBadge.TextColor3 = ACCENT_LIGHT
    valueBadge.TextSize = 12
    addCorner(valueBadge, 8)
    addStroke(valueBadge, Theme.Accent, 1, 0.6)

    if desc then
        local descLabel = Instance.new("TextLabel", sliderFrame)
        descLabel.Size = UDim2.new(1, -130, 0, 14)
        descLabel.Position = UDim2.new(0, 50, 0, 28)
        descLabel.BackgroundTransparency = 1
        descLabel.Font = Enum.Font.Gotham
        descLabel.Text = desc
        descLabel.TextColor3 = Theme.Muted
        descLabel.TextSize = 10.5
        descLabel.TextXAlignment = Enum.TextXAlignment.Left
    end

    local trackY = desc and 50 or 38
    local sliderTrack = Instance.new("Frame", sliderFrame)
    sliderTrack.Size = UDim2.new(1, -66, 0, 8)
    sliderTrack.Position = UDim2.new(0, 50, 0, trackY)
    sliderTrack.BackgroundColor3 = Color3.fromRGB(44, 44, 56)
    sliderTrack.BorderSizePixel = 0
    addCorner(sliderTrack, 7)

    local startScale = math.clamp((Config[configKey] - minVal) / (maxVal - minVal), 0, 1)
    local sliderFill = Instance.new("Frame", sliderTrack)
    sliderFill.Size = UDim2.fromScale(startScale, 1)
    sliderFill.BackgroundColor3 = Theme.Accent
    sliderFill.BorderSizePixel = 0
    addCorner(sliderFill, 7)
    addGradient(sliderFill, Theme.Accent2, ACCENT_LIGHT, 0)

    -- Ручка слайдера
    local knob = Instance.new("Frame", sliderTrack)
    knob.Size = UDim2.new(0, 14, 0, 14)
    knob.AnchorPoint = Vector2.new(0.5, 0.5)
    knob.Position = UDim2.new(startScale, 0, 0.5, 0)
    knob.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
    knob.BorderSizePixel = 0
    addCorner(knob, 7)
    addStroke(knob, Theme.Accent, 1.5, 0.2)

    local sliderButton = Instance.new("TextButton", sliderTrack)
    sliderButton.Size = UDim2.fromScale(1, 1)
    sliderButton.BackgroundTransparency = 1
    sliderButton.Text = ""

    local dragging = false

    local function updateSlider(input)
        local relativeX = math.clamp((input.Position.X - sliderTrack.AbsolutePosition.X) / sliderTrack.AbsoluteSize.X, 0, 1)
        sliderFill.Size = UDim2.fromScale(relativeX, 1)
        knob.Position = UDim2.new(relativeX, 0, 0.5, 0)
        local value = math.floor(minVal + relativeX * (maxVal - minVal))
        Config[configKey] = value
        valueBadge.Text = tostring(value)
        if callback then callback(value) end
    end

    sliderButton.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            tween(knob, {Size = UDim2.new(0, 18, 0, 18)})
            updateSlider(input)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch) then
            updateSlider(input)
        end
    end)

    UserInputService.InputEnded:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
            if dragging then tween(knob, {Size = UDim2.new(0, 14, 0, 14)}) end
            dragging = false
        end
    end)

    sliderFrame.MouseEnter:Connect(function()
        sliderStroke.Color = Theme.Accent
        tween(sliderStroke, {Transparency = 0.4})
    end)
    sliderFrame.MouseLeave:Connect(function()
        sliderStroke.Color = Theme.Stroke
        tween(sliderStroke, {Transparency = 0.7})
    end)
end

-- MAIN TAB TOGGLES
createToggle(mainTab, "Highlight ESP", "HL_ENABLED", Color3.fromRGB(100, 150, 255), function(val)
    for _, p in ipairs(Players:GetPlayers()) do 
        if p ~= localPlayer and p.Character then 
            local hl = p.Character:FindFirstChild("FoxPlayer_Highlight")
            if hl then hl.Enabled = val end
        end 
    end
end)

createToggle(mainTab, "Generator ESP", "GEN_ESP", Color3.fromRGB(255, 200, 50), function(val)
    for _, gen in pairs(gens) do 
        if gen then 
            local hl = gen:FindFirstChild("GenESP_Highlight")
            if hl then hl.Enabled = val end 
        end 
    end
end)

createToggle(mainTab, "Auto Skillcheck", "AutoGen", Color3.fromRGB(130, 80, 200), function(val)
    Config.AutoHeal = val
end)

createToggle(mainTab, "Speed Boost", "SpeedBoostEnabled", Color3.fromRGB(50, 200, 100), function(val)
    if not val then disableSpeed() end
end)

createSlider(mainTab, "Speed", "SpeedValue", 16, 50)

-- SURVIVOR TAB TOGGLES
createToggle(survivorTab, "Auto Parry", "AutoParry", Color3.fromRGB(255, 100, 50))
createToggle(survivorTab, "Fast Vault", "FastVaultEnabled", Color3.fromRGB(200, 50, 100))
createToggle(survivorTab, "Auto Pallet Drop", "AutoPalletEnabled", Color3.fromRGB(50, 200, 200))
createToggle(survivorTab, "Auto Unhook", "AutoUnhookEnabled", Color3.fromRGB(200, 150, 50))
createToggle(survivorTab, "Auto Exit Gate", "AutoExitGateEnabled", Color3.fromRGB(100, 80, 200))
createToggle(survivorTab, "Anti-Stun", "AntiStunEnabled", Color3.fromRGB(200, 80, 150))
createToggle(survivorTab, "Anti-Bodyblock", "AntiBodyblockEnabled", Color3.fromRGB(50, 200, 150))
createToggle(survivorTab, "Auto Flashlight Blind", "AutoFlashlightBlindEnabled", Color3.fromRGB(255, 220, 80))
createToggle(survivorTab, "Infinite Stamina", "InfiniteStaminaEnabled", Color3.fromRGB(80, 255, 180))
createToggle(survivorTab, "Auto Pallet Stun", "AutoPalletStunEnabled", Color3.fromRGB(50, 220, 220))
createToggle(survivorTab, "God Mode", "GodModeEnabled", Color3.fromRGB(255, 215, 0))
createToggle(survivorTab, "Auto Self-Heal", "AutoSelfHealEnabled", Color3.fromRGB(80, 255, 120))
createToggle(survivorTab, "Auto Item Use", "AutoItemUseEnabled", Color3.fromRGB(150, 200, 255))

-- KILLER TAB TOGGLES
createToggle(killerTab, "Force Killer Role", "ForceKillerRole", Color3.fromRGB(255, 60, 60))
createToggle(killerTab, "Hitbox Expander", "HitboxExpanderEnabled", Color3.fromRGB(255, 80, 80))
createSlider(killerTab, "Hitbox Size", "HitboxSize", 5, 20)
createToggle(killerTab, "No Cooldown", "NoCooldownEnabled", Color3.fromRGB(150, 80, 200))
createToggle(killerTab, "Auto Swing Attack", "AutoSwingAttackEnabled", Color3.fromRGB(255, 100, 100))
createToggle(killerTab, "Instant Hit Detection", "InstantHitDetectionEnabled", Color3.fromRGB(255, 120, 120))
createToggle(killerTab, "Attack Range Expander", "AttackRangeExpanderEnabled", Color3.fromRGB(200, 100, 100))
createToggle(killerTab, "Lunge Predictor", "LungePredictorEnabled", Color3.fromRGB(255, 150, 100))
createToggle(killerTab, "Guaranteed Hit System", "GuaranteedHitSystemEnabled", Color3.fromRGB(255, 80, 80))
createToggle(killerTab, "Instinct Reveal", "InstinctRevealEnabled", Color3.fromRGB(255, 140, 60))
createToggle(killerTab, "Instant Pallet Break", "InstantPalletBreakEnabled", Color3.fromRGB(200, 120, 60))
createToggle(killerTab, "Stalker Instant Tier 3", "StalkerInstantTier3Enabled", Color3.fromRGB(180, 60, 200))
createToggle(killerTab, "Masked Auto Power", "MaskedAutoPowerEnabled", Color3.fromRGB(120, 100, 220))
createToggle(killerTab, "Hidden Auto Leap", "HiddenAutoLeapEnabled", Color3.fromRGB(100, 180, 220))

-- MYERS TAB TOGGLES
createToggle(myersTab, "Instant Tier 3", "InstantTier3Enabled", Color3.fromRGB(255, 180, 50))
createToggle(myersTab, "Infinite Tier 3", "InfiniteTier3Enabled", Color3.fromRGB(255, 150, 50))
createToggle(myersTab, "Auto Stalk", "AutoStalkEnabled", Color3.fromRGB(255, 120, 50))
createToggle(myersTab, "Wallhack Stalk", "WallhackStalkEnabled", Color3.fromRGB(255, 100, 50))

-- VISUAL TAB TOGGLES
createToggle(visualTab, "Fly Platform", "FlyPlatformEnabled", Color3.fromRGB(80, 180, 255))
createToggle(visualTab, "Hook ESP", "HookESP", Color3.fromRGB(255, 85, 105))
createToggle(visualTab, "Exit Gate ESP", "ExitGateESP", Color3.fromRGB(85, 220, 170))
createToggle(visualTab, "Hit Stars", "HitStarsEnabled", Color3.fromRGB(255, 215, 85))
createToggle(visualTab, "Attack Range Circle", "AttackRangeCircleEnabled", Color3.fromRGB(255, 95, 70))
createToggle(visualTab, "Danger Pulse", "DangerPulseEnabled", Color3.fromRGB(235, 83, 94))
createToggle(visualTab, "Generator Effects", "GeneratorRepairEffectsEnabled", Color3.fromRGB(255, 205, 70))
createToggle(visualTab, "Tracers", "TracersEnabled", Color3.fromRGB(120, 220, 255))
createToggle(visualTab, "Health Bars", "HealthBarsEnabled", Color3.fromRGB(255, 90, 110))

-- MISC TAB TOGGLES
createToggle(miscTab, "Fly", "FlyEnabled", Color3.fromRGB(120, 200, 255))
createSlider(miscTab, "Fly Speed", "FlySpeed", 20, 200)
createToggle(miscTab, "NoClip", "NoClipEnabled", Color3.fromRGB(200, 120, 255))
createToggle(miscTab, "Fling", "FlingEnabled", Color3.fromRGB(255, 120, 200))
createSlider(miscTab, "Fling Power", "FlingPower", 1000, 10000)
createToggle(miscTab, "FOV", "FOVEnabled", Color3.fromRGB(120, 220, 255))
createSlider(miscTab, "FOV Value", "FOVValue", 70, 120)
createToggle(miscTab, "Camera Unlock", "CameraUnlockEnabled", Color3.fromRGB(160, 200, 255))

-- ===== Живые анимации интерфейса =====
-- Дыхание неоновой рамки
local strokeThread = task.spawn(function()
    while true do
        tween(mainStroke, {Transparency = 0.25}, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
        tween(mainStroke, {Transparency = 0.6}, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
    end
end)
table.insert(cleanupTasks, strokeThread)

-- Дыхание внешнего свечения
local glowThread = task.spawn(function()
    while true do
        tween(glow, {ImageTransparency = 0.42}, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
        tween(glow, {ImageTransparency = 0.66}, TweenInfo.new(1.6, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
    end
end)
table.insert(cleanupTasks, glowThread)

-- Медленное вращение углового блика
local blobThread = task.spawn(function()
    while true do
        local startRot = glassShard.Rotation
        tween(glassShard, {Rotation = startRot + 360}, TweenInfo.new(48, Enum.EasingStyle.Linear)).Completed:Wait()
        glassShard.Rotation = startRot
    end
end)
table.insert(cleanupTasks, blobThread)

-- Световой пробег по верхней полосе
local shimmerThread = task.spawn(function()
    while true do
        topGrad.Offset = Vector2.new(-1, 0)
        tween(topGrad, {Offset = Vector2.new(1, 0)}, TweenInfo.new(2.4, Enum.EasingStyle.Linear)).Completed:Wait()
        task.wait(1.1)
    end
end)
table.insert(cleanupTasks, shimmerThread)

-- Пульс индикатора статуса в футере
local dotThread = task.spawn(function()
    while true do
        tween(footerDot, {BackgroundTransparency = 0.55}, TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
        tween(footerDot, {BackgroundTransparency = 0}, TweenInfo.new(0.95, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
    end
end)
table.insert(cleanupTasks, dotThread)

-- Катана: покачивание + периодический слэш (всё на TweenService — без нагрузки на FPS)
local katanaThread = task.spawn(function()
    local idle = -20
    local count = 0
    while true do
        count = count + 1
        if count % 4 == 0 then
            tween(katana, {Rotation = idle + 32}, TweenInfo.new(0.11, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)).Completed:Wait()
            tween(katana, {Rotation = idle}, TweenInfo.new(0.55, Enum.EasingStyle.Back, Enum.EasingDirection.Out)).Completed:Wait()
        else
            tween(katana, {Rotation = idle + 3}, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
            tween(katana, {Rotation = idle - 3}, TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
        end
    end
end)
table.insert(cleanupTasks, katanaThread)

-- Катана: бегущий блик по клинку
local sheenThread = task.spawn(function()
    while true do
        kSheen.Position = UDim2.new(0, -12, 0, 0)
        kSheen.BackgroundTransparency = 0.15
        tween(kSheen, {Position = UDim2.new(1, 2, 0, 0)}, TweenInfo.new(0.85, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)).Completed:Wait()
        kSheen.BackgroundTransparency = 1
        task.wait(2.4)
    end
end)
table.insert(cleanupTasks, sheenThread)

-- Появление панели с лёгким "pop"-эффектом
do
    local target = guiScale.Scale
    guiScale.Scale = target * 0.82
    tween(guiScale, {Scale = target}, TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out))
end

print("[XENON]: GUI загружен!")
end

-- BILLBOARD GUI (ДИСТАНЦИИ)
-- ========================
local function applyBillboard(parentPart, text, color, enabled)
    if not parentPart then return end
    
    local bbg = parentPart:FindFirstChild("Fox_ESP_Billboard")
    if not enabled then
        if bbg then bbg.Enabled = false end
        return
    end
    
    if not bbg then
        bbg = Instance.new("BillboardGui")
        bbg.Name = "Fox_ESP_Billboard"
        bbg.AlwaysOnTop = true
        bbg.Size = UDim2.new(0, 110, 0, 35)
        bbg.StudsOffset = Vector3.new(0, 3, 0)
        
        local textLabel = Instance.new("TextLabel")
        textLabel.Name = "TextLabel"
        textLabel.Size = UDim2.new(1, 0, 1, 0)
        textLabel.BackgroundTransparency = 1
        textLabel.Font = Enum.Font.GothamBold
        textLabel.TextSize = 9
        textLabel.TextStrokeTransparency = 0.3
        textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
        textLabel.Parent = bbg
        
        bbg.Parent = parentPart
        table.insert(cleanupTasks, bbg)
    end
    
    local label = bbg:FindFirstChild("TextLabel")
    if label then
        label.Text = text
        label.TextColor3 = color
    end
    bbg.Enabled = true
end

-- ESP ИГРОКОВ
local function applyHighlight(player)
    local char = player.Character
    if not char then return end
    
    local hl = char:FindFirstChild("FoxPlayer_Highlight")
    if not Config.HL_ENABLED then
        if hl then hl:Destroy() end
        return
    end
    
    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = "FoxPlayer_Highlight"
        hl.OutlineColor = Color3.fromRGB(255, 255, 255)
        hl.FillTransparency = 0.45
        hl.OutlineTransparency = 0
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = char
    end
    
    hl.FillColor = getColor(player)
    hl.Enabled = true
end

local playerLoopConn = RunService.Heartbeat:Connect(function()
    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer then 
            applyHighlight(p)
            
            local char = p.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            if root and myRoot and Config.HL_ENABLED then
                local dist = math.round((myRoot.Position - root.Position).Magnitude)
                local role = getRole(p)
                local text = string.format("%s\n[%s]\n%d m", p.Name, role, dist)
                local color = getColor(p)
                applyBillboard(root, text, color, true)
            else
                if char then
                    local bbg = char:FindFirstChild("Fox_ESP_Billboard", true)
                    if bbg then bbg.Enabled = false end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, playerLoopConn)

-- ESP ГЕНЕРАТОРОВ
local function updateGenHighlightColor(gen, hl)
    local progress = genProgress[gen]
    if not progress then
        for _, attr in ipairs({"Progress","progress","HP","Health","Charge","Power"}) do
            local v = gen:GetAttribute(attr)
            if v and type(v) == "number" then progress = v; break end
        end
    end

    if not progress then
        for _, child in ipairs(gen:GetChildren()) do
            if child:IsA("NumberValue") or child:IsA("IntValue") then
                local n = child.Name:lower()
                if n:find("progress") or n:find("charge") or n:find("hp") then
                    progress = child.Value; break
                end
            end
        end
    end

    local norm = progress and math.clamp(progress / 100, 0, 1) or 0

    if norm >= 1 then
        hl.FillColor = Color3.fromRGB(50, 210, 90)
        hl.OutlineColor = Color3.fromRGB(50, 210, 90)
    elseif progress and progress > 0 then
        hl.FillColor = Color3.fromRGB(255, 120, 0)
        hl.OutlineColor = Color3.fromRGB(255, 120, 0)
    else
        hl.FillColor = Color3.fromRGB(255, 200, 50)
        hl.OutlineColor = Color3.fromRGB(255, 200, 50)
    end
end

local function attachGenESP(gen)
    local hl = gen:FindFirstChild("GenESP_Highlight")
    if not Config.GEN_ESP then 
        if hl then hl:Destroy() end
        return 
    end

    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = "GenESP_Highlight"
        hl.OutlineColor = Color3.fromRGB(255,200,50)
        hl.FillTransparency = 0.7
        hl.OutlineTransparency = 0.2
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = gen
    end

    hl.Enabled = true
    updateGenHighlightColor(gen, hl)
end

local lastGenUpdate = 0
local genLoopConn = RunService.Heartbeat:Connect(function()
    local now = tick()
    if now - lastGenUpdate < 0.1 then return end 
    lastGenUpdate = now

    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")

    for _, gen in ipairs(gens) do
        if gen and gen.Parent then
            attachGenESP(gen)
            
            local root = gen.PrimaryPart or gen:FindFirstChildOfClass("BasePart")
            if root and myRoot and Config.GEN_ESP then
                local dist = math.round((myRoot.Position - root.Position).Magnitude)
                local progress = genProgress[gen] or 0
                local text = string.format("Gen\n%d%% | %d m", progress, dist)
                
                local color = Color3.fromRGB(255, 200, 50)
                if progress >= 100 then
                    color = Color3.fromRGB(50, 210, 90)
                elseif progress > 0 then
                    color = Color3.fromRGB(255, 120, 0)
                end
                
                applyBillboard(root, text, color, true)
            else
                if gen then
                    local bbg = gen:FindFirstChild("Fox_ESP_Billboard", true)
                    if bbg then bbg.Enabled = false end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, genLoopConn)

-- OBJECT ESP: HOOKS / EXIT GATES
local function getObjectRoot(obj)
    if not obj then return nil end
    if obj:IsA("BasePart") then return obj end
    if obj:IsA("Model") then
        return obj.PrimaryPart or obj:FindFirstChildOfClass("BasePart")
    end
    return obj:FindFirstChildOfClass("BasePart")
end

local function attachObjectESP(obj, enabled, highlightName, labelText, color)
    if not obj or not obj.Parent then return end

    local hl = obj:FindFirstChild(highlightName)
    local root = getObjectRoot(obj)
    local billboardName = highlightName:gsub("_Highlight", "_Billboard")

    if not enabled then
        if hl then hl:Destroy() end
        if root then
            local bbg = root:FindFirstChild(billboardName)
            if bbg then bbg.Enabled = false end
        end
        return
    end

    if not hl then
        hl = Instance.new("Highlight")
        hl.Name = highlightName
        hl.FillTransparency = 0.65
        hl.OutlineTransparency = 0.08
        hl.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        hl.Parent = obj
        table.insert(cleanupTasks, hl)
    end

    hl.FillColor = color
    hl.OutlineColor = color
    hl.Enabled = true

    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if root and myRoot then
        local dist = math.round((myRoot.Position - root.Position).Magnitude)
        local bbg = root:FindFirstChild(billboardName)
        if not bbg then
            bbg = Instance.new("BillboardGui")
            bbg.Name = billboardName
            bbg.AlwaysOnTop = true
            bbg.Size = UDim2.new(0, 100, 0, 32)
            bbg.StudsOffset = Vector3.new(0, 3, 0)

            local textLabel = Instance.new("TextLabel", bbg)
            textLabel.Name = "TextLabel"
            textLabel.Size = UDim2.new(1, 0, 1, 0)
            textLabel.BackgroundTransparency = 1
            textLabel.Font = Enum.Font.GothamBold
            textLabel.TextSize = 9
            textLabel.TextStrokeTransparency = 0.3
            textLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)

            bbg.Parent = root
            table.insert(cleanupTasks, bbg)
        end

        local label = bbg:FindFirstChild("TextLabel")
        if label then
            label.Text = string.format("%s\n%d m", labelText, dist)
            label.TextColor3 = color
        end
        bbg.Enabled = true
    end
end

local objectEspConn = RunService.Heartbeat:Connect(function()
    for _, hook in ipairs(cachedHooks) do
        attachObjectESP(hook, Config.HookESP, "FoxHookESP_Highlight", "Hook", Color3.fromRGB(255, 85, 105))
    end

    for _, lever in ipairs(cachedLevers) do
        attachObjectESP(lever, Config.ExitGateESP, "FoxExitESP_Highlight", "Exit", Color3.fromRGB(85, 220, 170))
    end
end)
table.insert(cleanupTasks, objectEspConn)

-- ATTACK RANGE CIRCLE
local attackRangeCircle = nil

local function ensureAttackRangeCircle()
    if attackRangeCircle and attackRangeCircle.Parent then return attackRangeCircle end

    attackRangeCircle = Instance.new("Part")
    attackRangeCircle.Name = "Fox_AttackRangeCircle"
    attackRangeCircle.Shape = Enum.PartType.Cylinder
    attackRangeCircle.Anchored = true
    attackRangeCircle.CanCollide = false
    attackRangeCircle.CanTouch = false
    attackRangeCircle.CanQuery = false
    attackRangeCircle.Material = Enum.Material.Neon
    attackRangeCircle.Color = Color3.fromRGB(255, 95, 70)
    attackRangeCircle.Transparency = 0.78
    attackRangeCircle.Parent = workspace
    table.insert(cleanupTasks, attackRangeCircle)

    return attackRangeCircle
end

local attackRangeConn = RunService.Heartbeat:Connect(function()
    if not Config.AttackRangeCircleEnabled then
        if attackRangeCircle then attackRangeCircle.Transparency = 1 end
        return
    end

    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then
        if attackRangeCircle then attackRangeCircle.Transparency = 1 end
        return
    end

    local circle = ensureAttackRangeCircle()
    local radius = math.clamp((Config.HitboxSize or 10) * (Config.AttackRangeMultiplier or 1.5), 8, 40)
    circle.Size = Vector3.new(0.08, radius * 2, radius * 2)
    circle.CFrame = CFrame.new(myRoot.Position.X, myRoot.Position.Y - 2.85, myRoot.Position.Z) * CFrame.Angles(0, 0, math.rad(90))
    circle.Transparency = 0.78
end)
table.insert(cleanupTasks, attackRangeConn)

-- HIT STARS EFFECT
local trackedHumanoids = {}

local function spawnHitStars(root)
    if not (Config.HitStarsEnabled and root and root.Parent) then return end

    local billboard = Instance.new("BillboardGui")
    billboard.Name = "Fox_HitStars"
    billboard.AlwaysOnTop = true
    billboard.Size = UDim2.new(0, 120, 0, 70)
    billboard.StudsOffset = Vector3.new(0, 3.2, 0)
    billboard.Parent = root
    table.insert(cleanupTasks, billboard)

    for i = 1, 6 do
        local star = Instance.new("TextLabel", billboard)
        star.BackgroundTransparency = 1
        star.Size = UDim2.new(0, 24, 0, 24)
        star.Position = UDim2.new(0.5, math.random(-35, 20), 0.5, math.random(-8, 18))
        star.Font = Enum.Font.GothamBold
        star.Text = (i % 2 == 0) and "✦" or "★"
        star.TextColor3 = (i % 2 == 0) and Color3.fromRGB(255, 220, 80) or Color3.fromRGB(255, 120, 90)
        star.TextStrokeTransparency = 0.25
        star.TextSize = math.random(18, 26)

        TweenService:Create(star, TweenInfo.new(0.55, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
            Position = star.Position - UDim2.new(0, math.random(-18, 18), 0, math.random(22, 38)),
            TextTransparency = 1,
            TextStrokeTransparency = 1,
            Rotation = math.random(-35, 35),
        }):Play()
    end

    task.delay(0.65, function()
        if billboard and billboard.Parent then
            billboard:Destroy()
        end
    end)
end

local function trackHitStarsForCharacter(char)
    if not char then return end

    local hum = char:FindFirstChildOfClass("Humanoid")
    local root = char:FindFirstChild("HumanoidRootPart")
    if not (hum and root) or trackedHumanoids[hum] then return end

    trackedHumanoids[hum] = hum.Health
    local conn = hum.HealthChanged:Connect(function(newHealth)
        local oldHealth = trackedHumanoids[hum] or newHealth
        if newHealth < oldHealth then
            spawnHitStars(root)
        end
        trackedHumanoids[hum] = newHealth
    end)
    table.insert(cleanupTasks, conn)
end

local hitStarsTrackConn = RunService.Heartbeat:Connect(function()
    if not Config.HitStarsEnabled then return end

    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then
            trackHitStarsForCharacter(p.Character)
        end
    end
end)
table.insert(cleanupTasks, hitStarsTrackConn)

-- DANGER PULSE OVERLAY
local dangerOverlay = Instance.new("Frame", screenGui)
dangerOverlay.Name = "DangerPulseOverlay"
dangerOverlay.Size = UDim2.fromScale(1, 1)
dangerOverlay.BackgroundColor3 = Color3.fromRGB(220, 35, 45)
dangerOverlay.BackgroundTransparency = 1
dangerOverlay.BorderSizePixel = 0
dangerOverlay.ZIndex = 1
dangerOverlay.Active = false
table.insert(cleanupTasks, dangerOverlay)

local dangerGradient = Instance.new("UIGradient", dangerOverlay)
dangerGradient.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.2),
    NumberSequenceKeypoint.new(0.45, 0.92),
    NumberSequenceKeypoint.new(0.55, 0.92),
    NumberSequenceKeypoint.new(1, 0.2),
})
dangerGradient.Rotation = 45

local function getNearestKillerDistance(myRoot)
    local nearest = math.huge

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Killer" and p.Character then
            local kRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if kRoot then
                nearest = math.min(nearest, (myRoot.Position - kRoot.Position).Magnitude)
            end
        end
    end

    return nearest
end

local dangerPulseConn = RunService.Heartbeat:Connect(function()
    if not Config.DangerPulseEnabled then
        dangerOverlay.BackgroundTransparency = 1
        return
    end

    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then
        dangerOverlay.BackgroundTransparency = 1
        return
    end

    local dist = getNearestKillerDistance(myRoot)
    if dist > 35 then
        dangerOverlay.BackgroundTransparency = 1
        return
    end

    local intensity = 1 - math.clamp(dist / 35, 0, 1)
    local pulse = (math.sin(tick() * (5 + intensity * 6)) + 1) / 2
    dangerOverlay.BackgroundTransparency = 0.96 - (intensity * 0.22 * pulse)
end)
table.insert(cleanupTasks, dangerPulseConn)

-- GENERATOR REPAIR EFFECTS
local activeGenEffectRoot = nil
local activeGenAttachment = nil
local activeGenEmitter = nil
local activeGenLight = nil

local function clearGeneratorEffect()
    if activeGenEmitter then activeGenEmitter.Enabled = false end
    if activeGenLight then activeGenLight.Enabled = false end
    activeGenEffectRoot = nil
end

local function getNearestGeneratorRoot(myRoot, maxDistance)
    local nearestGen = nil
    local nearestRoot = nil
    local nearestDist = maxDistance or 9

    for _, gen in ipairs(gens) do
        if gen and gen.Parent then
            local root = gen.PrimaryPart or gen:FindFirstChildOfClass("BasePart")
            if root then
                local dist = (myRoot.Position - root.Position).Magnitude
                if dist < nearestDist then
                    nearestGen = gen
                    nearestRoot = root
                    nearestDist = dist
                end
            end
        end
    end

    return nearestGen, nearestRoot, nearestDist
end

local function ensureGeneratorEffect(root)
    if activeGenEffectRoot == root and activeGenAttachment and activeGenAttachment.Parent then return end

    if activeGenAttachment then
        activeGenAttachment:Destroy()
    end

    activeGenEffectRoot = root
    activeGenAttachment = Instance.new("Attachment", root)
    activeGenAttachment.Name = "Fox_GenRepairEffect"
    activeGenAttachment.Position = Vector3.new(0, 1.2, 0)
    table.insert(cleanupTasks, activeGenAttachment)

    activeGenEmitter = Instance.new("ParticleEmitter", activeGenAttachment)
    activeGenEmitter.Name = "Fox_GenSparks"
    activeGenEmitter.Texture = "rbxassetid://243660364"
    activeGenEmitter.Color = ColorSequence.new(Color3.fromRGB(255, 220, 95), Color3.fromRGB(80, 220, 255))
    activeGenEmitter.LightEmission = 0.8
    activeGenEmitter.Rate = 18
    activeGenEmitter.Lifetime = NumberRange.new(0.25, 0.55)
    activeGenEmitter.Speed = NumberRange.new(2, 5)
    activeGenEmitter.SpreadAngle = Vector2.new(70, 70)
    activeGenEmitter.Size = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.18),
        NumberSequenceKeypoint.new(1, 0),
    })

    activeGenLight = Instance.new("PointLight", activeGenAttachment)
    activeGenLight.Name = "Fox_GenGlow"
    activeGenLight.Color = Color3.fromRGB(255, 205, 70)
    activeGenLight.Brightness = 1.8
    activeGenLight.Range = 10
end

local genEffectConn = RunService.Heartbeat:Connect(function()
    if not Config.GeneratorRepairEffectsEnabled then
        clearGeneratorEffect()
        return
    end

    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then
        clearGeneratorEffect()
        return
    end

    local nearGen, root = getNearestGeneratorRoot(myRoot, 8)
    local repairing = myChar:GetAttribute("Repairing") == true or myChar:GetAttribute("Interacting") == true or myChar:GetAttribute("Action") == "Repair"

    -- эффект только когда РЕАЛЬНО чинишь (а не просто рядом с включённым AutoGen)
    if nearGen and repairing then
        ensureGeneratorEffect(root)
        local pulse = (math.sin(tick() * 8) + 1) / 2
        activeGenEmitter.Enabled = true
        activeGenLight.Enabled = true
        activeGenLight.Brightness = 1.2 + pulse * 1.8
    else
        clearGeneratorEffect()
    end
end)
table.insert(cleanupTasks, genEffectConn)

-- AUTO PALLET DROP - ИСПРАВЛЕНО
local function isPalletDropped(pallet)
    if pallet:GetAttribute("Dropped") == true or pallet:GetAttribute("IsDropped") == true then
        return true
    end
    local root = pallet:FindFirstChild("Part") or pallet:FindFirstChildOfClass("BasePart")
    if root and math.abs(root.Orientation.Z) > 45 then
        return true
    end
    return droppedPalletsDebounce[pallet] == true
end

local lastPalletCheck = 0
local palletDropDebounce = {}

local palletLoopConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoPalletEnabled then return end
    
    local now = tick()
    if now - lastPalletCheck < 0.15 then return end 
    lastPalletCheck = now
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local PalletFolder = Remotes:FindFirstChild("Pallet")
    if not PalletFolder then return end
    
    local PalletDropEvent = PalletFolder:FindFirstChild("PalletDropEvent")
    local PalletDropAnim = PalletFolder:FindFirstChild("PalletDropAnim")
    local PalletDropCommit = PalletFolder:FindFirstChild("PalletDropCommit")
    
    if not (PalletDropEvent and PalletDropAnim and PalletDropCommit) then return end

    for _, pallet in ipairs(cachedPallets) do
        if pallet and pallet.Parent and not isPalletDropped(pallet) then
            local skipThis = false
            if palletDropDebounce[pallet] and tick() - palletDropDebounce[pallet] < 1.5 then
                skipThis = true
            end
            
            if not skipThis then
                local pPos = pallet:GetPivot().Position
                local distToMe = (myRoot.Position - pPos).Magnitude
                
                if distToMe <= 18 then
                    local shouldDrop = false
                    
                    for _, p in ipairs(Players:GetPlayers()) do
                        if p ~= localPlayer and getRole(p) == "Killer" and p.Character then
                            local kRoot = p.Character:FindFirstChild("HumanoidRootPart")
                            if kRoot then
                                local distToKiller = (kRoot.Position - pPos).Magnitude
                                if distToKiller <= 14 then
                                    shouldDrop = true
                                    break
                                end
                            end
                        end
                    end
                    
                    if shouldDrop then
                        palletDropDebounce[pallet] = tick()
                        droppedPalletsDebounce[pallet] = true
                        
                        task.spawn(function()
                            pcall(function()
                                PalletDropEvent:FireServer(pallet)
                                task.wait(0.05)
                                PalletDropAnim:FireServer(pallet)
                                task.wait(0.08)
                                PalletDropCommit:FireServer(pallet)
                            end)
                        end)
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, palletLoopConn)

-- AUTO UNHOOK - ИСПРАВЛЕНО
local lastUnhookCheck = 0
local selfUnhookActive = false
local unhookLoopConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoUnhookEnabled then return end
    
    local now = tick()
    if now - lastUnhookCheck < 0.2 then return end
    lastUnhookCheck = now

    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    local UnHookEvent = Remotes:FindFirstChild("Carry") and Remotes.Carry:FindFirstChild("UnHookEvent")
    local SelfUnHookEvent = Remotes:FindFirstChild("Carry") and Remotes.Carry:FindFirstChild("SelfUnHookEvent")

    -- Если сам на крюке — спамим само-слезание для 100% выхода
    if SelfUnHookEvent then
        local amIHooked = false
        if myChar:GetAttribute("Hooked") == true or myChar:GetAttribute("IsHooked") == true
            or myChar:GetAttribute("OnHook") == true or myChar:GetAttribute("Carried") == true
            or myChar:FindFirstChild("Hooked") then
            amIHooked = true
        else
            for _, hook in ipairs(cachedHooks) do
                if hook and hook.Parent then
                    local dist = (myRoot.Position - hook:GetPivot().Position).Magnitude
                    if dist <= 9 then amIHooked = true; break end
                end
            end
        end

        if amIHooked and not selfUnhookActive then
            selfUnhookActive = true
            local HookPhase = Remotes.Carry:FindFirstChild("HookPhase")
            task.spawn(function()
                -- пачка попыток — пробиваем рандомный шанс слезть
                for i = 1, 25 do
                    pcall(function() SelfUnHookEvent:FireServer() end)
                    if HookPhase then pcall(function() HookPhase:FireServer() end) end
                    task.wait(0.05)
                end
                selfUnhookActive = false
            end)
        end
    end

    -- Если союзник на крюке
    if UnHookEvent then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
                local pRoot = p.Character:FindFirstChild("HumanoidRootPart")
                if pRoot then
                    local distToMe = (myRoot.Position - pRoot.Position).Magnitude
                    if distToMe <= 18 then
                        local isTeammateHooked = false
                        if p.Character:GetAttribute("Hooked") == true or p.Character:GetAttribute("IsHooked") == true or p.Character:FindFirstChild("Hooked") then
                            isTeammateHooked = true
                        else
                            for _, hook in ipairs(cachedHooks) do
                                if hook and hook.Parent then
                                    local distToHook = (pRoot.Position - hook:GetPivot().Position).Magnitude
                                    if distToHook <= 8 then isTeammateHooked = true; break end
                                end
                            end
                        end
                        
                        if isTeammateHooked then
                            task.spawn(function()
                                pcall(function()
                                    UnHookEvent:FireServer(p)
                                end)
                            end)
                        end
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, unhookLoopConn)

-- AUTO EXIT GATE
local lastGateCheck = 0
local leverDebounce = {}        -- троттлинг на каждый рычаг отдельно
local leverPerInterval = 0.35   -- не чаще, чем раз в 0.35с на один рычаг
local gateLoopConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoExitGateEnabled then return end

    local now = tick()
    if now - lastGateCheck < 0.1 then return end
    lastGateCheck = now

    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    local LeverEvent = Remotes:FindFirstChild("Exit") and Remotes.Exit:FindFirstChild("LeverEvent")
    if not LeverEvent then return end

    for _, lever in ipairs(cachedLevers) do
        if lever and lever.Parent then
            -- пропускаем уже полностью открытые ворота
            local opened = lever:GetAttribute("Opened") or lever:GetAttribute("Open") or lever:GetAttribute("Done")
            if not opened then
                local dist = (myRoot.Position - lever:GetPivot().Position).Magnitude
                if dist <= 18 then
                    local last = leverDebounce[lever] or 0
                    if now - last >= leverPerInterval then
                        leverDebounce[lever] = now
                        task.spawn(function()
                            pcall(function()
                                LeverEvent:FireServer(lever)
                            end)
                        end)
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, gateLoopConn)

-- ANTI-STUN
local function stopStunAnimations(char)
    local hum = char:WaitForChild("Humanoid", 5)
    local animator = hum and hum:WaitForChild("Animator", 5)
    if animator then
        local conn = animator.AnimationPlayed:Connect(function(animTrack)
            if not Config.AntiStunEnabled then return end
            local name = animTrack.Animation.Name:lower()
            if name:find("stun") or name:find("hit") or name:find("stagger") or name:find("fall") then
                animTrack:Stop()
            end
        end)
        table.insert(cleanupTasks, conn)
    end
end

if localPlayer.Character then stopStunAnimations(localPlayer.Character) end
local connCharAnim = localPlayer.CharacterAdded:Connect(stopStunAnimations)
table.insert(cleanupTasks, connCharAnim)

local lastStunCheck = 0
local stunDebounce = 0.05
local stunLoopConn = RunService.Heartbeat:Connect(function()
    if not Config.AntiStunEnabled then return end
    
    local myChar = localPlayer.Character
    local hum = myChar and myChar:FindFirstChildOfClass("Humanoid")
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
    
    if not (myChar and hum and myRoot) then return end
    
    local now = tick()
    if now - lastStunCheck < stunDebounce then return end
    lastStunCheck = now
    
    if hum.PlatformStand then
        hum.PlatformStand = false
    end
    
    if myRoot.Anchored then
        myRoot.Anchored = false
    end
    
    if hum.WalkSpeed < 10 then
        hum.WalkSpeed = Config.SpeedValue or 22
    end
    
    for _, attr in ipairs({"Stunned", "Stun", "Slowed", "Parried", "Slow", "Slowing", "Stunover"}) do
        if myChar:GetAttribute(attr) then
            myChar:SetAttribute(attr, false)
        end
    end
    
    local isKiller = (getRole(localPlayer) == "Killer")
    
    if isKiller then
        pcall(function()
            local pallet = Remotes:FindFirstChild("Pallet")
            if pallet then
                local jason = pallet:FindFirstChild("Jason")
                if jason then
                    local stunover = jason:FindFirstChild("Stunover")
                    if stunover then
                        stunover:FireServer()
                    end
                end
            end
        end)
    end
    
    if hum.Health > 0 then
        local humanoidState = hum:GetState()
        -- Убираем Staggering (не существует в Luau)
        if humanoidState == Enum.HumanoidStateType.FallingDown or humanoidState == Enum.HumanoidStateType.Ragdoll then
            hum:ChangeState(Enum.HumanoidStateType.Running)
        end
    end
end)
table.insert(cleanupTasks, stunLoopConn)

-- FLY PLATFORM
local flyHud = Instance.new("Frame")
flyHud.Name = "FlyHUD"
flyHud.Size = UDim2.new(0, 100, 0, 45)
flyHud.Position = UDim2.new(0.85, -50, 0.5, -22) 
flyHud.BackgroundTransparency = 1
flyHud.Visible = false
flyHud.Parent = screenGui
table.insert(cleanupTasks, flyHud)

local btnUp = Instance.new("TextButton", flyHud)
btnUp.Size = UDim2.new(0, 44, 0, 44)
btnUp.Position = UDim2.new(0, 0, 0, 0)
btnUp.BackgroundColor3 = Color3.fromRGB(10, 10, 18)
btnUp.BackgroundTransparency = 0.15
btnUp.Text = "▲"
btnUp.TextColor3 = Color3.fromRGB(255, 255, 255)
btnUp.TextSize = 16
btnUp.Font = Enum.Font.GothamBold
Instance.new("UICorner", btnUp).CornerRadius = UDim.new(0, 10)
local s1 = Instance.new("UIStroke", btnUp)
s1.Color = Color3.fromRGB(60, 100, 180); s1.Thickness = 1.5

local btnDown = Instance.new("TextButton", flyHud)
btnDown.Size = UDim2.new(0, 44, 0, 44)
btnDown.Position = UDim2.new(0, 52, 0, 0)
btnDown.BackgroundColor3 = Color3.fromRGB(10, 10, 18)
btnDown.BackgroundTransparency = 0.15
btnDown.Text = "▼"
btnDown.TextColor3 = Color3.fromRGB(255, 255, 255)
btnDown.TextSize = 16
btnDown.Font = Enum.Font.GothamBold
Instance.new("UICorner", btnDown).CornerRadius = UDim.new(0, 10)
local s2 = Instance.new("UIStroke", btnDown)
s2.Color = Color3.fromRGB(60, 100, 180); s2.Thickness = 1.5

btnUp.MouseButton1Click:Connect(function()
    platformHeightOffset = platformHeightOffset + 1
end)

btnDown.MouseButton1Click:Connect(function()
    platformHeightOffset = platformHeightOffset - 1
end)

local function updatePlatform()
    if Config.FlyPlatformEnabled then
        local myChar = localPlayer.Character
        local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")
        if myRoot then
            flyHud.Visible = true
            if not platformPart or not platformPart.Parent then
                platformPart = Instance.new("Part")
                platformPart.Name = "FoxFlyPlatform"
                platformPart.Size = Vector3.new(6, 0.5, 6)
                platformPart.Transparency = 0.5 
                platformPart.Color = Color3.fromRGB(80, 120, 200)
                platformPart.Material = Enum.Material.ForceField
                platformPart.Anchored = true
                platformPart.CanCollide = true
                platformPart.Parent = workspace
                table.insert(cleanupTasks, platformPart)
            end
            platformPart.CFrame = CFrame.new(myRoot.Position.X, myRoot.Position.Y + platformHeightOffset, myRoot.Position.Z)
        end
    else
        flyHud.Visible = false
        if platformPart then
            pcall(function() platformPart:Destroy() end)
            platformPart = nil
        end
    end
end

local flyConn = RunService.PostSimulation:Connect(updatePlatform)
table.insert(cleanupTasks, flyConn)

-- ANTI-BODYBLOCK - УЛУЧШЕНО (ФАЗИРОВАНИЕ)
local disabledCollisions = {}
local lastCollisionCheck = 0

local bodyblockConn = RunService.PreRender:Connect(function()
    if not Config.AntiBodyblockEnabled then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local now = tick()
    
    -- ОТКЛЮЧАЕМ КОЛЛИЗИИ ДЛЯ СЕБЯ (чтобы проходить сквозь всех)
    for _, part in ipairs(myChar:GetDescendants()) do
        if part:IsA("BasePart") then
            part.CanCollide = false
        end
    end
    
    if getRole(localPlayer) == "Survivor" then
        -- Отключаем коллизии киллера
        for _, kChar in ipairs(cachedKillers) do
            if kChar and kChar.Parent then
                local kRoot = kChar:FindFirstChild("HumanoidRootPart")
                if kRoot then
                    local dist = (myRoot.Position - kRoot.Position).Magnitude
                    -- Увеличили дистанцию с 20 до 30 метров
                    if dist <= 30 then
                        for _, part in ipairs(kChar:GetDescendants()) do
                            if part:IsA("BasePart") and part.CanCollide then
                                part.CanCollide = false
                                disabledCollisions[part] = true
                                
                                pcall(function()
                                    local disableCollision = Remotes:FindFirstChild("Collision") and Remotes.Collision:FindFirstChild("DisableCollision")
                                    if disableCollision then
                                        disableCollision:FireServer(part)
                                    end
                                end)
                            end
                        end
                    end
                end
            end
        end
    end
    
    if getRole(localPlayer) == "Killer" then
        -- Отключаем коллизии выживших
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
                local pRoot = p.Character:FindFirstChild("HumanoidRootPart")
                if pRoot then
                    local dist = (myRoot.Position - pRoot.Position).Magnitude
                    -- Увеличили дистанцию с 20 до 30 метров
                    if dist <= 30 then
                        for _, part in ipairs(p.Character:GetDescendants()) do
                            if part:IsA("BasePart") and part.CanCollide then
                                part.CanCollide = false
                                disabledCollisions[part] = true
                                
                                pcall(function()
                                    local disableCollision = Remotes:FindFirstChild("Collision") and Remotes.Collision:FindFirstChild("DisableCollision")
                                    if disableCollision then
                                        disableCollision:FireServer(part)
                                    end
                                end)
                            end
                        end
                    end
                end
            end
        end
    end
    
    if now - lastCollisionCheck > 1 then
        lastCollisionCheck = now
        for part, _ in pairs(disabledCollisions) do
            if not part or not part.Parent then
                disabledCollisions[part] = nil
            end
        end
    end
end)
table.insert(cleanupTasks, bodyblockConn)

local function restoreCollisions()
    for part, _ in pairs(disabledCollisions) do
        pcall(function()
            if part and part.Parent then
                part.CanCollide = true
                
                local enableCollision = Remotes:FindFirstChild("Collision") and Remotes.Collision:FindFirstChild("EnableCollision")
                if enableCollision then
                    enableCollision:FireServer(part)
                end
            end
        end)
    end
    table.clear(disabledCollisions)
end

local originalToggle = Config.AntiBodyblockEnabled
local bodyblockToggleConn = RunService.Heartbeat:Connect(function()
    if originalToggle ~= Config.AntiBodyblockEnabled then
        originalToggle = Config.AntiBodyblockEnabled
        if not Config.AntiBodyblockEnabled then
            restoreCollisions()
        end
    end
end)
table.insert(cleanupTasks, bodyblockToggleConn)

print("[XENON]: Основные функции загружены!")

-- ========================
-- ФУНКЦИИ КИЛЛЕРА
-- ========================

-- AUTO SWING ATTACK
local lastSwingTime = 0
local swingDebounce = 0.4

local autoSwingConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoSwingAttackEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local now = tick()
    if now - lastSwingTime < swingDebounce then return end
    
    local closestSurvivor = nil
    local closestDist = 16
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local sRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if sRoot then
                local dist = (myRoot.Position - sRoot.Position).Magnitude
                if dist < closestDist then
                    closestDist = dist
                    closestSurvivor = p
                end
            end
        end
    end
    
    if closestSurvivor then
        lastSwingTime = now
        local sRoot = closestSurvivor.Character and closestSurvivor.Character:FindFirstChild("HumanoidRootPart")
        task.spawn(function()
            fireAttack()
        end)
    end
end)
table.insert(cleanupTasks, autoSwingConn)

-- INSTANT HIT DETECTION - ИСПРАВЛЕНО
local lastInstantHit = 0
local instantHitDebounce = 0.15

local hitDetectionConn = RunService.Heartbeat:Connect(function()
    if not Config.InstantHitDetectionEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local now = tick()
    if now - lastInstantHit < instantHitDebounce then return end
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local sRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if sRoot then
                local dist = (myRoot.Position - sRoot.Position).Magnitude
                
                if dist <= 6 then
                    lastInstantHit = now
                    task.spawn(function()
                        fireAttack()
                    end)
                    return
                end
            end
        end
    end
end)
table.insert(cleanupTasks, hitDetectionConn)

-- ATTACK RANGE EXPANDER
local rangeExpanderConn = RunService.Heartbeat:Connect(function()
    if not Config.AttackRangeExpanderEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local char = p.Character
            
            for _, partName in ipairs({"HumanoidRootPart", "Torso", "LowerTorso", "UpperTorso", "Head"}) do
                local part = char:FindFirstChild(partName)
                if part then
                    if not originalHitboxSizes[part] then
                        originalHitboxSizes[part] = part.Size
                    end
                    
                    local expandedSize = originalHitboxSizes[part] * Config.AttackRangeMultiplier
                    part.Size = expandedSize
                    part.CanCollide = false
                end
            end
        end
    end
end)
table.insert(cleanupTasks, rangeExpanderConn)

-- LUNGE PREDICTOR
local lastLungeTime = 0
local lungeDebounce = 0.5

local lungePredictorConn = RunService.Heartbeat:Connect(function()
    if not Config.LungePredictorEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local now = tick()
    if now - lastLungeTime < lungeDebounce then return end
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local sRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if sRoot then
                local dist = (myRoot.Position - sRoot.Position).Magnitude
                
                if dist <= Config.LungePredictionDistance and dist > 6 then
                    local survivorVelocity = sRoot.AssemblyLinearVelocity
                    local predictedPos = sRoot.Position + (survivorVelocity * 0.35)
                    
                    local toSurvivor = (predictedPos - myRoot.Position).Unit
                    local myLook = myRoot.CFrame.LookVector
                    local dotProduct = myLook:Dot(toSurvivor)
                    
                    if dotProduct > 0.4 then
                        lastLungeTime = now
                        task.spawn(function()
                            fireLunge()
                        end)
                        return
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, lungePredictorConn)

-- GUARANTEED HIT SYSTEM - ИСПРАВЛЕНО
local lastGuaranteedHit = 0
local guaranteedHitDebounce = 0.3

local guaranteedHitConn = RunService.Heartbeat:Connect(function()
    if not Config.GuaranteedHitSystemEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local now = tick()
    if now - lastGuaranteedHit < guaranteedHitDebounce then return end
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local sRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if sRoot then
                local dist = (myRoot.Position - sRoot.Position).Magnitude
                
                if dist <= 9 then
                    lastGuaranteedHit = now
                    task.spawn(function()
                        for i = 1, 3 do
                            fireAttack()
                            task.wait(0.04)
                        end
                    end)
                    return
                end
            end
        end
    end
end)
table.insert(cleanupTasks, guaranteedHitConn)

-- INSTINCT / REVEAL — серверная подсветка выживших сквозь стены
local lastInstinct = 0
local instinctConn = RunService.Heartbeat:Connect(function()
    if not Config.InstinctRevealEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end

    local now = tick()
    if now - lastInstinct < 1.0 then return end
    lastInstinct = now

    local Killers = Remotes:FindFirstChild("Killers")
    if not Killers then return end

    task.spawn(function()
        pcall(function()
            local instinct = Killers:FindFirstChild("Instinct")
            if instinct then instinct:FireServer() end
        end)
        pcall(function()
            local hl = Killers:FindFirstChild("Highlightremote")
            if hl then hl:FireServer() end
        end)
    end)
end)
table.insert(cleanupTasks, instinctConn)

-- INSTANT PALLET BREAK — мгновенный слом досок
local lastPalletBreak = 0
local palletBreakDebounce = {}
local palletBreakConn = RunService.Heartbeat:Connect(function()
    if not Config.InstantPalletBreakEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end

    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    local now = tick()
    if now - lastPalletBreak < 0.1 then return end
    lastPalletBreak = now

    local Pallet = Remotes:FindFirstChild("Pallet")
    local Jason = Pallet and Pallet:FindFirstChild("Jason")
    if not Jason then return end

    for _, pallet in ipairs(cachedPallets) do
        if pallet and pallet.Parent then
            local dropped = pallet:GetAttribute("Dropped") or pallet:GetAttribute("Down") or pallet:GetAttribute("isDropped")
            if dropped then
                local ok, pivot = pcall(function() return pallet:GetPivot().Position end)
                if ok then
                    local dist = (myRoot.Position - pivot).Magnitude
                    if dist <= 16 then
                        local last = palletBreakDebounce[pallet] or 0
                        if now - last >= 0.5 then
                            palletBreakDebounce[pallet] = now
                            task.spawn(function()
                                pcall(function()
                                    local commit = Jason:FindFirstChild("PalletBreakCommit")
                                    if commit then commit:FireServer(pallet) end
                                end)
                                pcall(function()
                                    local destroy = Jason:FindFirstChild("Destroy")
                                    if destroy then destroy:FireServer(pallet) end
                                end)
                            end)
                        end
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, palletBreakConn)

-- STALKER: INSTANT TIER 3 — мгновенный сталк
local lastStalkerTier = 0
local stalkerTier3Conn = RunService.Heartbeat:Connect(function()
    if not Config.StalkerInstantTier3Enabled then return end
    if getRole(localPlayer) ~= "Killer" then return end

    local now = tick()
    if now - lastStalkerTier < 0.4 then return end
    lastStalkerTier = now

    local Killers = Remotes:FindFirstChild("Killers")
    local Stalker = Killers and Killers:FindFirstChild("Stalker")
    if not Stalker then return end

    task.spawn(function()
        pcall(function()
            local start = Stalker:FindFirstChild("StartStalking")
            if start then start:FireServer() end
        end)
        pcall(function()
            local evolve = Stalker:FindFirstChild("EvolveStage")
            if evolve then evolve:FireServer() end
        end)
        pcall(function()
            local update = Stalker:FindFirstChild("UpdateStalking")
            if update then update:FireServer(100) end
        end)
    end)
end)
table.insert(cleanupTasks, stalkerTier3Conn)

-- MASKED: AUTO POWER
local lastMaskedPower = 0
local maskedPowerConn = RunService.Heartbeat:Connect(function()
    if not Config.MaskedAutoPowerEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end

    local now = tick()
    if now - lastMaskedPower < 1.0 then return end
    lastMaskedPower = now

    local Killers = Remotes:FindFirstChild("Killers")
    local Masked = Killers and Killers:FindFirstChild("Masked")
    if not Masked then return end

    task.spawn(function()
        pcall(function()
            local activate = Masked:FindFirstChild("Activatepower")
            if activate then activate:FireServer() end
        end)
    end)
end)
table.insert(cleanupTasks, maskedPowerConn)

-- HIDDEN: AUTO LEAP — авто-прыжок на ближайшего выжившего
local lastHiddenLeap = 0
local hiddenLeapConn = RunService.Heartbeat:Connect(function()
    if not Config.HiddenAutoLeapEnabled then return end
    if getRole(localPlayer) ~= "Killer" then return end

    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    local now = tick()
    if now - lastHiddenLeap < 0.8 then return end

    local Killers = Remotes:FindFirstChild("Killers")
    local Hidden = Killers and Killers:FindFirstChild("Hidden")
    if not Hidden then return end

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local sRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if sRoot then
                local dist = (myRoot.Position - sRoot.Position).Magnitude
                if dist <= 25 and dist > 4 then
                    lastHiddenLeap = now
                    task.spawn(function()
                        pcall(function()
                            local leap = Hidden:FindFirstChild("Leap")
                            if leap then leap:FireServer(sRoot.Position) end
                        end)
                        pcall(function()
                            local m2 = Hidden:FindFirstChild("M2")
                            if m2 then m2:FireServer() end
                        end)
                    end)
                    return
                end
            end
        end
    end
end)
table.insert(cleanupTasks, hiddenLeapConn)

-- AUTO FLASHLIGHT BLIND
local lastFlashlightBlind = 0
local flashlightBlindConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoFlashlightBlindEnabled then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    local now = tick()
    if now - lastFlashlightBlind < Config.FlashlightBlindDelay then return end
    
    local flashlight = nil
    for _, item in ipairs(myChar:GetChildren()) do
        if item:IsA("Tool") then
            local name = item.Name:lower()
            if name:find("flashlight") or name:find("torch") or name:find("light") then
                flashlight = item
                break
            end
        end
    end
    
    if not flashlight then return end
    
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Killer" and p.Character then
            local kRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if kRoot then
                local dist = (myRoot.Position - kRoot.Position).Magnitude
                
                if dist <= Config.FlashlightBlindDistance then
                    local killerLook = kRoot.CFrame.LookVector
                    local toKiller = (kRoot.Position - myRoot.Position).Unit
                    local dotProduct = killerLook:Dot(toKiller)
                    
                    if dotProduct > 0 then
                        lastFlashlightBlind = now
                        
                        task.spawn(function()
                            pcall(function()
                                local flashlightActivate = Remotes:FindFirstChild("Items") and Remotes.Items:FindFirstChild("Flashlight") and Remotes.Items.Flashlight:FindFirstChild("Activate")
                                if flashlightActivate then
                                    flashlightActivate:FireServer(flashlight)
                                end
                                
                                local gotBlinded = Remotes:FindFirstChild("Items") and Remotes.Items:FindFirstChild("Flashlight") and Remotes.Items.Flashlight:FindFirstChild("GotBlinded")
                                if gotBlinded then
                                    gotBlinded:FireServer(p)
                                end
                            end)
                        end)
                        
                        return
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, flashlightBlindConn)

-- ========================
-- МАЙКЛ МАЙЕРС - ФУНКЦИИ
-- (обёрнуто в do..end чтобы освободить слоты локалов главного чанка)
-- ========================
do
local michaelRemoteCache = nil
local lastMichaelRemoteRefresh = 0
local michaelRemoteRefreshInterval = 1
local michaelTierBurstDebounce = 0.75
local michaelTierSustainInterval = 1.5
local michaelStalkUpdateInterval = 0.2
local michaelHighlightInterval = 0.45
local michaelState = {
    targetPlayer = nil,
    targetCharacter = nil,
    activeStalk = false,
    lastStalkUpdate = 0,
    lastTierBurst = 0,
    lastTierRefresh = 0,
    lastHighlight = 0,
}

local function getMichaelRemoteMap(forceRefresh)
    local now = tick()
    if not forceRefresh and michaelRemoteCache and now - lastMichaelRemoteRefresh < michaelRemoteRefreshInterval then
        return michaelRemoteCache
    end

    local killers = Remotes:FindFirstChild("Killers")
    local stalker = killers and killers:FindFirstChild("Stalker")
    local masked = killers and killers:FindFirstChild("Masked")

    michaelRemoteCache = {
        killers = killers,
        stalker = stalker,
        masked = masked,
        instinct = killers and killers:FindFirstChild("Instinct"),
        highlight = killers and killers:FindFirstChild("Highlightremote"),
        startStalking = stalker and stalker:FindFirstChild("StartStalking"),
        updateStalking = stalker and stalker:FindFirstChild("UpdateStalking"),
        stopStalking = stalker and stalker:FindFirstChild("StopStalking"),
        evolveStage = stalker and stalker:FindFirstChild("EvolveStage"),
        consumeReady = stalker and stalker:FindFirstChild("ConsumeReady"),
        activatePower = masked and masked:FindFirstChild("Activatepower"),
        deactivatePower = masked and masked:FindFirstChild("Deactivatepower"),
    }
    lastMichaelRemoteRefresh = now
    return michaelRemoteCache
end

local function fireServerEvent(remote, ...)
    if not (remote and remote:IsA("RemoteEvent")) then return false end
    local args = {...}
    return pcall(function()
        remote:FireServer(unpack(args))
    end)
end

local function isMichaelCharacter(myChar)
    if not myChar or getRole(localPlayer) ~= "Killer" then
        return false
    end

    for _, attr in ipairs({"EvilWithin", "Tier", "StalkLevel", "Tier3Timer", "EvilWithinTimer"}) do
        if myChar:GetAttribute(attr) ~= nil then
            return true
        end
    end

    local charName = myChar.Name:lower()
    if charName:find("michael") or charName:find("myers") or charName:find("stalker") then
        return true
    end

    return false
end

local function setMichaelTierAttributes(myChar, tierLevel)
    tierLevel = tierLevel or 3

    if myChar:GetAttribute("EvilWithin") ~= nil then
        myChar:SetAttribute("EvilWithin", tierLevel)
    end
    if myChar:GetAttribute("Tier") ~= nil then
        myChar:SetAttribute("Tier", tierLevel)
    end
    if myChar:GetAttribute("StalkLevel") ~= nil then
        myChar:SetAttribute("StalkLevel", 100)
    end
    if myChar:GetAttribute("Tier3Timer") ~= nil then
        myChar:SetAttribute("Tier3Timer", 999)
    end
    if myChar:GetAttribute("EvilWithinTimer") ~= nil then
        myChar:SetAttribute("EvilWithinTimer", 999)
    end
    if myChar:GetAttribute("Tier3Expired") ~= nil then
        myChar:SetAttribute("Tier3Expired", false)
    end
end

local function forceMichaelTier3(myChar, remoteMap)
    if not myChar then return end

    setMichaelTierAttributes(myChar, 3)

    if remoteMap.evolveStage then
        fireServerEvent(remoteMap.evolveStage, 3)
    end
    if remoteMap.consumeReady then
        fireServerEvent(remoteMap.consumeReady, true)
    end
    if remoteMap.activatePower then
        fireServerEvent(remoteMap.activatePower)
    end
end

local function stopMichaelStalk(remoteMap)
    local targetChar = michaelState.targetCharacter
    if michaelState.activeStalk and remoteMap then
        if remoteMap.stopStalking then
            fireServerEvent(remoteMap.stopStalking, targetChar)
        end
        if remoteMap.deactivatePower then
            fireServerEvent(remoteMap.deactivatePower)
        end
    end

    michaelState.targetPlayer = nil
    michaelState.targetCharacter = nil
    michaelState.activeStalk = false
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = true

local function hasLineOfSight(myChar, targetChar, myRoot, targetRoot)
    rayParams.FilterDescendantsInstances = {myChar, targetChar}
    local direction = targetRoot.Position - myRoot.Position
    local result = workspace:Raycast(myRoot.Position, direction, rayParams)
    return not result or isDescendantOf(result.Instance, targetChar)
end

local function getBestMichaelTarget(myChar, myRoot, maxDistance, requireLOS)
    local bestPlayer = nil
    local bestCharacter = nil
    local bestDistance = maxDistance + 0.001

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Survivor" and p.Character then
            local char = p.Character
            local hum = char:FindFirstChildOfClass("Humanoid")
            local root = char:FindFirstChild("HumanoidRootPart")
            if hum and hum.Health > 0 and root then
                local dist = (myRoot.Position - root.Position).Magnitude
                if dist <= maxDistance then
                    local canSee = true
                    if requireLOS then
                        canSee = hasLineOfSight(myChar, char, myRoot, root)
                    end

                    if canSee and dist < bestDistance then
                        bestDistance = dist
                        bestPlayer = p
                        bestCharacter = char
                    end
                end
            end
        end
    end

    return bestPlayer, bestCharacter, bestDistance
end

local function updateMichaelHighlight(remoteMap, targetChar, now)
    if not (remoteMap and remoteMap.highlight and targetChar) then return end
    if now - michaelState.lastHighlight < michaelHighlightInterval then return end

    michaelState.lastHighlight = now
    fireServerEvent(remoteMap.highlight, targetChar, true)
end

local function updateMichaelStalk(remoteMap, targetPlayer, targetChar, intensity, now)
    if not (remoteMap and targetPlayer and targetChar) then return end

    if michaelState.targetCharacter ~= targetChar or not michaelState.activeStalk then
        stopMichaelStalk(remoteMap)
        if remoteMap.activatePower then
            fireServerEvent(remoteMap.activatePower)
        end
        if remoteMap.startStalking then
            fireServerEvent(remoteMap.startStalking, targetChar)
        end
        michaelState.targetPlayer = targetPlayer
        michaelState.targetCharacter = targetChar
        michaelState.activeStalk = true
        michaelState.lastStalkUpdate = 0
    end

    if now - michaelState.lastStalkUpdate < michaelStalkUpdateInterval then
        return
    end

    michaelState.lastStalkUpdate = now

    if remoteMap.updateStalking then
        fireServerEvent(remoteMap.updateStalking, targetChar, intensity)
    end
    if remoteMap.instinct then
        fireServerEvent(remoteMap.instinct, targetChar)
    end
end

local function runMichaelStalkLogic(maxDistance, intensity, useWallhack)
    if not (Config.AutoStalkEnabled or Config.WallhackStalkEnabled) then
        stopMichaelStalk(getMichaelRemoteMap())
        return
    end

    local myChar = localPlayer.Character
    if not isMichaelCharacter(myChar) then
        stopMichaelStalk(getMichaelRemoteMap())
        return
    end

    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then
        stopMichaelStalk(getMichaelRemoteMap())
        return
    end

    local now = tick()
    local remoteMap = getMichaelRemoteMap()
    local targetPlayer, targetChar = getBestMichaelTarget(myChar, myRoot, maxDistance, not useWallhack)

    if not targetPlayer or not targetChar then
        stopMichaelStalk(remoteMap)
        return
    end

    updateMichaelStalk(remoteMap, targetPlayer, targetChar, intensity, now)
    if useWallhack then
        updateMichaelHighlight(remoteMap, targetChar, now)
    end
end

-- INSTANT TIER 3 (Мгновенно 3 уровень)
local instantTier3Conn = RunService.Heartbeat:Connect(function()
    if not Config.InstantTier3Enabled then return end

    local myChar = localPlayer.Character
    if not isMichaelCharacter(myChar) then return end

    local now = tick()
    if now - michaelState.lastTierBurst < michaelTierBurstDebounce then return end
    michaelState.lastTierBurst = now

    forceMichaelTier3(myChar, getMichaelRemoteMap())
end)
table.insert(cleanupTasks, instantTier3Conn)

-- INFINITE TIER 3 (Бесконечный 3 уровень)
local infiniteTier3Conn = RunService.Heartbeat:Connect(function()
    if not Config.InfiniteTier3Enabled then return end

    local myChar = localPlayer.Character
    if not isMichaelCharacter(myChar) then return end

    setMichaelTierAttributes(myChar, 3)

    local now = tick()
    if now - michaelState.lastTierRefresh < michaelTierSustainInterval then return end
    michaelState.lastTierRefresh = now

    forceMichaelTier3(myChar, getMichaelRemoteMap())
end)
table.insert(cleanupTasks, infiniteTier3Conn)

-- AUTO STALK (Автоматическая слежка)
local autoStalkConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoStalkEnabled then
        if not Config.WallhackStalkEnabled then
            stopMichaelStalk(getMichaelRemoteMap())
        end
        return
    end
    if Config.WallhackStalkEnabled then return end

    runMichaelStalkLogic(40, 10, false)
end)
table.insert(cleanupTasks, autoStalkConn)

-- WALLHACK STALK (Слежка сквозь стены)
local wallhackStalkConn = RunService.Heartbeat:Connect(function()
    if not Config.WallhackStalkEnabled then
        if not Config.AutoStalkEnabled then
            stopMichaelStalk(getMichaelRemoteMap())
        end
        return
    end

    runMichaelStalkLogic(60, 15, true)
end)
table.insert(cleanupTasks, wallhackStalkConn)
end

-- СКАНЕР КАРТЫ
local function isPlayerCharacterModel(model)
    if not model or not model:IsA("Model") then return false end
    return Players:GetPlayerFromCharacter(model) ~= nil or model:FindFirstChildOfClass("Humanoid") ~= nil
end

local function scanMapObjects()
    for model, _ in pairs(searchedModels) do
        if not model or not model.Parent then
            searchedModels[model] = nil
            for i, v in ipairs(gens) do
                if v == model then
                    table.remove(gens, i)
                    break
                end
            end
        end
    end

    table.clear(cachedPallets)
    table.clear(cachedLevers)
    table.clear(cachedHooks)
    
    for _, obj in ipairs(workspace:GetDescendants()) do
        if obj:IsA("Model") and not isPlayerCharacterModel(obj) then
            local name = obj.Name:lower()
            
            if name == "generator" or name == "gen" or name:find("generator") then
                if not searchedModels[obj] then
                    searchedModels[obj] = true
                    table.insert(gens, obj)
                    attachGenESP(obj)
                end
            elseif name:find("pallet") or name:find("board") or name:find("plank") or name:find("barricade") then
                if not table.find(cachedPallets, obj) then
                    table.insert(cachedPallets, obj)
                end
            elseif name:find("lever") or name:find("switch") or name:find("gate") then
                if not table.find(cachedLevers, obj) then
                    table.insert(cachedLevers, obj)
                end
            elseif name:find("hook") or name:find("noose") or name:find("cage") or name:find("chair") or name:find("gallow") or name:find("hang") then
                if not table.find(cachedHooks, obj) then
                    table.insert(cachedHooks, obj)
                end
            end
        end
    end
end

local scanLoop = task.spawn(function()
    while true do
        task.wait(3)
        pcall(scanMapObjects)
    end
end)
table.insert(cleanupTasks, scanLoop)

-- ИНИЦИАЛИЗАЦИЯ ИГРОКОВ
local function initPlayer(player)
    if player == localPlayer then return end
    
    local function onChar()
        task.wait(0.3)
        applyHighlight(player)
    end
    
    if player.Character then onChar() end
    local conn = player.CharacterAdded:Connect(onChar)
    table.insert(cleanupTasks, conn)
    
    local conn2 = player:GetAttributeChangedSignal("Role"):Connect(function() getRole(player) end)
    table.insert(cleanupTasks, conn2)
end

for _, p in ipairs(Players:GetPlayers()) do initPlayer(p) end
local connPlayerAdded = Players.PlayerAdded:Connect(initPlayer)
table.insert(cleanupTasks, connPlayerAdded)

local function removeHighlight(player)
    if playerHighlights[player] then
        pcall(function() playerHighlights[player]:Destroy() end)
        playerHighlights[player] = nil
    end
end

local connPlayerRemoving = Players.PlayerRemoving:Connect(function(p)
    playerData[p.UserId] = nil
    removeHighlight(p)
    if p.Character then
        for _, partName in ipairs({"HumanoidRootPart", "Torso", "LowerTorso", "UpperTorso", "Head"}) do
            local part = p.Character:FindFirstChild(partName)
            if part then
                originalHitboxSizes[part] = nil
            end
        end
    end
end)
table.insert(cleanupTasks, connPlayerRemoving)

pcall(scanMapObjects)

-- ========================
-- FLY (ПОЛЁТ) - ИСПРАВЛЕНО V2
-- ========================
local flyBodyVelocity = nil
local flyBodyGyro = nil

local function enableFly()
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end
    
    if not flyBodyVelocity then
        flyBodyVelocity = Instance.new("BodyVelocity")
        flyBodyVelocity.MaxForce = Vector3.new(9e9, 9e9, 9e9)
        flyBodyVelocity.Velocity = Vector3.new(0, 0, 0)
        flyBodyVelocity.Parent = myRoot
        table.insert(cleanupTasks, flyBodyVelocity)
    end
    
    if not flyBodyGyro then
        flyBodyGyro = Instance.new("BodyGyro")
        flyBodyGyro.MaxTorque = Vector3.new(0, 9e9, 0) -- Только по Y оси (горизонтальное вращение)
        flyBodyGyro.P = 9e4
        flyBodyGyro.D = 500
        flyBodyGyro.Parent = myRoot
        table.insert(cleanupTasks, flyBodyGyro)
    end
end

local function disableFly()
    if flyBodyVelocity then
        flyBodyVelocity:Destroy()
        flyBodyVelocity = nil
    end
    if flyBodyGyro then
        flyBodyGyro:Destroy()
        flyBodyGyro = nil
    end
end

local flyConn2 = RunService.Heartbeat:Connect(function()
    if Config.FlyEnabled then
        enableFly()
        
        local myChar = localPlayer.Character
        if not myChar then return end
        local myRoot = myChar:FindFirstChild("HumanoidRootPart")
        local hum = myChar:FindFirstChildOfClass("Humanoid")
        if not (myRoot and hum and flyBodyVelocity and flyBodyGyro) then return end
        
        local camera = workspace.CurrentCamera
        local moveDirection = Vector3.new(0, 0, 0)
        
        -- Получаем направление камеры
        local camCF = camera.CFrame
        local camLook = camCF.LookVector
        local camRight = camCF.RightVector
        
        -- Управление WASD - ИСПРАВЛЕНО
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then
            moveDirection = moveDirection + camLook
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then
            moveDirection = moveDirection - camLook
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.A) then
            moveDirection = moveDirection - camRight
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.D) then
            moveDirection = moveDirection + camRight
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
            moveDirection = moveDirection + Vector3.new(0, 1, 0)
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
            moveDirection = moveDirection - Vector3.new(0, 1, 0)
        end
        
        -- Мобильное управление (джойстик) - ИСПРАВЛЕНО
        if hum.MoveDirection.Magnitude > 0 then
            local moveDir = hum.MoveDirection
            -- Преобразуем направление джойстика в мировые координаты относительно камеры
            local forward = camLook * moveDir.Z
            local right = camRight * moveDir.X
            moveDirection = moveDirection + forward + right
        end
        
        -- Нормализуем направление
        if moveDirection.Magnitude > 0 then
            moveDirection = moveDirection.Unit
        end
        
        -- Применяем скорость
        flyBodyVelocity.Velocity = moveDirection * Config.FlySpeed
        
        -- Поворачиваем персонажа в сторону движения (только горизонтально)
        if moveDirection.Magnitude > 0 then
            local horizontalDirection = Vector3.new(moveDirection.X, 0, moveDirection.Z)
            if horizontalDirection.Magnitude > 0 then
                local targetCFrame = CFrame.lookAt(myRoot.Position, myRoot.Position + horizontalDirection)
                flyBodyGyro.CFrame = targetCFrame
            end
        else
            -- Если стоим на месте, смотрим в сторону камеры
            local camHorizontal = Vector3.new(camLook.X, 0, camLook.Z)
            if camHorizontal.Magnitude > 0 then
                local targetCFrame = CFrame.lookAt(myRoot.Position, myRoot.Position + camHorizontal)
                flyBodyGyro.CFrame = targetCFrame
            end
        end
        
        hum.PlatformStand = true
    else
        disableFly()
        
        local myChar = localPlayer.Character
        if myChar then
            local hum = myChar:FindFirstChildOfClass("Humanoid")
            if hum then
                hum.PlatformStand = false
            end
        end
    end
end)
table.insert(cleanupTasks, flyConn2)

-- ========================
-- NOCLIP (ПРОХОЖДЕНИЕ СКВОЗЬ СТЕНЫ)
-- ========================
local noclipConn = RunService.Stepped:Connect(function()
    if Config.NoClipEnabled then
        local myChar = localPlayer.Character
        if myChar then
            for _, part in ipairs(myChar:GetDescendants()) do
                if part:IsA("BasePart") then
                    part.CanCollide = false
                end
            end
        end
    end
end)
table.insert(cleanupTasks, noclipConn)

-- ========================
-- FLING (СПОКОЙНЫЙ ТОЛЧОК БЕЗ КРУТИЛКИ)
-- ========================
local flingVelocity = nil
local flingWasEnabled = false
local lastFlingPushTime = 0
local flingOriginalPartStates = {}

local function repairLocalMovementPhysics()
    local myChar = localPlayer.Character
    if not myChar then return end

    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    local hum = myChar:FindFirstChildOfClass("Humanoid")

    if hum then
        hum.PlatformStand = false
        hum.Sit = false
        hum.AutoRotate = true
    end

    if myRoot then
        myRoot.CanCollide = false
        myRoot.AssemblyAngularVelocity = Vector3.new(0, 0, 0)

        for _, child in ipairs(myRoot:GetChildren()) do
            if child:IsA("BodyAngularVelocity") and child.P >= 9e8 then
                child:Destroy()
            elseif child:IsA("BodyVelocity") and not Config.FlyEnabled and child.MaxForce.Magnitude >= 1e8 then
                child:Destroy()
            end
        end
    end
end

local function disableFling()
    local myChar = localPlayer.Character
    local myRoot = myChar and myChar:FindFirstChild("HumanoidRootPart")

    if flingVelocity then
        flingVelocity:Destroy()
        flingVelocity = nil
    end

    if myRoot then
        myRoot.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
        myRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    end

    for part, state in pairs(flingOriginalPartStates) do
        if part and part.Parent then
            part.CanCollide = state.CanCollide
            part.Massless = state.Massless
        end
        flingOriginalPartStates[part] = nil
    end

    repairLocalMovementPhysics()
end

local function getClosestFlingTarget(myRoot)
    local closestRoot = nil
    local closestDistance = math.huge

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and p.Character then
            local char = p.Character
            local hum = char:FindFirstChildOfClass("Humanoid")
            local root = char:FindFirstChild("HumanoidRootPart")

            if root and hum and hum.Health > 0 then
                local dist = (myRoot.Position - root.Position).Magnitude
                if dist <= 9 and dist < closestDistance then
                    closestRoot = root
                    closestDistance = dist
                end
            end
        end
    end

    return closestRoot
end

local flingConn = RunService.Heartbeat:Connect(function()
    if not Config.FlingEnabled then
        if flingWasEnabled then
            disableFling()
            flingWasEnabled = false
        end
        return
    end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    local myHum = myChar:FindFirstChildOfClass("Humanoid")
    if not (myRoot and myHum and myHum.Health > 0) then return end

    flingWasEnabled = true

    if Config.FlyEnabled then
        Config.FlyEnabled = false
        disableFly()
    end
    
    local targetRoot = getClosestFlingTarget(myRoot)
    if targetRoot then
        local now = tick()
        if now - lastFlingPushTime < 0.6 then return end
        lastFlingPushTime = now

        -- Запоминаем исходное состояние корня, чтобы disableFling() мог его вернуть
        if not flingOriginalPartStates[myRoot] then
            flingOriginalPartStates[myRoot] = {
                CanCollide = myRoot.CanCollide,
                Massless = myRoot.Massless,
            }
        end

        local power = math.clamp(Config.FlingPower or 5000, 1000, 10000)

        -- Контактный fling: задать скорость напрямую чужому персонажу нельзя
        -- (нет network ownership — сервер перезапишет). Поэтому перекрываем корнем
        -- тело цели и разгоняем СВОЙ корень (его скорость реплицируется) — физический
        -- движок при разрешении взаимопроникновения выбрасывает цель.
        myRoot.CanCollide = true

        task.spawn(function()
            for _ = 1, 5 do
                if not (Config.FlingEnabled and myChar.Parent and targetRoot.Parent and myRoot.Parent) then
                    break
                end

                local offset = targetRoot.Position - myRoot.Position
                local horizontal = Vector3.new(offset.X, 0, offset.Z)
                if horizontal.Magnitude < 0.1 then
                    horizontal = myRoot.CFrame.LookVector
                end
                local direction = horizontal.Unit

                myRoot.CFrame = targetRoot.CFrame  -- перекрываем тело цели
                myRoot.AssemblyLinearVelocity = direction * power + Vector3.new(0, power * 0.5, 0)
                myRoot.AssemblyAngularVelocity = Vector3.new(0, power, 0)

                RunService.Heartbeat:Wait()
            end

            -- Гасим собственную инерцию, чтобы не улетать следом за целью
            if myRoot and myRoot.Parent then
                myRoot.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
                myRoot.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
            end
        end)
    end
end)
table.insert(cleanupTasks, flingConn)
task.defer(repairLocalMovementPhysics)

-- ========================
-- INFINITE STAMINA (БЕСКОНЕЧНАЯ ВЫНОСЛИВОСТЬ)
-- ========================
local staminaConn = RunService.Heartbeat:Connect(function()
    if not Config.InfiniteStaminaEnabled then return end
    
    local myChar = localPlayer.Character
    if not myChar then return end
    local hum = myChar:FindFirstChildOfClass("Humanoid")
    if not hum then return end
    
    -- Сбрасываем все атрибуты усталости
    for _, attr in ipairs({"Exhausted", "Tired", "Fatigue", "Stamina", "Sprint", "Running"}) do
        if myChar:GetAttribute(attr) then
            myChar:SetAttribute(attr, false)
        end
    end
    
    -- Убираем эффекты усталости
    if hum:FindFirstChild("Exhausted") then
        hum.Exhausted:Destroy()
    end
    
    -- Всегда можем бежать
    if myChar:FindFirstChild("Stamina") then
        local stamina = myChar.Stamina
        if stamina:IsA("NumberValue") or stamina:IsA("IntValue") then
            stamina.Value = 100
        end
    end
    
    -- Убираем замедление от усталости
    if hum.WalkSpeed < Config.SpeedValue then
        hum.WalkSpeed = Config.SpeedValue
    end
end)
table.insert(cleanupTasks, staminaConn)

-- ========================
-- AUTO PALLET STUN — сброс доски когда киллер прямо под ней (гарантия оглушения)
-- ========================
local palletStunDebounce = {}
local lastPalletStun = 0
local palletStunConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoPalletStunEnabled then return end

    local now = tick()
    if now - lastPalletStun < 0.1 then return end
    lastPalletStun = now

    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    local PalletFolder = Remotes:FindFirstChild("Pallet")
    if not PalletFolder then return end
    local PalletDropEvent = PalletFolder:FindFirstChild("PalletDropEvent")
    local PalletDropAnim = PalletFolder:FindFirstChild("PalletDropAnim")
    local PalletDropCommit = PalletFolder:FindFirstChild("PalletDropCommit")
    if not (PalletDropEvent and PalletDropAnim and PalletDropCommit) then return end

    -- ищем ближайшего киллера
    local killerRoot = nil
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Killer" and p.Character then
            killerRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if killerRoot then break end
        end
    end
    if not killerRoot then return end

    for _, pallet in ipairs(cachedPallets) do
        if pallet and pallet.Parent then
            local ok, pPos = pcall(function() return pallet:GetPivot().Position end)
            if ok then
                local dropped = pallet:GetAttribute("Dropped") or pallet:GetAttribute("Down") or pallet:GetAttribute("isDropped")
                local distKiller = (killerRoot.Position - pPos).Magnitude
                local distMe = (myRoot.Position - pPos).Magnitude
                -- киллер вплотную к доске (под ней), я рядом, доска ещё стоит
                if not dropped and distKiller <= 7 and distMe <= 16 then
                    local last = palletStunDebounce[pallet] or 0
                    if now - last >= 2 then
                        palletStunDebounce[pallet] = now
                        droppedPalletsDebounce[pallet] = true
                        task.spawn(function()
                            pcall(function()
                                PalletDropEvent:FireServer(pallet)
                                task.wait(0.04)
                                PalletDropAnim:FireServer(pallet)
                                task.wait(0.06)
                                PalletDropCommit:FireServer(pallet)
                            end)
                        end)
                    end
                end
            end
        end
    end
end)
table.insert(cleanupTasks, palletStunConn)

-- ========================
-- GOD MODE / ANTI-DOWN — держим состояние "здоров" (РИСКОВАННО: античит)
-- ========================
local lastGodMode = 0
local godModeConn = RunService.Heartbeat:Connect(function()
    if not Config.GodModeEnabled then return end

    local myChar = localPlayer.Character
    if not myChar then return end
    local hum = myChar:FindFirstChildOfClass("Humanoid")
    if hum then
        if hum.Health < hum.MaxHealth then hum.Health = hum.MaxHealth end
    end

    -- сбрасываем флаги ранения/нокдауна на персонаже
    for _, attr in ipairs({"Injured", "Hurt", "Downed", "Knocked", "Dying", "Carried", "Damaged"}) do
        if myChar:GetAttribute(attr) then
            myChar:SetAttribute(attr, false)
        end
    end

    -- периодически шлём Reset лечения (снять статус ранения)
    local now = tick()
    if now - lastGodMode >= 0.5 then
        lastGodMode = now
        local Healing = Remotes:FindFirstChild("Healing")
        if Healing then
            task.spawn(function()
                pcall(function()
                    local reset = Healing:FindFirstChild("Reset")
                    if reset then reset:FireServer() end
                end)
            end)
        end
    end
end)
table.insert(cleanupTasks, godModeConn)

-- ========================
-- AUTO SELF-HEAL — авто-лечение когда ранен
-- ========================
local lastSelfHeal = 0
local selfHealConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoSelfHealEnabled then return end

    local now = tick()
    if now - lastSelfHeal < 0.4 then return end

    local myChar = localPlayer.Character
    if not myChar then return end
    local hum = myChar:FindFirstChildOfClass("Humanoid")

    -- считаем "ранен" если есть флаг или хп не полное
    local injured = myChar:GetAttribute("Injured") or myChar:GetAttribute("Hurt")
        or (hum and hum.Health < hum.MaxHealth)
    if not injured then return end

    lastSelfHeal = now
    task.spawn(function()
        -- бинт
        pcall(function()
            local Items = Remotes:FindFirstChild("Items")
            local bandage = Items and Items:FindFirstChild("Bandage")
            local fire = bandage and bandage:FindFirstChild("Fire")
            if fire then fire:FireServer() end
        end)
        -- событие лечения (true = успешный скилл-чек)
        pcall(function()
            local Healing = Remotes:FindFirstChild("Healing")
            local heal = Healing and Healing:FindFirstChild("HealEvent")
            if heal then heal:FireServer(localPlayer, true) end
        end)
    end)
end)
table.insert(cleanupTasks, selfHealConn)

-- ========================
-- AUTO ITEM USE — авто-использование экипированного предмета
-- ========================
local lastItemUse = 0
local itemUseConn = RunService.Heartbeat:Connect(function()
    if not Config.AutoItemUseEnabled then return end

    local now = tick()
    if now - lastItemUse < 0.6 then return end

    local myChar = localPlayer.Character
    if not myChar then return end
    local myRoot = myChar:FindFirstChild("HumanoidRootPart")
    if not myRoot then return end

    -- активируем предмет только если киллер рядом
    local killerNear = false
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer and getRole(p) == "Killer" and p.Character then
            local kRoot = p.Character:FindFirstChild("HumanoidRootPart")
            if kRoot and (kRoot.Position - myRoot.Position).Magnitude <= 16 then
                killerNear = true
                break
            end
        end
    end
    if not killerNear then return end

    local equipped = localPlayer:GetAttribute("EquippedItem")
    local Items = Remotes:FindFirstChild("Items")
    if not (equipped and Items) then return end

    lastItemUse = now
    task.spawn(function()
        if equipped == "Parrying Dagger" then
            pcall(function()
                local pd = Items:FindFirstChild("Parrying Dagger")
                local parry = pd and pd:FindFirstChild("parry")
                if parry then parry:FireServer() end
            end)
        elseif equipped == "Riot Shield" then
            pcall(function()
                local rs = Items:FindFirstChild("Riot Shield")
                local rush = rs and rs:FindFirstChild("Rush")
                if rush then rush:FireServer() end
            end)
        end
    end)
end)
table.insert(cleanupTasks, itemUseConn)

-- ========================
-- FOV / CAMERA UNLOCK + TRACERS + HEALTH BARS
-- (обёрнуто в do..end чтобы не превышать лимит локалов главного чанка)
-- ========================
do
local DEFAULT_FOV = 70
local originalMaxZoom = localPlayer.CameraMaxZoomDistance

local fovConn = RunService.RenderStepped:Connect(function()
    local cam = workspace.CurrentCamera
    if not cam then return end

    if Config.FOVEnabled then
        cam.FieldOfView = math.clamp(Config.FOVValue or 90, 70, 120)
    elseif math.abs(cam.FieldOfView - DEFAULT_FOV) > 0.01 then
        cam.FieldOfView = DEFAULT_FOV
    end

    if Config.CameraUnlockEnabled then
        if localPlayer.CameraMaxZoomDistance < 9999 then
            localPlayer.CameraMaxZoomDistance = 10000
        end
    elseif localPlayer.CameraMaxZoomDistance > originalMaxZoom then
        localPlayer.CameraMaxZoomDistance = originalMaxZoom
    end
end)
table.insert(cleanupTasks, fovConn)

-- ========================
-- TRACERS (линии до игроков через Drawing API)
-- ========================
local tracerLines = {}
local hasDrawing = (typeof(Drawing) == "table") or (type(Drawing) == "userdata")

local function clearTracer(plr)
    local line = tracerLines[plr]
    if line then
        pcall(function() line:Remove() end)
        tracerLines[plr] = nil
    end
end

local function clearAllTracers()
    for plr in pairs(tracerLines) do
        clearTracer(plr)
    end
end

local tracerConn = RunService.RenderStepped:Connect(function()
    if not (Config.TracersEnabled and hasDrawing) then
        if next(tracerLines) then clearAllTracers() end
        return
    end

    local cam = workspace.CurrentCamera
    if not cam then return end
    local origin = Vector2.new(cam.ViewportSize.X / 2, cam.ViewportSize.Y)

    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer then
            local char = p.Character
            local root = char and char:FindFirstChild("HumanoidRootPart")
            local hum = char and char:FindFirstChildOfClass("Humanoid")

            if root and hum and hum.Health > 0 then
                local screenPos, onScreen = cam:WorldToViewportPoint(root.Position)
                local line = tracerLines[p]
                if onScreen then
                    if not line then
                        line = Drawing.new("Line")
                        line.Thickness = 1.6
                        line.Transparency = 1
                        tracerLines[p] = line
                    end
                    line.Color = getColor(p)
                    line.From = origin
                    line.To = Vector2.new(screenPos.X, screenPos.Y)
                    line.Visible = true
                elseif line then
                    line.Visible = false
                end
            else
                clearTracer(p)
            end
        end
    end

    -- убрать линии вышедших игроков
    for plr in pairs(tracerLines) do
        if not plr.Parent then
            clearTracer(plr)
        end
    end
end)
table.insert(cleanupTasks, tracerConn)
local tracerLeaveConn = Players.PlayerRemoving:Connect(clearTracer)
table.insert(cleanupTasks, tracerLeaveConn)

if not hasDrawing then
    warn("[XENON]: Drawing API недоступен — трейсеры работать не будут на этом эксекьюторе")
end

-- ========================
-- HEALTH BARS (полоса здоровья над выжившими)
-- ========================
local function applyHealthBar(player)
    local char = player.Character
    if not char then return end
    local root = char:FindFirstChild("HumanoidRootPart")
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not (root and hum) then return end

    local bar = root:FindFirstChild("Fox_HealthBar")

    -- показываем только живым выжившим
    if not (Config.HealthBarsEnabled and getRole(player) == "Survivor" and hum.Health > 0) then
        if bar then bar.Enabled = false end
        return
    end

    if not bar then
        bar = Instance.new("BillboardGui")
        bar.Name = "Fox_HealthBar"
        bar.AlwaysOnTop = true
        bar.Size = UDim2.new(0, 60, 0, 8)
        bar.StudsOffset = Vector3.new(0, 3.6, 0)
        bar.Parent = root
        table.insert(cleanupTasks, bar)

        local bg = Instance.new("Frame")
        bg.Name = "BG"
        bg.Size = UDim2.new(1, 0, 1, 0)
        bg.BackgroundColor3 = Color3.fromRGB(20, 20, 24)
        bg.BackgroundTransparency = 0.25
        bg.BorderSizePixel = 0
        bg.Parent = bar
        local bgCorner = Instance.new("UICorner", bg)
        bgCorner.CornerRadius = UDim.new(0, 3)
        local bgStroke = Instance.new("UIStroke", bg)
        bgStroke.Color = Color3.fromRGB(0, 0, 0)
        bgStroke.Thickness = 1
        bgStroke.Transparency = 0.4

        local fill = Instance.new("Frame")
        fill.Name = "Fill"
        fill.Size = UDim2.new(1, 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(60, 220, 90)
        fill.BorderSizePixel = 0
        fill.Parent = bg
        local fillCorner = Instance.new("UICorner", fill)
        fillCorner.CornerRadius = UDim.new(0, 3)
    end

    bar.Enabled = true
    local fill = bar:FindFirstChild("BG") and bar.BG:FindFirstChild("Fill")
    if fill then
        local ratio = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
        fill.Size = UDim2.new(ratio, 0, 1, 0)
        fill.BackgroundColor3 = Color3.fromRGB(255, 70, 70):Lerp(Color3.fromRGB(60, 220, 90), ratio)
    end
end

local healthBarConn = RunService.Heartbeat:Connect(function()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= localPlayer then
            applyHealthBar(p)
        end
    end
end)
table.insert(cleanupTasks, healthBarConn)

print("[XENON]: Camera/FOV + Tracers + HealthBars загружены!")
end
