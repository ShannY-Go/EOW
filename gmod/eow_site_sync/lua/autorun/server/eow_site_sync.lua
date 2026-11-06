--[[
    Eclipse of War — синхронизация игрового сервера с сайтом eclipseofwar.com

    Сервер САМ отправляет данные персонажей на сервер сайта (Cloudflare Worker). Снаружи к базе
    игрового сервера никто не подключается, пароли от БД никуда не уходят.

    Установка:
      1) Папку eow_site_sync положить в garrysmod/addons/
      2) В server.cfg добавить (ключ — тот же, что в секрете GAME_SYNC_KEY воркера, или LOGS_INGEST_KEY):
             eow_site_sync_key "ВАШ_ДЛИННЫЙ_КЛЮЧ"
         Ключ НЕ коммитьте в репозиторий и не пишите в чат.
      3) Перезапустить сервер. В консоли сервера: eow_site_sync_now — отправить данные сразу.

    Откуда берутся персонажи (по порядку):
      а) хук  EOWSite_GetCharacters(ply)  → вернуть таблицу персонажей (лучший вариант: из своей системы персонажей)
      б) SQL-запрос из EOW_SITE.SQL (sv.db / SQLite), если включён
      в) запасной вариант — текущий персонаж игрока по данным на сервере (ник, профессия/команда, фраги)

    Формат персонажа:
      { id = "1", name = "CT | 1234 | Lork", rank = "SGT", unit = "assault", unitTitle = "Штурмовой Корпус",
        profession = "Пулемётчик", level = 42, xp = 1234, credits = 18450, playtime = 532800 (сек),
        kills = 412, deaths = 50, reputation = 92, reprimands = 0, joined = os.time() }
    unit — ключ подразделения сайта: assault, recon, medical, engineering, coruscant_guard, aviation
           или любой другой ключ латиницей (например "merc_69th").

    Донат-баланс: хук  EOWSite_GetDonate(ply)  → число (или EOW_SITE.SQL.donateQuery).
]]

EOW_SITE = EOW_SITE or {}

EOW_SITE.API      = "https://eow-auth.shanny-games-yt.workers.dev/api/game/sync"
EOW_SITE.INTERVAL = 180     -- как часто отправлять данные онлайн-игроков, сек
EOW_SITE.DEBUG    = false

-- Профессия / команда (team) → подразделение сайта
EOW_SITE.UNIT_BY_TEAM = {
    -- ["Штурмовик"]        = "assault",
    -- ["Разведчик ARF"]    = "recon",
    -- ["Медик"]            = "medical",
    -- ["Инженер"]          = "engineering",
    -- ["Корусантская гвардия"] = "coruscant_guard",
    -- ["Пилот"]            = "aviation",
}
EOW_SITE.UNIT_TITLES = {
    assault = "Штурмовой Корпус", recon = "Разведывательный Корпус (ARF)", medical = "Медицинский Корпус",
    engineering = "Инженерный Корпус", coruscant_guard = "Корусантская Гвардия", aviation = "Пилотный Корпус ВКС",
}

-- Чтение из базы сервера (SQLite sv.db). %s подставляется как SteamID64 (уже экранированный).
EOW_SITE.SQL = {
    enabled = false,
    -- пример: SELECT id, name, rank, unit, level, xp, money, playtime FROM characters WHERE steamid = %s
    charactersQuery = "",
    -- какие колонки результата во что превращать
    columns = { id = "id", name = "name", rank = "rank", unit = "unit", unitTitle = "unit_title", profession = "profession",
                level = "level", xp = "xp", credits = "money", playtime = "playtime", kills = "kills", deaths = "deaths",
                reputation = "reputation", reprimands = "reprimands", joined = "created_at" },
    donateQuery = "",       -- пример: SELECT balance FROM donate WHERE steamid = %s
}

local keyCvar = CreateConVar("eow_site_sync_key", "", bit.bor(FCVAR_ARCHIVE, FCVAR_PROTECTED, FCVAR_DONTRECORD), "Ключ синхронизации с сайтом")

local function log(...) if EOW_SITE.DEBUG then print("[EOW Site]", ...) end end

-- ---------- собственный учёт наигранного времени (если в вашей системе его нет) ----------
sql.Query("CREATE TABLE IF NOT EXISTS eow_site_playtime (steamid TEXT PRIMARY KEY, seconds INTEGER NOT NULL DEFAULT 0, first_seen INTEGER NOT NULL DEFAULT 0)")
local joinedAt = {}
local function storedPlaytime(sid)
    local r = sql.QueryRow("SELECT seconds, first_seen FROM eow_site_playtime WHERE steamid = " .. sql.SQLStr(sid))
    return r and tonumber(r.seconds) or 0, r and tonumber(r.first_seen) or 0
end
local function flushPlaytime(ply)
    local sid = ply:SteamID64(); if not sid or not joinedAt[sid] then return end
    local add = math.max(0, math.floor(CurTime() - joinedAt[sid])); joinedAt[sid] = CurTime()
    sql.Query(string.format("INSERT INTO eow_site_playtime (steamid, seconds, first_seen) VALUES (%s, %d, %d) ON CONFLICT(steamid) DO UPDATE SET seconds = seconds + %d",
        sql.SQLStr(sid), add, os.time(), add))
end
local function playtimeOf(ply)
    local sid = ply:SteamID64()
    local sec, first = storedPlaytime(sid)
    if joinedAt[sid] then sec = sec + math.floor(CurTime() - joinedAt[sid]) end
    return sec, (first > 0 and first or os.time())
end

-- ---------- сбор данных ----------
local function unitFor(name)
    local key = EOW_SITE.UNIT_BY_TEAM[name or ""]
    if key then return key, EOW_SITE.UNIT_TITLES[key] or name end
    if name and name ~= "" then return "div:" .. string.lower(name), name end
    return "", ""
end

local function fromSQL(ply)
    local cfg = EOW_SITE.SQL
    if not cfg.enabled or cfg.charactersQuery == "" then return nil end
    local rows = sql.Query(string.format(cfg.charactersQuery, sql.SQLStr(ply:SteamID64())))
    if rows == false then print("[EOW Site] Ошибка SQL: " .. tostring(sql.LastError())) return nil end
    local out = {}
    for _, r in ipairs(rows or {}) do
        local c = {}
        for field, col in pairs(cfg.columns) do c[field] = r[col] end
        if c.unit == nil or c.unit == "" then c.unit, c.unitTitle = unitFor(c.unitTitle or c.profession) end
        out[#out + 1] = c
    end
    return out
end

local function fallbackCharacter(ply)
    local teamName = team.GetName(ply:Team())
    local unit, unitTitle = unitFor(teamName)
    local playtime, first = playtimeOf(ply)
    local money = (ply.getDarkRPVar and ply:getDarkRPVar("money")) or ply:GetNWInt("money", 0)
    return {{
        id = "main", name = ply:Nick(), rank = ply:GetNWString("rank", ""), unit = unit, unitTitle = unitTitle,
        profession = teamName, level = ply:GetNWInt("level", 0), xp = ply:GetNWInt("xp", 0), credits = money,
        playtime = playtime, kills = ply:Frags(), deaths = ply:Deaths(), joined = first,
    }}
end

local function collect(ply)
    local list = hook.Run("EOWSite_GetCharacters", ply) or fromSQL(ply) or fallbackCharacter(ply)
    local sid = ply:SteamID64()
    for _, c in ipairs(list) do
        c.steamid = sid
        c.id = tostring(c.id or "main")
        if c.playtime == nil then c.playtime = playtimeOf(ply) end
    end
    local donate = hook.Run("EOWSite_GetDonate", ply)
    if donate == nil and EOW_SITE.SQL.donateQuery ~= "" then
        local v = sql.QueryValue(string.format(EOW_SITE.SQL.donateQuery, sql.SQLStr(sid)))
        donate = tonumber(v)
    end
    return list, donate
end

-- ---------- отправка ----------
local function send(players)
    local key = keyCvar:GetString()
    if key == "" then print("[EOW Site] Не задан eow_site_sync_key — синхронизация выключена") return end
    local payload = { characters = {}, accounts = {}, replace = {} }
    for _, ply in ipairs(players) do
        if IsValid(ply) and not ply:IsBot() then
            local ok, list, donate = pcall(collect, ply)
            if ok then
                for _, c in ipairs(list) do payload.characters[#payload.characters + 1] = c end
                payload.replace[#payload.replace + 1] = ply:SteamID64()
                if donate ~= nil then payload.accounts[#payload.accounts + 1] = { steamid = ply:SteamID64(), donate = donate } end
            else
                print("[EOW Site] Ошибка сбора данных " .. ply:Nick() .. ": " .. tostring(list))
            end
        end
    end
    if #payload.replace == 0 then return end
    HTTP({
        url = EOW_SITE.API, method = "POST", type = "application/json",
        headers = { Authorization = "Bearer " .. key },
        body = util.TableToJSON(payload),
        success = function(code, body) if code ~= 200 then print("[EOW Site] Сайт ответил " .. code .. ": " .. tostring(body)) else log("ok", body) end end,
        failed = function(err) print("[EOW Site] Не удалось связаться с сайтом: " .. tostring(err)) end,
    })
end
EOW_SITE.Send = send

hook.Add("PlayerInitialSpawn", "EOWSite_Join", function(ply)
    joinedAt[ply:SteamID64() or ""] = CurTime()
    timer.Simple(15, function() if IsValid(ply) then send({ ply }) end end)
end)
hook.Add("PlayerDisconnected", "EOWSite_Leave", function(ply)
    flushPlaytime(ply)
    send({ ply })
    joinedAt[ply:SteamID64() or ""] = nil
end)
hook.Add("ShutDown", "EOWSite_Shutdown", function() for _, ply in ipairs(player.GetHumans()) do flushPlaytime(ply) end end)

timer.Create("EOWSite_Sync", EOW_SITE.INTERVAL, 0, function()
    for _, ply in ipairs(player.GetHumans()) do flushPlaytime(ply) end
    local all = player.GetHumans()
    for i = 1, #all, 40 do send({ unpack(all, i, math.min(i + 39, #all)) }) end   -- пачками по 40 игроков
end)

concommand.Add("eow_site_sync_now", function(ply)
    if IsValid(ply) and not ply:IsSuperAdmin() then return end
    send(player.GetHumans())
    print("[EOW Site] Отправка данных запущена")
end)

print("[EOW Site] Синхронизация с сайтом загружена")
