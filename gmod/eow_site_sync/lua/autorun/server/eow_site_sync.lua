--[[
    Eclipse of War — синхронизация игрового сервера с сайтом eclipseofwar.com  (v2)

    Что делает:
      Сервер сам читает свою базу (MySQL через MySQLite геймода) и отправляет на сервер сайта
      (Cloudflare Worker) персонажей игроков и баланс доната. Снаружи к базе никто не подключается,
      пароль от базы никуда не уходит. На сайте игрок видит только своих персонажей (вход через Steam).

    Что уходит на сайт по каждому персонажу:
      имя и номер, звание, подразделение и специализация, должность, группа крови, уровень и опыт,
      кредиты, наигранное время, убийства NPC, урон, лечение, ремонт, операции, класс джедая,
      последний вход, в игре ли сейчас. Пароли, IP, история/цитата анкеты и инвентарь — НЕ уходят.

    Когда отправляется:
      - при старте сервера (через минуту после подключения к базе) — все персонажи из базы;
      - раз в час — все персонажи (уходят только изменившиеся аккаунты);
      - каждые 5 минут — игроки онлайн с живыми значениями текущего персонажа;
      - при входе и выходе игрока.

    Ключ:
      Берётся из уже настроенного аддона логов (lua/autorun/server/eow_site_logs.lua), отдельно задавать
      не нужно. Если в воркере задан отдельный секрет GAME_SYNC_KEY — впишите его в server.cfg:
          eow_site_sync_key "КЛЮЧ"
      Ключ не коммитьте в репозиторий и не пишите в чат.

    Консоль сервера (или суперадмин):
      eow_site_sync_now        — отправить игроков онлайн
      eow_site_sync_now full   — отправить всю базу персонажей
      eow_site_sync_status     — когда и сколько отправлено, последняя ошибка
]]

if not SERVER then return end

EOW_SITE = EOW_SITE or {}
local S = EOW_SITE

S.API             = "https://eow-auth.shanny-games-yt.workers.dev/api/game/sync"
S.ONLINE_INTERVAL = 300      -- игроки онлайн, сек
S.FULL_INTERVAL   = 3600     -- вся база, сек (уходят только изменившиеся аккаунты)
S.FORCE_EVERY     = 86400    -- раз в сутки отправить всё заново, даже без изменений
S.BATCH_ACCOUNTS  = 120      -- аккаунтов в одном запросе
S.BATCH_CHARS     = 400      -- персонажей в одном запросе (лимит сайта — 500)
S.DEBUG           = false

-- Подразделение игры → подразделение сайта (ключи сайта: assault, recon, medical, engineering,
-- coruscant_guard, aviation; остальные — свои, латиницей). Не указано — подразделение без ключа.
S.UNIT_BY_TEAM = {
    ["Кадет"]                   = "cadet",
    ["69-й общевойсковой полк"] = "assault",          -- уточняется специализацией ниже
    ["Медицинская рота"]        = "medical",
    ["Рота Военной Полиции"]    = "coruscant_guard",
    ["Пилотно-Инженерная рота"] = "engineering",
    ["Ударный Батальон"]        = "assault",
    ["Клан Д'Ксан"]             = "mando",
    ["Орден Джедаев"]           = "jedi",
    ["Ивент Профессия"]         = "event",
}
-- Специализация 69-го полка → подразделение сайта (остальные специализации — штурмовой корпус)
S.UNIT_BY_SPEC = {
    ["Медик"]   = "medical",
    ["Инженер"] = "engineering",
    ["R5-7R4P"] = "engineering",
    ["Пилот"]   = "aviation",
    ["ARF"]     = "recon",
}

local keyCvar = CreateConVar("eow_site_sync_key", "", bit.bor(FCVAR_PROTECTED, FCVAR_DONTRECORD), "Ключ синхронизации с сайтом (если не задан — берётся из аддона логов)")

local function log(...) if S.DEBUG then print("[EOW Site]", ...) end end
local function say(msg) print("[EOW Site] " .. msg) end

S.Stat = S.Stat or { sent = 0, chars = 0, requests = 0, lastOk = 0, lastErr = "", lastErrAt = 0, lastFull = 0 }
S.Sig = S.Sig or {}          -- SteamID64 → подпись последних успешно отправленных данных
S.SigReset = S.SigReset or os.time()

-- ---------------------------------------------------------------- ключ
local function getKey()
    local k = string.Trim(keyCvar:GetString() or "")
    if #k >= 16 then return k end
    local src = file.Read("lua/autorun/server/eow_site_logs.lua", "GAME") or file.Read("autorun/server/eow_site_logs.lua", "LUA")
    if src then
        local m = src:match("%f[%w_]key%s*=%s*\"([^\"]+)\"")
        if m and #m >= 16 and not m:find("KEY__", 1, true) then return m end
    end
    return ""
end

-- ---------------------------------------------------------------- база
local function dbReady() return MySQLite and MySQLite.query and true or false end

-- запрос; cb(rows) — rows == nil при ошибке (например, таблицы ещё нет)
local function q(text, cb, quiet)
    MySQLite.query(text, function(rows) cb(rows or {}) end, function(err)
        if not quiet then say("Ошибка запроса к базе: " .. tostring(err)) end
        cb(nil)
    end)
end
local function Q(v) return MySQLite.SQLStr(v) end

local function inList(vals)
    local t = {}
    for i, v in ipairs(vals) do t[i] = Q(v) end
    return table.concat(t, ",")
end

local function sid64Of(steamId, communityId)
    local c = tostring(communityId or "")
    if c:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then return c end
    local s = tostring(steamId or "")
    if s:match("^STEAM_%d:%d:%d+$") then
        local v = util.SteamIDTo64(s)
        if v and v:match("^7656119%d%d%d%d%d%d%d%d%d%d$") then return v end
    end
    return nil
end

local function json(s)
    if not isstring(s) or s == "" then return {} end
    local ok, t = pcall(util.JSONToTable, s)
    return ok and istable(t) and t or {}
end

-- Загрузка из базы. sids2 — список SteamID (STEAM_0:...) или nil = вся база.
-- cb(data) — data == nil, если основная таблица недоступна.
local function load(sids2, cb)
    local where = sids2 and (" WHERE steam_id IN (" .. inList(sids2) .. ")") or ""
    q("SELECT id, steam_id, community_id, player FROM nwt_p_data" .. where .. ";", function(accs)
        if not accs then return cb(nil) end
        local data = { accounts = accs, chars = {}, progress = {}, money = {}, profile = {}, donate = {}, seen = {} }
        if #accs == 0 then return cb(data) end
        local pids = {}
        for _, a in ipairs(accs) do pids[#pids + 1] = tonumber(a.id) end
        local charWhere = sids2 and (" WHERE player_id IN (" .. inList(pids) .. ")") or ""
        q("SELECT character_id, player_id, character_name, rpid, ranking, team_id, pripiska FROM nwt_characters" .. charWhere .. ";", function(chars)
            if not chars then return cb(nil) end
            data.chars = chars
            local ids = {}
            for _, c in ipairs(chars) do ids[#ids + 1] = tonumber(c.character_id) end
            local idWhere = sids2 and (#ids > 0 and (" WHERE character_id IN (" .. inList(ids) .. ")") or " WHERE 1 = 0") or ""

            local pending = 5
            local function done() pending = pending - 1 if pending == 0 then cb(data) end end
            q("SELECT character_id, data FROM nwt_char_progress" .. idWhere .. ";", function(r)
                for _, x in ipairs(r or {}) do data.progress[tonumber(x.character_id) or -1] = x.data end done()
            end, true)
            q("SELECT character_id, money FROM nwt_char_money" .. idWhere .. ";", function(r)
                for _, x in ipairs(r or {}) do data.money[tonumber(x.character_id) or -1] = tonumber(x.money) end done()
            end, true)
            q("SELECT character_id, data FROM nwt_char_profile" .. idWhere .. ";", function(r)
                for _, x in ipairs(r or {}) do data.profile[tonumber(x.character_id) or -1] = x.data end done()
            end, true)
            q("SELECT steam_id, amount FROM nwt_p_donate" .. where .. ";", function(r)
                for _, x in ipairs(r or {}) do data.donate[tostring(x.steam_id)] = tonumber(x.amount) end done()
            end, true)
            q("SELECT steam_id, last_seen FROM nwt_p_seen" .. where .. ";", function(r)
                for _, x in ipairs(r or {}) do data.seen[tostring(x.steam_id)] = tonumber(x.last_seen) end done()
            end, true)
        end)
    end)
end

-- ---------------------------------------------------------------- сборка
local function clean(s, n)
    s = string.Trim(tostring(s or ""))
    s = s:gsub("'", "’"):gsub("[%c<>\"`\\]", "")      -- апостроф сайт вырезает, типографский — оставляет
    return n and utf8 and utf8.len(s) and utf8.len(s) > n and s:sub(1, utf8.offset(s, n + 1) - 1) or s
end

local function teamNameOf(teamId)
    local n = tonumber(teamId)
    local job = nwt and ((nwt.jobs_by_id and nwt.jobs_by_id[teamId]) or (n and nwt.jobs_by_index and nwt.jobs_by_index[n]))
    local name = job and (job.Name or (job.index and team.GetName(job.index))) or (n and team.GetName(n)) or ""
    name = string.Trim(tostring(name or ""))
    if name == "Unassigned" then name = "" end
    return name
end

local function unitKeyOf(teamName, spec)
    local key = S.UNIT_BY_TEAM[teamName]
    if key == "assault" and S.UNIT_BY_SPEC[spec] then key = S.UNIT_BY_SPEC[spec] end
    return key or ""
end

local function jediClassName(id)
    local P = FUSION and FUSION.Progress
    for _, c in ipairs(P and P.JediClasses or {}) do if c.id == id then return c.name end end
    return isstring(id) and id or nil
end

local function num(v) return math.max(0, math.floor(tonumber(v) or 0)) end

-- живые значения персонажа, которым игрок играет прямо сейчас
local function liveFor(ply, id)
    local live = {}
    if not IsValid(ply) then return live end
    local P = FUSION and FUSION.Progress
    if P and ply.fusionProgressLoaded and tonumber(ply.fusionProgressCharId) == id then
        local st = P.GetState(ply) or {}
        live.progress = { level = P.GetLevel(ply), xp = P.GetXP(ply), stats = st.stats, jediClass = st.jediClass }
    end
    if ply.eowMoneyLoaded and tonumber(ply.eowMoneyChar) == id and ply.GetMoney then live.money = ply:GetMoney() end
    if istable(ply.fusionProfile) and tonumber(ply.fusionProfileCharId) == id then live.profile = ply.fusionProfile end
    live.current = tonumber(ply:GetNVar("nwt_character")) == id
    return live
end

-- data из load() → список аккаунтов { sid64, chars = {...}, donate }
local function build(data)
    local online = {}
    for _, p in ipairs(player.GetHumans()) do online[p:SteamID64() or ""] = p end

    local byPid = {}
    for _, a in ipairs(data.accounts) do
        local sid64 = sid64Of(a.steam_id, a.community_id)
        if sid64 then
            byPid[tonumber(a.id) or -1] = { sid64 = sid64, sid2 = tostring(a.steam_id or ""), chars = {},
                donate = data.donate[tostring(a.steam_id or "")] or 0,      -- нет записи — баланс 0
                seen = data.seen[tostring(a.steam_id or "")] }
        end
    end

    for _, c in ipairs(data.chars) do
        local acc = byPid[tonumber(c.player_id) or -2]
        local id = tonumber(c.character_id)
        if acc and id then
            local ply = online[acc.sid64]
            local live = liveFor(ply, id)
            local prog = live.progress or json(data.progress[id])
            local stats = istable(prog.stats) and prog.stats or {}
            local prof = live.profile or json(data.profile[id])
            local teamName = teamNameOf(c.team_id)
            local spec = clean(c.ranking, 48)
            local rpid = tonumber(c.rpid) and tostring(math.floor(tonumber(c.rpid))) or ""
            local cname = clean(c.character_name, 40)
            local position = isstring(prof.position) and clean(prof.position, 40) or ""
            local P = FUSION and FUSION.Progress
            local maxLevel = P and P.Settings and P.Settings.MaxLevel or 100
            local level = math.min(num(prog.level), maxLevel)

            acc.chars[#acc.chars + 1] = {
                steamid = acc.sid64,
                id = tostring(id),
                -- поля, которые сайт уже показывает
                name = (rpid ~= "" and (rpid .. " | ") or "") .. (cname ~= "" and cname or "Без имени"),
                rank = clean(c.pripiska, 32),
                unit = unitKeyOf(teamName, spec),
                unitTitle = clean(teamName, 60),
                profession = (position == "" or position == spec) and spec or (spec ~= "" and (spec .. " · " .. position) or position),
                level = level,
                xp = num(prog.xp),
                credits = num(live.money or data.money[id]),
                playtime = num(stats.playtime) * 60,            -- в базе минуты, сайт ждёт секунды
                kills = num(stats.npc_kills),
                -- подробности для профиля
                number = rpid,
                callsign = cname,
                spec = spec,
                position = position,
                blood = isstring(prof.blood) and clean(prof.blood, 16) or "",
                levelMax = maxLevel,
                xpNeed = (P and P.XPForLevel and level < maxLevel) and num(P.XPForLevel(level)) or 0,
                jediClass = prog.jediClass and clean(jediClassName(prog.jediClass), 32) or "",
                stats = { damage = num(stats.damage), heals = num(stats.heals), repairs = num(stats.repairs),
                          ops = num(stats.ops), tasks = num(stats.tasks), hacks = num(stats.hacks) },
                online = live.current or false,
                lastSeen = num(acc.seen),
            }
        end
    end

    local out = {}
    for _, acc in pairs(byPid) do out[#out + 1] = acc end
    table.sort(out, function(a, b) return a.sid64 < b.sid64 end)
    return out
end

-- ---------------------------------------------------------------- отправка
local function sigOf(acc)
    local parts = { tostring(acc.donate or "-") }
    for _, c in ipairs(acc.chars) do parts[#parts + 1] = util.TableToJSON(c) end
    table.sort(parts)
    return util.CRC(table.concat(parts, "\n")) .. ":" .. #parts
end

local function post(batch, done)
    local key = getKey()
    if key == "" then
        S.Stat.lastErr, S.Stat.lastErrAt = "нет ключа", os.time()
        say("Нет ключа синхронизации: нет аддона логов с ключом и не задан eow_site_sync_key — отправка выключена")
        return done(false)
    end
    local payload = { characters = {}, accounts = {}, replace = {} }
    for _, acc in ipairs(batch) do
        payload.replace[#payload.replace + 1] = acc.sid64
        for _, c in ipairs(acc.chars) do payload.characters[#payload.characters + 1] = c end
        if acc.donate ~= nil then payload.accounts[#payload.accounts + 1] = { steamid = acc.sid64, donate = num(acc.donate) } end
    end
    S.Stat.requests = S.Stat.requests + 1
    HTTP({
        url = S.API, method = "POST", type = "application/json",
        headers = { Authorization = "Bearer " .. key },
        body = util.TableToJSON(payload),
        timeout = 30,
        success = function(code, body)
            if code == 200 then
                for _, acc in ipairs(batch) do S.Sig[acc.sid64] = acc.sig end
                S.Stat.sent = S.Stat.sent + #batch
                S.Stat.chars = S.Stat.chars + #payload.characters
                S.Stat.lastOk = os.time()
                log("ok", #batch, "аккаунтов,", #payload.characters, "персонажей:", body)
                done(true)
            else
                S.Stat.lastErr, S.Stat.lastErrAt = "сайт ответил " .. code .. ": " .. string.sub(tostring(body), 1, 200), os.time()
                if code == 401 then
                    say("Сайт не принял ключ (401). Если в воркере задан отдельный GAME_SYNC_KEY — впишите его в server.cfg: eow_site_sync_key \"...\"")
                else
                    say("Сайт ответил " .. code .. ": " .. string.sub(tostring(body), 1, 200))
                end
                done(false)
            end
        end,
        failed = function(err)
            S.Stat.lastErr, S.Stat.lastErrAt = "нет связи: " .. tostring(err), os.time()
            say("Не удалось связаться с сайтом: " .. tostring(err))
            done(false)
        end,
    })
end

-- отправить аккаунты пачками, по одной за раз; force — отправить даже без изменений
local function sendAccounts(accounts, force, cb)
    local todo = {}
    for _, acc in ipairs(accounts) do
        acc.sig = sigOf(acc)
        if force or S.Sig[acc.sid64] ~= acc.sig then todo[#todo + 1] = acc end
    end
    local batches, cur, curChars = {}, {}, 0
    for _, acc in ipairs(todo) do
        if #cur > 0 and (#cur >= S.BATCH_ACCOUNTS or curChars + #acc.chars > S.BATCH_CHARS) then
            batches[#batches + 1] = cur cur, curChars = {}, 0
        end
        cur[#cur + 1] = acc
        curChars = curChars + #acc.chars
    end
    if #cur > 0 then batches[#batches + 1] = cur end

    local i, okAll = 0, true
    local function nextBatch()
        i = i + 1
        if i > #batches then
            if cb then cb(okAll, #todo, #accounts) end
            return
        end
        post(batches[i], function(ok)
            okAll = okAll and ok
            if not ok then if cb then cb(false, #todo, #accounts) end return end   -- сайт недоступен: дальше не шлём
            timer.Simple(1, nextBatch)
        end)
    end
    nextBatch()
end

local busy = false
-- sids2 == nil — вся база
local function sync(sids2, force, cb)
    if not dbReady() then if cb then cb(false, 0, 0) end return end
    if busy and not sids2 then if cb then cb(false, 0, 0) end return end
    if not sids2 then busy = true end
    load(sids2, function(data)
        if not data then
            if not sids2 then busy = false end
            S.Stat.lastErr, S.Stat.lastErrAt = "база недоступна", os.time()
            if cb then cb(false, 0, 0) end
            return
        end
        local accounts = build(data)
        sendAccounts(accounts, force, function(ok, sent, total)
            if not sids2 then busy = false if ok then S.Stat.lastFull = os.time() end end
            if cb then cb(ok, sent, total) end
        end)
    end)
end

local function syncFull(force, cb)
    if os.time() - S.SigReset > S.FORCE_EVERY then S.Sig = {} S.SigReset = os.time() end
    sync(nil, force, cb)
end

local function syncPlayers(plys, cb)
    local sids = {}
    for _, p in ipairs(plys) do
        if IsValid(p) and not p:IsBot() and p:SteamID() then sids[#sids + 1] = p:SteamID() end
    end
    if #sids == 0 then if cb then cb(true, 0, 0) end return end
    sync(sids, false, cb)
end

local function syncSids(sids, cb) if #sids > 0 then sync(sids, false, cb) end end

S.SyncFull, S.SyncPlayers = syncFull, syncPlayers

-- ---------------------------------------------------------------- события
local started = false
local function start()
    if started then return end
    started = true
    timer.Simple(60, function() syncFull(false) end)
end
hook.Add("DatabaseInitialized", "EOWSite.Sync.Start", start)
timer.Simple(150, start)       -- если база подключилась раньше загрузки аддона

hook.Add("PlayerInitialSpawn", "EOWSite.Sync.Join", function(ply)
    timer.Simple(45, function() if IsValid(ply) then syncPlayers({ ply }) end end)
end)
hook.Add("PlayerDisconnected", "EOWSite.Sync.Leave", function(ply)
    local sid = ply:SteamID()
    if not sid or ply:IsBot() then return end
    -- даём геймоду сохранить прогресс и кредиты, потом читаем из базы
    timer.Simple(8, function() syncSids({ sid }) end)
end)

timer.Create("EOWSite.Sync.Online", S.ONLINE_INTERVAL, 0, function()
    local all = player.GetHumans()
    for i = 1, #all, S.BATCH_ACCOUNTS do
        syncPlayers({ unpack(all, i, math.min(i + S.BATCH_ACCOUNTS - 1, #all)) })
    end
end)
timer.Create("EOWSite.Sync.Full", S.FULL_INTERVAL, 0, function() syncFull(false) end)

-- ---------------------------------------------------------------- консоль
local function allowed(ply) return not IsValid(ply) or ply:IsSuperAdmin() end
local function reply(ply, msg) if IsValid(ply) then ply:ChatPrint("[EOW Site] " .. msg) end say(msg) end

concommand.Add("eow_site_sync_now", function(ply, _, args)
    if not allowed(ply) then return end
    local full = args[1] == "full"
    reply(ply, full and "Отправляю всю базу персонажей…" or "Отправляю игроков онлайн…")
    local function res(ok, sent, total)
        if ok then
            reply(ply, "Готово: отправлено аккаунтов " .. sent .. " из " .. total .. (sent < total and " (остальные без изменений)" or ""))
        else
            reply(ply, "Не получилось отправить: " .. tostring(S.Stat.lastErr ~= "" and S.Stat.lastErr or "база недоступна или отправка уже идёт"))
        end
    end
    if full then syncFull(true, res) else syncPlayers(player.GetHumans(), res) end
end)

concommand.Add("eow_site_sync_status", function(ply)
    if not allowed(ply) then return end
    local st = S.Stat
    local function ago(t) return t > 0 and (os.time() - t) .. " сек назад" or "ещё не было" end
    reply(ply, string.format("ключ: %s | база: %s | успешная отправка: %s | полная: %s | запросов: %d, аккаунтов: %d, персонажей: %d | ошибка: %s",
        getKey() ~= "" and "есть" or "НЕТ", dbReady() and "есть" or "нет",
        ago(st.lastOk), ago(st.lastFull), st.requests, st.sent, st.chars,
        st.lastErr ~= "" and (st.lastErr .. " (" .. ago(st.lastErrAt) .. ")") or "нет"))
end)

say("Синхронизация с сайтом загружена (v2)")
