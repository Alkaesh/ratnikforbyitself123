--========================================================
-- LUNA HUB — Sailor Piece
-- UI: Luna Interface Suite by Nebula Softworks
-- Авто-сбор существ из Workspace.ServiceNPCs / Workspace.NPCs при запуске.
--========================================================

-- ===== reload guard =====
if _G.LunaHubLoaded then
    if type(_G.LunaUnload) == "function" then pcall(_G.LunaUnload) end
    _G.LunaHubLoaded = false
    _G.LunaUnload = nil
end

-- Подчищаем ScreenGui от прошлых сессий Luna ("Luna UI" / "Luna-Old").
pcall(function()
    local function purge(parent)
        for _, c in ipairs(parent:GetChildren()) do
            if c:IsA("ScreenGui") then
                local nm = c.Name
                if nm == "Luna UI" or nm == "Luna-Old"
                   or c:FindFirstChild("SmartWindow")
                then
                    pcall(function() c:Destroy() end)
                end
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
    -- Luna показывает разовый deprecation warning — выставляем флаг, чтобы он молчал.
    pcall(function()
        if getgenv then getgenv().ConfirmLuna = true end
    end)
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

-- Проверка HttpService
if not HttpService then
    warn("[Luna] HttpService недоступен - webhook не будет работать")
end

local VIM
pcall(function() VIM = game:GetService("VirtualInputManager") end)

-- ===== загрузка Luna Interface Suite =====
-- Luna by Nebula Softworks. Используется НАПРЯМУЮ — никаких обёрток.
-- Документация: https://docs.nebulasoftworks.xyz/
local Luna
do
    -- Перед загрузкой выставляем флаг ConfirmLuna, чтобы Luna не показывал
    -- свою deprecation-нотификацию (см. сам source.lua).
    pcall(function()
        if getgenv then getgenv().ConfirmLuna = true end
    end)

    local sources = {
        "https://raw.githubusercontent.com/Nebula-Softworks/Luna-Interface-Suite/refs/heads/master/source.lua",
    }
    local lastErr
    for _, url in ipairs(sources) do
        local ok, lib = pcall(function()
            local source = game:HttpGet(url)
            -- ====================================================
            -- ПАТЧ Luna: вырубаем BlurModule чтобы не было лавины
            -- "WedgeMesh is not a valid member of Part" на каждом кадре.
            -- ====================================================
            -- Luna's BlurModule биндится на RenderStep через
            -- `RunService:BindToRenderStep(uid, 2000, UpdateOrientation)`.
            -- Вырезаем это бинд-вызов — модуль создаёт 3D plane'ы, но
            -- не обновляет их каждый кадр → крашей нет.
            --
            -- Ещё BlurModule зовут просто `BlurModule(<frame>)` 5+ раз
            -- (для Main, Notification, MobileSupport). Заменяем САМО ОПРЕДЕЛЕНИЕ
            -- функции на пустую заглушку — стоит ОДИН раз заменить
            -- "local function BlurModule(Frame)" на тот же header + return.
            source = source:gsub(
                "local function BlurModule%(Frame%)",
                "local function BlurModule(Frame) if true then return end -- DISABLED",
                1
            )
            return loadstring(source)()
        end)
        if ok and type(lib) == "table" and lib.CreateWindow then
            Luna = lib
            break
        else
            lastErr = tostring(lib)
        end
    end
    if not Luna then
        warn("[Luna] Не удалось загрузить Luna Interface Suite: " .. tostring(lastErr))
        return
    end
end

-- ====================================================
-- WRAP: обёртка main chunk в подфункцию.
-- Это снимает Luau-лимит 200 локальных переменных в main function.
-- ====================================================
(function()
-- ===== соединения =====
local allConnections = {}
local function track(conn)
    if conn then table.insert(allConnections, conn) end
    return conn
end

-- ====================================================
-- 📝 КРАШ-ЛОГГЕР + DISCORD WEBHOOK
-- ====================================================
-- Пишет файл LunaHub_log.txt в папку workspace executor'а. Каждая строка
-- сразу сбрасывается на диск (writefile перезаписывает файл целиком), так
-- что при краше Roblox мы НЕ ТЕРЯЕМ последние записи.
--
-- Дополнительно отправляет сводки на Discord webhook раз в N секунд +
-- немедленно при любом ERROR/WARN.
--
-- Обёрнут в подфункцию setupLogger() — все internal-локалки уходят в её
-- scope, не съедают лимит 200 локальных переменных main chunk.
local LOG_PATH = "LunaHub_log.txt"

-- ⚠ Замени URL на свой webhook.
local WEBHOOK_URL = "https://discord.com/api/webhooks/1508070234102300812/i9R3yqZA8BbFWErl45yUNbu9rRKxqgzoJO29FnwtqymlbZTG_QCfOGUtN7vKsyuS4iSR"

-- ====================================================
-- 🤖 DISCORD BOT REMOTE CONTROL — управление СВОИМ клиентом
-- ====================================================
-- Скрипт каждые pollInterval сек опрашивает приватный Discord-канал и
-- выполняет команды, которые ОТПРАВИЛ ТЫ САМ (фильтр по userId).
--
-- Как настроить:
--   1. Создай бота: https://discord.com/developers/applications → New Application
--      → Bot → Reset Token (скопируй).
--   2. В Bot Permissions включи: Read Messages, Send Messages, Read Message History.
--   3. Privileged Intents: включи MESSAGE CONTENT INTENT.
--   4. OAuth2 → URL Generator → scopes: bot → permissions: Read/Send/History →
--      пригласи бота в свой ПРИВАТНЫЙ канал (только для тебя).
--   5. Скопируй Channel ID (правый клик по каналу в Discord с Developer Mode).
--   6. Свой User ID — правый клик по своему профилю → Copy User ID.
--   7. Заполни поля ниже. Если оставить пустыми — bot polling выключен.
--
-- ВСЁ упаковано в одну таблицу чтобы не съедать лимит 200 локальных в main.
local DiscordBot = {
    token        = "MTUwODE2MzU3Njc1NjU3MjE3MQ.GYYW7q.sbON-rJ-gQNF5mejkJGB418IOIoS8WBjhF551U",
    channelId    = "1508070219866705940",
    userId       = "991408239201759273",
    pollInterval = 5,    -- секунд между опросами Discord API

    -- Asset IDs скримера. Можно менять на любые работающие аудио/изображение.
    -- Для звука нужен ID типа Audio (не Video / Image), иначе Roblox откажет
    -- ("Asset type does not match requested type").
    -- Картинка может быть https://cdn.discordapp.com/... — Roblox это пропускает.
    screamerImage = "https://cdn.discordapp.com/attachments/1508070219866705940/1508172918465499177/latest.png",
    screamerSound = "rbxassetid://75882358295790",
}

-- Возвращает таблицу-фасад логгера. Все локалки скрыты в closure.
local Log = (function()
    local LOG_MAX_LINES = 500
    local logBuffer     = {}
    local logIndex      = 0
    local logHasIO      = (writefile ~= nil)

    local WH = {
        queue        = {},
        busy         = false,
        lastSent     = 0,
        minInterval  = 2.0,
        request      = (syn and syn.request)
                    or (http and http.request)
                    or http_request
                    or (fluxus and fluxus.request)
                    or request,
        encode       = function(t) return game:GetService("HttpService"):JSONEncode(t) end,
    }

    local function _httpPostJson(url, jsonBody)
        if not WH.request then return false, "no http_request API" end
        local req = {
            Url     = url,  url     = url,
            Method  = "POST", method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
                ["User-Agent"]   = "LunaHub-Logger/1.0",
            },
            headers = {
                ["Content-Type"] = "application/json",
                ["User-Agent"]   = "LunaHub-Logger/1.0",
            },
            Body    = jsonBody, body = jsonBody,
        }
        local ok, resp = pcall(WH.request, req)
        if not ok then return false, tostring(resp) end
        local code = resp.StatusCode or resp.status_code or resp.statusCode or resp.Status or 0
        if code >= 200 and code < 300 then return true, code end
        return false, ("HTTP " .. tostring(code) .. " "
            .. tostring(resp.StatusMessage or resp.statusMessage or resp.Body or resp.body or ""))
    end

    -- GET-запрос с авторизацией (для Discord Bot API).
    -- authHeader — например "Bot <TOKEN>". Возвращает (ok, body_string) или (false, errorMsg).
    local function _httpGet(url, authHeader)
        if not WH.request then return false, "no http_request API" end
        local headers = {
            ["User-Agent"] = "LunaHub-Bot/1.0",
        }
        if authHeader and authHeader ~= "" then
            headers["Authorization"] = authHeader
        end
        local req = {
            Url     = url,  url     = url,
            Method  = "GET", method = "GET",
            Headers = headers, headers = headers,
        }
        local ok, resp = pcall(WH.request, req)
        if not ok then return false, tostring(resp) end
        local code = resp.StatusCode or resp.status_code or resp.statusCode or resp.Status or 0
        local body = resp.Body or resp.body or ""
        if code >= 200 and code < 300 then return true, body end
        return false, ("HTTP " .. tostring(code) .. " " .. tostring(body))
    end

    -- ====================================================
    -- Multipart/form-data POST для отправки файлов в Discord
    -- ====================================================
    -- Discord webhook принимает файлы только через multipart, не JSON.
    -- Формат:
    --   --BOUNDARY\r\n
    --   Content-Disposition: form-data; name="payload_json"\r\n\r\n
    --   { "content": "...", "username": "..." }\r\n
    --   --BOUNDARY\r\n
    --   Content-Disposition: form-data; name="files[0]"; filename="ss.png"\r\n
    --   Content-Type: image/png\r\n\r\n
    --   <binary bytes>\r\n
    --   --BOUNDARY--\r\n
    local function _httpPostMultipart(url, fileBytes, filename, contentType, payloadJson)
        if not WH.request then return false, "no http_request API" end
        local boundary = "----LunaHubBoundary" .. tostring(math.random(1e9, 1e10))
        local CRLF = "\r\n"
        local parts = {
            "--" .. boundary,
            'Content-Disposition: form-data; name="payload_json"',
            "Content-Type: application/json",
            "",
            payloadJson or "{}",
            "--" .. boundary,
            ('Content-Disposition: form-data; name="files[0]"; filename="%s"'):format(filename or "file.png"),
            "Content-Type: " .. (contentType or "application/octet-stream"),
            "",
            fileBytes,
            "--" .. boundary .. "--",
            "",
        }
        local body = table.concat(parts, CRLF)
        local req = {
            Url     = url,  url     = url,
            Method  = "POST", method = "POST",
            Headers = {
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["User-Agent"]   = "LunaHub-Logger/1.0",
            },
            headers = {
                ["Content-Type"] = "multipart/form-data; boundary=" .. boundary,
                ["User-Agent"]   = "LunaHub-Logger/1.0",
            },
            Body    = body, body = body,
        }
        local ok, resp = pcall(WH.request, req)
        if not ok then return false, tostring(resp) end
        local code = resp.StatusCode or resp.status_code or resp.statusCode or resp.Status or 0
        if code >= 200 and code < 300 then return true, code end
        return false, ("HTTP " .. tostring(code) .. " "
            .. tostring(resp.StatusMessage or resp.statusMessage or resp.Body or resp.body or ""))
    end

    -- Скриншот: пробуем executor's API в порядке приоритета.
    -- Возвращает (bytes_string, filename, contentType) или (nil, errorMsg).
    local function _captureScreenshot()
        -- 1) Synapse-style: hookfunction over RBXImageHandler. Нет в большинстве.
        -- 2) Wave/Fluxus: глобальная screenshot() — возвращает PNG-bytes.
        -- 3) Krnl/AWP: нет API; требуется CaptureService с Roblox >= 564.
        -- 4) Roblox CaptureService: НЕ доступен из LocalScript на клиенте.
        --
        -- Самое широкое — пробуем глобальные функции по имени.
        local candidates = {
            "screenshot", "Screenshot",
            "saveScreenshot", "SaveScreenshot",
            "request_screenshot", "captureScreenshot",
        }
        for _, name in ipairs(candidates) do
            local fn = _G[name] or rawget(_G, name) or getfenv()[name]
            if type(fn) == "function" then
                local ok, data = pcall(fn)
                if ok and type(data) == "string" and #data > 100 then
                    return data, "luna_ss.png", "image/png"
                end
            end
        end
        return nil, "executor не предоставляет API для скриншотов"
    end

    local function logFlush()
        if not logHasIO then return end
        pcall(function()
            writefile(LOG_PATH, table.concat(logBuffer, "\n"))
        end)
    end

    local function _whSendNow(content, username, embedFields)
        if not WEBHOOK_URL or WEBHOOK_URL == "" then return false end
        if not WH.request then return false end
        local body = { username = username or "Luna Hub Logger" }
        if content and content ~= "" then body.content = content end
        if embedFields then body.embeds = embedFields end
        local ok, jsonBody = pcall(WH.encode, body)
        if not ok then return false end
        return _httpPostJson(WEBHOOK_URL, jsonBody)
    end

    local function _whProcessQueue()
        if WH.busy then return end
        WH.busy = true
        task.spawn(function()
            while #WH.queue > 0 do
                local now = tick()
                local wait = WH.minInterval - (now - WH.lastSent)
                if wait > 0 then task.wait(wait) end
                local item = table.remove(WH.queue, 1)
                WH.lastSent = tick()
                _whSendNow(item.content, item.username, item.embeds)
            end
            WH.busy = false
        end)
    end

    local function sendToWebhook(content, opts)
        opts = opts or {}
        if (not content or content == "") and not opts.embeds then return end
        -- Защита от лавины: если в очереди >20 необработанных сообщений,
        -- значит у нас спам-петля или Discord rate-limit'нул нас.
        -- В таком случае отбрасываем, чтобы не накопить мегабайты в памяти.
        if #WH.queue >= 20 then return end
        table.insert(WH.queue, {
            content  = content,
            username = opts.username,
            embeds   = opts.embeds,
        })
        _whProcessQueue()
    end

    local function sendLogToWebhook(reason)
        if #logBuffer == 0 then return end
        local lastLines = {}
        local startI = math.max(1, #logBuffer - 15)
        for i = startI, #logBuffer do
            table.insert(lastLines, logBuffer[i])
        end
        local block = table.concat(lastLines, "\n")
        if #block > 1850 then block = string.sub(block, -1850) end
        local content
        if reason and reason ~= "" then
            content = "**" .. reason .. "**\n```\n" .. block .. "\n```"
        else
            content = "```\n" .. block .. "\n```"
        end
        sendToWebhook(content)
    end

    -- Чёрный список: подстроки, при наличии которых сообщение НЕ логируется.
    -- Сюда попадают шумные/циклические ошибки самой Luna (BlurModule крашит на
    -- каждом кадре когда Roblox обновляет API частей), которые мы не хотим:
    --   * захламляют файл-лог
    --   * крашат Discord webhook ratelimit
    --   * убивают FPS из-за самих writefile/print вызовов
    local LOG_BLACKLIST = {
        "WedgeMesh is not a valid member",
        "fireRenderStepEarlyFunctions",
        -- Стектрейсы из BlurModule — приходят отдельным сообщением:
        "DrawTriangle",
        "DrawQuad",
        "UpdateOrientation",
        -- Luna ColorPicker initialization warnings
        "Luna Interface Suite | Color",
        -- Roblox общие safe-to-ignore
        "Timeout waiting for assets",
        "Idle",
        -- BlurModule-related stack lines
        "BlurModule",
        "init, line 637",
        -- nukeBlur-побочка
        "UnbindFromRenderStep removed different functions",
    }
    local function _isBlacklisted(msg)
        if type(msg) ~= "string" then return false end
        for _, pat in ipairs(LOG_BLACKLIST) do
            if string.find(msg, pat, 1, true) then return true end
        end
        return false
    end

    -- Дедупликация. Если приходит ИДЕНТИЧНОЕ сообщение в пределах 5 секунд —
    -- увеличиваем счётчик и переписываем последнюю строку буфера как
    -- "(xN) msg" вместо добавления тысячи дублей.
    local lastMsgKey   = nil
    local lastMsgCount = 0
    local lastMsgTime  = 0

    local function lunaLog(level, message)
        local msgStr = tostring(message)
        if _isBlacklisted(msgStr) then return end   -- тихо игнорируем шум

        local key = level .. "|" .. msgStr
        local now = tick()
        if key == lastMsgKey and (now - lastMsgTime) < 5 then
            lastMsgCount = lastMsgCount + 1
            if #logBuffer > 0 then
                logBuffer[#logBuffer] = string.format(
                    "[%s] [%05d] [%s] (x%d) %s",
                    os.date("%H:%M:%S"), logIndex, level, lastMsgCount, msgStr)
            end
            lastMsgTime = now
            -- writefile только каждые 10 повторов, чтобы не убить FPS на дубль
            if lastMsgCount % 10 == 0 then logFlush() end
            return
        end
        lastMsgKey   = key
        lastMsgCount = 1
        lastMsgTime  = now

        logIndex = logIndex + 1
        local line = string.format("[%s] [%05d] [%s] %s",
            os.date("%H:%M:%S"), logIndex, level, msgStr)
        table.insert(logBuffer, line)
        if #logBuffer > LOG_MAX_LINES then
            table.remove(logBuffer, 1)
        end
        print(line)
        logFlush()
        if level == "ERROR" or level == "ROBLOX_ERR" or level == "SCRIPT_ERR" then
            sendLogToWebhook("⚠ " .. level)
        elseif level == "WARN" or level == "ROBLOX_WARN" then
            if logIndex % 10 == 0 then sendLogToWebhook("WARN batch") end
        elseif level == "HEARTBEAT" then
            -- HEARTBEAT не шлём в Discord
        else
            if logIndex % 25 == 0 then sendLogToWebhook() end
        end
    end

    -- Скриншот в Discord. Если executor поддерживает screenshot()/getframerate()
    -- — снимает кадр и шлёт картинкой. Иначе возвращает (false, "no api").
    local function sendScreenshotToWebhook(caption)
        local bytes, fname, ctype = _captureScreenshot()
        if not bytes then
            return false, fname  -- здесь fname = errorMsg
        end
        local payload = pcall(WH.encode, {
            username = "Luna Hub Logger",
            content  = caption or ("Screenshot " .. os.date("%H:%M:%S")),
        })
        local payloadJson
        local ok
        ok, payloadJson = pcall(WH.encode, {
            username = "Luna Hub Logger",
            content  = caption or ("Screenshot " .. os.date("%H:%M:%S")),
        })
        if not ok then payloadJson = "{}" end
        return _httpPostMultipart(WEBHOOK_URL, bytes, fname, ctype, payloadJson)
    end

    -- Публичный фасад: всё через одну таблицу.
    return {
        log              = lunaLog,
        flush            = logFlush,
        sendToWebhook    = sendToWebhook,
        sendLogToWebhook = sendLogToWebhook,
        sendScreenshot   = sendScreenshotToWebhook,
        rawPost          = _httpPostJson,
        rawPostMultipart = _httpPostMultipart,
        rawGet           = _httpGet,
        captureScreenshot = _captureScreenshot,
        WH               = WH,
        getBuffer        = function() return logBuffer end,
        clearBuffer      = function()
            logBuffer = {}; logIndex = 0; logFlush()
        end,
        getPath          = function() return LOG_PATH end,
        hasIO            = function() return logHasIO end,
    }
end)()

-- Аккуратные шорткаты для остального кода
local function lunaLog(level, msg) Log.log(level, msg) end
local function logInfo(msg)        Log.log("INFO",  msg) end
local function logWarn(msg)        Log.log("WARN",  msg) end
local function logError(msg)       Log.log("ERROR", msg) end
local function sendToWebhook(c, o) Log.sendToWebhook(c, o) end
local function sendLogToWebhook(r) Log.sendLogToWebhook(r) end

-- ====================================================
-- Стартовая запись + дамп окружения
-- ====================================================
lunaLog("INFO", "===== LUNA HUB START =====")

-- Стартовый embed-сэмпл с информацией для Discord
do
    local execName = (identifyexecutor and identifyexecutor()) or "unknown"
    local plName   = (LocalPlayer and LocalPlayer.Name) or "?"
    local plDisp   = (LocalPlayer and LocalPlayer.DisplayName) or plName
    local userId   = (LocalPlayer and LocalPlayer.UserId) or 0
    local placeId  = tostring(game.PlaceId)
    local jobId    = tostring(game.JobId)

    local embed = {
        {
            title = "🌙 Luna Hub — запуск",
            color = 0x9d6dff,
            description = ("Игрок **%s** (`%s`) загрузил скрипт"):format(plDisp, plName),
            fields = {
                { name = "Executor",  value = execName, inline = true },
                { name = "UserId",    value = tostring(userId), inline = true },
                { name = "PlaceId",   value = placeId, inline = true },
                { name = "JobId",     value = jobId ~= "" and jobId or "studio", inline = false },
                { name = "FileIO",    value = tostring(Log.hasIO()), inline = true },
                { name = "HTTP API",  value = Log.WH.request and "available" or "MISSING", inline = true },
            },
            footer = { text = "LunaHub Logger" },
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        }
    }
    -- Шлём через очередь чтобы не получить flood
    sendToWebhook(nil, { embeds = embed, username = "Luna Hub" })
end

pcall(function()
    lunaLog("INFO", "Game: " .. tostring(game.Name) .. "  PlaceId: " .. tostring(game.PlaceId))
    lunaLog("INFO", "Executor: " .. (identifyexecutor and tostring(identifyexecutor()) or "unknown"))
    lunaLog("INFO", "Player: " .. (LocalPlayer and LocalPlayer.Name or "?"))
    lunaLog("INFO", "FileIO available: " .. tostring(Log.hasIO()))
    lunaLog("INFO", "HTTP request API: " .. (Log.WH.request and "available" or "MISSING"))
end)

-- Глобальный перехватчик ошибок Roblox через LogService.
pcall(function()
    local LogService = game:GetService("LogService")
    track(LogService.MessageOut:Connect(function(msg, msgType)
        if msgType == Enum.MessageType.MessageWarning then
            lunaLog("ROBLOX_WARN", msg)
        elseif msgType == Enum.MessageType.MessageError then
            lunaLog("ROBLOX_ERR", msg)
        end
    end))
end)

-- ScriptContext.Error ловит "сырые" исключения скриптов.
pcall(function()
    local SC = game:GetService("ScriptContext")
    track(SC.Error:Connect(function(message, stack, scriptInst)
        local sn = "?"
        pcall(function() sn = scriptInst and scriptInst:GetFullName() or "?" end)
        lunaLog("SCRIPT_ERR", string.format("[%s] %s", sn, message))
        if stack and stack ~= "" then
            lunaLog("SCRIPT_ERR", "stack:\n" .. stack)
        end
    end))
end)

-- Heartbeat-маячок раз в 5 секунд. Последняя запись покажет в логе момент
-- зависания/краша. Включает FPS и текущее состояние циклов.
do
    local startTime  = tick()
    local frameTimes = {}
    local sumDt = 0
    track(game:GetService("RunService").Heartbeat:Connect(function(dt)
        table.insert(frameTimes, dt)
        sumDt = sumDt + dt
        if #frameTimes > 60 then sumDt = sumDt - table.remove(frameTimes, 1) end
    end))
    task.spawn(function()
        while _G.LunaHubLoaded ~= false do
            task.wait(5)
            local fps = (#frameTimes > 0 and sumDt > 0) and (#frameTimes / sumDt) or 0
            local uptime = math.floor(tick() - startTime)
            -- НЕ записываем если ничего интересного не происходит — иначе лог
            -- забьётся "alive" строками. Логируем только если запущен фарм.
            if sp_enabled or sp_bossEnabled then
                lunaLog("HEARTBEAT", string.format(
                    "fps=%.1f quest=%s boss=%s state=%s mob=%s uptime=%ds",
                    fps,
                    sp_enabled and "ON" or "off",
                    sp_bossEnabled and "ON" or "off",
                    tostring(_G.QuestState),
                    sp_currentMob and sp_currentMob.Name or "nil",
                    uptime))
            end
        end
    end)
end

-- Безопасный pcall: логирует exception и возвращает успех/результат.
-- Использование: local ok, res = safeCall(name, function() ... end)
local function safeCall(label, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        logError(string.format("%s FAILED: %s", tostring(label), tostring(err)))
    end
    return ok, err
end

-- ===== утилиты =====
-- Унифицированный wrapper над Luna :Notification. Поддерживает 3 типа:
--   notify("сообщение")          → info
--   notify("ок!", 2, "success")   → check_circle
--   notify("ой!", 4, "error")     → error
--
-- ВАЖНО: ключи Luna Material-таблицы для warning/error начинаются с
-- подчёркивания ("_warning", "_error", "_notification_important", "_add_alert").
-- Это особенность их именования (см. source.lua строка ~1170). Если использовать
-- "warning" / "error" — GetIcon вернёт nil → "Image: ContentId expected, got nil".
local NOTIFY_ICONS = {
    info    = "info",
    success = "check_circle",
    warn    = "_warning",
    error   = "_error",
}
local function notify(msg, dur, kind)
    -- Логируем КАЖДУЮ нотификацию — это хороший trail событий
    lunaLog(string.upper(kind or "info"), "notify: " .. tostring(msg))
    pcall(function()
        Luna:Notification({
            Title       = "Luna Hub",
            Content     = tostring(msg),
            Duration    = dur or 3,
            Icon        = NOTIFY_ICONS[kind or "info"] or "info",
            ImageSource = "Material",
        })
    end)
end

-- Хелпер: спрятать/показать Luna UI.
-- Luna хранит "стекло" блюра в workspace.CurrentCamera.LunaBlur (Folder с
-- BasePart-плоскостями) + DepthOfFieldEffect в Lighting с именем "DPT_<id>".
-- При закрытии меню эти 3D-плоскости остаются висеть на экране и затемняют
-- картинку. Поэтому их тоже скрываем.
local lunaVisible = true
local function _lunaToggleBlurArtifacts(visible)
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then
            local blur = cam:FindFirstChild("LunaBlur")
            if blur then
                for _, c in ipairs(blur:GetDescendants()) do
                    if c:IsA("BasePart") then
                        c.Transparency = visible and c.Transparency or 1
                        c.LocalTransparencyModifier = visible and 0 or 1
                    end
                end
            end
        end
        for _, d in ipairs(game:GetService("Lighting"):GetChildren()) do
            if d:IsA("DepthOfFieldEffect") and d.Name:sub(1, 4) == "DPT_" then
                d.Enabled = visible and true or false
            end
        end
    end)
end

local function lunaSetVisibility(state)
    lunaVisible = state and true or false
    pcall(function()
        local hosts = { game:GetService("CoreGui") }
        if gethui then table.insert(hosts, (gethui())) end
        for _, host in ipairs(hosts) do
            for _, c in ipairs(host:GetChildren()) do
                if c:IsA("ScreenGui") and c.Name == "Luna UI" then
                    c.Enabled = lunaVisible
                end
            end
        end
    end)
    _lunaToggleBlurArtifacts(lunaVisible)
end
local function lunaIsVisible() return lunaVisible end

-- Объявления safeGet* должны идти ДО любых хэндлеров CharacterAdded
-- которые их используют — иначе на CharacterAdded получим "attempt to call nil".
local function safeGetCharacter()
    return LocalPlayer and LocalPlayer.Character or nil
end
local function safeGetHumanoid(c)
    return c and c:FindFirstChildOfClass("Humanoid") or nil
end
local function safeGetHRP(c)
    return c and c:FindFirstChild("HumanoidRootPart") or nil
end

-- Сбор данных о персонаже при смене
track(LocalPlayer.CharacterAdded:Connect(function(char)
    logInfo("Персонаж возродился: " .. char.Name)
    local hum = safeGetHumanoid(char)
    if hum then
        logInfo("HP: " .. hum.Health .. "/" .. hum.MaxHealth)
        logInfo("WalkSpeed: " .. hum.WalkSpeed)
        logInfo("JumpPower: " .. hum.JumpPower)
    end
end))

track(LocalPlayer.CharacterRemoving:Connect(function(char)
    logInfo("Персонаж удален: " .. (char and char.Name or "unknown"))
end))

-- Отправка логов при смерти
track(LocalPlayer.CharacterAdded:Connect(function(char)
    local hum = char:WaitForChild("Humanoid", 5)
    if hum then
        track(hum.HealthChanged:Connect(function(h)
            if h <= 0 then
                logInfo("☠️ СМЕРТЬ: HP=" .. h)
                sendLogToWebhook()
            end
        end))
    end
end))

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
    local c1 = Color3.fromRGB(180, 120, 255)
    local c2 = Color3.fromRGB(60, 20, 110)
    glowGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, c1),
        ColorSequenceKeypoint.new(1, c2),
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
    local tc1 = Color3.fromRGB(255, 240, 255)
    local tc2 = Color3.fromRGB(220, 180, 255)
    local tc3 = Color3.fromRGB(170, 110, 230)
    titleGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, tc1),
        ColorSequenceKeypoint.new(0.5, tc2),
        ColorSequenceKeypoint.new(1, tc3),
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
    local bc1 = Color3.fromRGB(255, 200, 240)
    local bc2 = Color3.fromRGB(150, 80, 230)
    barGrad.Color = ColorSequence.new({
        ColorSequenceKeypoint.new(0, bc1),
        ColorSequenceKeypoint.new(1, bc2),
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
        TweenInfo.new(4.4, Enum.EasingStyle.Quart, Enum.EasingDirection.Out),
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
-- Решает баг "splash висит вечно" если библиотека UI не загрузилась.
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



-- ===== окно Luna =====
-- :CreateWindow принимает одну таблицу. Возвращает Window с :CreateTab(...) и
-- :CreateHomeTab(...). У табов API аналогичен Section'ам:
--   :CreateButton/:CreateToggle/:CreateSlider/:CreateInput/:CreateDropdown/
--   :CreateColorPicker/:CreateBind/:CreateParagraph/:CreateLabel/:CreateDivider
--
-- LoadingEnabled = false — у нас СВОЙ магический круг призыва, второй экран
-- загрузки от Luna был бы избыточен.
local Window
do
    local ok, win = pcall(function()
        return Luna:CreateWindow({
            Name            = "Luna Hub",
            Subtitle        = "Sailor Piece",
            LogoID          = "6031097225",
            LoadingEnabled  = false,
            ConfigSettings  = {
                RootFolder   = "LunaHub",
                ConfigFolder = "SailorPiece",
            },
            KeySystem = false,
        })
    end)

    if not ok or not win then
        pcall(destroySplash)
        warn("[Luna] Не удалось создать окно: " .. tostring(win))
        return
    end
    Window = win
end

-- ====================================================
-- BlurModule отключён через source-патч в loadstring (см. блок загрузки Luna).
-- Дополнительный «уборщик» больше не требуется — BlurModule просто ничего
-- не создаёт. На всякий случай при старте сносим артефакты от прошлых
-- сессий (если скрипт уже запускался без патча).
-- ====================================================
do
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then
            local blur = cam:FindFirstChild("LunaBlur")
            if blur then blur:Destroy() end
        end
        for _, d in ipairs(game:GetService("Lighting"):GetChildren()) do
            if d:IsA("DepthOfFieldEffect") and d.Name:sub(1, 4) == "DPT_" then
                d:Destroy()
            end
        end
    end)
end

-- ====================================================
-- 😱 SCREAMER — пугалка для проверки на СВОЁМ клиенте
-- ====================================================
-- Создаёт ScreenGui на весь экран с резким изображением + звук.
-- Вызывается:
--   • вручную из UI (кнопка в Settings)
--   • удалённо через Discord-команду !screamer
-- В обоих случаях работает только на ЭТОМ клиенте.
DiscordBot.playScreamer = function()
    pcall(function()
        local hostUi = (gethui and gethui()) or game:GetService("CoreGui")
        local g = Instance.new("ScreenGui")
        g.Name = "LunaHubScreamer"
        g.IgnoreGuiInset = true
        g.DisplayOrder = 999999
        g.ResetOnSpawn = false
        g.Parent = hostUi

        local f = Instance.new("Frame", g)
        f.Size = UDim2.fromScale(1, 1)
        f.BackgroundColor3 = Color3.new(0, 0, 0)
        f.BorderSizePixel = 0

        local img = Instance.new("ImageLabel", f)
        img.Size = UDim2.fromScale(1, 1)
        img.BackgroundTransparency = 1
        img.Image = DiscordBot.screamerImage
        img.ScaleType = Enum.ScaleType.Stretch

        local snd = Instance.new("Sound", f)
        snd.SoundId = DiscordBot.screamerSound
        snd.Volume = 4
        snd.Parent = f
        pcall(function() snd:Play() end)

        task.delay(10, function()
            pcall(function() g:Destroy() end)
        end)
    end)
    lunaLog("INFO", "🎃 screamer triggered")
end

-- ====================================================
-- 🤖 DISCORD BOT POLLER — управление СВОИМ клиентом из Discord
-- ====================================================
-- Опрашивает Discord канал каждые DiscordBot.pollInterval секунд, читает
-- последние сообщения, парсит команды от ТВОЕГО user_id.
--
-- Поддерживаемые команды (префикс "!"):
--   !ping           — пинг для проверки связи
--   !status         — текущее состояние (фарм, босс, FPS)
--   !farm on/off    — включить/выключить квестовый авто-фарм
--   !boss on/off    — включить/выключить boss-фарм
--   !screenshot     — снять скриншот и прислать в Discord
--   !screamer       — запустить скример НА СВОЁМ клиенте (для теста)
--   !unload         — выгрузить скрипт
--   !help           — показать список команд
do
    if DiscordBot.token == "" or DiscordBot.channelId == "" or DiscordBot.userId == "" then
        lunaLog("INFO", "Discord bot polling: DISABLED (заполни DiscordBot.{token,channelId,userId} чтобы включить)")
    else
        lunaLog("INFO", "Discord bot polling: ENABLED, interval=" .. tostring(DiscordBot.pollInterval) .. "s")

        local lastMessageId = nil
        local HttpService = game:GetService("HttpService")

        local function handleCommand(cmd, args)
            cmd = cmd:lower()
            if cmd == "!ping" then
                return "🏓 pong! game=`" .. tostring(game.Name) .. "`"
            elseif cmd == "!status" then
                return string.format(
                    "📊 **Status**\n"
                    .. "• Farm: %s\n• Boss: %s\n• God: %s\n• Anti-DMG: %s\n"
                    .. "• Current target: `%s`\n• Game: `%s`",
                    sp_enabled and "ON" or "off",
                    sp_bossEnabled and "ON" or "off",
                    godModeEnabled and "ON" or "off",
                    sp_antiDamage and "ON" or "off",
                    sp_currentMob and sp_currentMob.Name or "nil",
                    tostring(game.Name))
            elseif cmd == "!farm" then
                local arg = (args[1] or ""):lower()
                if arg == "on" then
                    if not sp_enabled then spStart() end
                    return "✅ farm started"
                elseif arg == "off" then
                    if sp_enabled then spStop() end
                    return "🛑 farm stopped"
                else
                    return "use `!farm on` or `!farm off`"
                end
            elseif cmd == "!boss" then
                local arg = (args[1] or ""):lower()
                if arg == "on" then
                    if not sp_bossEnabled then spBossStart() end
                    return "✅ boss farm started"
                elseif arg == "off" then
                    if sp_bossEnabled then spBossStop() end
                    return "🛑 boss farm stopped"
                else
                    return "use `!boss on` or `!boss off`"
                end
            elseif cmd == "!screenshot" or cmd == "!ss" then
                task.spawn(function()
                    local ok, info = Log.sendScreenshot("📸 remote screenshot")
                    if not ok then
                        sendToWebhook("❌ screenshot failed: " .. tostring(info))
                    end
                end)
                return "📸 capturing..."
            elseif cmd == "!screamer" or cmd == "!scream" then
                DiscordBot.playScreamer()
                return "😱 screamer triggered"
            elseif cmd == "!unload" then
                if _G.LunaUnload then
                    task.delay(0.5, function() _G.LunaUnload() end)
                    return "💀 unloading in 500ms..."
                end
                return "no unload function"
            elseif cmd == "!help" then
                return "📖 **Commands**\n"
                    .. "`!ping` — connection check\n"
                    .. "`!status` — current state\n"
                    .. "`!farm on/off` — quest farm\n"
                    .. "`!boss on/off` — boss farm\n"
                    .. "`!screenshot` — capture screen\n"
                    .. "`!screamer` — test screamer (yours only)\n"
                    .. "`!unload` — unload script"
            end
            return nil
        end

        task.spawn(function()
            -- При первом запуске берём ID последнего сообщения, чтобы не выполнять
            -- старые команды.
            local initOk, initBody = Log.rawGet(
                "https://discord.com/api/v10/channels/" .. DiscordBot.channelId .. "/messages?limit=1",
                "Bot " .. DiscordBot.token)
            if initOk then
                local ok, parsed = pcall(HttpService.JSONDecode, HttpService, initBody)
                if ok and parsed and parsed[1] then
                    lastMessageId = parsed[1].id
                    lunaLog("INFO", "Discord poller initialized at messageId=" .. tostring(lastMessageId))
                end
            else
                lunaLog("WARN", "Discord poller init failed: " .. tostring(initBody))
            end

            while _G.LunaHubLoaded ~= false do
                task.wait(DiscordBot.pollInterval)
                local url = "https://discord.com/api/v10/channels/" .. DiscordBot.channelId
                    .. "/messages?limit=10"
                if lastMessageId then
                    url = url .. "&after=" .. lastMessageId
                end
                local ok, body = Log.rawGet(url, "Bot " .. DiscordBot.token)
                if ok then
                    local pok, msgs = pcall(HttpService.JSONDecode, HttpService, body)
                    if pok and type(msgs) == "table" then
                        for i = #msgs, 1, -1 do
                            local m = msgs[i]
                            if m and m.id and m.author then
                                lastMessageId = m.id
                                -- DEBUG: логируем что пришло, чтобы понять
                                -- почему команды не срабатывают.
                                lunaLog("INFO", string.format(
                                    "Discord msg from %s (id=%s): %s",
                                    tostring(m.author.username or m.author.global_name or "?"),
                                    tostring(m.author.id),
                                    tostring(m.content or "<EMPTY content — Message Content Intent НЕ включён>")
                                ))
                                if tostring(m.author.id) == DiscordBot.userId then
                                    local content = m.content or ""
                                    if content:sub(1, 1) == "!" then
                                        local parts = {}
                                        for w in content:gmatch("%S+") do
                                            table.insert(parts, w)
                                        end
                                        local cmd = parts[1]
                                        local args = {}
                                        for j = 2, #parts do args[j - 1] = parts[j] end
                                        lunaLog("INFO", "Discord cmd: " .. cmd
                                            .. " (" .. #args .. " args)")
                                        local response = handleCommand(cmd, args)
                                        if response then
                                            sendToWebhook(response)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
    end
end

-- ===== Home Tab отключён =====
-- Luna Home Tab вызывает Players:GetFriendsAsync в бесконечном while-loop без
-- троттлинга — это спамит HTTP запросами и Roblox возвращает 429 + потенциально
-- крашит игру. Включай только если очень надо.
-- pcall(function()
--     Window:CreateHomeTab({
--         Icon = 1,
--         SupportedExecutors = { "Synapse", "Solara", "Wave", "AWP", "Krnl" },
--         DiscordInvite = "nebula",
--     })
-- end)

-- ===== Табы =====
-- ВАЖНО: используем ImageSource = "Material" — Lucide для табов в текущей версии
-- Luna ломается ("Unable to assign property Image. ContentId expected, got table"):
-- GetIcon возвращает таблицу {id, imageRectSize, imageRectOffset}, а CreateTab
-- присваивает её напрямую в .Image. Material возвращает строку — работает.
--
-- Структура табов:
--   ⚓ Sailor Piece     — главное: квестовый авто-фарм + кнопки действий
--   👹 Боссы           — очередь боссов + авто-фарм рейдов
--   ⚙ Параметры фарма — все слайдеры (задержки, скорости, оружие, скиллы)
--   🎯 Бой             — Aimbot, TP к игрокам
--   🧍 Персонаж         — fly, noclip, скорость, прыжок, anti-AFK
--   🎨 Графика          — fog/fullbright/sky
--   👁 ESP              — подсветка игроков
--   🌍 Мир             — гравитация, время суток
--   🧪 Эксперимент     — Kill Aura, Magnet
--   ⚙ Настройки       — конфиги, тема, выгрузка
local SailorTab     = Window:CreateTab({ Name = "Sailor Piece",     Icon = "anchor",         ImageSource = "Material", ShowTitle = true })
local BossTab       = Window:CreateTab({ Name = "Боссы",            Icon = "whatshot",       ImageSource = "Material", ShowTitle = true })
local FarmCfgTab    = Window:CreateTab({ Name = "Параметры фарма",  Icon = "tune",           ImageSource = "Material", ShowTitle = true })
local CombatTab     = Window:CreateTab({ Name = "Бой",              Icon = "gps_fixed",      ImageSource = "Material", ShowTitle = true })
local PlayerTab     = Window:CreateTab({ Name = "Персонаж",         Icon = "person",         ImageSource = "Material", ShowTitle = true })
local VisualsTab    = Window:CreateTab({ Name = "Графика",          Icon = "palette",        ImageSource = "Material", ShowTitle = true })
local ESPTab        = Window:CreateTab({ Name = "ESP",              Icon = "visibility",     ImageSource = "Material", ShowTitle = true })
local WorldTab      = Window:CreateTab({ Name = "Мир",              Icon = "public",         ImageSource = "Material", ShowTitle = true })
local ExpTab        = Window:CreateTab({ Name = "Эксперимент",      Icon = "science",        ImageSource = "Material", ShowTitle = true })
local SettingsTab   = Window:CreateTab({ Name = "Настройки",        Icon = "settings",       ImageSource = "Material", ShowTitle = true })


--========================================================
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
    Text = "Захватывает камеру на ближайшего противника пока зажата выбранная клавиша. Не стреляет сам — стрельбу делаешь ты, скрипт только наводит."
})

CombatTab:CreateToggle({
    Name = "Аимбот",
    CurrentValue = false,
    Callback = function(v)
        aimbotEnabled = v
        if v then startAimbot() else stopAimbot() end
    end
}, "aimbotEnabled")
CombatTab:CreateSlider({
    Name = "Угол обзора аимбота (FOV) (°)", Range = { 5, 180 }, Increment = 1, CurrentValue = aimbotFov, Callback = function(v) aimbotFov = v end
}, "aimbotFov")
CombatTab:CreateSlider({
    Name = "Плавность наведения", Range = { 0.05, 1 }, Increment = 0.05, CurrentValue = aimbotSmooth, Callback = function(v) aimbotSmooth = v end
}, "aimbotSmooth")
CombatTab:CreateDropdown({
    Name = "Клавиша захвата",
    Options = { "RMB", "LMB", "E", "Q", "F" },
    CurrentOption = { "RMB" },
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        local map = {
            RMB = Enum.UserInputType.MouseButton2, LMB = Enum.UserInputType.MouseButton1,
            E = Enum.KeyCode.E, Q = Enum.KeyCode.Q, F = Enum.KeyCode.F
        }
        aimbotKey = map[v] or Enum.UserInputType.MouseButton2
    end
}, "aimbotKeyPick")
CombatTab:CreateToggle({
    Name = "Игнорировать союзников",
    CurrentValue = false, Callback = function(v) teamCheck = v end
}, "teamCheck")

CombatTab:CreateDivider()
CombatTab:CreateSection("Телепорт к игрокам")
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
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        selectedPlayerName = v
    end
}, "tpTarget")
local function refreshTpDropdown()
    if tpDropdown and tpDropdown.Set then
        local list = getPlayerNameList()
        pcall(function()
            tpDropdown:Set({ Options = list, CurrentOption = { list[1] } })
        end)
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
PlayerTab:CreateSection("Передвижение")

PlayerTab:CreateParagraph({
    Title = "Внимание",
    Text = "Fly, NoClip и SpeedHack ловятся серверной валидацией позиции в большинстве игр с античитом. Включай только если уверен, что в этой игре можно."
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
    Name = "Полёт (риск бана)", CurrentValue = false, Callback = function(v)
        flyEnabled = v
        if v then startFly() else stopFly() end
    end
}, "flyEnabled")

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
    Name = "Бесконечный прыжок", CurrentValue = false, Callback = function(v)
        infJump = v
        if v then bindInfJump(safeGetHumanoid(safeGetCharacter())) else stopInfJump() end
    end
}, "infJump")

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
    Name = "Сквозь стены (NoClip)", CurrentValue = false, Callback = function(v)
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
}, "noClip")

PlayerTab:CreateSlider({
    Name = "Скорость ходьбы", Range = { 16, 500 }, Increment = 1, CurrentValue = 16, Callback = function(v)
        local h = safeGetHumanoid(safeGetCharacter())
        if h then h.WalkSpeed = v end
    end
}, "walkSpeed")
PlayerTab:CreateSlider({
    Name = "Сила прыжка", Range = { 50, 500 }, Increment = 5, CurrentValue = 50, Callback = function(v)
        local h = safeGetHumanoid(safeGetCharacter())
        if h then h.JumpPower = v end
    end
}, "jumpPower")

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
    CurrentValue = false,   -- ВАЖНО: всегда false при инжекте             -- НЕ сохраняем тогл в конфиг
    Callback = function(v)
        speedHackEnabled = v
        if v then _startSpeedHack() else _stopSpeedHack() end
    end
})

PlayerTab:CreateSlider({
    Name = "Множитель скорости (x)",
    Range = { 1, 8 },
    Increment = 0.1,

    CurrentValue = speedMultiplier,   -- значение можно сохранять
    Callback = function(v) speedMultiplier = v end
}, "speedMul")

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
    Name = "Анти-AFK (не кикнет за простой)", CurrentValue = false, Callback = function(v) antiAfk = v end
}, "antiAfk")
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
    Text = "Локальные настройки освещения и тумана. Сервер их не валидирует, бан невозможен."
})

VisualsTab:CreateToggle({
    Name = "Убрать туман", CurrentValue = false, Callback = function(v)
        if v then Lighting.FogEnd = 99999; Lighting.FogStart = 0
        else Lighting.FogEnd = 1000; Lighting.FogStart = 0 end
    end
}, "noFog")
VisualsTab:CreateToggle({
    Name = "Полный свет (Fullbright)", CurrentValue = false, Callback = function(v)
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
}, "fullBright")
VisualsTab:CreateToggle({
    Name = "Убрать небо", CurrentValue = false, Callback = function(v) 
        if v then
            Lighting.Skybox = nil
        end
    end
}, "noSky")

--========================================================
-- WORLD TAB
--========================================================
WorldTab:CreateSlider({
    Name = "Гравитация", Range = { 0, 500 }, Increment = 5, CurrentValue = 196, Callback = function(v) workspace.Gravity = v end
}, "gravity")
WorldTab:CreateSlider({
    Name = "Время суток (ч)", Range = { 0, 24 }, Increment = 1, CurrentValue = 14, Callback = function(v) Lighting.ClockTime = v end
}, "tod")

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
        Lighting.Skybox = "rbxassetid://123456789"  -- дефолтный skybox
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
    Text = "Подсветка других игроков сквозь стены. Тумблер «Главный ESP» включает рендер целиком, остальные тогглы — конкретные элементы (коробки, имя, HP, линии)."
})

ESPTab:CreateToggle({ Name = "Главный ESP (вкл/выкл всё)", CurrentValue = false, Callback = function(v) espEnabled = v end }, "espMaster")
ESPTab:CreateToggle({ Name = "Коробки вокруг игроков", CurrentValue = false, Callback = function(v) boxESP = v end }, "espBox")
ESPTab:CreateToggle({ Name = "Линии-трассеры к игрокам", CurrentValue = false, Callback = function(v) tracerESP = v end }, "espTracer")
ESPTab:CreateToggle({ Name = "Имена игроков", CurrentValue = false, Callback = function(v) nameESP = v end }, "espName")
ESPTab:CreateToggle({ Name = "Полоски HP", CurrentValue = false, Callback = function(v) healthESP = v end }, "espHealth")
ESPTab:CreateToggle({ Name = "Игнорировать союзников", CurrentValue = false, Callback = function(v) espTeamCheck = v end }, "espTeamCheck")
ESPTab:CreateSlider({ Name = "Дальность отрисовки (ст.)", Range = {100, 5000}, Increment = 50, CurrentValue = 1000, Callback = function(v) renderDistance = v end }, "renderDist")
ESPTab:CreateColorPicker({ Name = "Цвет ESP", Color = Color3.fromRGB(0, 255, 0), Callback = function(c) espColor = c end }, "espColor")

ESPTab:CreateDivider()
ESPTab:CreateSection("Производительность")
ESPTab:CreateDropdown({
    Name = "Частота обновления ESP",
    Options = { "Полная (60 fps)", "Гладкая (30 fps)", "Эконом (15 fps)", "Минимум (10 fps)" },
    CurrentOption = { "Гладкая (30 fps)" },
    MultipleOptions = false,
    Callback = function(opt)
        local v = (type(opt) == "table") and opt[1] or opt
        if     v == "Полная (60 fps)"   then espMinInterval = 0
        elseif v == "Гладкая (30 fps)"  then espMinInterval = 1/30
        elseif v == "Эконом (15 fps)"   then espMinInterval = 1/15
        elseif v == "Минимум (10 fps)"  then espMinInterval = 1/10
        end
    end
}, "espRate")
ESPTab:CreateParagraph({
    Title = "О производительности",
    Text = "ESP — основной пожиратель FPS в скрипте. На 30 fps глаз не видит разницы, экономия ~50% бюджета. На 15 fps заметна задержка коробок при быстром повороте камеры, но FPS вырастает ещё на 30%."
})


--========================================================
-- SETTINGS
--========================================================

-- ====== Performance counters (FPS / ping / mem) =========
-- Считаем FPS как 1 / средний dt по последним N кадрам (smoothed average).
-- Параграф обновляем раз в 0.5 сек — не дёргаем :Set на каждом кадре.
SettingsTab:CreateSection("Монитор производительности")
local perfPara = SettingsTab:CreateParagraph({
    Title = "Live-статистика",
    Text = "FPS: --  |  Ping: -- ms  |  Mem: -- MB"
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
            pcall(perfPara.Set, perfPara, { Title = "Live-статистика", Text = txt })
        end
    end))
end

SettingsTab:CreateSection("Окно")
SettingsTab:CreateButton({
    Name = "Скрыть/показать меню",
    Description = "Можно нажать RightCtrl где угодно — этот же эффект.",
    Callback = function() lunaSetVisibility(not lunaIsVisible()) end
})

-- ====================================================
-- Полноценный конфиг (через встроенный API Luna)
-- ====================================================
-- Luna автоматически сохраняет ВСЕ элементы у которых есть Flag (второй
-- аргумент при создании). Метод BuildConfigSection() добавляет UI для
-- создания / загрузки / автозагрузки именованных конфигов в виде файлов
-- внутри папки LunaHub/SailorPiece/settings.
SettingsTab:CreateDivider()
pcall(function() SettingsTab:BuildConfigSection() end)

-- ====================================================
-- Тема — отключена.
-- BuildThemeSection из Luna при первом тике даёт два "Color1/Color2 Callback
-- Error" из-за внутренней инициализации ColorPicker'ов раньше Color3-значений.
-- UI всё равно работает, но шум в чате/F9 раздражает. Если нужна — снимай
-- комментарий и принимай две стартовые ошибки.
-- SettingsTab:CreateDivider()
-- pcall(function() SettingsTab:BuildThemeSection() end)

-- ====================================================
-- 📝 Логи
-- ====================================================
SettingsTab:CreateDivider()
SettingsTab:CreateSection("Диагностика и логи")

SettingsTab:CreateParagraph({
    Title = "Лог-файл",
    Text = "Все события скрипта (нотификации, ошибки, варнинги Roblox) пишутся в файл " ..
              "«" .. LOG_PATH .. "» в папке workspace инжектора. Файл переписывается на " ..
              "диск ПОСЛЕ КАЖДОЙ записи — даже если Roblox крашнет, последние 500 строк " ..
              "сохранятся.\n\n" ..
              "Если игра падает — открой файл в Блокноте и посмотри последние строки. " ..
              "Там будет видно, какая операция / нотификация была последней перед смертью."
})

SettingsTab:CreateButton({
    Name = "📋 Скопировать путь к логу",
    Description = "В буфер обмена попадёт путь, который можно вставить в проводник.",
    Callback = function()
        if setclipboard then
            pcall(setclipboard, LOG_PATH)
            notify("Путь скопирован: " .. LOG_PATH, 3, "success")
        else
            notify("Executor не поддерживает setclipboard", 3, "warn")
        end
    end
})

SettingsTab:CreateButton({
    Name = "🧪 Тест Discord webhook",
    Description = "Шлёт пробное сообщение. Покажет статус-код в нотификации.",
    Callback = function()
        if not Log.WH.request then
            notify("❌ Executor не поддерживает HTTP request", 5, "error")
            lunaLog("ERROR", "webhook test: no httpRequest API available")
            return
        end
        if not WEBHOOK_URL or WEBHOOK_URL == "" then
            notify("❌ WEBHOOK_URL не задан в скрипте", 5, "error")
            return
        end
        notify("Шлю тестовое сообщение...", 2)
        task.spawn(function()
            local body = Log.WH.encode({
                username = "Luna Hub Test",
                content  = "🧪 Тест webhook от " .. (LocalPlayer and LocalPlayer.Name or "?")
                    .. " в `" .. tostring(game.Name) .. "` ("
                    .. os.date("%H:%M:%S") .. ")",
            })
            local ok, info = Log.rawPost(WEBHOOK_URL, body)
            if ok then
                notify("✅ Webhook работает! HTTP " .. tostring(info), 4, "success")
                lunaLog("INFO", "webhook test OK: HTTP " .. tostring(info))
            else
                notify("❌ Webhook упал: " .. tostring(info), 6, "error")
                lunaLog("ERROR", "webhook test FAIL: " .. tostring(info))
            end
        end)
    end
})

SettingsTab:CreateButton({
    Name = "📸 Скриншот → Discord",
    Description = "Снимает экран и отправляет в Discord. Требует executor с screenshot() API.",
    Callback = function()
        if not Log.WH.request then
            notify("❌ Executor не поддерживает HTTP request", 5, "error")
            return
        end
        notify("Делаю скриншот...", 2)
        task.spawn(function()
            local ok, info = Log.sendScreenshot(
                ("📸 Снимок от **%s** в `%s` (%s)"):format(
                    LocalPlayer and LocalPlayer.Name or "?",
                    tostring(game.Name),
                    os.date("%H:%M:%S")))
            if ok then
                notify("✅ Скриншот отправлен в Discord! HTTP " .. tostring(info), 4, "success")
                lunaLog("INFO", "screenshot sent: HTTP " .. tostring(info))
            else
                notify("❌ " .. tostring(info), 6, "error")
                lunaLog("WARN", "screenshot fail: " .. tostring(info))
            end
        end)
    end
})

SettingsTab:CreateParagraph({
    Title = "Про скриншоты",
    Text  = "Roblox НЕ предоставляет API скриншотов LocalScript'ам. Эту фичу " ..
            "может предоставить только сам инжектор через глобальную функцию " ..
            "screenshot() (или Screenshot/saveScreenshot/captureScreenshot).\n\n" ..
            "Поддерживают: Wave, Fluxus (новые билды).\n" ..
            "НЕ поддерживают: Synapse, Krnl, AWP, Solara — там кнопка вернёт " ..
            "«executor не предоставляет API для скриншотов»."
})

SettingsTab:CreateDivider()
SettingsTab:CreateSection("Discord Bot Remote")

SettingsTab:CreateParagraph({
    Title = "Управление из Discord",
    Text  = "Если в начале скрипта заполнить DISCORD_BOT_TOKEN / CHANNEL_ID / USER_ID, " ..
            "скрипт будет читать команды из приватного канала Discord. Команды " ..
            "выполняются ТОЛЬКО на ЭТОМ клиенте (твой собственный) и ТОЛЬКО от " ..
            "твоего user_id.\n\n" ..
            "Команды: `!ping`, `!status`, `!farm on/off`, `!boss on/off`, " ..
            "`!screenshot`, `!screamer`, `!unload`, `!help`."
})

SettingsTab:CreateButton({
    Name = "😱 Тест скримера (только мой экран)",
    Description = "Показывает скример НА ТВОЁМ клиенте чтобы проверить что он работает. Никуда не отправляется.",
    Callback = function()
        DiscordBot.playScreamer()
        notify("Скример показан", 2)
    end
})

SettingsTab:CreateButton({
    Name = "🗑 Очистить лог-файл",
    Description = "Сбрасывает буфер и переписывает файл пустым.",
    Callback = function()
        Log.clearBuffer()
        lunaLog("INFO", "log cleared by user")
        notify("Лог очищен", 2, "success")
    end
})

SettingsTab:CreateButton({
    Name = "💾 Записать снимок состояния",
    Description = "Дамп текущих переменных скрипта в лог. Полезно перед крашем.",
    Callback = function()
        lunaLog("DUMP", "===== STATE SNAPSHOT =====")
        lunaLog("DUMP", "sp_enabled="     .. tostring(sp_enabled))
        lunaLog("DUMP", "sp_bossEnabled=" .. tostring(sp_bossEnabled))
        lunaLog("DUMP", "godModeEnabled=" .. tostring(godModeEnabled))
        lunaLog("DUMP", "godMode2Enabled=" .. tostring(godMode2Enabled))
        lunaLog("DUMP", "sp_questNpc='"   .. tostring(sp_questNpcName) .. "'")
        lunaLog("DUMP", "sp_mob='"        .. tostring(sp_mobBaseName) .. "'")
        lunaLog("DUMP", "sp_bossQueue=["  .. table.concat(sp_bossQueue or {}, ", ") .. "]")
        lunaLog("DUMP", "sp_currentMob="  .. (sp_currentMob and sp_currentMob.Name or "nil"))
        lunaLog("DUMP", "#NPCs folder="   .. tostring(workspace:FindFirstChild("NPCs") and #workspace.NPCs:GetChildren() or "no folder"))
        lunaLog("DUMP", "#ServiceNPCs="   .. tostring(workspace:FindFirstChild("ServiceNPCs") and #workspace.ServiceNPCs:GetChildren() or "no folder"))
        lunaLog("DUMP", "==========================")
        notify("Снимок записан в лог", 2, "success")
    end
})

-- ====================================================
-- Управление скриптом
-- ====================================================
SettingsTab:CreateDivider()
SettingsTab:CreateSection("Управление скриптом")

SettingsTab:CreateButton({
    Name = "Полностью выгрузить скрипт",
    Description = "Снимет все хуки, удалит UI и вернёт игру в исходное состояние.",
    Callback = function() if _G.LunaUnload then _G.LunaUnload() end end
})

SettingsTab:CreateParagraph({
    Title = "Статус",
    Text = "Загружен  |  Игра: " .. game.Name .. "  |  PlaceId: " .. tostring(game.PlaceId)
})

-- Подгружаем автозагружаемый конфиг (если игрок назначил его в BuildConfigSection)
pcall(function() Luna:LoadAutoloadConfig() end)

--========================================================
-- ⚠ EXPERIMENTAL TAB — Kill Aura
--========================================================
-- Старые попытки one-shot убраны (HP-zero / Remote spam / Void kick) —
-- ничего из этого в Sailor Piece не работает.
--
-- Kill Aura работает иначе: вместо попытки нанести damage напрямую,
-- мы заставляем СЕРВЕР засчитать твои СОБСТВЕННЫЕ удары как попадание.
-- Идея простая:
--   1) Каждый кадр находим всех живых мобов в радиусе X
--   2) Подтягиваем их HRP к нашему персонажу через CFrame
--   3) Спамим Tool:Activate (твой обычный удар)
--   4) Сервер видит легитимный твой удар + моба впритык → засчитывает урон
--
-- В Sailor Piece это работает потому что combat-handler проверяет
-- "цель в radius твоего удара" — и да, она в радиусе, потому что мы её
-- сами туда подтащили. Никакой попытки записать damage напрямую.

ExpTab:CreateParagraph({
    Title = "⚠ Kill Aura",
    Text = "Подтягивает живых мобов в радиусе к тебе и спамит твой обычный удар. Сервер не видит подвоха — ты бьёшь как обычно, моб сам внезапно оказывается рядом.\n\n" ..
              "Включи + экипируй любое оружие/стиль + стой на одном месте → всё что в радиусе будет молотиться твоим текущим оружием. На боссах работает с тем же DPS что и ручной auto-clicker."
})

local exp_killAuraEnabled = false
local exp_killAuraRadius  = 60         -- радиус в студах
local exp_killAuraDelay   = 0.10       -- между Activate (раз в 100 ms по умолчанию)
local exp_includeBosses   = true       -- бить и боссов?
local exp_includePlayers  = false      -- бить других игроков? (PvP-режим)

local _exp_auraConn
local _exp_auraLastClick = 0

-- Кэш: набор моделей которые мы уже подтянули в этом кадре, чтобы не
-- передвигать одного и того же моба несколько раз
local _exp_auraTargets = {}

-- Утилита: проверка что моб живой и валиден для kill aura
local function _spIsValidAuraTarget(model)
    if not model or not model.Parent then return false end
    if not model:IsA("Model") then return false end
    local hum = model:FindFirstChildOfClass("Humanoid")
    if not hum or hum.Health <= 0 then return false end
    -- Не бьём своего персонажа :)
    if model == safeGetCharacter() then return false end
    return true
end

-- Сбор всех целей в радиусе одним проходом по workspace.NPCs (+ Players)
local function _exp_collectAuraTargets(myPos, radius)
    local r2 = radius * radius
    table.clear(_exp_auraTargets)

    -- Мобы из workspace.NPCs
    local npcsFolder = workspace:FindFirstChild("NPCs")
    if npcsFolder then
        for _, m in ipairs(npcsFolder:GetChildren()) do
            if _spIsValidAuraTarget(m) then
                local pos = spModelPos(m)
                if pos then
                    local dx = pos.X - myPos.X
                    local dy = pos.Y - myPos.Y
                    local dz = pos.Z - myPos.Z
                    if (dx*dx + dy*dy + dz*dz) <= r2 then
                        -- Если режим "не бить боссов" — фильтруем
                        if exp_includeBosses or not _spLooksLikeBoss(m,
                            m:FindFirstChildOfClass("Humanoid")) then
                            table.insert(_exp_auraTargets, m)
                        end
                    end
                end
            end
        end
    end

    -- Игроки (опционально, для PvP)
    if exp_includePlayers then
        for _, p in ipairs(Players:GetPlayers()) do
            if p ~= LocalPlayer and p.Character then
                local m = p.Character
                if _spIsValidAuraTarget(m) then
                    local hrp = m:FindFirstChild("HumanoidRootPart")
                    if hrp then
                        local dx = hrp.Position.X - myPos.X
                        local dy = hrp.Position.Y - myPos.Y
                        local dz = hrp.Position.Z - myPos.Z
                        if (dx*dx + dy*dy + dz*dz) <= r2 then
                            table.insert(_exp_auraTargets, m)
                        end
                    end
                end
            end
        end
    end
end

local function _exp_stopKillAura()
    if _exp_auraConn then _exp_auraConn:Disconnect(); _exp_auraConn = nil end
    table.clear(_exp_auraTargets)
end

local function _exp_startKillAura()
    _exp_stopKillAura()
    _exp_auraConn = RunService.Heartbeat:Connect(function()
        if not exp_killAuraEnabled then _exp_stopKillAura(); return end

        local char = safeGetCharacter()
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local myPos = hrp.Position
        _exp_collectAuraTargets(myPos, exp_killAuraRadius)
        if #_exp_auraTargets == 0 then return end

        -- Подтягиваем КАЖДОГО найденного моба прямо к себе.
        -- Размещаем их по дуге вокруг персонажа на расстоянии 4 ст. — близко
        -- но не совсем впритык, чтобы коллизия не толкала тебя.
        local count = #_exp_auraTargets
        local r = 4   -- радиус "круга" вокруг тебя
        for i, m in ipairs(_exp_auraTargets) do
            local angle = (i / count) * math.pi * 2
            local offset = Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
            local mobHrp = m:FindFirstChild("HumanoidRootPart")
                or m:FindFirstChild("Torso") or m.PrimaryPart
            if mobHrp then
                pcall(function()
                    -- Снимаем Anchored если был
                    if mobHrp.Anchored then mobHrp.Anchored = false end
                    mobHrp.CFrame = CFrame.new(myPos + offset)
                    mobHrp.AssemblyLinearVelocity = Vector3.zero
                end)
            end
        end

        -- Спамим Tool:Activate. Без этого моб просто стоит впритык, никто его
        -- не бьёт. Этот же путь использует sp_attackDelay автоматически — но
        -- мы тут используем свой, более агрессивный (0.10с по умолчанию).
        local now = tick()
        if now - _exp_auraLastClick >= exp_killAuraDelay then
            _exp_auraLastClick = now

            local tool = char:FindFirstChildOfClass("Tool")
            if tool and tool.Parent == char and tool:FindFirstChild("Handle") then
                pcall(function() tool:Activate() end)
            end
        end
    end)
    track(_exp_auraConn)
end

ExpTab:CreateSection("⚔ Kill Aura")
ExpTab:CreateToggle({
    Name = "Kill Aura (подтягивать мобов + спам удара)",
    CurrentValue = false,
    Callback = function(v)
        exp_killAuraEnabled = v
        if v then _exp_startKillAura() else _exp_stopKillAura() end
    end
}, "exp_killAura")
ExpTab:CreateSlider({
    Name = "Радиус ауры (ст.)",
    Range = { 10, 200 },
    Increment = 5,

    CurrentValue = exp_killAuraRadius,
    Callback = function(v) exp_killAuraRadius = v end
}, "exp_killAuraRadius")
ExpTab:CreateSlider({
    Name = "Задержка между ударами (сек)",
    Range = { 0.05, 1.0 },
    Increment = 0.05,

    CurrentValue = exp_killAuraDelay,
    Callback = function(v) exp_killAuraDelay = v end
}, "exp_killAuraDelay")
ExpTab:CreateToggle({
    Name = "Бить и боссов",
    CurrentValue = exp_includeBosses,
    Callback = function(v) exp_includeBosses = v end
}, "exp_includeBosses")
ExpTab:CreateToggle({
    Name = "Бить других игроков (PvP)",
    CurrentValue = false,
    Callback = function(v) exp_includePlayers = v end
}, "exp_includePlayers")

ExpTab:CreateParagraph({
    Title = "Как пользоваться",
    Text = "1. Экипируй оружие (любое — катана, фрукт, стиль)\n" ..
              "2. Включи Kill Aura\n" ..
              "3. Стой и не двигайся\n\n" ..
              "Все живые мобы в радиусе будут стянуты к тебе и получат твои удары. Радиус 60 ст. — золотая середина: достаточно чтобы зацепить толпу, но не настолько большой что сервер увидит «как ты бьёшь моба за 100 ст.»."
})

ExpTab:CreateDivider()

-- ====================================================
-- 🎯 Single Target Magnet (для боссов которые убегают)
-- ====================================================
-- То же что Kill Aura, но только на ОДНОЙ цели — текущей sp_currentMob.
-- Этот вариант полезен для боссов с механикой телепорта или быстрого бега:
-- авто-фарм бьёт sp_currentMob, а магнит не даёт боссу убежать.
local exp_magnetEnabled = false
local _exp_magnetConn

local function _exp_stopMagnet()
    if _exp_magnetConn then _exp_magnetConn:Disconnect(); _exp_magnetConn = nil end
end

local function _exp_startMagnet()
    _exp_stopMagnet()
    _exp_magnetConn = RunService.Heartbeat:Connect(function()
        if not exp_magnetEnabled then _exp_stopMagnet(); return end

        local char = safeGetCharacter()
        local hrp  = char and char:FindFirstChild("HumanoidRootPart")
        if not hrp then return end

        local mob = sp_currentMob
        if not mob or not mob.Parent then return end
        local mobHrp = mob:FindFirstChild("HumanoidRootPart")
            or mob:FindFirstChild("Torso") or mob.PrimaryPart
        if not mobHrp then return end

        pcall(function()
            if mobHrp.Anchored then mobHrp.Anchored = false end
            -- Подтягиваем моба к тебе на 3 ст. перед лицом
            local front = hrp.CFrame.LookVector * 3
            mobHrp.CFrame = CFrame.new(hrp.Position + front)
            mobHrp.AssemblyLinearVelocity = Vector3.zero
        end)
    end)
    track(_exp_magnetConn)
end

ExpTab:CreateSection("🎯 Magnet (только текущая цель)")
ExpTab:CreateToggle({
    Name = "Magnet — притянуть босса к лицу",
    CurrentValue = false,
    Callback = function(v)
        exp_magnetEnabled = v
        if v then _exp_startMagnet() else _exp_stopMagnet() end
    end
}, "exp_magnet")
ExpTab:CreateParagraph({
    Title = "Когда использовать",
    Text = "Включай вместе с обычным авто-фармом или Boss-фармом. Полезно когда босс телепортируется или бегает быстрее тебя. Magnet держит его в 3 ст. перед твоим лицом — твои удары всегда попадают.\n\nНа боссах с Anchored=true сервером может не сработать."
})

ExpTab:CreateDivider()
ExpTab:CreateButton({
    Name = "🛑 Выключить ВСЁ экспериментальное",
    Callback = function()
        exp_killAuraEnabled = false
        exp_magnetEnabled = false
        _exp_stopKillAura()
        _exp_stopMagnet()
        notify("[Exp] Всё выключено")
    end
})

ExpTab:CreateParagraph({
    Title = "Почему это работает",
    Text = "В отличие от прошлых попыток (HP-zero, Remote spam, Void kick — все были заблокированы серверной валидацией), этот метод не пытается подделать damage. Он просто заставляет твои СОБСТВЕННЫЕ удары попасть. Сервер видит легитимного игрока с легитимным оружием → урон засчитывается.\n\nЕдинственный риск — серверный анти-чит может заметить «моб телепортируется к игроку каждый кадр». Если получишь кик — увеличь задержку и уменьши радиус."
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
    -- Experimental: гасим все циклы Kill Aura
    exp_killAuraEnabled = false
    exp_magnetEnabled = false
    pcall(_exp_stopKillAura); pcall(_exp_stopMagnet)

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
    pcall(function() Luna:Destroy() end)

    -- Зачищаем блюр-артефакты Luna (3D-плоскости в Camera.LunaBlur + DOF в Lighting)
    pcall(function()
        local cam = workspace.CurrentCamera
        if cam then
            local blur = cam:FindFirstChild("LunaBlur")
            if blur then blur:Destroy() end
        end
        for _, d in ipairs(game:GetService("Lighting"):GetChildren()) do
            if d:IsA("DepthOfFieldEffect") and d.Name:sub(1, 4) == "DPT_" then
                d:Destroy()
            end
        end
    end)

    _G.LunaWindowGui = nil
    _G.LunaHubLoaded = false
    lunaLog("INFO", "===== LUNA HUB UNLOAD =====")
    Log.flush()
end

-- ====================================================
-- BindToClose: финальный flush лога перед выгрузкой клиента
-- ====================================================
-- Если игра вылетает по своей воле (Player:Kick, рестарт сервера) — Roblox
-- даёт до 30 секунд через game:BindToClose. Используем шанс записать лог.
pcall(function()
    if game.BindToClose then
        game:BindToClose(function()
            lunaLog("INFO", "===== game:BindToClose fired =====")
            Log.flush()
        end)
    end
end)

-- В прошлой версии был кастомный JSON-конфиг, его роль теперь
-- закрывает встроенный BuildConfigSection (см. ниже в Settings).

-- ====================================================
-- Страховочный UIS-хендлер для toggle UI (RightControl)
-- ====================================================
-- Luna имеет свой keybind, но если он залипнет после ручного :SetVisibility,
-- этот fallback-слушатель всегда работает напрямую через UserInputService.
do
    local debounce = 0
    track(UIS.InputBegan:Connect(function(input, gameProcessed)
        if gameProcessed then return end
        if input.KeyCode ~= Enum.KeyCode.RightControl then return end
        local now = tick()
        if now - debounce < 0.15 then return end
        debounce = now
        pcall(function()
            lunaSetVisibility(not lunaIsVisible())
        end)
    end))
end

-- Убираем splash через 2.2 сек (совпадает с финишем анимации прогресс-бара)
task.delay(4.4, function() pcall(destroySplash) end)

notify(("Найдено: NPC %d  |  Мобов %d  |  Боссов %d"):format(
    #sp_npcChoices, #sp_mobChoices, #sp_bossChoices), 4, "success")
notify("RightCtrl — открыть/закрыть меню", 5)
if Log.hasIO() then
    notify("Лог пишется в файл: " .. LOG_PATH, 6)
end
lunaLog("INFO", "===== READY (game ready, ui built) =====")
print("[Luna] ready | game: " .. game.Name)
_G.LunaHubLoaded = true
end)()
