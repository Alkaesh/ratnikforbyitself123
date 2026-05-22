--========================================================
-- LUNA HUB - Sailor Piece (Rayfield Edition)
-- Полный рерайт UI на Rayfield + config save/load
--========================================================

-- ===== reload guard =====
if _G.LunaCheatLoaded then
    if type(_G.LunaUnload) == "function" then pcall(_G.LunaUnload) end
    _G.LunaCheatLoaded = false
    _G.LunaUnload = nil
end

-- Подчищаем рудименты от прошлых сессий: и Kavo (старый ScreenGui с "Main"),
-- и Rayfield (его контейнер называется "Rayfield").
pcall(function()
    local function purge(parent)
        for _, c in ipairs(parent:GetChildren()) do
            if c:IsA("ScreenGui") and (c.Name == "Rayfield" or c:FindFirstChild("Main")) then
                pcall(function() c:Destroy() end)
            end
        end
    end
    purge(game:GetService("CoreGui"))
    if gethui then
        local ok, hui = pcall(gethui)
        if ok and hui then purge(hui) end
    end
    for _, k in ipairs({"LunaTracerGui", "LunaFovGui", "LunaWindowGui", "LunaSplashGui"}) do
        if typeof(_G[k]) == "Instance" then
            pcall(function() _G[k]:Destroy() end)
            _G[k] = nil
        end
    end
end)

-- ===== services =====
local okSvc, Players, RunService, UIS, Camera, Lighting, LocalPlayer, ReplicatedStorage, HttpService =
    pcall(function()
        local P = game:GetService("Players")
        local lp = P.LocalPlayer
        local t0 = tick()
        while not lp and tick() - t0 < 10 do
            task.wait(0.1)
            lp = P.LocalPlayer
        end
        return P,
            game:GetService("RunService"),
            game:GetService("UserInputService"),
            workspace.CurrentCamera,
            game:GetService("Lighting"),
            lp,
            game:GetService("ReplicatedStorage"),
            game:GetService("HttpService")
    end)

if not okSvc or not Players or not LocalPlayer then
    warn("[Luna] Игра не поддерживается (DataModel: " .. tostring(game.Name) .. ")")
    return
end

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

-- ===== загрузка Rayfield =====
local Rayfield
do
    local sources = {
        "https://sirius.menu/rayfield",
        "https://raw.githubusercontent.com/SiriusSoftwareLtd/Rayfield/main/source.lua",
    }
    local lastErr
    for _, url in ipairs(sources) do
        local ok, lib = pcall(function()
            return loadstring(game:HttpGet(url))()
        end)
        if ok and type(lib) == "table" and lib.CreateWindow then
            Rayfield = lib
            break
        else
            lastErr = tostring(lib)
        end
    end
    if not Rayfield then
        warn("[Luna] Не удалось загрузить Rayfield: " .. tostring(lastErr))
        return
    end
end

-- ===== соединения =====
local allConnections = {}
local function track(conn)
    if conn then table.insert(allConnections, conn) end
    return conn
end

-- ===== утилиты =====
local function notify(msg, dur)
    pcall(function()
        Rayfield:Notify({ Title = "Luna", Content = tostring(msg),
            Duration = dur or 3, Image = 4483362458 })
    end)
    print("[Luna] " .. tostring(msg))
end

local function safeGetCharacter()
    return LocalPlayer and LocalPlayer.Character or nil
end
local function safeGetHumanoid(c)
    return c and c:FindFirstChildOfClass("Humanoid") or nil
end
local function safeGetHRP(c)
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end

local function isSameTeam(plr)
    if not LocalPlayer then return false end
    if plr.Team and LocalPlayer.Team and plr.Team == LocalPlayer.Team then return true end
    if plr.TeamColor and LocalPlayer.TeamColor and plr.TeamColor == LocalPlayer.TeamColor then return true end
    return false
end

local function randomName()
    local s, t = "abcdefghijklmnopqrstuvwxyz", {}
    for i = 1, math.random(8, 14) do
        local k = math.random(1, #s)
        t[i] = s:sub(k, k)
    end
    return table.concat(t)
end

local hiddenParent
pcall(function()
    if gethui then hiddenParent = gethui() end
end)
hiddenParent = hiddenParent or game:GetService("CoreGui")

-- ====================================================
-- ====================================================
-- LOADING SPLASH — магический круг призыва
-- ====================================================
-- На весь экран, видим 2 секунды, затем плавный fade-out за 0.5 сек.
-- Композиция:
--   - Чёрный фон с пульсирующим фиолетовым "глоу"
--   - Внешний рунный круг (вращается по часовой)
--   - Внутренний круг (вращается против часовой)
--   - Центральная пятиконечная звезда (Roblox decal — рамповый алгоритм:
--     вместо SVG-звезды берём 5 сходящихся к центру тонких лучей-Frame)
--   - LUNA HUB поверх с двойным stroke (внешний фиолетовый, внутренний белый)
--   - Прогресс-бар с градиентом + меняющийся статус
local splashGui
local destroySplash   -- forward
do
    local TweenService = game:GetService("TweenService")

    splashGui = Instance.new("ScreenGui")
    splashGui.Name = randomName()
    splashGui.IgnoreGuiInset = true
    splashGui.ResetOnSpawn = false
    splashGui.DisplayOrder = 999999
    pcall(function()
        splashGui.Parent = hiddenParent
        if syn and syn.protect_gui then syn.protect_gui(splashGui) end
    end)

    -- ---- Фон ----
    local bg = Instance.new("Frame")
    bg.Name = "BG"
    bg.Size = UDim2.fromScale(1, 1)
    bg.BackgroundColor3 = Color3.fromRGB(6, 4, 12)
    bg.BorderSizePixel = 0
    bg.Parent = splashGui

    -- Тонкая виньетка (плотный градиент к чёрному по краям)
    local vignette = Instance.new("ImageLabel")
    vignette.Name = "Vignette"
    vignette.Size = UDim2.fromScale(1, 1)
    vignette.BackgroundTransparency = 1
    vignette.Image = "rbxassetid://5028857084"   -- стандартный radial gradient asset
    vignette.ImageColor3 = Color3.fromRGB(0, 0, 0)
    vignette.ImageTransparency = 0.35
    vignette.ScaleType = Enum.ScaleType.Stretch
    vignette.Parent = bg

    -- Пульсирующий фиолетовый glow в центре (как аура заклинания)
    local glow = Instance.new("Frame")
    glow.AnchorPoint = Vector2.new(0.5, 0.5)
    glow.Position = UDim2.fromScale(0.5, 0.5)
    glow.Size = UDim2.fromOffset(560, 560)
    glow.BackgroundColor3 = Color3.fromRGB(140, 70, 230)
    glow.BackgroundTransparency = 0.85
    glow.BorderSizePixel = 0
    glow.Parent = bg
    local glowCorner = Instance.new("UICorner"); glowCorner.CornerRadius = UDim.new(1, 0); glowCorner.Parent = glow
    local glowGrad = Instance.new("UIGradient")
    glowGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 120, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(60, 20, 110)),
    })
    glowGrad.Transparency = NumberSequence.new({
        NumberSequenceKeypoint.new(0, 0.7),
        NumberSequenceKeypoint.new(1, 1.0),
    })
    glowGrad.Parent = glow

    -- ---- Магический круг (вращающийся) ----
    -- Контейнер чтобы Rotation работал на оба круга независимо
    local circleHolder = Instance.new("Frame")
    circleHolder.AnchorPoint = Vector2.new(0.5, 0.5)
    circleHolder.Position = UDim2.fromScale(0.5, 0.42)
    circleHolder.Size = UDim2.fromOffset(420, 420)
    circleHolder.BackgroundTransparency = 1
    circleHolder.Parent = bg

    -- Внешний круг (тонкое фиолетовое кольцо)
    local outerRing = Instance.new("Frame")
    outerRing.Name = "OuterRing"
    outerRing.AnchorPoint = Vector2.new(0.5, 0.5)
    outerRing.Position = UDim2.fromScale(0.5, 0.5)
    outerRing.Size = UDim2.fromScale(1, 1)
    outerRing.BackgroundTransparency = 1
    outerRing.Parent = circleHolder
    local oc = Instance.new("UICorner"); oc.CornerRadius = UDim.new(1, 0); oc.Parent = outerRing
    local outerStroke = Instance.new("UIStroke")
    outerStroke.Color = Color3.fromRGB(180, 120, 255)
    outerStroke.Thickness = 2.5
    outerStroke.Transparency = 0.15
    outerStroke.Parent = outerRing

    -- На внешнем кольце — 8 коротких "штрихов" (имитация рунных меток).
    -- Просто 8 тонких Frame, расставленных по кругу через angle.
    for i = 0, 7 do
        local ang = math.rad(i * 45)
        local r = 210
        local mark = Instance.new("Frame")
        mark.AnchorPoint = Vector2.new(0.5, 0.5)
        mark.BackgroundColor3 = Color3.fromRGB(220, 180, 255)
        mark.BorderSizePixel = 0
        mark.Size = UDim2.fromOffset(14, 3)
        mark.Position = UDim2.new(0.5, math.cos(ang) * r, 0.5, math.sin(ang) * r)
        mark.Rotation = math.deg(ang)
        mark.BackgroundTransparency = 0.1
        mark.Parent = outerRing
        local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(1, 0); mc.Parent = mark
    end

    -- Внутренний круг (на 70% от внешнего, штрих толще, цвет другой)
    local innerRing = Instance.new("Frame")
    innerRing.Name = "InnerRing"
    innerRing.AnchorPoint = Vector2.new(0.5, 0.5)
    innerRing.Position = UDim2.fromScale(0.5, 0.5)
    innerRing.Size = UDim2.fromScale(0.7, 0.7)
    innerRing.BackgroundTransparency = 1
    innerRing.Parent = circleHolder
    local ic = Instance.new("UICorner"); ic.CornerRadius = UDim.new(1, 0); ic.Parent = innerRing
    local innerStroke = Instance.new("UIStroke")
    innerStroke.Color = Color3.fromRGB(255, 230, 180)   -- золотисто-белый
    innerStroke.Thickness = 1.5
    innerStroke.Transparency = 0.25
    innerStroke.Parent = innerRing

    -- 5 крупных рунных штрихов на внутреннем круге (пятиконечник)
    for i = 0, 4 do
        local ang = math.rad(i * 72 - 90)   -- начинаем сверху
        local r = 137
        local mark = Instance.new("Frame")
        mark.AnchorPoint = Vector2.new(0.5, 0.5)
        mark.BackgroundColor3 = Color3.fromRGB(255, 240, 200)
        mark.BorderSizePixel = 0
        mark.Size = UDim2.fromOffset(20, 4)
        mark.Position = UDim2.new(0.5, math.cos(ang) * r, 0.5, math.sin(ang) * r)
        mark.Rotation = math.deg(ang) + 90
        mark.Parent = innerRing
        local mc = Instance.new("UICorner"); mc.CornerRadius = UDim.new(1, 0); mc.Parent = mark
    end

    -- Центральная пентаграмма из 5 лучей.
    -- Не векторная: 5 длинных тонких Frame, сходящихся к центру под углами 72°.
    -- Базовая позиция = (0.5, 0.5), длина по AnchorPoint (0, 0.5).
    local pentaHolder = Instance.new("Frame")
    pentaHolder.AnchorPoint = Vector2.new(0.5, 0.5)
    pentaHolder.Position = UDim2.fromScale(0.5, 0.5)
    pentaHolder.Size = UDim2.fromOffset(2, 2)
    pentaHolder.BackgroundTransparency = 1
    pentaHolder.Parent = circleHolder

    for i = 0, 4 do
        local ang = i * 72 - 90
        local ray = Instance.new("Frame")
        ray.AnchorPoint = Vector2.new(0.5, 0.5)
        ray.Position = UDim2.fromScale(0.5, 0.5)
        ray.Size = UDim2.fromOffset(110, 2)
        ray.Rotation = ang
        ray.BackgroundColor3 = Color3.fromRGB(255, 220, 240)
        ray.BorderSizePixel = 0
        ray.BackgroundTransparency = 0.2
        ray.Parent = pentaHolder
    end

    -- ---- ПЕРСОНАЖ В ЦЕНТРЕ КРУГА (Sukuna / Gojo как символ "магической битвы") ----
    -- Под персонажем — багровое свечение (имитация "проклятой энергии").
    local cursedGlow = Instance.new("Frame")
    cursedGlow.AnchorPoint = Vector2.new(0.5, 0.5)
    cursedGlow.Position = UDim2.fromScale(0.5, 0.5)
    cursedGlow.Size = UDim2.fromOffset(300, 300)
    cursedGlow.BackgroundColor3 = Color3.fromRGB(180, 30, 50)
    cursedGlow.BackgroundTransparency = 0.65
    cursedGlow.BorderSizePixel = 0
    cursedGlow.ZIndex = 3
    cursedGlow.Parent = bg
    local cgc = Instance.new("UICorner"); cgc.CornerRadius = UDim.new(1, 0); cgc.Parent = cursedGlow

    -- Если Roblox Asset Moderation удалит ID — fallback показывает текстовый кандзи "呪".
    -- Лежат под кругом, чтобы кольца "обнимали" персонажа.
    local charImg = Instance.new("ImageLabel")
    charImg.Name = "MagicChar"
    charImg.AnchorPoint = Vector2.new(0.5, 0.5)
    charImg.Position = UDim2.fromScale(0.5, 0.5)
    charImg.Size = UDim2.fromOffset(280, 280)
    charImg.BackgroundTransparency = 1
    charImg.ScaleType = Enum.ScaleType.Fit
    charImg.Image = "rbxassetid://13312562937"   -- Sukuna decal (если упадёт — заменим)
    charImg.ImageTransparency = 0.05
    charImg.ZIndex = 5   -- поверх кругов
    charImg.Parent = bg

    -- Резервный кандзи "呪" (jujutsu = проклятие) — фолбек если картинка не загрузится
    local kanji = Instance.new("TextLabel")
    kanji.AnchorPoint = Vector2.new(0.5, 0.5)
    kanji.Position = UDim2.fromScale(0.5, 0.5)
    kanji.Size = UDim2.fromOffset(280, 280)
    kanji.BackgroundTransparency = 1
    kanji.Text = "呪"
    kanji.Font = Enum.Font.FredokaOne
    kanji.TextSize = 220
    kanji.TextColor3 = Color3.fromRGB(220, 80, 80)
    kanji.TextTransparency = 0.5
    kanji.TextStrokeTransparency = 0.3
    kanji.TextStrokeColor3 = Color3.fromRGB(60, 0, 0)
    kanji.ZIndex = 4   -- ниже картинки, выше кругов
    kanji.Parent = bg

    -- ---- Заголовок LUNA HUB (внизу под кругом, чтобы не закрывал персонажа) ----
    local title = Instance.new("TextLabel")
    title.AnchorPoint = Vector2.new(0.5, 0.5)
    title.Position = UDim2.fromScale(0.5, 0.85)
    title.Size = UDim2.new(0, 720, 0, 90)
    title.BackgroundTransparency = 1
    title.Text = "LUNA HUB"
    title.Font = Enum.Font.GothamBlack
    title.TextSize = 64
    title.TextColor3 = Color3.fromRGB(245, 235, 255)
    title.TextStrokeTransparency = 1
    title.ZIndex = 10
    title.Parent = bg

    -- Двойной stroke: внешний толстый фиолетовый + тонкий белый поверх
    local titleStrokeOuter = Instance.new("UIStroke")
    titleStrokeOuter.Color = Color3.fromRGB(140, 80, 230)
    titleStrokeOuter.Thickness = 4
    titleStrokeOuter.Transparency = 0
    titleStrokeOuter.LineJoinMode = Enum.LineJoinMode.Round
    titleStrokeOuter.Parent = title

    -- Градиент по тексту (бело-фиолетовый сверху-вниз)
    local titleGrad = Instance.new("UIGradient")
    titleGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 255)),
        ColorSequenceKeypoint.new(0.5, Color3.fromRGB(220, 180, 255)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(170, 110, 230)),
    })
    titleGrad.Rotation = 90
    titleGrad.Parent = title

    -- Подзаголовок
    local subtitle = Instance.new("TextLabel")
    subtitle.AnchorPoint = Vector2.new(0.5, 0.5)
    subtitle.Position = UDim2.fromScale(0.5, 0.91)
    subtitle.Size = UDim2.new(0, 600, 0, 22)
    subtitle.BackgroundTransparency = 1
    subtitle.Text = "✦  S A I L O R   P I E C E  ✦"
    subtitle.Font = Enum.Font.GothamMedium
    subtitle.TextSize = 14
    subtitle.TextColor3 = Color3.fromRGB(200, 180, 240)
    subtitle.TextTransparency = 0.1
    subtitle.ZIndex = 10
    subtitle.Parent = bg

    -- ---- Прогресс-бар ----
    local barBg = Instance.new("Frame")
    barBg.AnchorPoint = Vector2.new(0.5, 0.5)
    barBg.Position = UDim2.fromScale(0.5, 0.74)
    barBg.Size = UDim2.new(0, 380, 0, 6)
    barBg.BackgroundColor3 = Color3.fromRGB(30, 20, 50)
    barBg.BorderSizePixel = 0
    barBg.ZIndex = 10
    barBg.Parent = bg
    local bbc = Instance.new("UICorner"); bbc.CornerRadius = UDim.new(1, 0); bbc.Parent = barBg

    local bar = Instance.new("Frame")
    bar.AnchorPoint = Vector2.new(0, 0.5)
    bar.Position = UDim2.new(0, 0, 0.5, 0)
    bar.Size = UDim2.new(0, 0, 1, 0)
    bar.BackgroundColor3 = Color3.fromRGB(180, 120, 255)
    bar.BorderSizePixel = 0
    bar.ZIndex = 11
    bar.Parent = barBg
    local bc = Instance.new("UICorner"); bc.CornerRadius = UDim.new(1, 0); bc.Parent = bar

    local barGrad = Instance.new("UIGradient")
    barGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 240)),
        ColorSequenceKeypoint.new(1, Color3.fromRGB(150, 80, 230)),
    })
    barGrad.Parent = bar

    -- статус
    local status = Instance.new("TextLabel")
    status.AnchorPoint = Vector2.new(0.5, 0.5)
    status.Position = UDim2.fromScale(0.5, 0.78)
    status.Size = UDim2.new(0, 600, 0, 18)
    status.BackgroundTransparency = 1
    status.Text = "плетение заклинания…"
    status.Font = Enum.Font.Gotham
    status.TextSize = 13
    status.TextColor3 = Color3.fromRGB(160, 145, 200)
    status.ZIndex = 10
    status.Parent = bg

    -- ---- Анимации ----
    -- Внешний круг крутим по часовой, внутренний — против часовой (бесконечно).
    -- Делаем через Tween с RepeatCount = -1 (зацикленно).
    local spinOut = TweenService:Create(outerRing,
        TweenInfo.new(8, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false, 0),
        { Rotation = 360 })
    spinOut:Play()
    local spinIn = TweenService:Create(innerRing,
        TweenInfo.new(6, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false, 0),
        { Rotation = -360 })
    spinIn:Play()
    -- Пентаграмма медленно вращается тоже (ту же сторону, что внешний)
    local spinPenta = TweenService:Create(pentaHolder,
        TweenInfo.new(12, Enum.EasingStyle.Linear, Enum.EasingDirection.InOut, -1, false, 0),
        { Rotation = 360 })
    spinPenta:Play()

    -- Glow пульсирует (туда-сюда) каждые 1.4 сек
    local glowPulse = TweenService:Create(glow,
        TweenInfo.new(1.4, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, 0),
        { Size = UDim2.fromOffset(680, 680), BackgroundTransparency = 0.7 })
    glowPulse:Play()

    -- Cursed-energy glow под персонажем — пульсирует короткими импульсами
    local cursedPulse = TweenService:Create(cursedGlow,
        TweenInfo.new(0.9, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, 0),
        { Size = UDim2.fromOffset(360, 360), BackgroundTransparency = 0.5 })
    cursedPulse:Play()

    -- Персонаж — лёгкое "дыхание"
    local charPulse = TweenService:Create(charImg,
        TweenInfo.new(2.0, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, 0),
        { Size = UDim2.fromOffset(295, 295) })
    charPulse:Play()

    -- Заголовок: лёгкое "дыхание" размера + плавающий градиент
    local titlePulse = TweenService:Create(title,
        TweenInfo.new(2.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true, 0),
        { TextSize = 70 })
    titlePulse:Play()
    task.spawn(function()
        local t0 = tick()
        while splashGui do
            local off = (tick() - t0) * 0.35
            titleGrad.Offset = Vector2.new(0, math.sin(off) * 0.15)
            task.wait(1/30)
        end
    end)

    -- Прогресс-бар: за 1.8с до 100%
    TweenService:Create(bar,
        TweenInfo.new(1.8, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
        { Size = UDim2.new(1, 0, 1, 0) }):Play()

    -- Статус по этапам
    task.spawn(function()
        local stages = {
            "плетение заклинания",
            "призыв интерфейса",
            "настройка камней",
            "связь установлена",
        }
        local i = 1
        while splashGui and i <= #stages do
            for n = 1, 4 do
                if not splashGui then return end
                status.Text = stages[i] .. string.rep(".", n - 1)
                task.wait(0.11)
            end
            i = i + 1
        end
    end)

    _G.LunaSplashGui = splashGui
end

destroySplash = function()
    if not splashGui then return end
    local g = splashGui
    splashGui = nil
    -- Сначала пробуем плавный fade
    pcall(function()
        local TweenService = game:GetService("TweenService")
        local fadeInfo = TweenInfo.new(0.5, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)
        for _, d in ipairs(g:GetDescendants()) do
            if d:IsA("Frame") then
                pcall(function() TweenService:Create(d, fadeInfo, { BackgroundTransparency = 1 }):Play() end)
            elseif d:IsA("TextLabel") then
                pcall(function() TweenService:Create(d, fadeInfo, { TextTransparency = 1 }):Play() end)
            elseif d:IsA("ImageLabel") then
                pcall(function() TweenService:Create(d, fadeInfo, { ImageTransparency = 1 }):Play() end)
            elseif d:IsA("UIStroke") then
                pcall(function() TweenService:Create(d, fadeInfo, { Transparency = 1 }):Play() end)
            end
        end
    end)
    -- Параллельно — гарантированный Destroy через 0.55 сек, что бы ни произошло
    task.delay(0.55, function() pcall(function() g:Destroy() end) end)
    -- АБСОЛЮТНАЯ страховка: если task.delay упадёт — сносим через раз
    task.spawn(function()
        task.wait(1.5)
        pcall(function() if g and g.Parent then g:Destroy() end end)
    end)
    _G.LunaSplashGui = nil
end

-- АБСОЛЮТНАЯ страховка: даже если ниже что-то крашнет — splash умрёт через 4 сек.
-- Это решает баг "splash висит вечно", если Rayfield не загрузился.
task.delay(4, function() pcall(destroySplash) end)
-- ЕЩЁ ОДНА страховка прямо на корень — если 4-сек таймер не сработает,
-- через 7 сек просто прибьём ScreenGui по ссылке через _G
task.delay(7, function()
    pcall(function()
        if typeof(_G.LunaSplashGui) == "Instance" then
            _G.LunaSplashGui:Destroy()
            _G.LunaSplashGui = nil
        end
    end)
end)



-- ===== окно Rayfield =====
-- Оборачиваем в pcall: если CreateWindow упадёт (битая Theme, неверный keybind,
-- старая версия Rayfield), сплэш будет немедленно убит и юзер увидит ошибку
-- вместо "висящего на экране LUNA HUB".
local Window
do
    local ok, win = pcall(function()
        return Rayfield:CreateWindow({
            Name = "Luna Hub | Sailor Piece",
            LoadingTitle = "Luna Hub",
            LoadingSubtitle = "загрузка модулей...",
            Theme = "Amethyst",
            ToggleUIKeybind = Enum.KeyCode.RightControl,
            DisableBuildWarnings = true,
            ConfigurationSaving = {
                Enabled = false,
                FolderName = "LunaHub",
                FileName = "sailor_piece_v3"
            },
            Discord = { Enabled = false },
            KeySystem = false
        })
    end)

    if not ok or not win then
        -- Фолбэк попытка БЕЗ ToggleUIKeybind и БЕЗ Theme — на случай если форк
        -- Rayfield не поддерживает эти параметры в их текущей форме.
        local ok2, win2 = pcall(function()
            return Rayfield:CreateWindow({
                Name = "Luna Hub | Sailor Piece",
                LoadingTitle = "Luna Hub",
                LoadingSubtitle = "загрузка модулей...",
                ConfigurationSaving = { Enabled = false },
                Discord = { Enabled = false },
                KeySystem = false
            })
        end)
        if ok2 and win2 then
            Window = win2
        else
            -- Полный провал — гасим сплэш и выходим, чтоб не висело
            pcall(destroySplash)
            warn("[Luna] Не удалось создать окно Rayfield: " ..
                tostring(win) .. " | fallback: " .. tostring(win2))
            return
        end
    else
        Window = win
    end
end

-- Увеличиваем размер окна (Rayfield по умолчанию ~500x440 — для 7 табов мало).
pcall(function()
    if Window and Window.Main then
        Window.Main.Size = UDim2.new(0, 620, 0, 520)
    end
end)

-- Создаём табы заранее, чтобы можно было ссылаться из любого места
local SailorTab   = Window:CreateTab("Sailor Piece", 4483362458)
local CombatTab   = Window:CreateTab("Бой",          4483345998)
local PlayerTab   = Window:CreateTab("Персонаж",     7733715400)
local VisualsTab  = Window:CreateTab("Графика",      4483345998)
local ESPTab      = Window:CreateTab("ESP",          7734053495)
local WorldTab    = Window:CreateTab("Мир",          4483345998)
local SettingsTab = Window:CreateTab("Настройки",    4483345998)


--========================================================
-- SAILOR PIECE — Auto Quest Farm
--========================================================
local SQuestSec  = SailorTab:CreateSection("Квест и зона")

-- ===== state =====
-- Квестовый цикл
local sp_questNpcName  = ""
local sp_mobBaseName   = ""
local sp_scanRadius    = 100
local sp_searchRadius  = 200
-- Длительность охоты квестового цикла
local sp_huntDuration  = 60
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

-- Слот оружия (1..5). При respawn автоматически экипируем.
local sp_weaponSlot = 1
local sp_autoEquip  = true

-- Hover/God Mode
local sp_hoverHeight = 7
local sp_maxSpeed    = 110
local sp_stepRate    = 30

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
-- Папки
-- ====================================================
local function spGetNpcFolder()     return workspace:FindFirstChild("NPCs")        end
local function spGetServiceFolder() return workspace:FindFirstChild("ServiceNPCs") end

-- ====================================================
-- Утилиты
-- ====================================================
local function spStripTrailingDigits(s)
    if type(s) ~= "string" then return "" end
    local cleaned = s:gsub("%d+$", "")
    if cleaned == "" then return s end
    return cleaned
end

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
-- Сканер зоны
-- ====================================================
local sp_npcChoices = { "(нажми Scan)" }
local sp_mobChoices = { "(нажми Scan)" }

local function spScanAreaNpcs()
    local list, seen = {}, {}
    local folder = spGetServiceFolder()
    if not folder then return { "(нет ServiceNPCs)" } end
    local myHRP = safeGetHRP(safeGetCharacter())
    if not myHRP then return { "(нет персонажа)" } end
    local origin, r2 = myHRP.Position, sp_scanRadius * sp_scanRadius
    for _, c in ipairs(folder:GetChildren()) do
        if c:IsA("Model") and not seen[c.Name] then
            local p = spModelPos(c)
            if p and (p - origin).Magnitude <= sp_scanRadius then
                seen[c.Name] = true
                table.insert(list, c.Name)
            end
        end
    end
    table.sort(list)
    if #list == 0 then table.insert(list, "(нет NPC в радиусе)") end
    return list
end

local function spScanAreaMobs()
    local list, seen = {}, {}
    local folder = spGetNpcFolder()
    if not folder then return { "(нет NPCs)" } end
    local myHRP = safeGetHRP(safeGetCharacter())
    if not myHRP then return { "(нет персонажа)" } end
    local origin = myHRP.Position
    for _, c in ipairs(folder:GetChildren()) do
        if c:IsA("Model") then
            local p = spModelPos(c)
            if p and (p - origin).Magnitude <= sp_scanRadius then
                local base = spStripTrailingDigits(c.Name)
                if base ~= "" and not seen[base] then
                    seen[base] = true
                    table.insert(list, base)
                end
            end
        end
    end
    table.sort(list)
    if #list == 0 then table.insert(list, "(нет мобов в радиусе)") end
    return list
end

-- ====================================================
-- Поиск моба / NPC по имени
-- ====================================================
local function _isPlaceholder(s)
    return not s or s == "" or s:sub(1, 1) == "("
end

local function spFindMob(baseName)
    if _isPlaceholder(baseName) then return nil end
    local folder = spGetNpcFolder()
    if not folder then return nil end
    local myHRP = safeGetHRP(safeGetCharacter())
    local origin = myHRP and myHRP.Position or Vector3.zero
    local best, bestDist = nil, math.huge
    for _, mob in ipairs(folder:GetChildren()) do
        if mob:IsA("Model") and string.find(mob.Name, baseName, 1, true) then
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
    local folder = spGetServiceFolder()
    if not folder then return nil end
    return folder:FindFirstChild(npcName)
end

-- ====================================================
-- Плавный TP с лимитом скорости
-- ====================================================
local _sp_forcedTp = false
local function spSmoothTeleportTo(targetCFrame)
    local char = safeGetCharacter()
    local hrp  = safeGetHRP(char)
    if not hrp then return end
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

    sp_loopThread = task.spawn(function()
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
                notify(("Hunt %ds: %s"):format(sp_huntDuration, sp_mobBaseName))
                while sp_enabled
                    and _G.QuestState == "Hunting"
                    -- Free Combat игнорирует таймер охоты (фармим вечно)
                    and (sp_freeCombat or (tick() - huntStart) < sp_huntDuration)
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
                        sp_currentMob = nil
                        task.wait(0.1)
                    end
                end
                _G.QuestState = sp_freeCombat and "Hunting" or "TakeQuest"
                task.wait(0.3)
            else
                _G.QuestState = sp_freeCombat and "Hunting" or "TakeQuest"
                task.wait(0.2)
            end
            task.wait(0.05)
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
-- Стартовый seed-список (то что "обычно" есть в игре). При нажатии "Авто-скан"
-- этот список расширится тем, что реально найдётся в workspace.NPCs.
-- Имена нормализуются: суффиксы _Normal/_Medium/_Hard/_Extreme/_Easy/_Insane
-- и хвостовые цифры срезаются, чтобы string.find ловил все варианты сразу.
local EliteBosses = {
    ["Black Reaper"] = "BlackReaperBoss",
    ["Monkey Boss"]  = "Monkey Boss",
    ["Thief Boss"]   = "ThiefBoss",
}
local EliteBossOrder = { "Black Reaper", "Monkey Boss", "Thief Boss" }
local sp_bossDisplayName = EliteBossOrder[1]
local sp_bossRootName    = EliteBosses[sp_bossDisplayName]

-- Утилита: нормализация имени модели в "корневое" имя босса.
-- "BlackReaperBoss_Hard" -> "BlackReaperBoss"
-- "FireDragon3"          -> "FireDragon"
-- "Boss_Easy"            -> "Boss" (если хочется, можно отключить)
local function _spStripBossSuffix(name)
    if type(name) ~= "string" then return name end
    -- Сначала срезаем суффикс сложности
    local stripped = name
        :gsub("_Easy$", "")
        :gsub("_Normal$", "")
        :gsub("_Medium$", "")
        :gsub("_Hard$", "")
        :gsub("_Extreme$", "")
        :gsub("_Insane$", "")
        :gsub("_Nightmare$", "")
        :gsub("_Boss$", "")  -- "Sukuna_Boss" -> "Sukuna"
    -- Потом срезаем хвостовые цифры
    local cleaned = stripped:gsub("%d+$", "")
    if cleaned == "" then return stripped end
    return cleaned
end

-- Эвристика "это похоже на босса": в имени есть Boss/Lord/King/Captain/Demon/Lord
-- ИЛИ Humanoid.MaxHealth заметно больше среднего рядового моба (>= 1000).
local function _spLooksLikeBoss(model, hum)
    local n = model.Name:lower()
    if n:find("boss")    or n:find("lord")    or n:find("king")
       or n:find("queen") or n:find("demon")   or n:find("captain")
       or n:find("titan") or n:find("reaper")  or n:find("master")
       or n:find("admiral") or n:find("warlord")
    then
        return true
    end
    -- Толстое HP = вероятно босс
    if hum and hum.MaxHealth and hum.MaxHealth >= 1000 then return true end
    return false
end

-- Авто-сканер ВСЕХ боссов в workspace.NPCs (без радиуса — пробегает карту целиком).
-- Возвращает Map<DisplayName, RootName>. Имя в дропдауне = очищенный root,
-- root = строка для string.find (чтобы ловить _Hard/_Extreme).
local function spAutoScanBosses()
    local found = {}
    local order = {}
    local folder = spGetNpcFolder()
    if folder then
        for _, m in ipairs(folder:GetChildren()) do
            if m:IsA("Model") then
                local hum = m:FindFirstChildOfClass("Humanoid")
                if _spLooksLikeBoss(m, hum) then
                    local root = _spStripBossSuffix(m.Name)
                    if root and root ~= "" and not found[root] then
                        found[root] = root   -- display = root
                        table.insert(order, root)
                    end
                end
            end
        end
    end
    table.sort(order)
    return found, order
end

local function spFindBoss(rootName)
    if not rootName or rootName == "" then return nil end
    local folder = spGetNpcFolder()
    if not folder then return nil end
    local myHRP  = safeGetHRP(safeGetCharacter())
    local origin = myHRP and myHRP.Position or Vector3.zero
    local best, bestHum, bestDist = nil, nil, math.huge
    for _, m in ipairs(folder:GetChildren()) do
        if m:IsA("Model") and string.find(m.Name, rootName, 1, true) then
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

local function spBossStart()
    if sp_bossThread then return end
    if not sp_bossRootName or sp_bossRootName == "" then
        notify("Выбери босса в дропдауне")
        return
    end
    if sp_enabled then spStop() end

    sp_bossEnabled = true
    sp_bossThread = task.spawn(function()
        while sp_bossEnabled do
            local hum = safeGetHumanoid(safeGetCharacter())
            if not hum or hum.Health <= 0 then
                sp_currentMob = nil
                task.wait(1)
            else
                local boss, bossHum = spFindBoss(sp_bossRootName)
                if not boss then
                    sp_currentMob = nil
                    notify("Босс '" .. sp_bossRootName .. "' не найден — жду 4с", 2)
                    local w = 0
                    while sp_bossEnabled and w < 4 do
                        task.wait(0.25); w = w + 0.25
                    end
                else
                    sp_currentMob = boss
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
                        -- Освежаем ссылку на Humanoid каждый кадр —
                        -- если босс был перерождён или модель пересобрана.
                        bossHum = boss:FindFirstChildOfClass("Humanoid") or bossHum
                        spHoverAbove(boss)
                        spMouseClick()
                        -- ПЕРЕСОБИРАЕМ skillKeys на каждой итерации, чтобы тогглы
                        -- Z/X/C/V/F работали в реальном времени (раньше snapshot
                        -- делался ОДИН раз перед боем — toggle игнорировался).
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
                    task.wait(0.5)
                end
            end
            task.wait(0.05)
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
    Title = "Как пользоваться",
    Content = "1. Подойди к нужной зоне квеста\n" ..
              "2. Жми «Сканировать NPC» и «Сканировать мобов»\n" ..
              "3. Выбери NPC и моба в выпадающих списках ниже\n" ..
              "4. (опционально) включи God Mode v1 и/или v2\n" ..
              "5. Включи «Авто-фарм»\n\n" ..
              "Для рейдов листай вниз до раздела «Рейдовые боссы»."
})

-- ===== Quest Setup =====
local npcDropdown, mobDropdown

npcDropdown = SailorTab:CreateDropdown({
    Name = "NPC квеста",
    Options = sp_npcChoices,
    CurrentOption = { sp_npcChoices[1] },
    MultipleOptions = false,
    Flag = "sp_questNpc",
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        if v and not _isPlaceholder(v) then sp_questNpcName = v end
    end
})

mobDropdown = SailorTab:CreateDropdown({
    Name = "Моб для фарма",
    Options = sp_mobChoices,
    CurrentOption = { sp_mobChoices[1] },
    MultipleOptions = false,
    Flag = "sp_mob",
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        if v and not _isPlaceholder(v) then sp_mobBaseName = v end
    end
})

SailorTab:CreateButton({
    Name = "Сканировать NPC рядом",
    Callback = function()
        sp_npcChoices = spScanAreaNpcs()
        if npcDropdown and npcDropdown.Refresh then
            pcall(npcDropdown.Refresh, npcDropdown, sp_npcChoices)
        end
        notify(("Найдено NPC: %d"):format(#sp_npcChoices))
    end
})

SailorTab:CreateButton({
    Name = "Сканировать мобов рядом",
    Callback = function()
        sp_mobChoices = spScanAreaMobs()
        if mobDropdown and mobDropdown.Refresh then
            pcall(mobDropdown.Refresh, mobDropdown, sp_mobChoices)
        end
        notify(("Найдено мобов: %d"):format(#sp_mobChoices))
    end
})

SailorTab:CreateParagraph({
    Title = "О сканере",
    Content = "Кнопки находят квестовых NPC (workspace.ServiceNPCs) и мобов (workspace.NPCs) только в радиусе сканирования от тебя. Для мобов имена нормализуются: «Monkey1», «Monkey2» → «Monkey»."
})

SailorTab:CreateSlider({
    Name = "Радиус сканера",
    Range = { 30, 500 },
    Increment = 10,
    Suffix = " ст.",
    CurrentValue = sp_scanRadius,
    Flag = "sp_scanRadius",
    Callback = function(v) sp_scanRadius = v end
})

SailorTab:CreateSlider({
    Name = "Радиус поиска моба (во время охоты)",
    Range = { 50, 1000 },
    Increment = 25,
    Suffix = " ст.",
    CurrentValue = sp_searchRadius,
    Flag = "sp_searchRadius",
    Callback = function(v) sp_searchRadius = v end
})

SailorTab:CreateSlider({
    Name = "Длительность охоты",
    Range = { 15, 300 },
    Increment = 5,
    Suffix = " сек",
    CurrentValue = sp_huntDuration,
    Flag = "sp_huntDuration",
    Callback = function(v) sp_huntDuration = v end
})

SailorTab:CreateSlider({
    Name = "Высота парения над мобом",
    Range = { 3, 20 },
    Increment = 1,
    Suffix = " ст.",
    CurrentValue = sp_hoverHeight,
    Flag = "sp_hoverHeight",
    Callback = function(v) sp_hoverHeight = v end
})

-- ===== Combat =====
SailorTab:CreateDivider()
local SCombatSec = SailorTab:CreateSection("Бой и оружие")

SailorTab:CreateParagraph({
    Title = "Слот оружия",
    Content = "После смерти игра экипирует слот 1 по умолчанию. Скрипт автоматически перенажимает выбранную тут цифру при каждом respawn — чтобы ты сам не путался в инвентаре."
})

SailorTab:CreateSlider({
    Name = "Слот оружия (1—5)",
    Range = { 1, 5 },
    Increment = 1,
    Suffix = "",
    CurrentValue = sp_weaponSlot,
    Flag = "sp_weaponSlot",
    Callback = function(v)
        sp_weaponSlot = v
        spSelectSlot(v)
    end
})

SailorTab:CreateToggle({
    Name = "Авто-экип после возрождения",
    CurrentValue = sp_autoEquip,
    Flag = "sp_autoEquip",
    Callback = function(v) sp_autoEquip = v end
})

SailorTab:CreateButton({
    Name = "Экипировать слот сейчас",
    Callback = function() spSelectSlot(sp_weaponSlot) end
})

SailorTab:CreateParagraph({
    Title = "Поведение кликов",
    Content = "«Бить руками» — отправлять клики мыши через VirtualInputManager.\n" ..
              "«Только с оружием» — не бить если в руках ничего нет (пропускать кадр и переэкипировать)."
})

SailorTab:CreateToggle({
    Name = "Бить руками (клики мыши)",
    CurrentValue = not sp_handFightOff,
    Flag = "sp_handFight",
    Callback = function(v) sp_handFightOff = not v end
})

SailorTab:CreateToggle({
    Name = "Бить только с оружием",
    CurrentValue = sp_useHandsOnly,
    Flag = "sp_requireTool",
    Callback = function(v) sp_useHandsOnly = v end
})

SailorTab:CreateSlider({
    Name = "Задержка между кликами",
    Range = { 0.15, 1.0 },
    Increment = 0.05,
    Suffix = " сек",
    CurrentValue = sp_attackDelay,
    Flag = "sp_attackDelay",
    Callback = function(v) sp_attackDelay = v end
})

SailorTab:CreateSlider({
    Name = "Задержка между скиллами",
    Range = { 0.3, 5.0 },
    Increment = 0.1,
    Suffix = " сек",
    CurrentValue = sp_skillDelay,
    Flag = "sp_skillDelay",
    Callback = function(v) sp_skillDelay = v end
})

SailorTab:CreateSlider({
    Name = "Удержание клавиши скилла",
    Range = { 0.05, 0.5 },
    Increment = 0.05,
    Suffix = " сек",
    CurrentValue = sp_skillHold,
    Flag = "sp_skillHold",
    Callback = function(v) sp_skillHold = v end
})

SailorTab:CreateParagraph({
    Title = "Скиллы",
    Content = "Тогглы ниже включают/выключают конкретные клавиши в ротации. Работают и для квестов, и для боссов."
})
SailorTab:CreateToggle({ Name = "Скилл Z", CurrentValue = sp_useZ, Flag = "sp_useZ", Callback = function(v) sp_useZ = v end })
SailorTab:CreateToggle({ Name = "Скилл X", CurrentValue = sp_useX, Flag = "sp_useX", Callback = function(v) sp_useX = v end })
SailorTab:CreateToggle({ Name = "Скилл C", CurrentValue = sp_useC, Flag = "sp_useC", Callback = function(v) sp_useC = v end })
SailorTab:CreateToggle({ Name = "Скилл V", CurrentValue = sp_useV, Flag = "sp_useV", Callback = function(v) sp_useV = v end })
SailorTab:CreateToggle({ Name = "Скилл F", CurrentValue = sp_useF, Flag = "sp_useF", Callback = function(v) sp_useF = v end })

-- ===== God Mode =====
SailorTab:CreateDivider()
local SGodSec = SailorTab:CreateSection("God Mode")

SailorTab:CreateParagraph({
    Title = "Что это",
    Content = "v1 — клиентский Noclip + парение над целью на заданной высоте. Работает против melee-боссов и AOE-сплеша.\n\n" ..
              "v2 — постоянное восстановление HP до максимума + блокировка состояния «Dead» у твоего Humanoid. Полезно когда игра доверяет клиенту HP.\n\n" ..
              "Можно включить оба одновременно — друг другу не мешают."
})

SailorTab:CreateToggle({
    Name = "God Mode v1 — Noclip + парение",
    CurrentValue = false,
    Flag = "godModeV1",
    Callback = function(v)
        godModeEnabled = v
        if v then startGodMode() else stopGodMode() end
    end
})

SailorTab:CreateToggle({
    Name = "God Mode v2 — восстановление HP",
    CurrentValue = false,
    Flag = "godModeV2",
    Callback = function(v)
        godMode2Enabled = v
        if v then startGodMode2() else stopGodMode2() end
    end
})

-- ===== Run =====
SailorTab:CreateDivider()
local SRunSec = SailorTab:CreateSection("Запуск")

SailorTab:CreateToggle({
    Name = "Авто-фарм (квест)",
    CurrentValue = false,
    Flag = "sp_autoFarm",
    Callback = function(v)
        if v then spStart() else spStop() end
    end
})

SailorTab:CreateButton({
    Name = "Взять квест сейчас",
    Callback = function()
        task.spawn(function()
            _sp_forcedTp = true
            local npc = spFindQuestNpc(sp_questNpcName)
            if npc then spTakeQuestFrom(npc) else notify("NPC не найден") end
            _sp_forcedTp = false
        end)
    end
})

SailorTab:CreateButton({
    Name = "Телепорт к мобу",
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
            else notify("Моб не найден") end
            _sp_forcedTp = false
        end)
    end
})

SailorTab:CreateParagraph({
    Title = "Принудительная смена фазы",
    Content = "Если скрипт «застрял» в фарме мобов, а тебе надо обратно к NPC — жми «К квесту». И наоборот."
})
SailorTab:CreateButton({
    Name = "Принудительно: к квесту",
    Callback = function() _G.QuestState = "TakeQuest" end
})
SailorTab:CreateButton({
    Name = "Принудительно: бить мобов",
    Callback = function() _G.QuestState = "Hunting" end
})

-- ===== Raid Bosses =====
SailorTab:CreateDivider()
local SBossSec = SailorTab:CreateSection("Рейдовые боссы")

SailorTab:CreateParagraph({
    Title = "Что это",
    Content = "Отдельный режим. Игнорирует квестовый NPC, ищет выбранного босса по корню имени (например «BlackReaperBoss» поймает любую сложность: _Normal, _Medium, _Hard, _Extreme).\n\nЕсли в дропдауне нет нужного босса — жми «Авто-скан карты». Скрипт пробежит workspace.NPCs и найдёт ВСЕХ кто похож на босса (по имени или большому HP)."
})

-- Динамический список боссов: при auto-scan заменяется на найденное.
-- Стартовый seed — EliteBossOrder, чтобы дропдаун не был пустым при первом запуске.
local sp_bossList    = {}     -- Map<displayName, rootName>
local sp_bossListOrder = {}   -- упорядоченный массив displayName'ов
for _, k in ipairs(EliteBossOrder) do
    sp_bossList[k] = EliteBosses[k]
    table.insert(sp_bossListOrder, k)
end

local bossDropdown
bossDropdown = SailorTab:CreateDropdown({
    Name = "Босс",
    Options = sp_bossListOrder,
    CurrentOption = { sp_bossDisplayName },
    MultipleOptions = false,
    Flag = "sp_bossPick",
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        if v and sp_bossList[v] then
            sp_bossDisplayName = v
            sp_bossRootName    = sp_bossList[v]
        end
    end
})

SailorTab:CreateButton({
    Name = "Авто-скан карты — все боссы",
    Callback = function()
        local found, order = spAutoScanBosses()
        if #order == 0 then
            notify("Не нашёл ни одного босса в workspace.NPCs")
            return
        end
        sp_bossList = found
        sp_bossListOrder = order
        if bossDropdown and bossDropdown.Refresh then
            pcall(bossDropdown.Refresh, bossDropdown, sp_bossListOrder)
        end
        -- Если текущий выбранный босс остался в списке — оставляем,
        -- иначе берём первого из списка
        if not sp_bossList[sp_bossDisplayName] then
            sp_bossDisplayName = sp_bossListOrder[1]
            sp_bossRootName    = sp_bossList[sp_bossDisplayName]
        end
        notify(("Найдено боссов: %d"):format(#sp_bossListOrder))
        for _, n in ipairs(sp_bossListOrder) do print("  Boss: " .. n) end
    end
})

SailorTab:CreateToggle({
    Name = "Авто-фарм выбранного босса",
    CurrentValue = false,
    Flag = "sp_bossFarm",
    Callback = function(v)
        if v then spBossStart() else spBossStop() end
    end
})

SailorTab:CreateDivider()
SailorTab:CreateSection("Свободный бой / Защита")

SailorTab:CreateParagraph({
    Title = "Free Combat и Anti-Damage",
    Content = "▸ «Free Combat» — обычный авто-фарм бьёт ЛЮБОГО моба из дропдауна без захода к NPC за квестом. Удобно когда выбрал босса через Scan Mobs.\n\n▸ «Anti-Damage» — поднимает игрока на 50 ст. над целью + якорит HRP. Большинство melee-боссов и AOE на такой высоте просто не достанут. Это надёжнее ForceField God Mode'а от шотов.\n\nОба совместимы и с квестовым фармом, и с Boss-фармом."
})

SailorTab:CreateToggle({
    Name = "Free Combat (бить без квеста)",
    CurrentValue = false,
    Flag = "sp_freeCombat",
    Callback = function(v) sp_freeCombat = v end
})

SailorTab:CreateToggle({
    Name = "Anti-Damage Anchor (50 ст. + якорь)",
    CurrentValue = false,
    Flag = "sp_antiDamage",
    Callback = function(v)
        sp_antiDamage = v
        -- Если выключаем — немедленно снимаем якорь
        if not v then
            local hrp = safeGetHRP(safeGetCharacter())
            if hrp and hrp.Anchored then hrp.Anchored = false end
        end
    end
})

SailorTab:CreateSlider({
    Name = "Высота Anti-Damage",
    Range = { 20, 200 },
    Increment = 5,
    Suffix = " ст.",
    CurrentValue = sp_antiDamageHeight,
    Flag = "sp_antiDamageHeight",
    Callback = function(v) sp_antiDamageHeight = v end
})


--========================================================
-- COMBAT TAB (Aimbot + TP Behind)
--========================================================
local CombatSec = CombatTab:CreateSection("Аимбот")

local aimbotEnabled = false
local aimbotKey  = Enum.UserInputType.MouseButton2
local aimbotFov  = 40
local aimbotSmooth = 0.25
local aimbotTarget
local teamCheck = false
local aimbotConn

local function getTargetPart(char)
    return char and (char:FindFirstChild("Head") or char:FindFirstChild("HumanoidRootPart"))
end

local function findClosestEnemy(requireFov, maxAngleDeg)
    local myHRP = safeGetHRP(safeGetCharacter())
    if not myHRP then return nil end
    local camCF = Camera.CFrame
    local cosLimit = requireFov and math.cos(math.rad(maxAngleDeg or 30)) or -2
    local best, bestScore = nil, math.huge
    for _, plr in ipairs(Players:GetPlayers()) do
        if plr ~= LocalPlayer and not (teamCheck and isSameTeam(plr)) then
            local char = plr.Character
            local hum  = char and char:FindFirstChildOfClass("Humanoid")
            local part = getTargetPart(char)
            if part and hum and hum.Health > 0 then
                local toT = part.Position - camCF.Position
                local d = toT.Magnitude
                if d > 0 then
                    local cosAng = (toT.Unit):Dot(camCF.LookVector)
                    if cosAng >= cosLimit and d < bestScore then
                        bestScore, best = d, plr
                    end
                end
            end
        end
    end
    return best
end

local function stopAimbot()
    if aimbotConn then aimbotConn:Disconnect(); aimbotConn = nil end
    aimbotTarget = nil
end

local function startAimbot()
    if aimbotConn then return end
    aimbotConn = RunService.RenderStepped:Connect(function()
        if not aimbotEnabled then stopAimbot(); return end
        local pressing = UIS:IsMouseButtonPressed(aimbotKey)
            or (aimbotKey.EnumType == Enum.KeyCode and UIS:IsKeyDown(aimbotKey))
        if not pressing then aimbotTarget = nil; return end
        if not aimbotTarget or not aimbotTarget.Character then
            aimbotTarget = findClosestEnemy(true, aimbotFov)
        end
        if not aimbotTarget then return end
        local part = getTargetPart(aimbotTarget.Character)
        if not part then return end
        Camera.CFrame = Camera.CFrame:Lerp(
            CFrame.lookAt(Camera.CFrame.Position, part.Position),
            math.clamp(aimbotSmooth, 0.05, 1))
    end)
    track(aimbotConn)
end

CombatTab:CreateParagraph({
    Title = "Аимбот",
    Content = "Захватывает камеру на ближайшего противника пока зажата выбранная клавиша. Не стреляет сам — стрельбу делаешь ты, скрипт только наводит."
})

CombatTab:CreateToggle({
    Name = "Аимбот",
    CurrentValue = false,
    Flag = "aimbotEnabled",
    Callback = function(v)
        aimbotEnabled = v
        if v then startAimbot() else stopAimbot() end
    end
})
CombatTab:CreateSlider({
    Name = "Угол обзора аимбота (FOV)", Range = { 5, 180 }, Increment = 1, Suffix = "°",
    CurrentValue = aimbotFov, Flag = "aimbotFov",
    Callback = function(v) aimbotFov = v end
})
CombatTab:CreateSlider({
    Name = "Плавность наведения", Range = { 0.05, 1 }, Increment = 0.05, Suffix = "",
    CurrentValue = aimbotSmooth, Flag = "aimbotSmooth",
    Callback = function(v) aimbotSmooth = v end
})
CombatTab:CreateDropdown({
    Name = "Клавиша захвата",
    Options = { "RMB", "LMB", "E", "Q", "F" },
    CurrentOption = { "RMB" },
    Flag = "aimbotKeyPick",
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        local map = {
            RMB = Enum.UserInputType.MouseButton2, LMB = Enum.UserInputType.MouseButton1,
            E = Enum.KeyCode.E, Q = Enum.KeyCode.Q, F = Enum.KeyCode.F
        }
        aimbotKey = map[v] or Enum.UserInputType.MouseButton2
    end
})
CombatTab:CreateToggle({
    Name = "Игнорировать союзников",
    CurrentValue = false, Flag = "teamCheck",
    Callback = function(v) teamCheck = v end
})

CombatTab:CreateDivider()
local TPSec = CombatTab:CreateSection("Телепорт к игрокам")
local selectedPlayerName

CombatTab:CreateButton({
    Name = "Телепорт за спину ближайшему врагу",
    Callback = function()
        local t = findClosestEnemy(false, nil)
        if not t then notify("Врагов нет"); return end
        local thrp = t.Character and t.Character:FindFirstChild("HumanoidRootPart")
        local mhrp = safeGetHRP(safeGetCharacter())
        if thrp and mhrp then
            mhrp.CFrame = thrp.CFrame * CFrame.new(0, 0, 3)
        end
    end
})

local function getPlayerNameList()
    local t = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer then table.insert(t, p.Name) end
    end
    if #t == 0 then table.insert(t, "(нет игроков)") end
    return t
end

local tpDropdown
tpDropdown = CombatTab:CreateDropdown({
    Name = "Игрок-цель",
    Options = getPlayerNameList(),
    CurrentOption = { (Players:GetPlayers()[2] and Players:GetPlayers()[2].Name) or "(нет игроков)" },
    Flag = "tpTarget",
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        selectedPlayerName = v
    end
})
local function refreshTpDropdown()
    if tpDropdown and tpDropdown.Refresh then
        pcall(tpDropdown.Refresh, tpDropdown, getPlayerNameList())
    end
end
track(Players.PlayerAdded:Connect(refreshTpDropdown))
track(Players.PlayerRemoving:Connect(refreshTpDropdown))

CombatTab:CreateButton({
    Name = "Обновить список игроков",
    Callback = function() refreshTpDropdown() end
})
CombatTab:CreateButton({
    Name = "Телепорт к выбранному игроку",
    Callback = function()
        if not selectedPlayerName or _isPlaceholder(selectedPlayerName) then return end
        local t = Players:FindFirstChild(selectedPlayerName)
        if t and t.Character then
            local thrp = t.Character:FindFirstChild("HumanoidRootPart")
            local mhrp = safeGetHRP(safeGetCharacter())
            if thrp and mhrp then
                mhrp.CFrame = thrp.CFrame * CFrame.new(0, 0, 3)
            end
        end
    end
})


--========================================================
-- PLAYER TAB
--========================================================
local PMoveSec = PlayerTab:CreateSection("Передвижение")

PlayerTab:CreateParagraph({
    Title = "Внимание",
    Content = "Fly, NoClip и SpeedHack ловятся серверной валидацией позиции в большинстве игр с античитом. Включай только если уверен, что в этой игре можно."
})

-- Fly
local flyEnabled, flyConn = false, nil
local function stopFly()
    if flyConn then flyConn:Disconnect(); flyConn = nil end
    local h = safeGetHumanoid(safeGetCharacter())
    if h then h.PlatformStand = false end
end
local function startFly()
    stopFly()
    flyConn = RunService.Heartbeat:Connect(function()
        if not flyEnabled then stopFly(); return end
        local char = safeGetCharacter()
        local hum, hrp = safeGetHumanoid(char), safeGetHRP(char)
        if not (hum and hrp) then return end
        hum.PlatformStand = true
        local d = Vector3.zero
        if UIS:IsKeyDown(Enum.KeyCode.W) then d = d + Camera.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.S) then d = d - Camera.CFrame.LookVector end
        if UIS:IsKeyDown(Enum.KeyCode.A) then d = d - Camera.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.D) then d = d + Camera.CFrame.RightVector end
        if UIS:IsKeyDown(Enum.KeyCode.Space) then d = d + Vector3.yAxis end
        if UIS:IsKeyDown(Enum.KeyCode.LeftControl) then d = d - Vector3.yAxis end
        hrp.Velocity = d.Magnitude > 0 and (d.Unit * 100) or Vector3.zero
    end)
    track(flyConn)
end

PlayerTab:CreateToggle({
    Name = "Полёт (риск бана)", CurrentValue = false, Flag = "flyEnabled",
    Callback = function(v)
        flyEnabled = v
        if v then startFly() else stopFly() end
    end
})

-- Infinite Jump
local infJump, jumpConn = false, nil
local function stopInfJump() if jumpConn then jumpConn:Disconnect(); jumpConn = nil end end
local function bindInfJump(hum)
    if not hum then return end
    stopInfJump()
    jumpConn = hum.StateChanged:Connect(function(_, s)
        if not infJump then stopInfJump(); return end
        if s == Enum.HumanoidStateType.Landed then
            hum:ChangeState(Enum.HumanoidStateType.Jumping)
        end
    end)
    track(jumpConn)
end
track(LocalPlayer.CharacterAdded:Connect(function(c)
    if infJump then bindInfJump(c:WaitForChild("Humanoid", 5)) end
end))
PlayerTab:CreateToggle({
    Name = "Бесконечный прыжок", CurrentValue = false, Flag = "infJump",
    Callback = function(v)
        infJump = v
        if v then bindInfJump(safeGetHumanoid(safeGetCharacter())) else stopInfJump() end
    end
})

-- Noclip (общий)
local noClip, noClipConn = false, nil
local function stopNoClip()
    if noClipConn then noClipConn:Disconnect(); noClipConn = nil end
    local c = safeGetCharacter()
    if c then for _, p in ipairs(c:GetDescendants()) do
        if p:IsA("BasePart") then p.CanCollide = true end
    end end
end
PlayerTab:CreateToggle({
    Name = "Сквозь стены (NoClip)", CurrentValue = false, Flag = "noClip",
    Callback = function(v)
        noClip = v
        if v then
            stopNoClip()
            noClipConn = RunService.Stepped:Connect(function()
                if not noClip then stopNoClip(); return end
                local c = safeGetCharacter()
                if not c then return end
                for _, p in ipairs(c:GetDescendants()) do
                    if p:IsA("BasePart") and p.CanCollide then p.CanCollide = false end
                end
            end)
            track(noClipConn)
        else stopNoClip() end
    end
})

PlayerTab:CreateSlider({
    Name = "Скорость ходьбы", Range = { 16, 500 }, Increment = 1, Suffix = "",
    CurrentValue = 16, Flag = "walkSpeed",
    Callback = function(v)
        local h = safeGetHumanoid(safeGetCharacter())
        if h then h.WalkSpeed = v end
    end
})
PlayerTab:CreateSlider({
    Name = "Сила прыжка", Range = { 50, 500 }, Increment = 5, Suffix = "",
    CurrentValue = 50, Flag = "jumpPower",
    Callback = function(v)
        local h = safeGetHumanoid(safeGetCharacter())
        if h then h.JumpPower = v end
    end
})

PlayerTab:CreateButton({
    Name = "Сбросить скорость и прыжок в дефолт",
    Callback = function()
        local h = safeGetHumanoid(safeGetCharacter())
        if h then
            h.WalkSpeed = 16
            h.JumpPower = 50
        end
        notify("Скорость и прыжок сброшены: 16 / 50")
    end
})

-- ===== Speed Hack (мульти-двигатель: WalkSpeed * множитель) =====
PlayerTab:CreateDivider()
PlayerTab:CreateSection("Speed Hack")

local speedHackEnabled = false
local speedMultiplier  = 2.0
local _speedConn       = nil
local _speedBaseCache  = 16

local function _stopSpeedHack()
    if _speedConn then _speedConn:Disconnect(); _speedConn = nil end
    -- Возвращаем базовую скорость (если игра не успела перебить)
    local h = safeGetHumanoid(safeGetCharacter())
    if h then h.WalkSpeed = _speedBaseCache end
end

local function _startSpeedHack()
    _stopSpeedHack()
    -- Кэшируем текущую WalkSpeed (что есть на момент включения) как "базу"
    local h = safeGetHumanoid(safeGetCharacter())
    _speedBaseCache = h and h.WalkSpeed or 16

    _speedConn = RunService.Heartbeat:Connect(function()
        if not speedHackEnabled then _stopSpeedHack(); return end
        local hum = safeGetHumanoid(safeGetCharacter())
        if hum then
            local target = _speedBaseCache * speedMultiplier
            -- Перезаписываем только если игра нас сбила
            if math.abs(hum.WalkSpeed - target) > 0.5 then
                hum.WalkSpeed = target
            end
        end
    end)
    track(_speedConn)
end

PlayerTab:CreateToggle({
    Name = "Speed Hack (через WalkSpeed × множитель)",
    CurrentValue = false,   -- ВАЖНО: всегда false при инжекте
    Flag = nil,             -- НЕ сохраняем тогл в конфиг
    Callback = function(v)
        speedHackEnabled = v
        if v then _startSpeedHack() else _stopSpeedHack() end
    end
})

PlayerTab:CreateSlider({
    Name = "Множитель скорости",
    Range = { 1, 8 },
    Increment = 0.1,
    Suffix = "x",
    CurrentValue = speedMultiplier,
    Flag = "speedMul",   -- значение можно сохранять
    Callback = function(v) speedMultiplier = v end
})

PlayerTab:CreateButton({
    Name = "Сбросить SpeedHack",
    Callback = function()
        speedHackEnabled = false
        speedMultiplier  = 2.0
        _stopSpeedHack()
        local h = safeGetHumanoid(safeGetCharacter())
        if h then h.WalkSpeed = 16 end
        notify("SpeedHack выключен, скорость = 16")
    end
})

-- Anti-AFK
local antiAfk = false
PlayerTab:CreateToggle({
    Name = "Анти-AFK (не кикнет за простой)", CurrentValue = false, Flag = "antiAfk",
    Callback = function(v) antiAfk = v end
})
pcall(function()
    track(LocalPlayer.Idled:Connect(function()
        if not antiAfk then return end
        local vu = game:GetService("VirtualUser")
        pcall(function()
            vu:CaptureController()
            vu:ClickButton2(Vector2.new())
        end)
    end))
end)

--========================================================
-- VISUALS TAB
--========================================================
VisualsTab:CreateParagraph({
    Title = "Что это",
    Content = "Локальные настройки освещения и тумана. Сервер их не валидирует, бан невозможен."
})

VisualsTab:CreateToggle({
    Name = "Убрать туман", CurrentValue = false, Flag = "noFog",
    Callback = function(v)
        if v then Lighting.FogEnd = 99999; Lighting.FogStart = 0
        else Lighting.FogEnd = 1000; Lighting.FogStart = 0 end
    end
})
VisualsTab:CreateToggle({
    Name = "Полный свет (Fullbright)", CurrentValue = false, Flag = "fullBright",
    Callback = function(v)
        if v then
            Lighting.Brightness = 10
            Lighting.Ambient = Color3.new(1, 1, 1)
            Lighting.OutdoorAmbient = Color3.new(1, 1, 1)
        else
            Lighting.Brightness = 3
            Lighting.Ambient = Color3.new(0.5, 0.5, 0.5)
            Lighting.OutdoorAmbient = Color3.new(0.5, 0.5, 0.5)
        end
    end
})
VisualsTab:CreateToggle({
    Name = "Убрать небо", CurrentValue = false, Flag = "noSky",
    Callback = function(v) Lighting.SkyboxEnabled = not v end
})

--========================================================
-- WORLD TAB
--========================================================
WorldTab:CreateSlider({
    Name = "Гравитация", Range = { 0, 500 }, Increment = 5, Suffix = "",
    CurrentValue = 196, Flag = "gravity",
    Callback = function(v) workspace.Gravity = v end
})
WorldTab:CreateSlider({
    Name = "Время суток", Range = { 0, 24 }, Increment = 1, Suffix = " ч",
    CurrentValue = 14, Flag = "tod",
    Callback = function(v) Lighting.ClockTime = v end
})

WorldTab:CreateButton({
    Name = "Сбросить гравитацию (196.2)",
    Callback = function()
        workspace.Gravity = 196.2
        notify("Гравитация: 196.2 (дефолт Roblox)")
    end
})

WorldTab:CreateButton({
    Name = "Сбросить мир в дефолт",
    Callback = function()
        workspace.Gravity = 196.2
        Lighting.ClockTime = 14
        Lighting.FogEnd = 1000
        Lighting.FogStart = 0
        Lighting.SkyboxEnabled = true
        Lighting.Brightness = 3
        Lighting.Ambient = Color3.new(0.5, 0.5, 0.5)
        Lighting.OutdoorAmbient = Color3.new(0.5, 0.5, 0.5)
        notify("Все настройки мира сброшены")
    end
})


--========================================================
-- ESP SYSTEM (один RenderStepped, кэш на всех игроков)
--========================================================
local espEnabled, boxESP, tracerESP, nameESP, healthESP = false, false, false, false, false
local renderDistance = 1000
local espColor = Color3.fromRGB(0, 255, 0)
local espTeamCheck = false

-- Adaptive throttle: 0 = каждый кадр, 1/30 = 30 fps, 1/15 = 15 fps.
-- Меняется через слайдер в ESP-табе. Значения < 1/60 = full speed.
local espMinInterval = 1 / 30
local _esp_lastTick = 0

local ESP = {}

local visParams = RaycastParams.new()
visParams.FilterType = Enum.RaycastFilterType.Exclude
visParams.IgnoreWater = true

local function refreshIgnoreList()
    local list = {}
    for _, p in ipairs(Players:GetPlayers()) do
        if p.Character then table.insert(list, p.Character) end
    end
    visParams.FilterDescendantsInstances = list
end
refreshIgnoreList()
track(Players.PlayerAdded:Connect(function(p)
    track(p.CharacterAdded:Connect(refreshIgnoreList))
end))
for _, p in ipairs(Players:GetPlayers()) do
    track(p.CharacterAdded:Connect(refreshIgnoreList))
end

local tracerGui = Instance.new("ScreenGui")
tracerGui.Name = randomName()
tracerGui.IgnoreGuiInset = true
tracerGui.ResetOnSpawn = false
pcall(function()
    tracerGui.Parent = hiddenParent
    if syn and syn.protect_gui then syn.protect_gui(tracerGui) end
end)
_G.LunaTracerGui = tracerGui

local function clearESP(plr)
    local d = ESP[plr]
    if not d then return end
    if d.root then d.root:Destroy() end
    if d.tracer then d.tracer:Destroy() end
    ESP[plr] = nil
    refreshIgnoreList()
end

local function buildESP(plr)
    if plr == LocalPlayer or ESP[plr] then return end
    local root = Instance.new("Frame")
    root.Name = randomName()
    root.BackgroundTransparency = 1
    root.Size = UDim2.fromScale(1, 1)
    root.Visible = false
    root.Parent = tracerGui

    local function makeLine()
        local f = Instance.new("Frame")
        f.Name = randomName()
        f.BackgroundColor3 = espColor
        f.BorderSizePixel = 0
        f.AnchorPoint = Vector2.new(0.5, 0.5)
        f.Size = UDim2.new(0, 0, 0, 0)
        f.Visible = false
        f.Parent = root
        return f
    end
    local boxTop, boxBottom, boxLeft, boxRight = makeLine(), makeLine(), makeLine(), makeLine()

    local nameLabel = Instance.new("TextLabel")
    nameLabel.Name = randomName()
    nameLabel.BackgroundTransparency = 1
    nameLabel.AnchorPoint = Vector2.new(0.5, 1)
    nameLabel.Size = UDim2.new(0, 200, 0, 18)
    nameLabel.Font = Enum.Font.GothamBold
    nameLabel.TextSize = 13
    nameLabel.TextStrokeTransparency = 0
    nameLabel.TextColor3 = espColor
    nameLabel.Text = ""
    nameLabel.Visible = false
    nameLabel.Parent = root

    local hpBg = Instance.new("Frame")
    hpBg.Name = randomName()
    hpBg.AnchorPoint = Vector2.new(1, 0.5)
    hpBg.BackgroundColor3 = Color3.new(0, 0, 0)
    hpBg.BorderSizePixel = 0
    hpBg.Size = UDim2.new(0, 3, 0, 0)
    hpBg.Visible = false
    hpBg.Parent = root
    local hpFill = Instance.new("Frame")
    hpFill.Name = randomName()
    hpFill.AnchorPoint = Vector2.new(0, 1)
    hpFill.Position = UDim2.new(0, 0, 1, 0)
    hpFill.BackgroundColor3 = Color3.fromRGB(0, 255, 0)
    hpFill.BorderSizePixel = 0
    hpFill.Size = UDim2.new(1, 0, 1, 0)
    hpFill.Parent = hpBg

    local tracer = Instance.new("Frame")
    tracer.Name = randomName()
    tracer.BackgroundColor3 = espColor
    tracer.BorderSizePixel = 0
    tracer.AnchorPoint = Vector2.new(0.5, 0.5)
    tracer.Size = UDim2.new(0, 0, 0, 2)
    tracer.Visible = false
    tracer.Parent = tracerGui

    ESP[plr] = {
        root = root, boxTop = boxTop, boxBottom = boxBottom, boxLeft = boxLeft, boxRight = boxRight,
        tracer = tracer, nameLabel = nameLabel, hpBg = hpBg, hpFill = hpFill,
        visible = false, nextVisCheck = tick() + math.random() * 0.1,
    }
end

local espRenderConn
local function hideEspEntry(d)
    if d.root.Visible then d.root.Visible = false end
    if d.tracer.Visible then d.tracer.Visible = false end
end

local function startEspLoop()
    if espRenderConn then return end
    espRenderConn = RunService.RenderStepped:Connect(function()
        if not espEnabled or not (boxESP or nameESP or healthESP or tracerESP) then
            for _, d in pairs(ESP) do hideEspEntry(d) end
            return
        end
        -- adaptive throttle: пропускаем кадры пока не накопился espMinInterval
        local now = tick()
        if (now - _esp_lastTick) < espMinInterval then return end
        _esp_lastTick = now

        local camCF = Camera.CFrame
        local camPos = camCF.Position
        local vp = Camera.ViewportSize
        local vpHalfX, vpY = vp.X * 0.5, vp.Y
        local maxSq = renderDistance * renderDistance

        for plr, d in pairs(ESP) do
            local char = plr.Character
            local hrp  = char and char:FindFirstChild("HumanoidRootPart")
            local hum  = char and char:FindFirstChild("Humanoid")
            if not hrp or not hum or hum.Health <= 0 or (espTeamCheck and isSameTeam(plr)) then
                hideEspEntry(d)
            else
                local hrpPos = hrp.Position
                local dx, dy, dz = hrpPos.X - camPos.X, hrpPos.Y - camPos.Y, hrpPos.Z - camPos.Z
                local distSq = dx*dx + dy*dy + dz*dz
                if distSq > maxSq then hideEspEntry(d)
                else
                    local dist = math.sqrt(distSq)
                    if now >= d.nextVisCheck then
                        d.nextVisCheck = now + 0.1
                        local rayOk, rayRes = pcall(workspace.Raycast, workspace,
                            camPos, hrpPos - camPos, visParams)
                        d.visible = rayOk and (rayRes == nil)
                    end
                    local isVisible = d.visible
                    local sp_, onScreen = Camera:WorldToViewportPoint(hrpPos)
                    local sx, sy, sz = sp_.X, sp_.Y, sp_.Z
                    local visibleOnScreen = onScreen and sz > 0
                    local h, w, halfW, halfH
                    if visibleOnScreen then
                        h = math.clamp(2000 / sz, 20, 400)
                        w = h * 0.55
                        halfW, halfH = w * 0.5, h * 0.5
                    end
                    local anyOnScreen = visibleOnScreen and (boxESP or nameESP or healthESP)
                    local showTracer = tracerESP
                    if not (anyOnScreen or showTracer) then hideEspEntry(d)
                    else
                        d.root.Visible = anyOnScreen or showTracer
                        local alphaOff = isVisible and 0 or 0.55
                        local showBox = boxESP and visibleOnScreen
                        if showBox then
                            local thick = 1
                            d.boxTop.Position = UDim2.new(0, sx, 0, sy - halfH); d.boxTop.Size = UDim2.new(0, w, 0, thick)
                            d.boxBottom.Position = UDim2.new(0, sx, 0, sy + halfH); d.boxBottom.Size = UDim2.new(0, w, 0, thick)
                            d.boxLeft.Position = UDim2.new(0, sx - halfW, 0, sy); d.boxLeft.Size = UDim2.new(0, thick, 0, h)
                            d.boxRight.Position = UDim2.new(0, sx + halfW, 0, sy); d.boxRight.Size = UDim2.new(0, thick, 0, h)
                            for _, l in ipairs({d.boxTop, d.boxBottom, d.boxLeft, d.boxRight}) do
                                l.BackgroundColor3 = espColor; l.BackgroundTransparency = alphaOff; l.Visible = true
                            end
                        else
                            d.boxTop.Visible = false; d.boxBottom.Visible = false; d.boxLeft.Visible = false; d.boxRight.Visible = false
                        end
                        if nameESP and visibleOnScreen then
                            local topY = showBox and (sy - halfH - 4) or (sy - math.clamp(2000/sz, 20, 400)*0.5 - 4)
                            d.nameLabel.Text = ("%s [%s] [%dm]"):format(plr.Name, isVisible and "VIS" or "HID", math.floor(dist))
                            d.nameLabel.Position = UDim2.new(0, sx, 0, topY)
                            d.nameLabel.TextColor3 = isVisible and espColor or Color3.fromRGB(180, 180, 180)
                            d.nameLabel.TextTransparency = isVisible and 0 or 0.2
                            d.nameLabel.Visible = true
                        else d.nameLabel.Visible = false end
                        if healthESP and visibleOnScreen then
                            local pct = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
                            local barH = showBox and h or math.clamp(2000/sz, 20, 400)
                            local barX = showBox and (sx - halfW - 4) or (sx - barH * 0.55 * 0.5 - 4)
                            d.hpBg.Position = UDim2.new(0, barX, 0, sy)
                            d.hpBg.Size = UDim2.new(0, 3, 0, barH)
                            d.hpBg.BackgroundTransparency = isVisible and 0 or 0.4
                            d.hpBg.Visible = true
                            d.hpFill.Size = UDim2.new(1, 0, pct, 0)
                            d.hpFill.BackgroundColor3 = (pct < 0.3 and Color3.fromRGB(255, 50, 50))
                                or (pct < 0.6 and Color3.fromRGB(255, 220, 50)) or Color3.fromRGB(50, 255, 50)
                        else d.hpBg.Visible = false end
                        if showTracer then
                            local tsx, tsy = sx, sy
                            if sz < 0 then
                                tsx = vp.X - sx; tsy = vpY - sy
                                local ddx, ddy = tsx - vpHalfX, tsy - vpY * 0.5
                                local len2 = ddx*ddx + ddy*ddy
                                if len2 > 0 then
                                    local len = math.sqrt(len2)
                                    tsx = vpHalfX + ddx/len * (vp.X * 0.6)
                                    tsy = vpY * 0.5 + ddy/len * (vpY * 0.6)
                                end
                            end
                            local m = 20
                            if tsx < m then tsx = m elseif tsx > vp.X - m then tsx = vp.X - m end
                            if tsy < m then tsy = m elseif tsy > vpY - m then tsy = vpY - m end
                            local fromX, fromY = vpHalfX, vpY
                            local diffX, diffY = tsx - fromX, tsy - fromY
                            local length = math.sqrt(diffX*diffX + diffY*diffY)
                            if length > 1 then
                                d.tracer.Position = UDim2.new(0, fromX + diffX*0.5, 0, fromY + diffY*0.5)
                                d.tracer.Size = UDim2.new(0, length, 0, 2)
                                d.tracer.Rotation = math.deg(math.atan2(diffY, diffX))
                                d.tracer.BackgroundColor3 = espColor
                                d.tracer.BackgroundTransparency = isVisible and 0 or 0.45
                                d.tracer.Visible = true
                            else d.tracer.Visible = false end
                        else d.tracer.Visible = false end
                    end
                end
            end
        end
    end)
    track(espRenderConn)
end
local function stopEspLoop()
    if espRenderConn then espRenderConn:Disconnect(); espRenderConn = nil end
end

task.spawn(function()
    pcall(function()
        track(Players.PlayerAdded:Connect(buildESP))
        track(Players.PlayerRemoving:Connect(clearESP))
        for _, p in ipairs(Players:GetPlayers()) do buildESP(p) end
        startEspLoop()
    end)
end)

ESPTab:CreateParagraph({
    Title = "Что это",
    Content = "Подсветка других игроков сквозь стены. Тумблер «Главный ESP» включает рендер целиком, остальные тогглы — конкретные элементы (коробки, имя, HP, линии)."
})

ESPTab:CreateToggle({ Name = "Главный ESP (вкл/выкл всё)", CurrentValue = false, Flag = "espMaster",
    Callback = function(v) espEnabled = v end })
ESPTab:CreateToggle({ Name = "Коробки вокруг игроков", CurrentValue = false, Flag = "espBox",
    Callback = function(v) boxESP = v end })
ESPTab:CreateToggle({ Name = "Линии-трассеры к игрокам", CurrentValue = false, Flag = "espTracer",
    Callback = function(v) tracerESP = v end })
ESPTab:CreateToggle({ Name = "Имена игроков", CurrentValue = false, Flag = "espName",
    Callback = function(v) nameESP = v end })
ESPTab:CreateToggle({ Name = "Полоски HP", CurrentValue = false, Flag = "espHealth",
    Callback = function(v) healthESP = v end })
ESPTab:CreateToggle({ Name = "Игнорировать союзников", CurrentValue = false, Flag = "espTeamCheck",
    Callback = function(v) espTeamCheck = v end })
ESPTab:CreateSlider({ Name = "Дальность отрисовки", Range = {100, 5000}, Increment = 50, Suffix = " ст.",
    CurrentValue = 1000, Flag = "renderDist",
    Callback = function(v) renderDistance = v end })
ESPTab:CreateColorPicker({ Name = "Цвет ESP", Color = Color3.fromRGB(0, 255, 0), Flag = "espColor",
    Callback = function(c) espColor = c end })

ESPTab:CreateDivider()
ESPTab:CreateSection("Производительность")
ESPTab:CreateDropdown({
    Name = "Частота обновления ESP",
    Options = { "Полная (60 fps)", "Гладкая (30 fps)", "Эконом (15 fps)", "Минимум (10 fps)" },
    CurrentOption = { "Гладкая (30 fps)" },
    MultipleOptions = false,
    Flag = "espRate",
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        if     v == "Полная (60 fps)"   then espMinInterval = 0
        elseif v == "Гладкая (30 fps)"  then espMinInterval = 1/30
        elseif v == "Эконом (15 fps)"   then espMinInterval = 1/15
        elseif v == "Минимум (10 fps)"  then espMinInterval = 1/10
        end
    end
})
ESPTab:CreateParagraph({
    Title = "О производительности",
    Content = "ESP — основной пожиратель FPS в скрипте. На 30 fps глаз не видит разницы, экономия ~50% бюджета. На 15 fps заметна задержка коробок при быстром повороте камеры, но FPS вырастает ещё на 30%."
})


--========================================================
-- SETTINGS
--========================================================

-- ====== Performance counters (FPS / ping / mem) =========
-- Считаем FPS как 1 / средний dt по последним N кадрам (smoothed average).
-- Обновляем UI-параграф раз в 0.5 сек, чтобы не дёргать Rayfield :Set каждый кадр.
local SPerfSec = SettingsTab:CreateSection("Монитор производительности")
local perfPara = SettingsTab:CreateParagraph({
    Title = "Live-статистика",
    Content = "FPS: --  |  Ping: -- ms  |  Mem: -- MB"
})

do
    local frameTimes = {}
    local FRAME_WINDOW = 60
    local sumDt = 0
    local lastUiUpdate = 0

    track(RunService.Heartbeat:Connect(function(dt)
        -- скользящее окно из 60 dt
        table.insert(frameTimes, dt)
        sumDt = sumDt + dt
        if #frameTimes > FRAME_WINDOW then
            sumDt = sumDt - table.remove(frameTimes, 1)
        end

        local now = tick()
        if now - lastUiUpdate < 0.5 then return end
        lastUiUpdate = now

        local avgDt = sumDt / #frameTimes
        local fps = avgDt > 0 and (1 / avgDt) or 0

        local ping = 0
        pcall(function()
            local stat = game:GetService("Stats"):FindFirstChild("PerformanceStats")
            local p = stat and stat:FindFirstChild("Ping")
            if p then ping = math.floor(p:GetValue()) end
        end)

        local memMB = math.floor(collectgarbage("count") / 1024)

        local txt = ("FPS: %d  |  Ping: %d ms  |  Mem: %d MB\nЦиклы:  квест=%s   босс=%s   God1=%s   God2=%s")
            :format(fps, ping, memMB,
                sp_enabled and "ON" or "off",
                sp_bossEnabled and "ON" or "off",
                godModeEnabled and "ON" or "off",
                godMode2Enabled and "ON" or "off")
        if perfPara and perfPara.Set then
            pcall(perfPara.Set, perfPara, { Title = "Live-статистика", Content = txt })
        end
    end))
end

SettingsTab:CreateSection("Окно")
SettingsTab:CreateButton({
    Name = "Скрыть/показать меню (или жми RightCtrl)",
    Callback = function() Rayfield:SetVisibility(not Rayfield:IsVisible()) end
})

-- ====================================================
-- Свой мини-конфиг (только значения, без тогглов!)
-- ====================================================
-- Сохраняем: задержки, дальности, длительности, слот оружия, скиллы (Z/X/C/V/F),
-- множитель скорости, FOV/плавность аимбота, цвет/дальность ESP, частота ESP.
-- НЕ сохраняем: Auto Farm, Boss Farm, God Mode, Fly, NoClip, ESP Master, Aimbot —
-- любой "включатель" остаётся OFF при каждом инжекте, чтобы не было сюрпризов.
SettingsTab:CreateDivider()
SettingsTab:CreateSection("Конфиг (только значения)")

local LUNA_CONFIG_PATH = "LunaHub_SailorPiece.json"
local function _serializeSettings()
    return {
        sp_scanRadius   = sp_scanRadius,
        sp_searchRadius = sp_searchRadius,
        sp_huntDuration = sp_huntDuration,
        sp_hoverHeight  = sp_hoverHeight,
        sp_attackDelay  = sp_attackDelay,
        sp_skillDelay   = sp_skillDelay,
        sp_skillHold    = sp_skillHold,
        sp_weaponSlot   = sp_weaponSlot,
        sp_useZ = sp_useZ, sp_useX = sp_useX, sp_useC = sp_useC,
        sp_useV = sp_useV, sp_useF = sp_useF,
        sp_antiDamageHeight = sp_antiDamageHeight,
        speedMultiplier = speedMultiplier,
        aimbotFov       = aimbotFov,
        aimbotSmooth    = aimbotSmooth,
        renderDistance  = renderDistance,
        espMinInterval  = espMinInterval,
    }
end

local function _applySettings(t)
    if type(t) ~= "table" then return end
    sp_scanRadius   = t.sp_scanRadius   or sp_scanRadius
    sp_searchRadius = t.sp_searchRadius or sp_searchRadius
    sp_huntDuration = t.sp_huntDuration or sp_huntDuration
    sp_hoverHeight  = t.sp_hoverHeight  or sp_hoverHeight
    sp_attackDelay  = t.sp_attackDelay  or sp_attackDelay
    sp_skillDelay   = t.sp_skillDelay   or sp_skillDelay
    sp_skillHold    = t.sp_skillHold    or sp_skillHold
    sp_weaponSlot   = t.sp_weaponSlot   or sp_weaponSlot
    if t.sp_useZ ~= nil then sp_useZ = t.sp_useZ end
    if t.sp_useX ~= nil then sp_useX = t.sp_useX end
    if t.sp_useC ~= nil then sp_useC = t.sp_useC end
    if t.sp_useV ~= nil then sp_useV = t.sp_useV end
    if t.sp_useF ~= nil then sp_useF = t.sp_useF end
    sp_antiDamageHeight = t.sp_antiDamageHeight or sp_antiDamageHeight
    speedMultiplier = t.speedMultiplier or speedMultiplier
    aimbotFov       = t.aimbotFov       or aimbotFov
    aimbotSmooth    = t.aimbotSmooth    or aimbotSmooth
    renderDistance  = t.renderDistance  or renderDistance
    espMinInterval  = t.espMinInterval  or espMinInterval
end

SettingsTab:CreateButton({
    Name = "Сохранить значения вручную",
    Callback = function()
        if not (writefile and HttpService) then
            notify("Executor не поддерживает запись файлов")
            return
        end
        local ok, json = pcall(function()
            return HttpService:JSONEncode(_serializeSettings())
        end)
        if not ok then notify("JSON encode error"); return end
        local ok2, err = pcall(function() writefile(LUNA_CONFIG_PATH, json) end)
        if ok2 then notify("Конфиг сохранён в " .. LUNA_CONFIG_PATH)
        else notify("Не удалось записать: " .. tostring(err)) end
    end
})

SettingsTab:CreateButton({
    Name = "Загрузить сохранённые значения",
    Callback = function()
        if not (readfile and isfile and HttpService) then
            notify("Executor не поддерживает чтение файлов")
            return
        end
        if not isfile(LUNA_CONFIG_PATH) then
            notify("Файл конфига не найден: " .. LUNA_CONFIG_PATH)
            return
        end
        local ok, raw = pcall(readfile, LUNA_CONFIG_PATH)
        if not ok then notify("Не удалось прочитать"); return end
        local ok2, t = pcall(function() return HttpService:JSONDecode(raw) end)
        if ok2 and type(t) == "table" then
            _applySettings(t)
            notify("Значения загружены — обнови UI слайдерами вручную")
        else
            notify("JSON-декод не удался")
        end
    end
})

SettingsTab:CreateParagraph({
    Title = "Про конфиг",
    Content = "Здесь сохраняются ТОЛЬКО ЗНАЧЕНИЯ слайдеров (задержки, скорости, FOV, слот оружия, тогглы скиллов Z/X/C/V/F). Любые «включатели» (Авто-фарм, Fly, NoClip, God Mode и т.п.) при каждом запуске остаются ВЫКЛЮЧЕНЫ — чтобы скрипт не запускал автофарм при заходе. Если хочешь восстановить значения — жми «Загрузить» после инжекта."
})

SettingsTab:CreateDivider()

SettingsTab:CreateButton({
    Name = "Полностью выгрузить скрипт",
    Callback = function() if _G.LunaUnload then _G.LunaUnload() end end
})

SettingsTab:CreateParagraph({
    Title = "Статус",
    Content = "Загружен  |  Игра: " .. game.Name
})

--========================================================
-- UNLOAD
--========================================================
_G.LunaUnload = function()
    -- Гасим все флаги
    espEnabled = false; boxESP = false; tracerESP = false; nameESP = false; healthESP = false
    flyEnabled = false; infJump = false; noClip = false; antiAfk = false
    aimbotEnabled = false
    sp_enabled = false; sp_bossEnabled = false
    godModeEnabled = false; godMode2Enabled = false
    sp_antiDamage = false   -- сбросить чтобы snять якорь HRP

    pcall(stopFly); pcall(stopInfJump); pcall(stopNoClip); pcall(stopAimbot)
    pcall(stopEspLoop); pcall(spStop); pcall(spBossStop)
    pcall(stopGodMode); pcall(stopGodMode2)

    -- Снимаем якорь персонажа на случай если Anti-Damage был включен
    pcall(function()
        local hrp = safeGetHRP(safeGetCharacter())
        if hrp and hrp.Anchored then hrp.Anchored = false end
    end)

    for _, c in ipairs(allConnections) do
        pcall(function() c:Disconnect() end)
    end
    table.clear(allConnections)

    for plr in pairs(ESP) do pcall(clearESP, plr) end

    pcall(function() if tracerGui then tracerGui:Destroy() end end)
    pcall(destroySplash)
    pcall(function() Rayfield:Destroy() end)

    _G.LunaWindowGui = nil
    _G.LunaCheatLoaded = false
    print("[Luna] unload done")
end

-- Rayfield:LoadConfiguration() убран:
-- ConfigurationSaving = { Enabled = false }, поэтому грузить нечего.
-- Свой mini-конфиг (только значения) грузится только по нажатию кнопки в Settings.

-- ====================================================
-- Страховочный UIS-хендлер для toggle UI (RightControl)
-- ====================================================
-- Rayfield-овский ToggleUIKeybind иногда залипает после
-- ручного :SetVisibility(). Поэтому держим запасной слушатель — он всегда
-- работает напрямую через UserInputService.
do
    local debounce = 0
    track(UIS.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode ~= Enum.KeyCode.RightControl then return end
        local now = tick()
        if now - debounce < 0.15 then return end
        debounce = now
        pcall(function()
            Rayfield:SetVisibility(not Rayfield:IsVisible())
        end)
    end))
end

-- Убираем splash через 2.2 сек (совпадает с финишем анимации прогресс-бара)
task.delay(2.2, function() pcall(destroySplash) end)

notify("Luna Hub загружен. RightCtrl — открыть/закрыть меню", 4)
print("[Luna] ready | game: " .. game.Name)
_G.LunaCheatLoaded = true
