--========================================================
-- SAILOR PIECE MODULE (3 tabs only)
-- Подгружается через Luna Hub. Требует _G.LunaHub.api.
--========================================================

if not _G.LunaHub or not _G.LunaHub.api then
    error("[SailorModule] Luna Hub не загружен. Сначала запусти core.")
end
local API = _G.LunaHub.api

local Window         = API.Window
local Luna           = API.Luna
local notify         = API.notify
local lunaLog        = API.lunaLog
local logInfo        = API.logInfo
local logWarn        = API.logWarn
local logError       = API.logError
local track          = API.track
local safeGetCharacter = API.safeGetCharacter
local safeGetHumanoid  = API.safeGetHumanoid
local safeGetHRP       = API.safeGetHRP
local isSameTeam     = API.isSameTeam
local Log            = API.Log
local DiscordBot     = API.DiscordBot
local Players        = API.Players
local RunService     = API.RunService
local UIS            = API.UIS
local Camera         = API.Camera
local Lighting       = API.Lighting
local LocalPlayer    = API.LocalPlayer
local ReplicatedStorage = API.ReplicatedStorage
local HttpService    = API.HttpService
local VIM            = API.VIM

if _G.LunaHub.modules.sailor_piece then
    notify("Sailor Piece модуль уже загружен", 3, "warn")
    return
end

local moduleConnections = {}
local function modTrack(c)
    if c then table.insert(moduleConnections, c) end
    return c
end

(function()

local SailorTab  = Window:CreateTab({ Name = "Sailor Piece",     Icon = "anchor",   ImageSource = "Material", ShowTitle = true })
local BossTab    = Window:CreateTab({ Name = "Боссы",            Icon = "whatshot", ImageSource = "Material", ShowTitle = true })
local FarmCfgTab = Window:CreateTab({ Name = "Параметры фарма",  Icon = "tune",     ImageSource = "Material", ShowTitle = true })


-- SAILOR PIECE — Auto Quest Farm
--========================================================
SailorTab:CreateSection("Квест и зона")

-- ===== state =====
-- Квестовый цикл
local sp_questNpcName  = ""
local sp_mobBaseName   = ""
local sp_scanRadius    = 100
local sp_searchRadius  = 200
-- Длительность охоты квестового цикла
local sp_huntDuration  = 60
-- Сколько мобов убить за один забег к NPC. Квесты Sailor Piece обычно "убей 5".
local sp_killsPerQuest = 5
local sp_postQuestWait = 3   -- legacy, сейчас baked в spTakeQuestFrom

-- Free Combat: бить без квеста (пропускает фазу TakeQuest, сразу Hunting).
-- Полезно когда в дропдауне моба ты выбрал босса и не хочешь возиться с NPC.
local sp_freeCombat = false

-- Anti-Damage Anchor: вместо парения 7 ст. над мобом — поднимает игрока
-- ВЫСОКО (50 ст. по умолчанию) и якорит HRP. Большинство melee/AOE
-- атак боссов не достают на такой высоте, и физика игрока заморожена.
-- Используется как замена сломанному ForceField God Mode'у.
local sp_antiDamage = false
local sp_antiDamageHeight = 50

-- Бой
local sp_attackDelay   = 0.25
local sp_skillDelay    = 0.8
local sp_skillHold     = 0.1
local sp_useHandsOnly  = false   -- если true — клики не идут когда оружие отсутствует
local sp_handFightOff  = false   -- true = отключить клики мыши вообще (только скиллы)
local sp_useZ, sp_useX, sp_useC, sp_useV, sp_useF = true, true, true, true, true

-- One Shot Kill: спам RemoteEvent ReplicatedStorage.CombatSystem.Remotes.RequestHit.
-- Игровой Tool каждый удар фаерит этот ивент один раз — сервер считает урон по
-- текущему оружию/скиллу. Если фаернуть его 50–200 раз за один кадр, накопится
-- N урона и моб умирает мгновенно ("один клик = килл"). Если сервер троттлит
-- по cooldown'у — увеличить sp_oneShotCount.
local sp_oneShotEnabled = false
local sp_oneShotCount   = 50      -- сколько раз :FireServer() за один цикл атаки
local sp_oneShotPerKill = 200     -- сколько раз фаерить из «убей одним нажатием»

-- Слот оружия (1..5). При respawn автоматически экипируем.
local sp_weaponSlot = 1
local sp_autoEquip  = true

-- Hover/God Mode
local sp_hoverHeight = 7
local sp_maxSpeed    = 350    -- студов в секунду при плавном перелёте
local sp_stepRate    = 60     -- частота кадров полёта (выше = плавнее)
local sp_instantTp   = false  -- true = мгновенный telepout без интерполяции

-- Глобал состояния
_G.QuestState = _G.QuestState or "TakeQuest"   -- "TakeQuest" | "Hunting"

-- Боевая цель — God Mode читает её, чтобы держать нас над мобом.
local sp_currentMob = nil

-- Forward decls (нужны для замыканий, ссылающихся на boss-фарм / God Mode / unload)
local sp_enabled, sp_loopThread = false, nil
local sp_bossEnabled, sp_bossThread = false, nil
local godModeEnabled = false
local godMode2Enabled = false

local function spStop()  end   -- placeholder, реальные функции ниже
local function spBossStop() end
local function stopGodMode() end
local function stopGodMode2() end

-- ====================================================
-- Утилиты
-- ====================================================
local function spModelPos(model)
    if not model then return nil end
    local hrp = model:FindFirstChild("HumanoidRootPart")
        or model:FindFirstChild("Torso") or model.PrimaryPart
    if hrp and hrp.Position then return hrp.Position end
    local ok, cf = pcall(function() return model:GetBoundingBox() end)
    if ok and cf then return cf.Position end
    return nil
end

-- ====================================================
-- Оружие: переключение слотов 1..5 через VIM
-- ====================================================
local function spSelectSlot(slot)
    if not slot or slot < 1 or slot > 5 then return end
    if not VIM then return end
    -- 49..53 = Enum.KeyCode.One..Five
    local keyCodes = { Enum.KeyCode.One, Enum.KeyCode.Two, Enum.KeyCode.Three, Enum.KeyCode.Four, Enum.KeyCode.Five }
    pcall(function()
        VIM:SendKeyEvent(true,  keyCodes[slot], false, game)
        task.wait(0.05)
        VIM:SendKeyEvent(false, keyCodes[slot], false, game)
    end)
end

-- Проверить что в руке есть Tool. Если нет — переключиться на sp_weaponSlot.
-- Возвращает текущий "готовый к использованию" Tool в Character'е (или nil).
-- "Готовый" = Tool находится В Character + у него есть Handle + Humanoid жив.
-- Это критично для серверного VFXHandlers.Katana — он ходит к Tool.Handle и
-- роняет :FindFirstChild("...") в nil, если Activate() пришёл слишком рано.
local function _spToolReady(char)
    if not char then return nil end
    local hum = char:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return nil end
    local tool = char:FindFirstChildOfClass("Tool")
    if not tool then return nil end
    if tool.Parent ~= char then return nil end       -- Tool не экипирован
    if not tool:FindFirstChild("Handle") then return nil end  -- Handle ещё не приехал с сервера
    return tool
end

local _sp_lastEquip = 0
local function spEnsureWeapon()
    local char = safeGetCharacter()
    if not char then return nil end

    local tool = _spToolReady(char)
    if tool then return tool end

    if not sp_autoEquip then return nil end

    -- Защита от пере-экипировки 10 раз в сек: не дёргаем чаще чем раз в 0.5с
    local now = tick()
    if now - _sp_lastEquip < 0.5 then return nil end
    _sp_lastEquip = now

    -- 1) пробуем выбрать слот через VIM
    spSelectSlot(sp_weaponSlot)
    task.wait(0.35)   -- даём серверу время прицепить Handle
    tool = _spToolReady(char)
    if tool then return tool end

    -- 2) Fallback: первый Tool в Backpack через Humanoid:EquipTool
    local hum = safeGetHumanoid(char)
    local backpack = LocalPlayer:FindFirstChildOfClass("Backpack")
    if hum and backpack then
        local first = backpack:FindFirstChildOfClass("Tool")
        if first then
            pcall(function() hum:EquipTool(first) end)
            task.wait(0.4)
            tool = _spToolReady(char)
        end
    end
    return tool
end

-- При respawn автоматически переэкипируем выбранный слот (игра по дефолту берёт #1).
track(LocalPlayer.CharacterAdded:Connect(function(char)
    if sp_autoEquip then
        char:WaitForChild("Humanoid", 5)
        task.wait(0.6)
        spSelectSlot(sp_weaponSlot)
    end
end))

-- ====================================================
-- АВТО-СБОР существ при запуске (без ручного скана)
-- ====================================================
-- Согласно требованию:
--   • Workspace.ServiceNPCs   — квест-гиверы
--   • Workspace.NPCs          — все мобы (среди них боссы помечены словом "boss"
--                                в имени, регистр любой)
-- Имена боссов содержат суффикс сложности (medium / hard / xard / ultra и т.п.)
-- — мы режем эти суффиксы и дедуплицируем, чтобы в дропдауне был один пункт
-- (например, "bossultra" вместо трёх вариантов "bossultra medium / hard / xard").

-- Список суффиксов сложности, которые надо отрезать у боссов.
-- Можно расширять — порядок важен: длинные комбинации перед короткими
-- (чтобы "extreme" срезался раньше чем "extra").
local SP_DIFFICULTY_TOKENS = {
    "nightmare", "extreme", "insane", "medium", "normal",
    "ultra", "xard", "hard", "easy", "boss",
}

-- ВАЖНО: возвращает чистое базовое имя для дропдауна.
--   "bossultra medium"  ->  "bossultra"
--   "bossultra_xard"    ->  "bossultra"
--   "BlackReaperBoss_Hard" -> "BlackReaper" (после среза "boss" + "hard")
-- Алгоритм: переводим в lower, разбиваем по разделителям [^a-z0-9],
-- убираем токены сложности, склеиваем обратно.
local function spCleanBossName(rawName)
    if type(rawName) ~= "string" or rawName == "" then return rawName end

    local s = rawName
    -- Срезаем хвостовые цифры ("Boss2" -> "Boss")
    s = s:gsub("%d+$", "")

    -- Если содержит сложности через разделители (_, -, пробел) — режем их.
    local lower = s:lower()
    -- 1) уберём суффиксы вида "_hard", " hard", "-hard" в конце имени
    --    цикл — потому что "_boss_hard" -> сначала "hard", потом "_boss".
    local changed = true
    while changed do
        changed = false
        for _, tok in ipairs(SP_DIFFICULTY_TOKENS) do
            -- pattern: разделитель + токен в конце строки
            local pat = "[%s%-_]" .. tok .. "$"
            local newLower = lower:gsub(pat, "")
            if newLower ~= lower then
                lower = newLower
                changed = true
                break
            end
        end
    end

    -- 2) Если после среза разделителей в имени осталось только название босса
    --    + слитный суффикс ("bossultraxard" / "bossultrahard"), режем по словарю
    --    в конце строки.
    changed = true
    while changed do
        changed = false
        for _, tok in ipairs(SP_DIFFICULTY_TOKENS) do
            -- Не трогаем "boss" — это часть КОРНЕВОГО имени для нашего скрипта
            -- ("bossultra" -> "boss" + "ultra", "boss" нужно ОСТАВИТЬ).
            -- Но "boss" в самом конце как чистый суффикс — режем
            -- (например, "BlackReaperBoss" -> "BlackReaper").
            -- Чтобы это работало, ниже специальная обработка.
            if tok ~= "boss" then
                local pat = tok .. "$"
                local newLower = lower:gsub(pat, "")
                if newLower ~= lower and newLower ~= "" then
                    lower = newLower
                    changed = true
                    break
                end
            end
        end
    end

    -- 3) Срезаем разделители на хвосте ("blackreaper_" -> "blackreaper")
    lower = lower:gsub("[%s%-_]+$", "")
    if lower == "" then return rawName end

    return lower
end

-- Утилита: текст имени для UI (DisplayName из Humanoid если есть).
local function _spReadableLabel(model)
    if not model then return "" end
    local hum = model:FindFirstChildOfClass("Humanoid")
    local d = hum and hum.DisplayName
    if d and d ~= "" then return d end
    return ""
end

-- Хранилища, которые UI использует для дропдаунов (опции = "чистые" имена).
-- Lookup'ы маппят выбранную опцию -> то что реально надо искать в Workspace.NPCs.
local sp_npcChoices  = {}     -- массив имён для квестового NPC дропдауна
local sp_npcLookup   = {}     -- entry -> raw NPC name (model.Name)
local sp_mobChoices  = {}     -- массив имён обычных мобов
local sp_mobLookup   = {}     -- entry -> baseName (для string.find в NPC папке)
local sp_bossChoices = {}     -- массив cleaned-имён боссов
local sp_bossLookup  = {}     -- cleanedName -> cleanedName (для string.find)

-- Преднабор имён боссов Sailor Piece. Сюда добавляй известные имена даже если
-- их сейчас нет в Workspace — список в дропдауне всё равно их покажет, чтобы
-- можно было поставить в очередь "до спавна". Поиск во время боя использует
-- string.find по lower-case, так что суффиксы сложности (medium/hard/xard/ultra)
-- НЕ нужны — они подцепятся автоматически.
local SP_BOSS_PRESET = {
    -- Известные / часто встречающиеся в Sailor Piece. Очищенные базовые имена.
    "bossultra",
    "blackreaper",
    "monkey boss",
    "thiefboss",
    "kingboss",
    "captainboss",
    "dragonboss",
    "skeletonboss",
    "demonboss",
    "shogunboss",
    "samuraiboss",
    "kraken",
    "leviathan",
    "phantomboss",
    "iceboss",
    "fireboss",
}

-- Функция авто-сбора. Вызывается один раз при старте + по запросу (refresh).
-- Перезаполняет все четыре таблицы выше.
local function spAutoCollectAll()
    -- ---- ServiceNPCs (квест-гиверы) ----
    sp_npcChoices = {}
    sp_npcLookup  = {}
    do
        local folder = workspace:FindFirstChild("ServiceNPCs")
        if folder then
            local seen = {}
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") then
                    local code = m.Name
                    local label = _spReadableLabel(m)
                    local entry = (label ~= "" and label ~= code)
                        and (code .. "  ▸  " .. label) or code
                    if not seen[entry] then
                        seen[entry] = true
                        sp_npcLookup[entry] = code
                        table.insert(sp_npcChoices, entry)
                    end
                end
            end
            table.sort(sp_npcChoices)
        end
        if #sp_npcChoices == 0 then
            table.insert(sp_npcChoices, "(нет ServiceNPCs)")
        end
    end

    -- ---- NPCs (мобы + боссы) ----
    sp_mobChoices  = {}
    sp_mobLookup   = {}
    sp_bossChoices = {}
    sp_bossLookup  = {}
    do
        local folder = workspace:FindFirstChild("NPCs")
        local seenMob, seenBoss = {}, {}
        if folder then
            for _, m in ipairs(folder:GetChildren()) do
                if m:IsA("Model") then
                    local rawName = m.Name
                    if rawName:lower():find("boss", 1, true) then
                        -- Босс: чистим имя от сложности и дедуплицируем
                        local clean = spCleanBossName(rawName)
                        if clean and clean ~= "" and not seenBoss[clean] then
                            seenBoss[clean] = true
                            sp_bossLookup[clean] = clean
                            table.insert(sp_bossChoices, clean)
                        end
                    else
                        -- Обычный моб: режем хвостовые цифры (Monkey1 -> Monkey)
                        local base = rawName:gsub("%d+$", "")
                        if base == "" then base = rawName end
                        if not seenMob[base] then
                            seenMob[base] = true
                            sp_mobLookup[base] = base
                            table.insert(sp_mobChoices, base)
                        end
                    end
                end
            end
        end

        -- ⭐ Доливаем preset боссов: даже если босса сейчас нет на сервере,
        -- его имя будет в дропдауне и игрок сможет поставить его в очередь.
        for _, name in ipairs(SP_BOSS_PRESET) do
            local clean = name:lower()
            if not seenBoss[clean] then
                seenBoss[clean] = true
                sp_bossLookup[clean] = clean
                table.insert(sp_bossChoices, clean)
            end
        end

        table.sort(sp_mobChoices)
        table.sort(sp_bossChoices)
        if #sp_mobChoices  == 0 then table.insert(sp_mobChoices,  "(нет мобов)") end
        if #sp_bossChoices == 0 then table.insert(sp_bossChoices, "(нет боссов)") end
    end
end

-- Сразу выполняем сбор при загрузке скрипта — UI получит уже готовые списки.
do
    local ok, err = pcall(spAutoCollectAll)
    if not ok then
        lunaLog("ERROR", "spAutoCollectAll FAILED: " .. tostring(err))
    else
        lunaLog("INFO", string.format(
            "auto-collect: NPC=%d mobs=%d bosses=%d",
            #sp_npcChoices, #sp_mobChoices, #sp_bossChoices))
    end
end

-- ====================================================
-- Поиск моба / NPC по имени
-- ====================================================
local function _isPlaceholder(s)
    return not s or s == "" or s:sub(1, 1) == "("
end

-- Поиск моба в Workspace.NPCs ПО ЧАСТИЧНОМУ совпадению имени (string.find).
-- Это требование задачи: в дропдауне теперь чистые имена без сложности
-- ("bossultra"), а в Workspace модели называются "bossultra medium" /
-- "bossultra xard" / "bossultra ultra". Сравнение через string.find ловит ВСЕ
-- варианты, включая разные регистры (lower-cased обе стороны).
-- Для обычных мобов "Monkey" найдёт и "Monkey1", и "MonkeyKing" — это ожидаемо
-- (в дропдауне у нас уже базовое имя без цифр, так что коллизий быть не должно).
local function spFindMob(baseName)
    if _isPlaceholder(baseName) then return nil end
    local folder = workspace:FindFirstChild("NPCs")
    if not folder then return nil end
    local needle = tostring(baseName):lower()
    local myHRP = safeGetHRP(safeGetCharacter())
    local origin = myHRP and myHRP.Position or Vector3.zero
    local best, bestDist = nil, math.huge
    for _, mob in ipairs(folder:GetChildren()) do
        if mob:IsA("Model") and string.find(mob.Name:lower(), needle, 1, true) then
            local hum = mob:FindFirstChildOfClass("Humanoid")
            local p = spModelPos(mob)
            if hum and hum.Health > 0 and p then
                local d = (p - origin).Magnitude
                if d < bestDist and d <= sp_searchRadius then
                    bestDist = d
                    best = mob
                end
            end
        end
    end
    return best
end

local function spFindQuestNpc(npcName)
    if _isPlaceholder(npcName) then return nil end
    local folder = workspace:FindFirstChild("ServiceNPCs")
    if not folder then return nil end
    return folder:FindFirstChild(npcName)
end

-- ====================================================
-- Плавный TP с лимитом скорости (или мгновенный, если sp_instantTp = true)
-- ====================================================
local _sp_forcedTp = false
local function spSmoothTeleportTo(targetCFrame)
    local char = safeGetCharacter()
    local hrp  = safeGetHRP(char)
    if not hrp then return end
    -- Мгновенный режим: одна запись CFrame и выход.
    if sp_instantTp then
        pcall(function() hrp.CFrame = targetCFrame end)
        return
    end
    local startCF = hrp.CFrame
    local dist = (targetCFrame.Position - startCF.Position).Magnitude
    if dist < 0.5 then
        hrp.CFrame = targetCFrame
        return
    end
    local maxSpeed = math.max(20, sp_maxSpeed)
    local rate     = math.clamp(sp_stepRate, 10, 60)
    local steps    = math.max(2, math.ceil((dist / maxSpeed) * rate))
    local dt       = 1 / rate
    for i = 1, steps do
        if not sp_enabled and not sp_bossEnabled and not _sp_forcedTp then return end
        hrp.CFrame = startCF:Lerp(targetCFrame, i / steps)
        task.wait(dt)
    end
end

-- ====================================================
-- Атака: VIM клики + клавиши
-- ====================================================
-- ВАЖНО: серверный ReplicatedStorage.AbilitySystem.VFXHandlers.Katana
-- падает с "attempt to index nil with 'FindFirstChild'" если Activate-event
-- пришёл до того как Tool.Handle прицепился к Character. Поэтому:
--   1) Жёсткий троттлинг по sp_attackDelay
--   2) Перед каждым кликом проверяем что Tool готов (см. _spToolReady)
--   3) Если оружие нужно (Hand Fight off ИЛИ требуется Tool) и его нет — пропускаем кадр
local _sp_lastClick = 0
local function spMouseClick()
    if sp_handFightOff then return end
    if not VIM then return end

    local now = tick()
    if now - _sp_lastClick < sp_attackDelay then return end

    -- Проверка готовности оружия
    local char = safeGetCharacter()
    local toolReady = char and _spToolReady(char)
    if not toolReady then
        -- Только если режим "только с оружием" — пробуем экипировать.
        -- Иначе бьём руками — это тоже валидный сценарий (Combat без тула).
        if sp_useHandsOnly then
            spEnsureWeapon()    -- может выйти, может нет — следующий кадр повторит
            return              -- НЕ кликаем в этот кадр в любом случае
        end
        -- Hand-fight: если вообще нет персонажа — нет смысла кликать
        if not char or not safeGetHumanoid(char) then return end
    end

    _sp_lastClick = now

    pcall(function()
        VIM:SendMouseButtonEvent(0, 0, 0, true,  game, 1)
        task.wait(0.03)
        VIM:SendMouseButtonEvent(0, 0, 0, false, game, 1)
    end)
end

local function spPressKey(keyCode)
    if not VIM then return end
    pcall(function()
        VIM:SendKeyEvent(true,  keyCode, false, game)
        task.wait(sp_skillHold)
        VIM:SendKeyEvent(false, keyCode, false, game)
    end)
end

-- ====================================================
-- One Shot Kill: ReplicatedStorage.CombatSystem.Remotes.RequestHit
-- ====================================================
-- Реальная рабочая комба для Sailor Piece (выясняли brute force'ом
-- через one_shot_test.lua):
--   ev:FireServer(targetModel, targetPosition, currentTool)
-- На ThiefBoss с 1500 HP одна порция (≤30 фаеров) → 0 HP.
-- Сервер не требует ни spy, ни snapshot, ни Tool:Activate. Просто шлём.
--
-- Если в этой игре есть кулдаун или валидация — увеличиваем count в UI.

-- Кэшируем RemoteEvent: каждый FindFirstChild дороже чем 200 фаеров.
local _sp_requestHitCache = nil
local _sp_requestHitWarned = false
local function _spGetRequestHit()
    if _sp_requestHitCache and _sp_requestHitCache.Parent then
        return _sp_requestHitCache
    end
    local ok, ev = pcall(function()
        local cs = ReplicatedStorage:FindFirstChild("CombatSystem")
        if not cs then return nil end
        local remotes = cs:FindFirstChild("Remotes")
        if not remotes then return nil end
        return remotes:FindFirstChild("RequestHit")
    end)
    if ok and ev and ev:IsA("RemoteEvent") then
        _sp_requestHitCache = ev
        return ev
    end
    if not _sp_requestHitWarned then
        _sp_requestHitWarned = true
        lunaLog("WARN", "RequestHit RemoteEvent не найден в ReplicatedStorage.CombatSystem.Remotes")
    end
    return nil
end

-- Собрать args для FireServer(target, position, tool).
-- target — Model моба. position — Vector3 центра моба (HRP/Torso/PrimaryPart).
-- tool — текущий Tool в Character (если есть). Если tool отсутствует, шлём nil
-- — сервер обычно всё равно засчитывает, потому что валидация по target+position.
local function _buildHitArgs(target)
    if not target then return nil end
    local hrp = target:FindFirstChild("HumanoidRootPart")
        or target:FindFirstChild("Torso") or target.PrimaryPart
    local pos = hrp and hrp.Position or Vector3.zero
    local char = safeGetCharacter()
    local tool = char and char:FindFirstChildOfClass("Tool") or nil
    return target, pos, tool
end

-- Фаерим RequestHit count раз против target.
-- count <= 0 → sp_oneShotCount. Возвращает (true|false, info).
--
-- ВАЖНО: НИКАКИХ task.wait() внутри цикла. Сервер троттлит по time-window:
-- если шлёшь с паузой в 16ms — считает что это «отдельные удары» и
-- применяет cooldown = большая часть пакетов в мусор. Если шлёшь все за
-- один кадр — сервер обрабатывает их батчем и засчитывает каждый.
-- Для очень больших n (>500) делим на батчи по 200, между батчами task.wait().
local function spOneShotFire(count, target)
    local ev = _spGetRequestHit()
    if not ev then return false, "no_remote" end
    if not target or not target.Parent then return false, "no_target" end

    local n = (count and count > 0) and count or sp_oneShotCount
    local arg1, arg2, arg3 = _buildHitArgs(target)

    -- Батчи по 200 без пауз внутри батча.
    local BATCH = 200
    local sent = 0
    while sent < n do
        local todo = math.min(BATCH, n - sent)
        for i = 1, todo do
            pcall(function() ev:FireServer(arg1, arg2, arg3) end)
        end
        sent = sent + todo
        if sent < n then task.wait() end   -- между батчами один кадр
    end
    return true, "ok"
end

-- ====================================================
-- Killshot: упорная атака до смерти моба
-- ====================================================
-- spOneShotFire со снайперской точностью бьёт один remote одной комбой.
-- Для жирных боссов (375K HP в Sailor Piece) этого мало — комбинации
-- (target,humanoid) дают по ~5K-6K урона за фаер, плюс сервер троттлит.
-- Killshot бьёт упорно: до 10 раундов по batch фаеров, проверяя HP после
-- каждого. Если HP не падает 2 раунда подряд — выходит (моб неуязвим / cooldown).
local function spKillshot(target, maxRounds, perRound)
    if not target or not target.Parent then return false, "no_target" end
    local ev = _spGetRequestHit()
    if not ev then return false, "no_remote" end
    local hum = target:FindFirstChildOfClass("Humanoid")
    if not hum then return false, "no_humanoid" end

    maxRounds = maxRounds or 10
    perRound  = perRound or 200

    local arg1, arg2, arg3 = _buildHitArgs(target)
    local stallCount = 0
    local lastHP = hum.Health
    local startHP = hum.Health
    local totalSent = 0

    for r = 1, maxRounds do
        if not target.Parent or hum.Health <= 0 then break end
        -- batch фаер за один кадр
        for i = 1, perRound do
            pcall(function() ev:FireServer(arg1, arg2, arg3) end)
        end
        totalSent = totalSent + perRound
        task.wait()  -- даём серверу обработать
        local hp = (target.Parent and hum.Parent) and hum.Health or 0
        if hp >= lastHP - 0.5 then
            stallCount = stallCount + 1
            if stallCount >= 2 then break end  -- 2 раунда без прогресса = выход
        else
            stallCount = 0
        end
        lastHP = hp
    end

    local hpEnd = (target.Parent and hum.Parent) and hum.Health or 0
    lunaLog("INFO", ("Killshot: %s HP %.0f→%.0f sent=%d"):format(
        target.Name, startHP, hpEnd, totalSent))
    return hpEnd <= 0, ("hp:%.0f→%.0f sent:%d"):format(startHP, hpEnd, totalSent)
end

-- Собрать массив скилл-клавиш в зависимости от тогглов
local function spActiveSkillKeys()
    local t = {}
    if sp_useZ then table.insert(t, Enum.KeyCode.Z) end
    if sp_useX then table.insert(t, Enum.KeyCode.X) end
    if sp_useC then table.insert(t, Enum.KeyCode.C) end
    if sp_useV then table.insert(t, Enum.KeyCode.V) end
    if sp_useF then table.insert(t, Enum.KeyCode.F) end
    return t
end


-- ====================================================
-- Удержание над мобом
-- ====================================================
local function spHoverAbove(mob)
    if not mob or not mob.Parent then return end
    -- God Mode v1 сам поднимает в Heartbeat — не дёргаем тут
    if godModeEnabled then return end
    local char = safeGetCharacter()
    local hum  = safeGetHumanoid(char)
    local hrp  = safeGetHRP(char)
    if not (hum and hrp) then return end
    local mobHead = mob:FindFirstChild("Head")
        or mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
    if not mobHead then return end
    local headPos = mobHead.Position
    -- Если включен Anti-Damage — поднимаемся на высоту 50 ст. + якорим HRP
    local height = sp_antiDamage and sp_antiDamageHeight or sp_hoverHeight
    local eye = headPos + Vector3.new(0, height, 0)
    pcall(function()
        hum.PlatformStand = false
        hrp.AssemblyLinearVelocity = Vector3.zero
        hrp.CFrame = CFrame.lookAt(eye, headPos)
        -- Anti-Damage — якорим HRP, чтобы knockback не сдвинул вниз
        if sp_antiDamage then
            if not hrp.Anchored then hrp.Anchored = true end
        elseif hrp.Anchored then
            hrp.Anchored = false
        end
    end)
end

-- ====================================================
-- Взятие квеста (AFK-режим: 0.8с задержка + 3с repeat-prompt)
-- ====================================================
local function spTakeQuestFrom(npc)
    if not npc then return end
    local hrpPos = spModelPos(npc)
    local myHRP  = safeGetHRP(safeGetCharacter())
    if not (hrpPos and myHRP) then return end

    spSmoothTeleportTo(CFrame.new(hrpPos + Vector3.new(0, 0, 4), hrpPos))
    task.wait(0.8)

    local prompts, clicks = {}, {}
    for _, d in ipairs(npc:GetDescendants()) do
        if d:IsA("ProximityPrompt") then table.insert(prompts, d)
        elseif d:IsA("ClickDetector") then table.insert(clicks, d) end
    end

    local deadline = tick() + 3
    repeat
        for _, p in ipairs(prompts) do
            pcall(function()
                if fireproximityprompt then fireproximityprompt(p) end
            end)
        end
        if #prompts == 0 then
            for _, cd in ipairs(clicks) do
                pcall(function()
                    if fireclickdetector then fireclickdetector(cd) end
                end)
            end
        end
        task.wait(0.5)
    until tick() >= deadline
end

-- ====================================================
-- Главный квестовый цикл
-- ====================================================
local function spStart()
    if sp_loopThread then return end
    -- Free Combat: пропускаем требование выбрать NPC
    if not sp_freeCombat and _isPlaceholder(sp_questNpcName) then
        notify("Сначала Scan + выбор NPC (или включи Free Combat)")
        return
    end
    if _isPlaceholder(sp_mobBaseName) then
        notify("Сначала Scan + выбор моба")
        return
    end
    if sp_bossEnabled then
        spBossStop()
    end

    sp_enabled = true
    -- Free Combat начинает сразу с Hunting
    _G.QuestState = sp_freeCombat and "Hunting" or "TakeQuest"
    lunaLog("INFO", string.format(
        "spStart: npc='%s' mob='%s' free=%s killsPerQuest=%d",
        sp_questNpcName, sp_mobBaseName, tostring(sp_freeCombat), sp_killsPerQuest))

    sp_loopThread = task.spawn(function()
        -- xpcall ловит любую ошибку и пишет stacktrace в лог,
        -- иначе при краше игра умирает молча.
        local ok, err = xpcall(function()
        while sp_enabled do
            local hum = safeGetHumanoid(safeGetCharacter())
            if not hum or hum.Health <= 0 then
                sp_currentMob = nil
                task.wait(1)
            elseif _G.QuestState == "TakeQuest" then
                sp_currentMob = nil
                if sp_freeCombat then
                    -- В режиме Free Combat — никогда не ходим к NPC, сразу в Hunting
                    _G.QuestState = "Hunting"
                else
                    local npc = spFindQuestNpc(sp_questNpcName)
                    if npc then
                        notify("Беру квест у " .. sp_questNpcName)
                        spTakeQuestFrom(npc)
                        _G.QuestState = "Hunting"
                    else
                        notify("NPC не найден: " .. sp_questNpcName)
                        task.wait(2)
                    end
                end
            elseif _G.QuestState == "Hunting" then
                local huntStart = tick()
                local kills = 0
                notify(("Hunt %ds: %s"):format(sp_huntDuration, sp_mobBaseName))
                while sp_enabled
                    and _G.QuestState == "Hunting"
                    -- Free Combat игнорирует таймер охоты (фармим вечно)
                    and (sp_freeCombat or (tick() - huntStart) < sp_huntDuration)
                    -- Лимит на убийства за один квестовый "забег". В Sailor Piece
                    -- большинство квестов = "убей 5 мобов". После лимита возвращаемся
                    -- к NPC сдать квест и взять новый.
                    and (sp_freeCombat or kills < sp_killsPerQuest)
                do
                    local mob = spFindMob(sp_mobBaseName)
                    if not mob then
                        if sp_freeCombat then
                            -- Free Combat: ждём респавна моба, не возвращаемся к NPC
                            task.wait(2)
                        else
                            notify("Моба нет — обратно к NPC")
                            break
                        end
                    else
                        sp_currentMob = mob

                        if not godModeEnabled and not sp_antiDamage then
                            local p = spModelPos(mob)
                            if p then
                                spSmoothTeleportTo(CFrame.lookAt(
                                    p + Vector3.new(0, sp_hoverHeight, 0), p))
                            end
                        end

                        local skillIdx, lastSkill = 1, tick()
                        local mobHum = mob:FindFirstChildOfClass("Humanoid")

                        while sp_enabled
                            and _G.QuestState == "Hunting"
                            and mob.Parent
                            and mobHum and mobHum.Health > 0
                            and (sp_freeCombat or (tick() - huntStart) < sp_huntDuration)
                        do
                            spHoverAbove(mob)
                            spMouseClick()
                            -- One Shot Kill: спамим RequestHit:FireServer() каждый тик
                            -- цикла. Моб уходит в 0 HP за 1-2 кадра.
                            if sp_oneShotEnabled then spOneShotFire(nil, mob) end
                            -- ВАЖНО: пересобираем массив скиллов КАЖДЫЙ цикл,
                            -- чтобы тогглы Z/X/C/V/F работали в реальном времени.
                            local skillKeys = spActiveSkillKeys()
                            if #skillKeys > 0 and (tick() - lastSkill) >= sp_skillDelay then
                                -- Циклический индекс на текущей длине массива
                                if skillIdx > #skillKeys then skillIdx = 1 end
                                spPressKey(skillKeys[skillIdx])
                                skillIdx = (skillIdx % #skillKeys) + 1
                                lastSkill = tick()
                            end
                            task.wait(sp_attackDelay)
                        end
                        -- Если моб умер (HP <= 0 или Parent == nil) — это кил.
                        -- Если мы вышли по другому условию (timeout, sp_enabled = false) —
                        -- кил не считаем.
                        if not mob.Parent or (mobHum and mobHum.Health <= 0) then
                            kills = kills + 1
                            notify(("Kill %d/%d"):format(kills, sp_killsPerQuest), 1.5)
                        end
                        sp_currentMob = nil
                        task.wait(0.1)
                    end
                end
                -- Достигли лимита убийств — обратно к NPC сдавать квест
                if not sp_freeCombat and kills >= sp_killsPerQuest then
                    notify(("Квест выполнен ({}). Возвращаюсь к NPC")
                        :gsub("{}", tostring(kills)), 2)
                end
                _G.QuestState = sp_freeCombat and "Hunting" or "TakeQuest"
                task.wait(0.3)
            else
                _G.QuestState = sp_freeCombat and "Hunting" or "TakeQuest"
                task.wait(0.2)
            end
            task.wait(0.05)
        end
        end, function(err)
            -- xpcall handler — пишем traceback в лог
            lunaLog("ERROR", "QUEST LOOP CRASH: " .. tostring(err))
            lunaLog("ERROR", debug.traceback("", 2))
        end)
        if not ok then
            -- xpcall вернул false, но если поток завершился штатно — ok=true
            sp_enabled = false
            pcall(function()
                Luna:Notification({
                    Title = "Luna Hub", Content = "Квест-цикл упал, см. лог",
                    Duration = 5, Icon = "_error", ImageSource = "Material",
                })
            end)
        end
        sp_currentMob = nil
        sp_loopThread = nil
    end)
end

-- override placeholder
spStop = function()
    sp_enabled = false
    sp_currentMob = nil
    sp_loopThread = nil
end

-- ====================================================
-- RAID BOSSES
-- ====================================================
-- Список боссов формируется автоматически при запуске скрипта (см. блок
-- spAutoCollectAll выше) — берётся из workspace.NPCs, фильтруется по слову
-- "boss" в имени (любой регистр), очищается от суффиксов сложности и
-- дедуплицируется. UI работает с уже готовым списком sp_bossChoices.
-- Очередь боссов. UI поддерживает MultipleOptions: можно выбрать N имён,
-- скрипт убивает их по порядку. Когда первый умер — переключается на второго.
-- sp_bossQueue ХРАНИТ ВЫБОР; runtime читает sp_bossRootName из неё.
local sp_bossQueue       = {}     -- массив cleaned-имён боссов в порядке выбора
local sp_bossDisplayName = sp_bossChoices[1] or ""
local sp_bossRootName    = sp_bossLookup[sp_bossDisplayName] or sp_bossDisplayName

-- Эвристика "это похоже на босса" — оставлена на случай ручного ре-скана:
-- проверяет имя по словам Boss/Lord/King/Captain... либо толстое HP.
-- В авто-сборе spAutoCollectAll мы используем только маркер "boss" в имени —
-- это требование задачи. Эта функция тут просто как утилита.
local function _spLooksLikeBoss(model, hum)
    local n = model.Name:lower()
    if n:find("boss")    or n:find("lord")    or n:find("king")
       or n:find("queen") or n:find("demon")   or n:find("captain")
       or n:find("titan") or n:find("reaper")  or n:find("master")
       or n:find("admiral") or n:find("warlord")
    then
        return true
    end
    if hum and hum.MaxHealth and hum.MaxHealth >= 1000 then return true end
    return false
end

local function spFindBoss(rootName)
    if not rootName or rootName == "" then return nil end
    local folder = workspace:FindFirstChild("NPCs")
    if not folder then return nil end
    local needle = tostring(rootName):lower()
    local myHRP  = safeGetHRP(safeGetCharacter())
    local origin = myHRP and myHRP.Position or Vector3.zero
    local best, bestHum, bestDist = nil, nil, math.huge
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and string.find(m.Name:lower(), needle, 1, true) then
            local hum = m:FindFirstChildOfClass("Humanoid")
            local p   = spModelPos(m)
            if hum and hum.Health > 0 and p then
                local d = (p - origin).Magnitude
                if d < bestDist then
                    bestDist, best, bestHum = d, m, hum
                end
            end
        end
    end
    return best, bestHum
end

-- Хелпер: получить актуальную очередь целей. Если sp_bossQueue пуст —
-- fallback на одиночный sp_bossRootName (обратная совместимость).
local function _spGetBossTargets()
    if sp_bossQueue and #sp_bossQueue > 0 then return sp_bossQueue end
    if sp_bossRootName and sp_bossRootName ~= "" then return { sp_bossRootName } end
    return {}
end

local function spBossStart()
    if sp_bossThread then return end
    local queue = _spGetBossTargets()
    if #queue == 0 then
        notify("Выбери хотя бы одного босса в дропдауне", 3, "warn")
        return
    end
    if sp_enabled then spStop() end

    sp_bossEnabled = true
    lunaLog("INFO", "spBossStart: queue=[" .. table.concat(_spGetBossTargets(), ", ") .. "]")
    sp_bossThread = task.spawn(function()
        local idx = 1   -- текущий босс в очереди
        local lastNotifiedTarget = nil   -- чтобы не спамить нотификациями
        -- Состояние ожидания respawn'а босса (для очереди из 1)
        local WAIT_SINCE     = nil
        local WAIT_NOTIFIED  = false
        local ok, err = xpcall(function()
        while sp_bossEnabled do
            local hum = safeGetHumanoid(safeGetCharacter())
            if not hum or hum.Health <= 0 then
                sp_currentMob = nil
                task.wait(1)
            else
                -- Каждый кадр освежаем очередь — игрок мог поменять выбор в UI.
                local q = _spGetBossTargets()
                if #q == 0 then
                    notify("Очередь боссов пуста — выключаю авто-фарм", 3, "warn")
                    break
                end
                if idx > #q then idx = 1 end
                local target = q[idx]

                local boss, bossHum = spFindBoss(target)
                if not boss then
                    sp_currentMob = nil
                    -- Засекаем когда впервые потеряли цель — нужно для warn'а.
                    if not WAIT_SINCE then
                        WAIT_SINCE = tick()
                    end
                    if #q > 1 then
                        -- В очереди >1 босса: переключаемся на следующего сразу,
                        -- не ждём respawn'а текущего.
                        idx = idx + 1
                        if idx > #q then idx = 1 end
                        task.wait(0.3)
                    else
                        -- Только один босс в очереди: ждём его respawn.
                        -- Не спамим notify'ями — один warn после 10 секунд тишины.
                        if (tick() - WAIT_SINCE) > 10 and not WAIT_NOTIFIED then
                            WAIT_NOTIFIED = true
                            notify(("Жду respawn '%s'…"):format(target), 3, "warn")
                        end
                        task.wait(0.5)
                    end
                else
                    -- Босс нашёлся — сбрасываем «жду respawn'а» состояние.
                    WAIT_SINCE    = nil
                    WAIT_NOTIFIED = false
                    sp_currentMob = boss
                    -- Уведомляем только если сменился target.
                    if lastNotifiedTarget ~= target then
                        if #q > 1 then
                            notify(("Босс [%d/%d]: %s"):format(idx, #q, target), 2)
                        else
                            notify(("Босс: %s"):format(target), 2)
                        end
                        lastNotifiedTarget = target
                    end
                    if not godModeEnabled and not sp_antiDamage then
                        local p = spModelPos(boss)
                        if p then
                            spSmoothTeleportTo(CFrame.lookAt(
                                p + Vector3.new(0, sp_hoverHeight, 0), p))
                        end
                    end

                    local skillIdx, lastSkill = 1, tick()

                    while sp_bossEnabled
                        and boss.Parent
                        and bossHum and bossHum.Health > 0
                    do
                        bossHum = boss:FindFirstChildOfClass("Humanoid") or bossHum
                        spHoverAbove(boss)
                        spMouseClick()
                        if sp_oneShotEnabled then spOneShotFire(nil, boss) end
                        local skillKeys = spActiveSkillKeys()
                        if #skillKeys > 0 and (tick() - lastSkill) >= sp_skillDelay then
                            if skillIdx > #skillKeys then skillIdx = 1 end
                            spPressKey(skillKeys[skillIdx])
                            skillIdx = (skillIdx % #skillKeys) + 1
                            lastSkill = tick()
                        end
                        task.wait(sp_attackDelay)
                    end
                    sp_currentMob = nil
                    -- Босс умер → переходим к следующему в очереди.
                    if not boss.Parent or (bossHum and bossHum.Health <= 0) then
                        if #q > 1 then
                            idx = idx + 1
                            if idx > #q then idx = 1 end
                            notify(("Убит. Переключаюсь на [%d/%d]"):format(idx, #q),
                                2, "success")
                        else
                            -- Очередь из 1: остаёмся на нём, ждём respawn.
                            notify(("Убит '%s'. Жду respawn"):format(target), 2, "success")
                        end
                        -- Сбрасываем "уведомили о цели" — при следующем нахождении
                        -- этого же босса снова дадим лог.
                        lastNotifiedTarget = nil
                    end
                    task.wait(0.5)
                end
            end
            task.wait(0.05)
        end
        end, function(e)
            lunaLog("ERROR", "BOSS LOOP CRASH: " .. tostring(e))
            lunaLog("ERROR", debug.traceback("", 2))
        end)
        if not ok then
            sp_bossEnabled = false
            pcall(function()
                Luna:Notification({
                    Title = "Luna Hub", Content = "Boss-цикл упал, см. лог",
                    Duration = 5, Icon = "_error", ImageSource = "Material",
                })
            end)
        end
        sp_currentMob = nil
        sp_bossThread = nil
    end)
end

-- override placeholder
spBossStop = function()
    sp_bossEnabled = false
    sp_currentMob = nil
    sp_bossThread = nil
end


-- ====================================================
-- GOD MODE v1: Noclip + hover (читает sp_currentMob)
-- ====================================================
local godConn
-- Кэш BasePart'ов Character'а — обновляется только при ChildAdded/Removed,
-- не итерируем GetChildren() каждый кадр (FPS-оптимизация).
local godPartsCache = {}
local godPartsConn  = {}

local function godRebuildCache()
    table.clear(godPartsCache)
    for _, c in ipairs(godPartsConn) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(godPartsConn)

    local char = safeGetCharacter()
    if not char then return end
    for _, p in ipairs(char:GetChildren()) do
        if p:IsA("BasePart") then
            table.insert(godPartsCache, p)
        end
    end
    table.insert(godPartsConn, char.ChildAdded:Connect(function(c)
        if c:IsA("BasePart") then
            table.insert(godPartsCache, c)
            if godModeEnabled then c.CanCollide = false end
        end
    end))
    table.insert(godPartsConn, char.ChildRemoved:Connect(function(c)
        for i = #godPartsCache, 1, -1 do
            if godPartsCache[i] == c then
                table.remove(godPartsCache, i)
                break
            end
        end
    end))
end

stopGodMode = function()
    if godConn then godConn:Disconnect(); godConn = nil end
    for _, c in ipairs(godPartsConn) do pcall(function() c:Disconnect() end) end
    table.clear(godPartsConn)
    -- Возвращаем коллизию + снимаем якорь HRP (если был от Anti-Damage режима)
    local char = safeGetCharacter()
    if char then
        for _, p in ipairs(char:GetChildren()) do
            if p:IsA("BasePart") then
                pcall(function() p.CanCollide = true end)
            end
        end
        local hrp = char:FindFirstChild("HumanoidRootPart")
        if hrp and hrp.Anchored then
            pcall(function() hrp.Anchored = false end)
        end
    end
    table.clear(godPartsCache)
end

local function startGodMode()
    stopGodMode()
    godRebuildCache()

    -- Throttle: noclip достаточно проверять 30 раз/сек.
    -- Hover же пишем КАЖДЫЙ кадр — иначе игрок падает под карту, когда босс стоит
    -- (старый код gate'ил hover за движением >0.5 ст. → если босс не двигался,
    -- gravity тащил персонажа вниз через провалившийся CanCollide=false).
    local lastNoclip = 0

    godConn = RunService.Heartbeat:Connect(function()
        if not godModeEnabled then
            stopGodMode()
            return
        end
        local now = tick()

        -- 1) Noclip — 30 Hz, пишем только если значение реально изменилось
        if now - lastNoclip >= 1/30 then
            lastNoclip = now
            for i = 1, #godPartsCache do
                local p = godPartsCache[i]
                if p.CanCollide then p.CanCollide = false end
            end
        end

        -- 2) Hover над целью — каждый кадр (без гейта на движение!).
        --    Если активен Anti-Damage — поднимаемся гораздо выше + якорим HRP.
        local mob = sp_currentMob
        if mob and mob.Parent then
            local mobHead = mob:FindFirstChild("Head")
                or mob:FindFirstChild("HumanoidRootPart") or mob.PrimaryPart
            if mobHead then
                local headPos = mobHead.Position
                local char = safeGetCharacter()
                local hrp = char and char:FindFirstChild("HumanoidRootPart")
                if hrp then
                    local height = sp_antiDamage and sp_antiDamageHeight or sp_hoverHeight
                    local eye = headPos + Vector3.new(0, height, 0)
                    hrp.CFrame = CFrame.lookAt(eye, headPos)
                    hrp.AssemblyLinearVelocity = Vector3.zero
                    -- В Anti-Damage режиме якорим HRP, чтобы серверная физика
                    -- НЕ могла нас сдвинуть вниз (knockback от босса etc.)
                    if sp_antiDamage then
                        if not hrp.Anchored then hrp.Anchored = true end
                    elseif hrp.Anchored then
                        hrp.Anchored = false
                    end
                end
            end
        else
            -- Цели нет — снимаем якорь, иначе игрок зависнет навсегда
            local char = safeGetCharacter()
            local hrp = char and char:FindFirstChild("HumanoidRootPart")
            if hrp and hrp.Anchored then hrp.Anchored = false end
        end
    end)
    track(godConn)
end

-- Пересоздаём кэш при респавне
track(LocalPlayer.CharacterAdded:Connect(function(_)
    if godModeEnabled then
        task.wait(0.4)
        godRebuildCache()
    end
end))

-- ====================================================
-- GOD MODE v2: Health-restore + Dead-state block
-- ====================================================
-- Идея: пока v2 включен, мы каждый Heartbeat ставим Health = MaxHealth обратно
-- (если игра пишет Health на клиенте, это работает). Дополнительно:
--   * блокируем переход в HumanoidStateType.Dead через :SetStateEnabled
--   * слушаем HealthChanged и сразу восстанавливаем
-- Не панацея против серверной валидации HP, но в Sailor Piece работает на
-- большинстве боссов кроме тех, где HP считается RemoteEvent'ом сервера.
local god2Thread        -- task.spawn corotine (НЕ RBXScriptConnection — :Disconnect нельзя!)
local god2HealthConn
local god2StateConn
local god2BoundHum

local function _god2Detach()
    -- thread сам помрёт когда godMode2Enabled = false
    god2Thread = nil
    if god2HealthConn then
        pcall(function() god2HealthConn:Disconnect() end)
        god2HealthConn = nil
    end
    if god2StateConn then
        pcall(function() god2StateConn:Disconnect() end)
        god2StateConn = nil
    end
    if god2BoundHum then
        pcall(function()
            god2BoundHum:SetStateEnabled(Enum.HumanoidStateType.Dead, true)
            god2BoundHum.BreakJointsOnDeath = true
        end)
    end
    god2BoundHum = nil
end

local function _god2Bind(hum)
    if not hum then return end
    god2BoundHum = hum
    pcall(function()
        hum:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
        hum.BreakJointsOnDeath = false
    end)
    god2HealthConn = hum.HealthChanged:Connect(function(h)
        if not godMode2Enabled then return end
        if h < hum.MaxHealth then
            pcall(function() hum.Health = hum.MaxHealth end)
        end
    end)
    god2StateConn = hum.StateChanged:Connect(function(_, new)
        if not godMode2Enabled then return end
        if new == Enum.HumanoidStateType.Dead
            or new == Enum.HumanoidStateType.Ragdoll
            or new == Enum.HumanoidStateType.FallingDown
        then
            pcall(function()
                hum:ChangeState(Enum.HumanoidStateType.GettingUp)
                hum.Health = hum.MaxHealth
            end)
        end
    end)
end

stopGodMode2 = function()
    _god2Detach()
end

local function startGodMode2()
    stopGodMode2()
    local hum = safeGetHumanoid(safeGetCharacter())
    if hum then _god2Bind(hum) end

    -- Каждые 0.1с подтягиваем Health (без Heartbeat, чтобы не съедать FPS).
    -- Это THREAD, НЕ соединение — :Disconnect() здесь невалиден.
    god2Thread = task.spawn(function()
        while godMode2Enabled do
            local h = safeGetHumanoid(safeGetCharacter())
            if h and h.Health < h.MaxHealth then
                pcall(function() h.Health = h.MaxHealth end)
            end
            task.wait(0.1)
        end
    end)
end

-- ребайнд при респавне
track(LocalPlayer.CharacterAdded:Connect(function(_)
    if godMode2Enabled then
        task.wait(0.5)
        local hum = safeGetHumanoid(safeGetCharacter())
        if hum then
            _god2Detach()
            _god2Bind(hum)
            -- перезапускаем поток восстановления HP, т.к. detach его выгасил флагом
            task.spawn(function()
                while godMode2Enabled do
                    local h = safeGetHumanoid(safeGetCharacter())
                    if h and h.Health < h.MaxHealth then
                        pcall(function() h.Health = h.MaxHealth end)
                    end
                    task.wait(0.1)
                end
            end)
        end
    end
end))


--========================================================
-- SAILOR PIECE — UI
--========================================================

SailorTab:CreateParagraph({
    Title = "🚀 Быстрый старт",
    Text = "Существа собраны автоматически из Workspace при запуске:\n" ..
              "      • квест-гиверы — Workspace.ServiceNPCs\n" ..
              "      • обычные мобы и боссы — Workspace.NPCs\n\n" ..
              "Здесь только ФАРМ. Тонкая настройка задержек, оружия, скиллов — " ..
              "во вкладке «Параметры фарма». Авто-фарм рейдовых боссов и очередь — " ..
              "во вкладке «Боссы»."
})

-- ===== Quest Setup =====
-- Дропдауны заполняются СРАЗУ из авто-собранных списков. Никаких автоматических
-- watcher'ов на Workspace — они вызывали лавину обновлений и крашили клиент при
-- массовых respawn'ах. Если что-то изменилось — жми кнопку refresh ниже.
local npcDropdown, mobDropdown, bossDropdown   -- forward decl

local function _resolveNpcCode(label)
    if not label or _isPlaceholder(label) then return nil end
    return sp_npcLookup[label] or label
end
local function _resolveMobCode(label)
    if not label or _isPlaceholder(label) then return nil end
    return sp_mobLookup[label] or label
end

-- Сразу подставляем первый валидный вариант, чтобы автофарм мог стартовать
-- БЕЗ дополнительных кликов в дропдауне.
do
    local firstNpc = sp_npcChoices[1]
    if firstNpc and not _isPlaceholder(firstNpc) then
        sp_questNpcName = _resolveNpcCode(firstNpc) or ""
    end
    local firstMob = sp_mobChoices[1]
    if firstMob and not _isPlaceholder(firstMob) then
        sp_mobBaseName = _resolveMobCode(firstMob) or ""
    end
end

npcDropdown = SailorTab:CreateDropdown({
    Name = "NPC квеста",
    Description = "Источник: Workspace.ServiceNPCs",
    Options = sp_npcChoices,
    CurrentOption = { sp_npcChoices[1] },
    MultipleOptions = false,
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        local code = _resolveNpcCode(v)
        if code then sp_questNpcName = code end
    end
}, "sp_questNpc")

mobDropdown = SailorTab:CreateDropdown({
    Name = "Моб для фарма",
    Description = "Источник: Workspace.NPCs (без слова boss в имени)",
    Options = sp_mobChoices,
    CurrentOption = { sp_mobChoices[1] },
    MultipleOptions = false,
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        local code = _resolveMobCode(v)
        if code then sp_mobBaseName = code end
    end
}, "sp_mob")

-- Хелпер: пересобрать списки и обновить все три дропдауна сразу.
local function spRefreshAllDropdowns()
    spAutoCollectAll()
    if npcDropdown and npcDropdown.Set then
        pcall(function()
            npcDropdown:Set({ Options = sp_npcChoices, CurrentOption = { sp_npcChoices[1] } })
        end)
    end
    if mobDropdown and mobDropdown.Set then
        pcall(function()
            mobDropdown:Set({ Options = sp_mobChoices, CurrentOption = { sp_mobChoices[1] } })
        end)
    end
    if bossDropdown and bossDropdown.Set then
        -- Сохраняем текущий выбор очереди, иначе при refresh всё сбросится.
        local keep = (sp_bossQueue and #sp_bossQueue > 0) and sp_bossQueue
            or { sp_bossChoices[1] }
        pcall(function()
            bossDropdown:Set({ Options = sp_bossChoices, CurrentOption = keep })
        end)
    end
    if not _isPlaceholder(sp_npcChoices[1]) then
        sp_questNpcName = _resolveNpcCode(sp_npcChoices[1]) or sp_questNpcName
    end
    if not _isPlaceholder(sp_mobChoices[1]) then
        sp_mobBaseName = _resolveMobCode(sp_mobChoices[1]) or sp_mobBaseName
    end
end

SailorTab:CreateButton({
    Name = "🔄 Пересобрать списки",
    Description = "Жми если на сервере появились новые NPC / мобы / боссы",
    Callback = function()
        spRefreshAllDropdowns()
        notify(("NPC: %d  •  Мобов: %d  •  Боссов: %d")
            :format(#sp_npcChoices, #sp_mobChoices, #sp_bossChoices),
            3, "success")
    end
})

-- ====================================================
-- ЗАПУСК — главные тогглы
-- ====================================================
SailorTab:CreateDivider()
SailorTab:CreateSection("Запуск")

SailorTab:CreateToggle({
    Name = "▶ Авто-фарм (квест)",
    Description = "Бегает к NPC, берёт квест, фармит мобов, возвращается.",
    CurrentValue = false,
    Callback = function(v)
        lunaLog("INFO", "Toggle Auto-фарм (квест) = " .. tostring(v))
        if v then spStart() else spStop() end
    end
}, "sp_autoFarm")

SailorTab:CreateToggle({
    Name = "Free Combat (без квеста)",
    Description = "Бьёт выбранного моба бесконечно, не ходит к NPC.",
    CurrentValue = false,
    Callback = function(v) sp_freeCombat = v end
}, "sp_freeCombat")

-- ====================================================
-- БЫСТРЫЕ ДЕЙСТВИЯ
-- ====================================================
SailorTab:CreateDivider()
SailorTab:CreateSection("Быстрые действия")

SailorTab:CreateButton({
    Name = "📥 Взять квест сейчас",
    Description = "Один раз слетать к NPC и активировать диалог.",
    Callback = function()
        task.spawn(function()
            _sp_forcedTp = true
            local npc = spFindQuestNpc(sp_questNpcName)
            if npc then spTakeQuestFrom(npc) else notify("NPC не найден", 3, "warn") end
            _sp_forcedTp = false
        end)
    end
})

SailorTab:CreateButton({
    Name = "🎯 Телепорт к мобу",
    Description = "Прыгнуть к ближайшему мобу из дропдауна.",
    Callback = function()
        task.spawn(function()
            _sp_forcedTp = true
            local mob = spFindMob(sp_mobBaseName)
            if mob then
                local p = spModelPos(mob)
                if p then
                    spSmoothTeleportTo(CFrame.lookAt(
                        p + Vector3.new(0, sp_hoverHeight, 0), p))
                end
            else notify("Моб не найден", 3, "warn") end
            _sp_forcedTp = false
        end)
    end
})

SailorTab:CreateButton({
    Name = "↩ Принудительно: к квесту",
    Description = "Если завис в фарме — переключиться обратно к NPC.",
    Callback = function() _G.QuestState = "TakeQuest" end
})
SailorTab:CreateButton({
    Name = "⚔ Принудительно: бить мобов",
    Description = "Пропустить шаг получения квеста и сразу фармить.",
    Callback = function() _G.QuestState = "Hunting" end
})

-- ====================================================
-- ОДИН УДАР = КИЛЛ
-- ====================================================
-- Спам RemoteEvent ReplicatedStorage.CombatSystem.Remotes.RequestHit.
-- Один FireServer() = один удар по серверу. Если фаернуть N раз за кадр,
-- сервер посчитает N ударов подряд и моб умрёт мгновенно.
SailorTab:CreateDivider()
SailorTab:CreateSection("⚡ Один удар = килл")

SailorTab:CreateParagraph({
    Title = "Как работает",
    Text = "Прямой спам RemoteEvent CombatSystem.Remotes.RequestHit с args " ..
              "(target, position, tool). Это рабочая комба для Sailor Piece — " ..
              "проверено брутфорсом, ThiefBoss с 1500 HP падает за 30 фаеров.\n\n" ..
              "Если хочешь использовать в авто-фарме — включи тогл «💥 Один удар = килл», " ..
              "и каждый цикл атаки будет добавлять N фаеров на текущую цель."
})

SailorTab:CreateToggle({
    Name = "💥 Один удар = килл (в авто-фарме)",
    Description = "Каждый цикл атаки спамит RequestHit на текущую цель.",
    CurrentValue = false,
    Callback = function(v)
        sp_oneShotEnabled = v
        if v then
            local ev = _spGetRequestHit()
            if not ev then
                notify("RequestHit не найден в ReplicatedStorage.CombatSystem", 4, "warn")
                return
            end
            notify(("One Shot активен • сила: %d за тик"):format(sp_oneShotCount), 3, "success")
        end
    end
}, "sp_oneShotEnabled")

SailorTab:CreateSlider({
    Name = "Сила (кол-во FireServer за тик)",
    Description = "Чем больше — тем быстрее моб умирает. >200 может задетектить сервер.",
    Range = { 1, 500 },
    Increment = 5,
    CurrentValue = sp_oneShotCount,
    Callback = function(v) sp_oneShotCount = v end
}, "sp_oneShotCount")

SailorTab:CreateSlider({
    Name = "Сила «Убить одним нажатием»",
    Description = "Сколько ударов отправить кнопкой ниже за один клик.",
    Range = { 10, 1000 },
    Increment = 10,
    CurrentValue = sp_oneShotPerKill,
    Callback = function(v) sp_oneShotPerKill = v end
}, "sp_oneShotPerKill")

SailorTab:CreateButton({
    Name = "💀 Убить ближайшего одним нажатием",
    Description = "Killshot: до 10 раундов x 200 фаеров RequestHit пока моб не сдохнет.",
    Callback = function()
        local ev = _spGetRequestHit()
        if not ev then
            notify("RequestHit RemoteEvent не найден", 4, "warn"); return
        end
        -- Сначала ищем выбранного босса/моба, иначе любого ближайшего из NPCs
        local target = nil
        if sp_bossRootName and sp_bossRootName ~= "" then
            target = spFindBoss(sp_bossRootName)
        end
        if not target and not _isPlaceholder(sp_mobBaseName) then
            target = spFindMob(sp_mobBaseName)
        end
        if not target then
            local folder = workspace:FindFirstChild("NPCs")
            local myHRP = safeGetHRP(safeGetCharacter())
            local origin = myHRP and myHRP.Position or Vector3.zero
            local best, bestDist = nil, math.huge
            if folder then
                for _, m in ipairs(folder:GetChildren()) do
                    if m:IsA("Model") then
                        local hum = m:FindFirstChildOfClass("Humanoid")
                        local p = spModelPos(m)
                        if hum and hum.Health > 0 and p then
                            local d = (p - origin).Magnitude
                            if d < bestDist then bestDist, best = d, m end
                        end
                    end
                end
            end
            target = best
        end
        if not target then notify("Цель не найдена", 3, "warn"); return end
        local hum = target:FindFirstChildOfClass("Humanoid")
        local hpBefore = hum and hum.Health or 0
        notify(("Killshot: %s (HP %.0f)"):format(target.Name, hpBefore), 2)
        task.spawn(function()
            local killed, info = spKillshot(target, 12, 200)
            local hpAfter = (hum and hum.Parent) and hum.Health or 0
            notify(("'%s' %.0f→%.0f %s"):format(
                target.Name, hpBefore, hpAfter,
                killed and "💀 KILLED" or "(stalled)"), 4,
                killed and "success" or "warn")
        end)
    end
})

-- ====================================================
-- ЗАЩИТА
-- ====================================================
SailorTab:CreateDivider()
SailorTab:CreateSection("Защита от урона")

SailorTab:CreateParagraph({
    Title = "Что использовать",
    Text = "▸ God Mode v1 — Noclip + парение. Работает против melee/AOE: ты летаешь над целью.\n" ..
              "▸ Anti-Damage — поднимает на 50-200 ст. + якорит HRP. Лучшее против шот-боссов.\n" ..
              "▸ God Mode v2 — HP-restore. На 99% игр НЕ РАБОТАЕТ из-за серверной валидации, оставлен как опция."
})

SailorTab:CreateToggle({
    Name = "🛡 God Mode v1 (Noclip + парение)",
    CurrentValue = false,
    Callback = function(v)
        lunaLog("INFO", "Toggle God Mode v1 = " .. tostring(v))
        godModeEnabled = v
        if v then startGodMode() else stopGodMode() end
    end
}, "godModeV1")

SailorTab:CreateToggle({
    Name = "⚓ Anti-Damage Anchor",
    Description = "Поднимает над целью + якорит. Лучшая защита от шот-боссов.",
    CurrentValue = false,
    Callback = function(v)
        sp_antiDamage = v
        if not v then
            local hrp = safeGetHRP(safeGetCharacter())
            if hrp and hrp.Anchored then hrp.Anchored = false end
        end
    end
}, "sp_antiDamage")

SailorTab:CreateToggle({
    Name = "God Mode v2 (HP-restore, экспериментально)",
    CurrentValue = false,
    Callback = function(v)
        godMode2Enabled = v
        if v then startGodMode2() else stopGodMode2() end
    end
}, "godModeV2")


--========================================================
-- 👹 BOSS TAB — очередь боссов и авто-фарм
--========================================================
BossTab:CreateSection("Очередь боссов")

BossTab:CreateParagraph({
    Title = "Как работает очередь",
    Text = "Выбери одного или нескольких боссов в списке ниже. Скрипт будет бить ПЕРВОГО " ..
              "выбранного. Когда первый умрёт — переключится на ВТОРОГО, потом на третьего и т.д. " ..
              "После последнего вернётся на первого (циклически).\n\n" ..
              "В списке есть и те боссы, кого ПРЯМО СЕЙЧАС нет в Workspace — это preset Sailor Piece. " ..
              "Если выбранного босса нет на сервере, скрипт пропустит его и попробует следующего из очереди.\n\n" ..
              "Поиск использует string.find по lower-case: «bossultra» поймает «bossultra medium», " ..
              "«bossultra hard», «bossultra xard» — все сложности сразу."
})

bossDropdown = BossTab:CreateDropdown({
    Name = "Боссы (можно выбрать несколько)",
    Description = "Очередь: первый выбранный → второй → третий → по кругу",
    Options = sp_bossChoices,
    CurrentOption = sp_bossChoices[1] and { sp_bossChoices[1] } or {},
    MultipleOptions = true,
    Callback = function(selected)
        -- selected — массив выбранных имён (т.к. MultipleOptions = true)
        if type(selected) ~= "table" then selected = { selected } end
        sp_bossQueue = {}
        for _, name in ipairs(selected) do
            if name and not _isPlaceholder(name) then
                table.insert(sp_bossQueue, sp_bossLookup[name] or name)
            end
        end
        -- Для обратной совместимости: первый в очереди = "текущий" одиночный.
        if #sp_bossQueue > 0 then
            sp_bossDisplayName = sp_bossQueue[1]
            sp_bossRootName    = sp_bossQueue[1]
        end
    end
}, "sp_bossQueue")

BossTab:CreateButton({
    Name = "🔄 Обновить список боссов",
    Description = "Если только что заспавнил босса — жми сюда.",
    Callback = function()
        spRefreshAllDropdowns()
        notify(("Боссов в списке: %d"):format(#sp_bossChoices), 3, "success")
    end
})

BossTab:CreateDivider()
BossTab:CreateSection("Управление")

BossTab:CreateToggle({
    Name = "▶ Авто-фарм очереди боссов",
    Description = "Бьёт первого в очереди → переключается на следующего после смерти.",
    CurrentValue = false,
    Callback = function(v)
        lunaLog("INFO", "Toggle Boss-фарм = " .. tostring(v))
        if v then spBossStart() else spBossStop() end
    end
}, "sp_bossFarm")

BossTab:CreateButton({
    Name = "⏭ Пропустить текущего босса",
    Description = "Принудительно перейти к следующему в очереди.",
    Callback = function()
        if sp_currentMob then
            sp_currentMob = nil
            notify("Пропускаю текущего босса", 2)
        end
    end
})

BossTab:CreateButton({
    Name = "🎯 Телепорт к выбранному боссу",
    Description = "Прыгнуть к первому из очереди (без авто-фарма).",
    Callback = function()
        local q = (sp_bossQueue and #sp_bossQueue > 0) and sp_bossQueue or { sp_bossRootName }
        local name = q[1]
        if not name or name == "" then notify("Очередь пуста", 3, "warn"); return end
        task.spawn(function()
            _sp_forcedTp = true
            local boss = spFindBoss(name)
            if boss then
                local p = spModelPos(boss)
                if p then
                    spSmoothTeleportTo(CFrame.lookAt(p + Vector3.new(0, sp_hoverHeight, 0), p))
                end
            else
                notify(("Босс '%s' не найден на сервере"):format(name), 3, "warn")
            end
            _sp_forcedTp = false
        end)
    end
})


--========================================================
-- ⚙ FARM SETTINGS TAB — все слайдеры/тогглы тонкой настройки
--========================================================
FarmCfgTab:CreateSection("Полёт и навигация")

FarmCfgTab:CreateSlider({
    Name = "Скорость полёта (ст/сек)",
    Range = { 50, 1000 },
    Increment = 25,
    CurrentValue = sp_maxSpeed,
    Callback = function(v) sp_maxSpeed = v end
}, "sp_maxSpeed")

FarmCfgTab:CreateToggle({
    Name = "Мгновенный TP (без анимации полёта)",
    Description = "Самый быстрый вариант, но сервер может расценить как teleport-detection.",
    CurrentValue = sp_instantTp,
    Callback = function(v) sp_instantTp = v end
}, "sp_instantTp")

FarmCfgTab:CreateSlider({
    Name = "Высота парения над мобом (ст.)",
    Range = { 3, 20 },
    Increment = 1,
    CurrentValue = sp_hoverHeight,
    Callback = function(v) sp_hoverHeight = v end
}, "sp_hoverHeight")

FarmCfgTab:CreateSlider({
    Name = "Высота Anti-Damage (ст.)",
    Range = { 20, 200 },
    Increment = 5,
    CurrentValue = sp_antiDamageHeight,
    Callback = function(v) sp_antiDamageHeight = v end
}, "sp_antiDamageHeight")

FarmCfgTab:CreateDivider()
FarmCfgTab:CreateSection("Поиск мобов")

FarmCfgTab:CreateSlider({
    Name = "Радиус поиска моба (ст.)",
    Range = { 50, 1000 },
    Increment = 25,
    CurrentValue = sp_searchRadius,
    Callback = function(v) sp_searchRadius = v end
}, "sp_searchRadius")

FarmCfgTab:CreateSlider({
    Name = "Длительность охоты (сек)",
    Range = { 15, 300 },
    Increment = 5,
    CurrentValue = sp_huntDuration,
    Callback = function(v) sp_huntDuration = v end
}, "sp_huntDuration")

FarmCfgTab:CreateSlider({
    Name = "Убийств на один квест",
    Range = { 1, 30 },
    Increment = 1,
    CurrentValue = sp_killsPerQuest,
    Callback = function(v) sp_killsPerQuest = v end
}, "sp_killsPerQuest")

FarmCfgTab:CreateParagraph({
    Title = "Условия возврата к NPC",
    Text = "Скрипт идёт обратно сдать квест когда выполняется ЛЮБОЕ:\n" ..
              "• Убил «Убийств на один квест» мобов (по умолчанию 5)\n" ..
              "• Прошло «Длительность охоты» секунд (по умолчанию 60)\n" ..
              "• Моб не найден в радиусе поиска\n\n" ..
              "Free Combat игнорирует оба лимита и фармит вечно."
})

FarmCfgTab:CreateDivider()
FarmCfgTab:CreateSection("Оружие")

FarmCfgTab:CreateSlider({
    Name = "Слот оружия (1—5)",
    Range = { 1, 5 },
    Increment = 1,
    CurrentValue = sp_weaponSlot,
    Callback = function(v)
        sp_weaponSlot = v
        spSelectSlot(v)
    end
}, "sp_weaponSlot")

FarmCfgTab:CreateToggle({
    Name = "Авто-экип после возрождения",
    Description = "После смерти автоматически перенажимает выбранный слот.",
    CurrentValue = sp_autoEquip,
    Callback = function(v) sp_autoEquip = v end
}, "sp_autoEquip")

FarmCfgTab:CreateButton({
    Name = "Экипировать слот сейчас",
    Callback = function() spSelectSlot(sp_weaponSlot) end
})

FarmCfgTab:CreateDivider()
FarmCfgTab:CreateSection("Атака")

FarmCfgTab:CreateToggle({
    Name = "Бить руками (клики мыши)",
    Description = "Отправлять клики мыши через VirtualInputManager.",
    CurrentValue = not sp_handFightOff,
    Callback = function(v) sp_handFightOff = not v end
}, "sp_handFight")

FarmCfgTab:CreateToggle({
    Name = "Бить только с оружием",
    Description = "Не бить если в руках ничего нет — пропускать кадр и переэкипировать.",
    CurrentValue = sp_useHandsOnly,
    Callback = function(v) sp_useHandsOnly = v end
}, "sp_requireTool")

FarmCfgTab:CreateSlider({
    Name = "Задержка между кликами (сек)",
    Range = { 0.15, 1.0 },
    Increment = 0.05,
    CurrentValue = sp_attackDelay,
    Callback = function(v) sp_attackDelay = v end
}, "sp_attackDelay")

FarmCfgTab:CreateSlider({
    Name = "Задержка между скиллами (сек)",
    Range = { 0.3, 5.0 },
    Increment = 0.1,
    CurrentValue = sp_skillDelay,
    Callback = function(v) sp_skillDelay = v end
}, "sp_skillDelay")

FarmCfgTab:CreateSlider({
    Name = "Удержание клавиши скилла (сек)",
    Range = { 0.05, 0.5 },
    Increment = 0.05,
    CurrentValue = sp_skillHold,
    Callback = function(v) sp_skillHold = v end
}, "sp_skillHold")

FarmCfgTab:CreateDivider()
FarmCfgTab:CreateSection("Скиллы (Z / X / C / V / F)")

FarmCfgTab:CreateParagraph({
    Title = "Ротация скиллов",
    Text = "Тогглы ниже включают/выключают конкретные клавиши в ротации. " ..
              "Работают и для квестов, и для боссов в реальном времени."
})
FarmCfgTab:CreateToggle({ Name = "Скилл Z", CurrentValue = sp_useZ, Callback = function(v) sp_useZ = v end }, "sp_useZ")
FarmCfgTab:CreateToggle({ Name = "Скилл X", CurrentValue = sp_useX, Callback = function(v) sp_useX = v end }, "sp_useX")
FarmCfgTab:CreateToggle({ Name = "Скилл C", CurrentValue = sp_useC, Callback = function(v) sp_useC = v end }, "sp_useC")
FarmCfgTab:CreateToggle({ Name = "Скилл V", CurrentValue = sp_useV, Callback = function(v) sp_useV = v end }, "sp_useV")
FarmCfgTab:CreateToggle({ Name = "Скилл F", CurrentValue = sp_useF, Callback = function(v) sp_useF = v end }, "sp_useF")


--========================================================

end)()

_G.LunaHub.modules.sailor_piece = {
    unload = function()
        pcall(function()
            sp_enabled = false; sp_bossEnabled = false
            godModeEnabled = false; godMode2Enabled = false
            sp_antiDamage = false
        end)
        pcall(spStop); pcall(spBossStop)
        pcall(stopGodMode); pcall(stopGodMode2)
        pcall(function()
            local hrp = safeGetHRP(safeGetCharacter())
            if hrp and hrp.Anchored then hrp.Anchored = false end
        end)
        for _, c in ipairs(moduleConnections) do
            pcall(function() c:Disconnect() end)
        end
        table.clear(moduleConnections)
        lunaLog("INFO", "Sailor Piece module unloaded")
    end,
}

notify("Sailor Piece модуль готов", 3, "success")
