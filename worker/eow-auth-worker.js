/**
 * Eclipse of War — сервер авторизации через Steam (Cloudflare Worker + D1)
 *
 * Что делает:
 *   GET  /auth/steam?return=<url>      → отправляет игрока на страницу входа Steam
 *   GET  /auth/steam/callback          → проверяет ответ Steam, создаёт/обновляет профиль, возвращает на сайт с токеном
 *   GET  /api/me                       → профиль текущего игрока (по токену)
 *   GET  /api/users                    → список игроков (только Овнер)
 *   POST /api/users/<steamid64>        → выдать/снять права игроку (только Овнер)
 *   GET  /api/content                  → общий контент сайта (новости, документы, карта и т.д.)
 *   POST /api/content/<ключ>           → сохранить раздел (с проверкой прав по ролям)
 *   POST /api/shop/buy                 → обмен баллов администратора на награду
 *   GET  /api/shop/purchases           → история обменов (свои; Овнер — все)
 *   POST /api/logs/ingest              → приём игровых логов с GMod-сервера (по ключу LOGS_INGEST_KEY)
 *   GET  /api/logs                     → игровые логи для администраторов и Овнеров
 *   POST /api/beta/apply               → заявка на закрытый бета-тест (SteamID + откуда узнали), без входа
 *   GET  /api/beta                     → заявки на ЗБТ (администраторы и Овнеры)
 *   POST /api/beta/<id>                → сменить статус заявки или удалить её (администраторы и Овнеры)
 *   GET  /api/discord                  → подключение к Discord и история анонсов (только Овнер)
 *   POST /api/discord/config           → подключить / отключить вебхук канала, роль для пинга (только Овнер)
 *   POST /api/discord/test             → проверочное сообщение в канал (только Овнер)
 *   POST /api/discord/announce         → отправить анонс в канал Discord (только Овнер)
 *   POST /api/discord/posts/<id>/delete → удалить отправленный анонс из Discord (только Овнер)
 *   GET  /api/reports?unit=<ключ>      → рапорта подразделения (вошедшие игроки этого подразделения)
 *   POST /api/reports                  → подать рапорт: уходит в Discord (ветка по категории) и сохраняется
 *   GET  /api/reports/<id>/attachments → свежие ссылки на скриншоты и подпись рапорта из Discord
 *   POST /api/media                    → загрузить картинку (Овнер, администраторы, командиры)
 *   GET  /media/<id>                   → картинка по постоянной ссылке
 *   POST /api/game/sync                → данные персонажей с GMod-сервера (по ключу GAME_SYNC_KEY)
 *   GET  /api/me/game                  → свои персонажи и баланс доната
 *
 * Настройка (Cloudflare → Workers):
 *   1) Привязка D1-базы с именем переменной  DB
 *   2) Секрет  TOKEN_SECRET  — любая длинная случайная строка
 *   3) (необязательно) секрет  STEAM_API_KEY  — ключ Steam Web API для ников/аватаров
 *   4) секрет  LOGS_INGEST_KEY  — тот же ключ, что в аддоне eow_site_logs.lua на игровом сервере
 *   5) (необязательно) секрет  DISCORD_WEBHOOK_URL — вебхук канала по умолчанию; проще подключить
 *      его на сайте: режим администратора → «Анонс» → «Подключение к Discord»
 *   6) секрет  REPORTS_WEBHOOK_URL — вебхук канала рапортов (ветки рапортов должны быть в этом канале)
 *   7) (необязательно) секрет  GAME_SYNC_KEY — ключ аддона eow_site_sync на GMod-сервере; если не задан, берётся LOGS_INGEST_KEY
 */

// ===== НАСТРОЙКИ ==========================================================
// Овнеры проекта (SteamID64).
//   STEAM_0:1:508833497 → 76561198977932723
//   STEAM_0:1:438253299 → 76561198836772327
const OWNER_STEAM_IDS = ['76561198977932723', '76561198836772327'];

// С каких адресов сайту разрешено обращаться к серверу и куда можно возвращать игрока
const ALLOWED_ORIGINS = [
    'https://eclipseofwar.com',
    'https://www.eclipseofwar.com',
    'https://shanny-go.github.io',
];
const DEFAULT_RETURN_URL = 'https://eclipseofwar.com/';
const TOKEN_TTL_SECONDS = 60 * 60 * 24 * 30; // вход действует 30 дней

const CORPS_KEYS = ['assault', 'recon', 'medical', 'engineering', 'coruscant_guard', 'aviation'];
const SERVER_PRIVILEGES = [
    'Игрок (Без привилегий)', 'VIP + Командир корпуса', 'Донат: Свободный наемник', 'Донат: Мастер-Джедай',
    'Донат: Республиканский коммандос', 'Модератор сервера', 'Старший Ивентолог', 'Root / Основатель',
];
// ==========================================================================

const STEAM_OPENID = 'https://steamcommunity.com/openid/login';
const STEAM_ID_BASE = 76561197960265728n;

let schemaReady = false;
async function ensureSchema(db) {
    if (schemaReady) return;
    await db.prepare(`CREATE TABLE IF NOT EXISTS users (
        steamid TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT '',
        avatar TEXT NOT NULL DEFAULT '',
        profile_url TEXT NOT NULL DEFAULT '',
        site_admin INTEGER NOT NULL DEFAULT 0,
        site_commander INTEGER NOT NULL DEFAULT 0,
        commander_corps TEXT NOT NULL DEFAULT 'assault',
        server_privilege TEXT NOT NULL DEFAULT 'Игрок (Без привилегий)',
        admin_points INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL DEFAULT 0,
        last_login INTEGER NOT NULL DEFAULT 0
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS content (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        version INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        updated_by TEXT NOT NULL DEFAULT ''
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS purchases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        steamid TEXT NOT NULL,
        item_id TEXT NOT NULL,
        title TEXT NOT NULL,
        cost INTEGER NOT NULL,
        created_at INTEGER NOT NULL
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS server_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        uid TEXT NOT NULL UNIQUE,
        t INTEGER NOT NULL,
        cat TEXT NOT NULL,
        text TEXT NOT NULL,
        sid TEXT NOT NULL DEFAULT '',
        port TEXT NOT NULL DEFAULT '',
        received INTEGER NOT NULL
    )`).run();
    await db.prepare('CREATE INDEX IF NOT EXISTS server_logs_t ON server_logs (t)').run();
    await db.prepare('CREATE INDEX IF NOT EXISTS server_logs_cat ON server_logs (cat, id)').run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS beta_apps (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        steamid TEXT NOT NULL UNIQUE,
        steam_input TEXT NOT NULL DEFAULT '',
        name TEXT NOT NULL DEFAULT '',
        avatar TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT '',
        comment TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'new',
        account TEXT NOT NULL DEFAULT '',
        ip_hash TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        reviewed_by TEXT NOT NULL DEFAULT ''
    )`).run();
    await db.prepare('CREATE INDEX IF NOT EXISTS beta_apps_ip ON beta_apps (ip_hash, updated_at)').run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS settings (
        key TEXT PRIMARY KEY,
        value TEXT NOT NULL,
        updated_at INTEGER NOT NULL DEFAULT 0,
        updated_by TEXT NOT NULL DEFAULT ''
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS discord_posts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '',
        channel_id TEXT NOT NULL DEFAULT '',
        guild_id TEXT NOT NULL DEFAULT '',
        webhook_id TEXT NOT NULL DEFAULT '',
        ping TEXT NOT NULL DEFAULT '',
        author TEXT NOT NULL DEFAULT '',
        author_id TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'sent',
        created_at INTEGER NOT NULL,
        deleted_at INTEGER NOT NULL DEFAULT 0,
        deleted_by TEXT NOT NULL DEFAULT ''
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS unit_reports (
        id TEXT PRIMARY KEY,
        unit TEXT NOT NULL,
        unit_title TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL,
        addressee TEXT NOT NULL,
        subject TEXT NOT NULL,
        body TEXT NOT NULL,
        signature TEXT NOT NULL DEFAULT '',
        char_name TEXT NOT NULL DEFAULT '',
        author_id TEXT NOT NULL,
        author_name TEXT NOT NULL DEFAULT '',
        photos INTEGER NOT NULL DEFAULT 0,
        thread_id TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
    )`).run();
    await db.prepare('CREATE INDEX IF NOT EXISTS unit_reports_unit ON unit_reports (unit, created_at)').run();
    await db.prepare('CREATE INDEX IF NOT EXISTS unit_reports_author ON unit_reports (author_id, created_at)').run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS media (
        id TEXT PRIMARY KEY,
        mime TEXT NOT NULL,
        data BLOB NOT NULL,
        size INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        created_by TEXT NOT NULL DEFAULT ''
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS game_characters (
        steamid TEXT NOT NULL,
        char_id TEXT NOT NULL,
        name TEXT NOT NULL DEFAULT '',
        rank TEXT NOT NULL DEFAULT '',
        unit TEXT NOT NULL DEFAULT '',
        unit_title TEXT NOT NULL DEFAULT '',
        profession TEXT NOT NULL DEFAULT '',
        level INTEGER NOT NULL DEFAULT 0,
        xp INTEGER NOT NULL DEFAULT 0,
        credits INTEGER NOT NULL DEFAULT 0,
        playtime INTEGER NOT NULL DEFAULT 0,
        kills INTEGER NOT NULL DEFAULT 0,
        deaths INTEGER NOT NULL DEFAULT 0,
        reputation INTEGER NOT NULL DEFAULT 0,
        reprimands INTEGER NOT NULL DEFAULT 0,
        first_seen INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (steamid, char_id)
    )`).run();
    await db.prepare(`CREATE TABLE IF NOT EXISTS game_accounts (
        steamid TEXT PRIMARY KEY,
        donate INTEGER NOT NULL DEFAULT 0,
        updated_at INTEGER NOT NULL DEFAULT 0
    )`).run();
    // v2 синхронизации: подробности персонажа (номер, должность, кровь, статистика, онлайн) одним JSON
    try { await db.prepare("ALTER TABLE game_characters ADD COLUMN extra TEXT NOT NULL DEFAULT '{}'").run(); } catch (e) { /* колонка уже есть */ }
    schemaReady = true;
}

// ---------- утилиты ----------
const now = () => Math.floor(Date.now() / 1000);
const isOwner = id => OWNER_STEAM_IDS.includes(String(id));

function steamId2(id64) {
    const v = BigInt(id64) - STEAM_ID_BASE;
    return `STEAM_0:${v % 2n}:${v / 2n}`;
}

function corsHeaders(request) {
    const origin = request.headers.get('Origin');
    const h = { 'Vary': 'Origin' };
    if (origin && ALLOWED_ORIGINS.includes(origin)) {
        h['Access-Control-Allow-Origin'] = origin;
        h['Access-Control-Allow-Methods'] = 'GET, POST, OPTIONS';
        h['Access-Control-Allow-Headers'] = 'Authorization, Content-Type';
        h['Access-Control-Max-Age'] = '86400';
    }
    return h;
}

function json(request, data, status = 200) {
    return new Response(JSON.stringify(data), {
        status,
        headers: { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', ...corsHeaders(request) },
    });
}

function safeReturnUrl(raw) {
    try {
        const u = new URL(raw);
        if (ALLOWED_ORIGINS.includes(u.origin)) { u.hash = ''; return u.toString(); }
    } catch (e) { /* ignore */ }
    return DEFAULT_RETURN_URL;
}

function redirectWithHash(returnUrl, key, value) {
    return new Response(null, { status: 302, headers: { Location: `${returnUrl}#${key}=${encodeURIComponent(value)}`, 'Cache-Control': 'no-store' } });
}

// ---------- токены (HMAC-SHA256) ----------
const enc = new TextEncoder();
function b64url(bytes) {
    let s = ''; const arr = new Uint8Array(bytes);
    for (let i = 0; i < arr.length; i++) s += String.fromCharCode(arr[i]);
    return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}
function b64urlToBytes(str) {
    const s = atob(str.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((str.length + 3) % 4));
    const out = new Uint8Array(s.length);
    for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
    return out;
}
async function hmacKey(secret) {
    return crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify']);
}
async function signToken(payload, secret) {
    const body = b64url(enc.encode(JSON.stringify(payload)));
    const sig = await crypto.subtle.sign('HMAC', await hmacKey(secret), enc.encode(body));
    return `${body}.${b64url(sig)}`;
}
async function verifyToken(token, secret) {
    if (!token || token.split('.').length !== 2) return null;
    const [body, sig] = token.split('.');
    let ok = false;
    try { ok = await crypto.subtle.verify('HMAC', await hmacKey(secret), b64urlToBytes(sig), enc.encode(body)); } catch (e) { return null; }
    if (!ok) return null;
    try {
        const payload = JSON.parse(new TextDecoder().decode(b64urlToBytes(body)));
        if (!payload.sid || !payload.exp || payload.exp < now()) return null;
        return payload;
    } catch (e) { return null; }
}

// ---------- профиль ----------
function publicUser(row) {
    const owner = isOwner(row.steamid);
    const siteAdmin = owner || !!row.site_admin;
    const siteCommander = owner || !!row.site_commander;
    return {
        steamId64: row.steamid,
        steamId2: steamId2(row.steamid),
        name: row.name || 'Игрок Steam',
        avatar: row.avatar || '',
        profileUrl: row.profile_url || `https://steamcommunity.com/profiles/${row.steamid}`,
        role: owner ? 'owner' : siteAdmin ? 'admin' : siteCommander ? 'commander' : 'player',
        siteAdmin,
        siteCommander,
        commanderCorps: CORPS_KEYS.includes(row.commander_corps) ? row.commander_corps : 'assault',
        serverPrivilege: owner ? 'Root / Основатель' : row.server_privilege,
        adminPoints: row.admin_points | 0,
        createdAt: row.created_at,
        lastLogin: row.last_login,
    };
}

function cleanName(n) {
    return String(n || '').replace(/<\/?[a-z][^>]*>/gi, '').replace(/[<>"'`&\\]/g, '').replace(/\s+/g, ' ').trim().slice(0, 48);
}

async function fetchSteamProfile(id64, env) {
    const p = await fetchSteamProfileRaw(id64, env);
    return { ...p, name: cleanName(p.name) || `Игрок ${id64.slice(-5)}`, avatar: /^https:\/\/[^"'<>\s]+$/.test(p.avatar) ? p.avatar : '' };
}

async function fetchSteamProfileRaw(id64, env) {
    const fallback = { name: `Игрок ${id64.slice(-5)}`, avatar: '', profileUrl: `https://steamcommunity.com/profiles/${id64}` };
    try {
        if (env.STEAM_API_KEY) {
            const r = await fetch(`https://api.steampowered.com/ISteamUser/GetPlayerSummaries/v2/?key=${encodeURIComponent(env.STEAM_API_KEY)}&steamids=${id64}`);
            const j = await r.json();
            const p = j && j.response && j.response.players && j.response.players[0];
            if (p) return { name: p.personaname || fallback.name, avatar: p.avatarfull || '', profileUrl: p.profileurl || fallback.profileUrl };
        }
        const r = await fetch(`https://steamcommunity.com/profiles/${id64}/?xml=1`, { headers: { 'User-Agent': 'EclipseOfWar-Auth/1.0' } });
        const xml = await r.text();
        const pick = tag => { const m = xml.match(new RegExp(`<${tag}>(?:<!\\[CDATA\\[)?([\\s\\S]*?)(?:\\]\\]>)?</${tag}>`)); return m ? m[1].trim() : ''; };
        const name = pick('steamID');
        const avatar = pick('avatarFull');
        const custom = pick('customURL');
        return {
            name: name || fallback.name,
            avatar: /^https:\/\//.test(avatar) ? avatar : '',
            profileUrl: custom ? `https://steamcommunity.com/id/${custom}/` : fallback.profileUrl,
        };
    } catch (e) {
        return fallback;
    }
}

async function getUser(env, id64) {
    return env.DB.prepare('SELECT * FROM users WHERE steamid = ?').bind(id64).first();
}

async function authUser(request, env) {
    const h = request.headers.get('Authorization') || '';
    const token = h.startsWith('Bearer ') ? h.slice(7) : '';
    const payload = await verifyToken(token, env.TOKEN_SECRET);
    if (!payload) return null;
    return getUser(env, payload.sid);
}

// ---------- Steam OpenID ----------
function steamLoginUrl(callbackUrl, realm) {
    const p = new URLSearchParams({
        'openid.ns': 'http://specs.openid.net/auth/2.0',
        'openid.mode': 'checkid_setup',
        'openid.return_to': callbackUrl,
        'openid.realm': realm,
        'openid.identity': 'http://specs.openid.net/auth/2.0/identifier_select',
        'openid.claimed_id': 'http://specs.openid.net/auth/2.0/identifier_select',
    });
    return `${STEAM_OPENID}?${p.toString()}`;
}

async function verifySteamResponse(url) {
    const q = url.searchParams;
    if (q.get('openid.mode') !== 'id_res') return { error: 'cancelled' };
    if (q.get('openid.op_endpoint') !== STEAM_OPENID) return { error: 'bad_endpoint' };

    // return_to должен указывать именно на этот callback с тем же параметром return
    let rt;
    try { rt = new URL(q.get('openid.return_to') || ''); } catch (e) { return { error: 'bad_return_to' }; }
    if (rt.origin + rt.pathname !== url.origin + url.pathname || rt.searchParams.get('return') !== q.get('return')) {
        return { error: 'bad_return_to' };
    }

    // ответ не старше 5 минут
    const nonce = q.get('openid.response_nonce') || '';
    const ts = Date.parse(nonce.slice(0, 20));
    if (!ts || Math.abs(Date.now() - ts) > 5 * 60 * 1000) return { error: 'expired' };

    const m = (q.get('openid.claimed_id') || '').match(/^https:\/\/steamcommunity\.com\/openid\/id\/(7656119\d{10})\/?$/);
    if (!m || q.get('openid.identity') !== q.get('openid.claimed_id')) return { error: 'bad_claimed_id' };

    // спрашиваем у Steam, подлинный ли ответ
    const body = new URLSearchParams();
    for (const [k, v] of q.entries()) if (k.startsWith('openid.')) body.set(k, v);
    body.set('openid.mode', 'check_authentication');
    const r = await fetch(STEAM_OPENID, {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Accept-Language': 'en' },
        body: body.toString(),
    });
    const text = await r.text();
    if (!/is_valid\s*:\s*true/.test(text)) return { error: 'invalid_signature' };
    return { steamId64: m[1] };
}

// ---------- обработчики ----------
async function handleSteamStart(request, url) {
    const returnUrl = safeReturnUrl(url.searchParams.get('return') || '');
    const callback = `${url.origin}/auth/steam/callback?return=${encodeURIComponent(returnUrl)}`;
    return Response.redirect(steamLoginUrl(callback, url.origin), 302);
}

async function handleSteamCallback(request, env, url) {
    const returnUrl = safeReturnUrl(url.searchParams.get('return') || '');
    const res = await verifySteamResponse(url);
    if (res.error) return redirectWithHash(returnUrl, 'eow_error', res.error);

    const id64 = res.steamId64;
    const profile = await fetchSteamProfile(id64, env);
    const t = now();
    await env.DB.prepare(`INSERT INTO users (steamid, name, avatar, profile_url, created_at, last_login)
            VALUES (?1, ?2, ?3, ?4, ?5, ?5)
            ON CONFLICT(steamid) DO UPDATE SET name = ?2, avatar = ?3, profile_url = ?4, last_login = ?5`)
        .bind(id64, profile.name, profile.avatar, profile.profileUrl, t).run();

    const token = await signToken({ sid: id64, iat: t, exp: t + TOKEN_TTL_SECONDS }, env.TOKEN_SECRET);
    return redirectWithHash(returnUrl, 'eow_token', token);
}

async function handleMe(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    return json(request, { user: publicUser(row) });
}

async function handleUsers(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    if (!isOwner(row.steamid)) return json(request, { error: 'forbidden' }, 403);
    const { results } = await env.DB.prepare('SELECT * FROM users ORDER BY last_login DESC LIMIT 1000').all();
    return json(request, { users: (results || []).map(publicUser) });
}

async function handleUpdateUser(request, env, targetId) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    if (!isOwner(row.steamid)) return json(request, { error: 'forbidden' }, 403);
    const target = await getUser(env, targetId);
    if (!target) return json(request, { error: 'not_found' }, 404);

    let body = {};
    try { body = await request.json(); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    // Овнер — роль из кода: выключить ему доступы или начислить баллы нельзя,
    // но привилегию на сервере и корпус для отображения поменять можно.
    if (isOwner(targetId) && ('siteAdmin' in body || 'siteCommander' in body || 'adminPointsDelta' in body)) {
        return json(request, { error: 'owner_locked' }, 400);
    }
    const sets = [], vals = [];
    if (typeof body.siteAdmin === 'boolean') { sets.push('site_admin = ?'); vals.push(body.siteAdmin ? 1 : 0); }
    if (typeof body.siteCommander === 'boolean') { sets.push('site_commander = ?'); vals.push(body.siteCommander ? 1 : 0); }
    if (typeof body.commanderCorps === 'string') {
        if (!CORPS_KEYS.includes(body.commanderCorps)) return json(request, { error: 'bad_corps' }, 400);
        sets.push('commander_corps = ?'); vals.push(body.commanderCorps);
    }
    if (typeof body.serverPrivilege === 'string') {
        if (!SERVER_PRIVILEGES.includes(body.serverPrivilege)) return json(request, { error: 'bad_privilege' }, 400);
        sets.push('server_privilege = ?'); vals.push(body.serverPrivilege);
    }
    if (Number.isInteger(body.adminPointsDelta)) {
        sets.push('admin_points = MAX(0, admin_points + ?)'); vals.push(Math.max(-100000, Math.min(100000, body.adminPointsDelta)));
    }
    if (!sets.length) return json(request, { error: 'nothing_to_update' }, 400);
    await env.DB.prepare(`UPDATE users SET ${sets.join(', ')} WHERE steamid = ?`).bind(...vals, targetId).run();
    return json(request, { user: publicUser(await getUser(env, targetId)) });
}

// =================================================================== КОНТЕНТ САЙТА
// Каждый раздел хранится целиком (JSON) с номером версии. Права проверяются по ролям:
//   owner — Овнер, admin — администратор сайта, commander — командир.
const CONTENT_MAX_BYTES = 1500000;
const ID_RE = /^[A-Za-z0-9_\-]{1,64}$/;
const DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const TIME_RE = /^\d{2}:\d{2}$/;
const SECTOR_STATUSES = ['Завоеван', 'В процессе завоевания', 'Завоевание провалено', 'Незавоеван'];

const CONTENT_KEYS = {
    news:     { read: 'public',   write: ['owner'],                         validate: validateNews },
    docs:     { read: 'public',   write: ['owner', 'commander'],            validate: validateDocs },
    map:      { read: 'public',   write: ['owner', 'admin'],                validate: validateMap },
    rosters:  { read: 'staff',    write: ['owner', 'commander'],            validate: validateRosters },
    reports:  { read: 'staff',    write: ['owner', 'commander'],            validate: (o, n, c) => validateAppendList(o, n, c, 'status', 'На рассмотрении Штаба') },
    addons:   { read: 'staff',    write: ['owner', 'admin'],                validate: (o, n, c) => validateAppendList(o, n, c, 'status', 'В процессе добавления') },
    factions: { read: 'staff',    write: ['owner', 'admin'],                validate: (o, n, c) => validateAppendList(o, n, c, 'status', 'На рассмотрении') },
    bookings: { read: 'bookings', write: ['owner', 'admin', 'commander'],   validate: mergeBookings, ownMerge: true },
};

class ContentError extends Error { constructor(code) { super(code); this.code = code; } }
const bad = code => { throw new ContentError(code); };
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v);

function rolesOf(row) {
    if (!row) return { id: '', owner: false, admin: false, commander: false, corps: '' };
    const owner = isOwner(row.steamid);
    return { id: row.steamid, owner, admin: owner || !!row.site_admin, commander: owner || !!row.site_commander, corps: row.commander_corps };
}
function canReadKey(def, r) {
    if (def.read === 'public') return true;
    return r.owner || r.admin || r.commander;
}
function canWriteKey(def, r) {
    return def.write.some(role => r[role]);
}

// все id в данных — только числа или короткие строки из букв/цифр (защита от вставки кода в обработчики)
function checkIds(v, depth = 0) {
    if (depth > 12) bad('too_deep');
    if (Array.isArray(v)) { v.forEach(x => checkIds(x, depth + 1)); return; }
    if (!isObj(v)) return;
    if ('id' in v) {
        const id = v.id;
        const okNum = typeof id === 'number' && Number.isSafeInteger(id);
        const okStr = typeof id === 'string' && ID_RE.test(id);
        if (!okNum && !okStr) bad('bad_id');
    }
    for (const k of Object.keys(v)) checkIds(v[k], depth + 1);
}
function uniqueIds(list) {
    const seen = new Set();
    for (const it of list) { if (!isObj(it) || it.id === undefined || seen.has(it.id)) bad('bad_item'); seen.add(it.id); }
}
const byId = list => new Map((list || []).map(x => [x.id, x]));

function validateNews(old, next) {
    if (!Array.isArray(next)) bad('bad_shape');
    uniqueIds(next);
    return next;
}

function validateDocs(old, next, r) {
    if (!Array.isArray(next)) bad('bad_shape');
    uniqueIds(next);
    for (const it of next) {
        if (!['document', 'order'].includes(it.kind)) bad('bad_kind');
        if (it.signatureDataUrl != null && !(typeof it.signatureDataUrl === 'string' && it.signatureDataUrl.startsWith('data:image/png;base64,') && it.signatureDataUrl.length < 400000)) bad('bad_signature');
    }
    if (r.owner || !Array.isArray(old)) return next;
    const nm = byId(next);
    for (const o of old) {
        const n = nm.get(o.id);
        if (!n) bad('delete_forbidden');                       // удалять документы может только Овнер
        if (!!n.lockedByOwner !== !!o.lockedByOwner) bad('lock_forbidden');
        if (o.lockedByOwner && !same(o, n)) bad('locked');
    }
    const om = byId(old);
    for (const n of next) if (!om.has(n.id) && n.lockedByOwner) bad('lock_forbidden');
    return next;
}

function validateMap(old, next, r) {
    if (!isObj(next)) bad('bad_shape');
    for (const p of Object.values(next)) {
        if (!isObj(p) || !Array.isArray(p.sectors)) bad('bad_shape');
        for (const sec of p.sectors) {
            if (!isObj(sec) || !SECTOR_STATUSES.includes(sec.status)) bad('bad_sector');
            if (sec.installations !== undefined && !(Array.isArray(sec.installations) && sec.installations.length <= 3 && sec.installations.every(x => typeof x === 'string' && x.length <= 120))) bad('bad_sector');
        }
    }
    if (r.owner || !isObj(old)) return next;
    // администратор меняет только фракцию планеты и статусы/постройки секторов
    const strip = p => ({ ...p, faction: null, sectors: p.sectors.map(sc => ({ ...sc, status: null, installations: null, installation: null })) });
    if (!same(Object.keys(old).sort(), Object.keys(next).sort())) bad('map_shape_forbidden');
    for (const k of Object.keys(old)) {
        if (old[k].sectors.length !== next[k].sectors.length || !same(strip(old[k]), strip(next[k]))) bad('map_fields_forbidden');
    }
    return next;
}

function validateRosters(old, next, r) {
    if (!isObj(next)) bad('bad_shape');
    for (const c of Object.values(next)) { if (!isObj(c) || !Array.isArray(c.soldiers)) bad('bad_shape'); uniqueIds(c.soldiers); }
    if (r.owner || !isObj(old)) return next;
    if (!same(Object.keys(old).sort(), Object.keys(next).sort())) bad('corps_forbidden');
    for (const k of Object.keys(old)) {
        if (k !== r.corps && !same(old[k], next[k])) bad('corps_forbidden');   // командир правит только своё формирование
    }
    return next;
}

// список, куда не-Овнер может только добавлять записи с начальным статусом
function validateAppendList(old, next, r, field, initial) {
    if (!Array.isArray(next)) bad('bad_shape');
    uniqueIds(next);
    if (r.owner) return next;
    const om = byId(Array.isArray(old) ? old : []);
    const nm = byId(next);
    for (const [id, o] of om) { const n = nm.get(id); if (!n) bad('delete_forbidden'); if (!same(o, n)) bad('edit_forbidden'); }
    for (const n of next) if (!om.has(n.id) && n[field] !== initial) bad('status_forbidden');
    return next;
}

// брони: не-Овнер может добавлять/снимать только свои записи
function mergeBookings(old, next, r) {
    if (!isObj(next)) bad('bad_shape');
    for (const [day, list] of Object.entries(next)) {
        if (!DATE_RE.test(day) || !Array.isArray(list)) bad('bad_shape');
        for (const e of list) {
            if (!isObj(e) || !['admin_event', 'cmd_training'].includes(e.entryKind) || !TIME_RE.test(String(e.time || ''))) bad('bad_booking');
        }
    }
    if (r.owner) return next;
    const result = {};
    for (const [day, list] of Object.entries(isObj(old) ? old : {})) {
        const keep = list.filter(e => e.authorId !== r.id);
        if (keep.length) result[day] = keep;
    }
    for (const [day, list] of Object.entries(next)) {
        for (const e of list) {
            if (e.authorId !== r.id) continue;
            if (e.entryKind === 'admin_event' && !r.admin) bad('booking_forbidden');
            if (e.entryKind === 'cmd_training') {
                if (!r.commander) bad('booking_forbidden');
                const t = toMin(e.time);
                const clash = (result[day] || []).some(x => x.entryKind === 'admin_event' && t >= toMin(x.time) && t < toMin(x.time) + 120);
                if (clash) bad('booking_conflict');
            }
            (result[day] = result[day] || []).push(e);
        }
    }
    return result;
}
const toMin = t => { const [h, m] = String(t).split(':').map(Number); return h * 60 + (m || 0); };

// что видит пользователь: командиру без админки не показываем содержимое ивентов
function contentView(key, value, r) {
    if (key !== 'bookings' || r.owner || r.admin || !isObj(value)) return value;
    const out = {};
    for (const [day, list] of Object.entries(value)) {
        out[day] = list.map(e => e.entryKind === 'admin_event'
            ? { id: e.id, entryKind: 'admin_event', time: e.time, title: '', desc: '', type: '', authorId: '', authorName: '' }
            : e);
    }
    return out;
}

async function handleGetContent(request, env) {
    const r = rolesOf(await authUser(request, env));
    const rows = (await env.DB.prepare('SELECT key, value, version FROM content').all()).results || [];
    const content = {};
    for (const row of rows) {
        const def = CONTENT_KEYS[row.key];
        if (!def || !canReadKey(def, r)) continue;
        let value; try { value = JSON.parse(row.value); } catch (e) { continue; }
        content[row.key] = { value: contentView(row.key, value, r), version: row.version };
    }
    return json(request, { content });
}

async function handleSaveContent(request, env, key) {
    const def = CONTENT_KEYS[key];
    if (!def) return json(request, { error: 'unknown_key' }, 404);
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const r = rolesOf(row);
    if (!canWriteKey(def, r)) return json(request, { error: 'forbidden' }, 403);

    const raw = await request.text();
    if (raw.length > CONTENT_MAX_BYTES) return json(request, { error: 'too_large' }, 413);
    let body; try { body = JSON.parse(raw); } catch (e) { return json(request, { error: 'bad_json' }, 400); }

    const cur = await env.DB.prepare('SELECT value, version FROM content WHERE key = ?').bind(key).first();
    const curVersion = cur ? cur.version : 0;
    let curValue = null; if (cur) { try { curValue = JSON.parse(cur.value); } catch (e) { curValue = null; } }

    if (!def.ownMerge && Number(body.baseVersion || 0) !== curVersion) {
        return json(request, { error: 'conflict', value: contentView(key, curValue, r), version: curVersion }, 409);
    }
    let next;
    try {
        checkIds(body.value);
        next = def.validate(curValue, body.value, r);
    } catch (e) {
        if (e instanceof ContentError) return json(request, { error: e.code }, 400);
        throw e;
    }
    const text = JSON.stringify(next);
    if (text.length > CONTENT_MAX_BYTES) return json(request, { error: 'too_large' }, 413);
    const version = curVersion + 1;
    const res = await env.DB.prepare(
        'INSERT INTO content (key, value, version, updated_at, updated_by) VALUES (?, ?, ?, ?, ?) ' +
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value, version = excluded.version, updated_at = excluded.updated_at, updated_by = excluded.updated_by ' +
        'WHERE content.version = ?'
    ).bind(key, text, version, now(), r.id, curVersion).run();
    if (res && res.meta && res.meta.changes === 0) {
        return json(request, { error: 'conflict', value: contentView(key, curValue, r), version: curVersion }, 409);
    }
    return json(request, { value: contentView(key, next, r), version });
}

// =================================================================== МАГАЗИН БАЛЛОВ АДМИНИСТРАТОРА
const ADMIN_SHOP = {
    prof_astro: ['Астромеханик', 700], prof_youngling: ['Юнлинг', 2000], prof_padawan: ['Падаван', 3000],
    prof_knight: ['Рыцарь-джедай', 4000], prof_master: ['Мастер-джедай', 6000],
    prof_merc: ['Свободный наёмник', 2000], prof_commando: ['Республиканский коммандос', 10000],
    extra_personal: ['Личная профессия', 2600], extra_weapon: ['Вооружение в слот', 550],
    extra_model: ['Добавление модельки на сервер', 900], extra_hparmor: ['Усиление +10 HP / Armor', 320],
};

async function handleShopBuy(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    if (!rolesOf(row).admin) return json(request, { error: 'forbidden' }, 403);
    let body = {}; try { body = await request.json(); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    const item = ADMIN_SHOP[body.itemId];
    if (!item) return json(request, { error: 'unknown_item' }, 400);
    const [title, cost] = item;
    const res = await env.DB.prepare('UPDATE users SET admin_points = admin_points - ? WHERE steamid = ? AND admin_points >= ?').bind(cost, row.steamid, cost).run();
    if (!res || !res.meta || res.meta.changes !== 1) return json(request, { error: 'not_enough_points' }, 400);
    const t = now();
    await env.DB.prepare('INSERT INTO purchases (steamid, item_id, title, cost, created_at) VALUES (?, ?, ?, ?, ?)').bind(row.steamid, body.itemId, title, cost, t).run();
    return json(request, { user: publicUser(await getUser(env, row.steamid)), purchase: { title, cost, createdAt: t, buyer: row.name } });
}

async function handleShopPurchases(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const r = rolesOf(row);
    if (!r.admin) return json(request, { error: 'forbidden' }, 403);
    const q = r.owner
        ? env.DB.prepare('SELECT p.title, p.cost, p.created_at, u.name AS buyer, p.steamid FROM purchases p LEFT JOIN users u ON u.steamid = p.steamid ORDER BY p.id DESC LIMIT 200')
        : env.DB.prepare('SELECT p.title, p.cost, p.created_at, u.name AS buyer, p.steamid FROM purchases p LEFT JOIN users u ON u.steamid = p.steamid WHERE p.steamid = ? ORDER BY p.id DESC LIMIT 200').bind(row.steamid);
    const list = ((await q.all()).results || []).map(x => ({ title: x.title, cost: x.cost, createdAt: x.created_at, buyer: x.buyer || '', steamId64: x.steamid }));
    return json(request, { purchases: list });
}

// =================================================================== ИГРОВЫЕ ЛОГИ С GMOD-СЕРВЕРА
// Сервер шлёт те же JSON-строки, что пишет FUSION.Log в garrysmod/data/eow_logs/ГГГГ-ММ-ДД.txt
const LOGS_KEEP_DAYS = 30;
const LOGS_MAX_LINES = 500;
const LOG_CAT_RE = /^[a-z_]{1,24}$/;
const OWNER_ONLY_LOG_CATS = ['pm'];          // личные сообщения видит только Овнер
const STEAM2_RE = /STEAM_[0-5]:[01]:\d{1,10}/;

function safeEqual(a, b) {
    a = String(a || ''); b = String(b || '');
    if (!a || a.length !== b.length) return false;
    let diff = 0;
    for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
    return diff === 0;
}
async function sha256hex(text) {
    const buf = await crypto.subtle.digest('SHA-256', enc.encode(text));
    return [...new Uint8Array(buf)].map(b => b.toString(16).padStart(2, '0')).join('');
}
function logSid(entry) {
    const d = isObj(entry.data) ? entry.data : {};
    const cand = [d.sid, d.admin, d.a, isObj(d.actor) ? d.actor.steamid : null].find(x => typeof x === 'string' && STEAM2_RE.test(x));
    if (cand) return cand.match(STEAM2_RE)[0];
    const m = String(entry.text || '').match(STEAM2_RE);
    return m ? m[0] : '';
}

async function handleLogsIngest(request, env) {
    if (!env.LOGS_INGEST_KEY || String(env.LOGS_INGEST_KEY).length < 16) return json(request, { error: 'ingest_not_configured' }, 503);
    const h = request.headers.get('Authorization') || '';
    if (!safeEqual(h.startsWith('Bearer ') ? h.slice(7) : '', env.LOGS_INGEST_KEY)) return json(request, { error: 'bad_key' }, 401);
    const raw = await request.text();
    if (raw.length > 2000000) return json(request, { error: 'too_large' }, 413);
    let body; try { body = JSON.parse(raw); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    const lines = Array.isArray(body && body.lines) ? body.lines.slice(0, LOGS_MAX_LINES) : null;
    if (!lines) return json(request, { error: 'bad_shape' }, 400);
    const port = String((body && body.port) || '').slice(0, 12);
    const received = now();
    const rows = [];
    let skipped = 0;
    for (const line of lines) {
        if (typeof line !== 'string' || line.length > 20000) { skipped++; continue; }
        let e; try { e = JSON.parse(line); } catch (err) { skipped++; continue; }
        if (!isObj(e) || typeof e.text !== 'string' || !e.text.trim() || !Number.isFinite(Number(e.t))) { skipped++; continue; }
        const cat = LOG_CAT_RE.test(String(e.cat || '')) ? String(e.cat) : 'other';
        const uid = (await sha256hex((e.port || port) + '|' + line)).slice(0, 40);
        rows.push([uid, Math.floor(Number(e.t)), cat, e.text.slice(0, 4000), logSid(e), String(e.port || port).slice(0, 12), received]);
    }
    // одна SQL-команда на пачку (json_each), чтобы не упираться в лимит запросов бесплатного тарифа
    const SQL_INSERT = "INSERT OR IGNORE INTO server_logs (uid, t, cat, text, sid, port, received) " +
        "SELECT json_extract(value, '$[0]'), json_extract(value, '$[1]'), json_extract(value, '$[2]'), json_extract(value, '$[3]'), " +
        "json_extract(value, '$[4]'), json_extract(value, '$[5]'), json_extract(value, '$[6]') FROM json_each(?)";
    let chunk = [], size = 0;
    const flush = async () => { if (chunk.length) await env.DB.prepare(SQL_INSERT).bind(JSON.stringify(chunk)).run(); chunk = []; size = 0; };
    for (const row of rows) {
        const len = JSON.stringify(row).length;
        if (size + len > 900000) await flush();
        chunk.push(row); size += len;
    }
    await flush();
    // старые записи удаляем понемногу
    await env.DB.prepare('DELETE FROM server_logs WHERE t < ?').bind(received - LOGS_KEEP_DAYS * 86400).run();
    return json(request, { ok: true, accepted: rows.length, skipped });
}

async function handleLogsList(request, env, url) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const r = rolesOf(row);
    if (!r.admin) return json(request, { error: 'forbidden' }, 403);
    const q = url.searchParams;
    const where = [], args = [];
    const cats = (q.get('cat') || '').split(',').map(x => x.trim()).filter(x => LOG_CAT_RE.test(x));
    if (cats.length) { where.push(`cat IN (${cats.map(() => '?').join(',')})`); args.push(...cats); }
    if (!r.owner) { where.push(`cat NOT IN (${OWNER_ONLY_LOG_CATS.map(() => '?').join(',')})`); args.push(...OWNER_ONLY_LOG_CATS); }
    const sid = (q.get('sid') || '').match(STEAM2_RE);
    if (sid) { where.push('(sid = ? OR text LIKE ?)'); args.push(sid[0], '%' + sid[0] + '%'); }
    const search = (q.get('q') || '').trim().slice(0, 80);
    if (search) { where.push("text LIKE ? ESCAPE '\\'"); args.push('%' + search.replace(/[\\%_]/g, c => '\\' + c) + '%'); }
    const before = parseInt(q.get('before') || '', 10), after = parseInt(q.get('after') || '', 10);
    if (Number.isFinite(before)) { where.push('id < ?'); args.push(before); }
    if (Number.isFinite(after)) { where.push('id > ?'); args.push(after); }
    const limit = Math.max(1, Math.min(200, parseInt(q.get('limit') || '80', 10) || 80));
    const sql = `SELECT id, t, cat, text, sid FROM server_logs ${where.length ? 'WHERE ' + where.join(' AND ') : ''} ORDER BY id ${Number.isFinite(after) ? 'ASC' : 'DESC'} LIMIT ?`;
    const list = ((await env.DB.prepare(sql).bind(...args, limit + 1).all()).results || []);
    const hasMore = list.length > limit;
    let logs = list.slice(0, limit);
    if (Number.isFinite(after)) logs = logs.reverse();
    const out = { logs, hasMore };
    if (q.get('stats') === '1') {
        const statWhere = r.owner ? '' : `AND cat NOT IN (${OWNER_ONLY_LOG_CATS.map(() => '?').join(',')})`;
        const st = await env.DB.prepare(`SELECT cat, COUNT(*) AS n FROM server_logs WHERE t >= ? ${statWhere} GROUP BY cat`).bind(now() - 86400, ...(r.owner ? [] : OWNER_ONLY_LOG_CATS)).all();
        out.stats = Object.fromEntries((st.results || []).map(x => [x.cat, x.n]));
        const last = await env.DB.prepare('SELECT MAX(received) AS r, MAX(t) AS t FROM server_logs').first();
        out.lastReceived = last ? last.r || 0 : 0;
        out.lastEvent = last ? last.t || 0 : 0;
        out.canSeePm = r.owner;
    }
    return json(request, out);
}

// =================================================================== ЗАЯВКИ НА ЗАКРЫТЫЙ БЕТА-ТЕСТ
const BETA_SOURCES = {
    discord: 'Discord', youtube: 'YouTube', tiktok: 'TikTok', telegram: 'Telegram', instagram: 'Instagram',
    vk: 'ВКонтакте', friend: 'От друга', search: 'Поиск / сайт', other: 'Другое',
};
const BETA_STATUSES = ['new', 'approved', 'declined'];
const BETA_RATE_PER_HOUR = 6;          // заявок с одного адреса в час

function cleanText(v, max) {
    return String(v || '').replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, '').replace(/\r\n?/g, '\n').trim().slice(0, max);
}
// SteamID в любом виде -> SteamID64 (или ник из ссылки /id/... — его уточняем у Steam)
function parseSteamInput(raw) {
    const s = String(raw || '').trim();
    let m = s.match(/steamcommunity\.com\/profiles\/(7656119\d{10})/i);
    if (m) return { id64: m[1] };
    m = s.match(/steamcommunity\.com\/id\/([A-Za-z0-9_-]{2,32})/i);
    if (m) return { vanity: m[1] };
    m = s.match(/^(7656119\d{10})$/);
    if (m) return { id64: m[1] };
    m = s.match(/^STEAM_[0-5]:([01]):(\d{1,10})$/i);
    if (m) return { id64: (STEAM_ID_BASE + BigInt(m[2]) * 2n + BigInt(m[1])).toString() };
    m = s.match(/^\[?U:1:(\d{1,10})\]?$/i);
    if (m) return { id64: (STEAM_ID_BASE + BigInt(m[1])).toString() };
    return null;
}
async function resolveVanity(name, env) {
    try {
        if (env.STEAM_API_KEY) {
            const r = await fetch(`https://api.steampowered.com/ISteamUser/ResolveVanityURL/v1/?key=${encodeURIComponent(env.STEAM_API_KEY)}&vanityurl=${encodeURIComponent(name)}`);
            const j = await r.json();
            if (j && j.response && j.response.success === 1 && /^7656119\d{10}$/.test(j.response.steamid)) return j.response.steamid;
        }
        const r = await fetch(`https://steamcommunity.com/id/${encodeURIComponent(name)}/?xml=1`, { headers: { 'User-Agent': 'EclipseOfWar-Auth/1.0' } });
        const m = (await r.text()).match(/<steamID64>(7656119\d{10})<\/steamID64>/);
        return m ? m[1] : null;
    } catch (e) { return null; }
}
function betaView(x) {
    return {
        id: x.id, steamId64: x.steamid, steamId2: steamId2(x.steamid), input: x.steam_input, name: x.name, avatar: x.avatar,
        source: x.source, sourceLabel: BETA_SOURCES[x.source] || x.source, comment: x.comment, status: x.status,
        account: x.account, createdAt: x.created_at, updatedAt: x.updated_at, reviewedBy: x.reviewed_by,
    };
}

async function handleBetaApply(request, env) {
    let body;
    try { body = await request.json(); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    if (!isObj(body)) return json(request, { error: 'bad_json' }, 400);
    if (body.website) return json(request, { ok: true });                 // ловушка для ботов
    const source = String(body.source || '');
    if (!BETA_SOURCES[source]) return json(request, { error: 'bad_source' }, 400);
    const comment = cleanText(body.comment, 500);
    if (source === 'other' && comment.length < 2) return json(request, { error: 'comment_required' }, 400);
    const steamInput = cleanText(body.steam, 120);
    const parsed = parseSteamInput(steamInput);
    if (!parsed) return json(request, { error: 'bad_steamid' }, 400);
    const id64 = parsed.id64 || await resolveVanity(parsed.vanity, env);
    if (!id64) return json(request, { error: 'steam_not_found' }, 400);

    const t = now();
    const ip = request.headers.get('CF-Connecting-IP') || '';
    const ipHash = ip ? (await sha256hex(env.TOKEN_SECRET + '|beta|' + ip)).slice(0, 32) : '';
    if (ipHash) {
        const rate = await env.DB.prepare('SELECT COUNT(*) AS n FROM beta_apps WHERE ip_hash = ? AND updated_at > ?').bind(ipHash, t - 3600).first();
        if (rate && rate.n >= BETA_RATE_PER_HOUR) return json(request, { error: 'too_many' }, 429);
    }
    const account = await authUser(request, env);
    const profile = await fetchSteamProfile(id64, env);
    const old = await env.DB.prepare('SELECT id, status FROM beta_apps WHERE steamid = ?').bind(id64).first();
    if (old) {
        await env.DB.prepare('UPDATE beta_apps SET steam_input = ?, name = ?, avatar = ?, source = ?, comment = ?, account = CASE WHEN ? <> \'\' THEN ? ELSE account END, ip_hash = ?, updated_at = ? WHERE id = ?')
            .bind(steamInput, profile.name, profile.avatar, source, comment, account ? account.steamid : '', account ? account.steamid : '', ipHash, t, old.id).run();
    } else {
        await env.DB.prepare('INSERT INTO beta_apps (steamid, steam_input, name, avatar, source, comment, status, account, ip_hash, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, \'new\', ?, ?, ?, ?)')
            .bind(id64, steamInput, profile.name, profile.avatar, source, comment, account ? account.steamid : '', ipHash, t, t).run();
    }
    return json(request, { ok: true, updated: !!old, steamId64: id64, steamId2: steamId2(id64), name: profile.name });
}

async function handleBetaList(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    if (!rolesOf(row).admin) return json(request, { error: 'forbidden' }, 403);
    const { results } = await env.DB.prepare('SELECT * FROM beta_apps ORDER BY id DESC LIMIT 2000').all();
    return json(request, { apps: (results || []).map(betaView), sources: BETA_SOURCES });
}

async function handleBetaUpdate(request, env, id) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    if (!rolesOf(row).admin) return json(request, { error: 'forbidden' }, 403);
    let body = {};
    try { body = await request.json(); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    const app = await env.DB.prepare('SELECT * FROM beta_apps WHERE id = ?').bind(id).first();
    if (!app) return json(request, { error: 'not_found' }, 404);
    if (body && body.delete === true) {
        await env.DB.prepare('DELETE FROM beta_apps WHERE id = ?').bind(id).run();
        return json(request, { ok: true, deleted: true });
    }
    const status = String(body && body.status || '');
    if (!BETA_STATUSES.includes(status)) return json(request, { error: 'bad_status' }, 400);
    await env.DB.prepare('UPDATE beta_apps SET status = ?, reviewed_by = ? WHERE id = ?').bind(status, row.name || row.steamid, id).run();
    const next = await env.DB.prepare('SELECT * FROM beta_apps WHERE id = ?').bind(id).first();
    return json(request, { ok: true, app: betaView(next) });
}

// ---------- Discord: анонсы через вебхук канала ----------
// Ссылка вебхука хранится только здесь (в D1), на сайт она не уходит. Отправляют только Овнеры.
const DISCORD_API = 'https://discord.com/api/v10';
const WEBHOOK_RE = /^https:\/\/(?:(?:canary|ptb)\.)?discord(?:app)?\.com\/api(?:\/v\d+)?\/webhooks\/(\d{15,22})\/([A-Za-z0-9_\-]{30,100})\/?$/;
const DISCORD_DEFAULT_NAME = 'Eclipse of War · Штаб Дантуина';
const DISCORD_COLOR = 0xe03543;
const JOIN_URL = 'http://45.136.204.181:8081/join.html?a=45.136.204.181:27015&p=ave69th';

async function getSetting(env, key) {
    const r = await env.DB.prepare('SELECT value FROM settings WHERE key = ?').bind(key).first();
    if (!r) return null;
    try { return JSON.parse(r.value); } catch (e) { return null; }
}
async function putSetting(env, key, value, by) {
    await env.DB.prepare(`INSERT INTO settings (key, value, updated_at, updated_by) VALUES (?, ?, ?, ?)
        ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at, updated_by = excluded.updated_by`)
        .bind(key, JSON.stringify(value), now(), by || '').run();
}
function parseWebhook(raw) {
    const m = String(raw || '').trim().split('?')[0].match(WEBHOOK_RE);
    return m ? { id: m[1], token: m[2] } : null;
}
async function discordCfg(env) {
    const cfg = (await getSetting(env, 'discord')) || {};
    if (!cfg.id && env.DISCORD_WEBHOOK_URL) {
        const w = parseWebhook(env.DISCORD_WEBHOOK_URL);
        if (w) { cfg.id = w.id; cfg.token = w.token; cfg.fromSecret = true; }
    }
    return cfg;
}
function parsePing(raw) {
    const v = String(raw || '').trim();
    if (!v) return '';
    if (v === '@everyone' || v === '@here') return v;
    const d = v.replace(/\D/g, '');
    return /^\d{15,22}$/.test(d) ? d : null;
}
function pingParts(ping) {
    if (!ping) return { mention: '', allowed: { parse: [] } };
    if (ping === '@everyone' || ping === '@here') return { mention: ping, allowed: { parse: ['everyone'] } };
    return { mention: `<@&${ping}>`, allowed: { roles: [ping] } };
}
function cut(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, n - 1) + '…' : s; }
function postLink(p) { return p.guild_id && p.channel_id && p.message_id ? `https://discord.com/channels/${p.guild_id}/${p.channel_id}/${p.message_id}` : ''; }
function postView(p) {
    return { id: p.id, title: p.title, author: p.author, ping: p.ping, status: p.status, createdAt: p.created_at,
        deletedAt: p.deleted_at || 0, deletedBy: p.deleted_by || '', link: p.status === 'sent' ? postLink(p) : '' };
}
function discordView(cfg, posts) {
    return {
        configured: !!(cfg.id && cfg.token),
        fromSecret: !!cfg.fromSecret,
        webhook: cfg.id ? { id: cfg.id, name: cfg.name || '', channelId: cfg.channelId || '', guildId: cfg.guildId || '',
            avatarUrl: cfg.avatar ? `https://cdn.discordapp.com/avatars/${cfg.id}/${cfg.avatar}.png?size=64` : '' } : null,
        ping: cfg.ping || '',
        username: cfg.username || DISCORD_DEFAULT_NAME,
        updatedBy: cfg.updatedBy || '',
        posts: (posts || []).map(postView),
    };
}
async function discordFetch(cfg, path, init) {
    const res = await fetch(`${DISCORD_API}/webhooks/${cfg.id}/${cfg.token}${path || ''}`, init || {});
    let data = null;
    const txt = await res.text();
    try { data = txt ? JSON.parse(txt) : null; } catch (e) { data = null; }
    return { status: res.status, ok: res.ok, data };
}
function discordError(r) {
    if (r.status === 401 || r.status === 404) return { error: 'webhook_gone', status: 400 };
    if (r.status === 429) return { error: 'rate_limited', retryAfter: (r.data && r.data.retry_after) || 1, status: 429 };
    if (r.status === 400) return { error: 'discord_rejected', detail: r.data && (r.data.message || JSON.stringify(r.data).slice(0, 200)), status: 400 };
    return { error: 'discord_unavailable', status: 502 };
}
async function ownerOnly(request, env) {
    const row = await authUser(request, env);
    if (!row) return { res: json(request, { error: 'unauthorized' }, 401) };
    if (!isOwner(row.steamid)) return { res: json(request, { error: 'forbidden' }, 403) };
    return { row };
}
async function recentPosts(env) {
    const { results } = await env.DB.prepare('SELECT * FROM discord_posts ORDER BY id DESC LIMIT 30').all();
    return results || [];
}

async function handleDiscordGet(request, env) {
    const { row, res } = await ownerOnly(request, env);
    if (res) return res;
    return json(request, discordView(await discordCfg(env), await recentPosts(env)));
}

async function handleDiscordConfig(request, env) {
    const { row, res } = await ownerOnly(request, env);
    if (res) return res;
    let body = {};
    try { body = await request.json(); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    const cfg = (await getSetting(env, 'discord')) || {};
    if ('webhookUrl' in body) {
        const raw = String(body.webhookUrl || '').trim();
        if (!raw) {
            delete cfg.id; delete cfg.token; delete cfg.name; delete cfg.channelId; delete cfg.guildId; delete cfg.avatar;
        } else {
            const w = parseWebhook(raw);
            if (!w) return json(request, { error: 'bad_webhook' }, 400);
            const r = await discordFetch(w, '');
            if (!r.ok) return json(request, { error: r.status === 401 || r.status === 404 ? 'webhook_gone' : 'discord_unavailable' }, 400);
            const d = r.data || {};
            Object.assign(cfg, { id: w.id, token: w.token, name: cut(d.name, 80), channelId: String(d.channel_id || ''), guildId: String(d.guild_id || ''), avatar: d.avatar || '' });
        }
    }
    if ('ping' in body) {
        const ping = parsePing(body.ping);
        if (ping === null) return json(request, { error: 'bad_role' }, 400);
        cfg.ping = ping;
    }
    if ('username' in body) cfg.username = cut(cleanText(body.username, 80), 80) || '';
    cfg.updatedBy = row.name || row.steamid;
    await putSetting(env, 'discord', cfg, row.steamid);
    return json(request, { ok: true, ...discordView(await discordCfg(env), await recentPosts(env)) });
}

async function sendToDiscord(env, cfg, payload) {
    const r = await discordFetch(cfg, '?wait=true', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    return r;
}

async function handleDiscordTest(request, env) {
    const { row, res } = await ownerOnly(request, env);
    if (res) return res;
    const cfg = await discordCfg(env);
    if (!cfg.id) return json(request, { error: 'not_configured' }, 400);
    const r = await sendToDiscord(env, cfg, {
        username: cfg.username || DISCORD_DEFAULT_NAME,
        content: `✅ Сайт eclipseofwar.com подключён к этому каналу. Проверку отправил: ${cut(row.name || row.steamid, 64)}`,
        allowed_mentions: { parse: [] },
    });
    if (!r.ok) { const e = discordError(r); return json(request, e, e.status); }
    return json(request, { ok: true });
}

async function handleDiscordAnnounce(request, env) {
    const { row, res } = await ownerOnly(request, env);
    if (res) return res;
    const cfg = await discordCfg(env);
    if (!cfg.id) return json(request, { error: 'not_configured' }, 400);
    let body = {};
    try { body = await request.json(); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    const title = cut(cleanText(body.title, 240), 240) || 'Оперативный анонс гарнизона Дантуин';
    const time = cut(cleanText(body.time, 100), 100) || 'Не указано';
    const text = cut(String(body.text || '').replace(/\r/g, '').trim(), 4000) || 'Подробности брифинга не указаны.';
    const image = String(body.imageUrl || '').trim();
    const usePing = body.ping !== false;
    const { mention, allowed } = pingParts(usePing ? (cfg.ping || '') : '');
    const author = cut(cleanText(body.author, 80) || row.name || 'Штаб Сектора', 80);
    const embed = {
        title: cut(`📡 ${title}`, 256),
        description: text,
        color: DISCORD_COLOR,
        fields: [
            { name: '🕒 Время сбора (МСК)', value: cut('`' + time + '`', 1024), inline: true },
            { name: '🎖️ Опубликовал', value: cut('`' + author + '`', 1024), inline: true },
            { name: '🌐 Сервер', value: `[Подключиться к Garry's Mod](${JOIN_URL})`, inline: false },
        ],
        footer: { text: 'ECLIPSE OF WAR · Сектор Райобалло · Система Дантуин' },
        timestamp: new Date().toISOString(),
    };
    if (/^https:\/\/\S{8,1000}$/.test(image)) embed.image = { url: image };
    const payload = {
        username: cfg.username || DISCORD_DEFAULT_NAME,
        content: mention ? `${mention} **Внимание личному составу! Получена новая сводка командования:**` : '📡 **Новая сводка командования Сектора Райобалло:**',
        allowed_mentions: allowed,
        embeds: [embed],
    };
    const r = await sendToDiscord(env, cfg, payload);
    if (!r.ok) { const e = discordError(r); return json(request, e, e.status); }
    const msg = r.data || {};
    const ins = await env.DB.prepare(`INSERT INTO discord_posts (title, message_id, channel_id, guild_id, webhook_id, ping, author, author_id, status, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'sent', ?)`)
        .bind(title, String(msg.id || ''), String(msg.channel_id || cfg.channelId || ''), String(cfg.guildId || ''), cfg.id, usePing ? (cfg.ping || '') : '', row.name || row.steamid, row.steamid, now()).run();
    const id = ins && ins.meta && ins.meta.last_row_id;
    const post = id ? await env.DB.prepare('SELECT * FROM discord_posts WHERE id = ?').bind(id).first() : null;
    return json(request, { ok: true, post: post ? postView(post) : null, link: post ? postLink(post) : '' });
}

async function handleDiscordDelete(request, env, id) {
    const { row, res } = await ownerOnly(request, env);
    if (res) return res;
    const post = await env.DB.prepare('SELECT * FROM discord_posts WHERE id = ?').bind(id).first();
    if (!post) return json(request, { error: 'not_found' }, 404);
    if (post.status === 'deleted') return json(request, { ok: true, post: postView(post) });
    const cfg = await discordCfg(env);
    if (post.message_id && cfg.id === post.webhook_id && cfg.token) {
        const r = await discordFetch(cfg, `/messages/${post.message_id}`, { method: 'DELETE' });
        if (!r.ok && r.status !== 404) { const e = discordError(r); return json(request, e, e.status); }
    } else if (post.message_id) {
        return json(request, { error: 'other_webhook' }, 400);
    }
    await env.DB.prepare("UPDATE discord_posts SET status = 'deleted', deleted_at = ?, deleted_by = ? WHERE id = ?").bind(now(), row.name || row.steamid, id).run();
    const next = await env.DB.prepare('SELECT * FROM discord_posts WHERE id = ?').bind(id).first();
    return json(request, { ok: true, post: postView(next) });
}

// =================================================================== РАПОРТАЦИЯ (рапорта игроков)
// Игрок подаёт рапорт на сайте → воркер отправляет его в Discord (красная плашка, ветка по категории)
// и сохраняет в таблицу unit_reports. Ссылка вебхука — только в секрете REPORTS_WEBHOOK_URL, на сайт не уходит.
// Читать рапорта подразделения могут вошедшие игроки этого подразделения; менять/удалять с сайта нельзя.
const REPORT_COLOR = 0xe53935;
const REPORT_CATEGORIES = {
    post:     ['Пост/патруль',        '1567979360097673390'],
    recon:    ['Разведка',            '1567979105905934438'],
    lecture:  ['Лекция',              '1567978637909819522'],
    sortie:   ['Боевой вылет',        '1567978286431211624'],
    training: ['Тренировка',          '1567977727695519835'],
    rank:     ['Повышение/понижение', '1567976726154190908'],
    transfer: ['Перевод',             '1567979876076621915'],
    other:    ['Другое',              ''],                    // без ветки: в сам канал вебхука
};
const REPORT_ADDRESSEES = { unit_cmd: 'Командиру подразделения', sector_hq: 'Штаб сектора' };
const REPORT_UNIT_RE = /^(?:[a-z_]{1,32}|div:[^\u0000-\u001f<>"'`\\]{1,60})$/;
const REPORT_ID_RE = /^rep_[a-z0-9]{6,40}$/;
const REPORT_MAX_PHOTOS = 6;
const REPORT_MAX_TOTAL_BYTES = 9.5 * 1024 * 1024;      // лимит вложений Discord без бустов — 10 МБ
const REPORT_PHOTO_TYPES = { 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp', 'image/gif': 'gif' };
const REPORT_RATE = 5;                                  // рапортов от одного игрока за 10 минут

function reportsWebhook(env) { return parseWebhook(env.REPORTS_WEBHOOK_URL || ''); }

// Какие подразделения видит игрок. null — любые (штаб сайта или игрок ещё не привязан к составу корпуса).
async function reportUnitsFor(env, row) {
    const r = rolesOf(row);
    if (r.owner || r.admin || r.commander) return null;
    const g = await env.DB.prepare("SELECT DISTINCT unit FROM game_characters WHERE steamid = ? AND unit <> ''").bind(row.steamid).all();
    const gameUnits = ((g && g.results) || []).map(x => x.unit);
    if (gameUnits.length) return gameUnits;                 // данные с игрового сервера — главный источник
    const c = await env.DB.prepare("SELECT value FROM content WHERE key = 'rosters'").first();
    let rosters = null; try { rosters = c ? JSON.parse(c.value) : null; } catch (e) { rosters = null; }
    const units = [];
    if (isObj(rosters)) {
        const sid2 = steamId2(row.steamid);
        for (const [key, corps] of Object.entries(rosters)) {
            const list = isObj(corps) && Array.isArray(corps.soldiers) ? corps.soldiers : [];
            if (list.some(s => isObj(s) && (String(s.steamId64 || '') === row.steamid || String(s.steamId || '') === sid2))) units.push(key);
        }
    }
    return units.length ? units : null;
}

function reportView(x) {
    return {
        id: x.id, unit: x.unit, unitTitle: x.unit_title, category: x.category, addressee: x.addressee,
        subject: x.subject, body: x.body, signature: x.signature, charName: x.char_name,
        authorSteamId: x.author_id, steamName: x.author_name, photos: x.photos | 0,
        time: new Date(x.created_at * 1000).toISOString(),
    };
}

async function handleReportsList(request, env, url) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const unit = String(url.searchParams.get('unit') || '');
    if (!REPORT_UNIT_RE.test(unit)) return json(request, { error: 'bad_unit' }, 400);
    const allowed = await reportUnitsFor(env, row);
    if (allowed && !allowed.includes(unit)) return json(request, { error: 'unit_forbidden' }, 403);
    const { results } = await env.DB.prepare('SELECT * FROM unit_reports WHERE unit = ? ORDER BY created_at DESC LIMIT 200').bind(unit).all();
    return json(request, { reports: (results || []).map(reportView), units: allowed });
}

function reportFiles(form) {
    const photos = form.getAll('photos').filter(f => f && typeof f !== 'string');
    const sig = form.get('signature');
    return { photos, sig: sig && typeof sig !== 'string' ? sig : null };
}

async function handleReportCreate(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const hook = reportsWebhook(env);
    if (!hook) return json(request, { error: 'reports_not_configured' }, 503);
    if (Number(request.headers.get('Content-Length') || 0) > REPORT_MAX_TOTAL_BYTES + 200000) return json(request, { error: 'too_large' }, 413);

    let form;
    try { form = await request.formData(); } catch (e) { return json(request, { error: 'bad_form' }, 400); }
    let p; try { p = JSON.parse(String(form.get('payload') || '')); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    if (!isObj(p)) return json(request, { error: 'bad_json' }, 400);

    const cat = REPORT_CATEGORIES[p.category];
    if (!cat) return json(request, { error: 'bad_category' }, 400);
    const addressee = REPORT_ADDRESSEES[p.addressee];
    if (!addressee) return json(request, { error: 'bad_addressee' }, 400);
    const unit = String(p.unit || '');
    if (!REPORT_UNIT_RE.test(unit)) return json(request, { error: 'bad_unit' }, 400);
    const allowed = await reportUnitsFor(env, row);
    if (allowed && !allowed.includes(unit)) return json(request, { error: 'unit_forbidden' }, 403);

    const subject = cleanText(p.subject, 200);
    const text = cleanText(p.body, 3500);
    const signature = cleanText(p.signature, 80);
    const charName = cleanText(p.charName, 80) || row.name || row.steamid;
    const unitTitle = cleanText(p.unitTitle, 80) || unit;
    if (!subject || !text) return json(request, { error: 'empty_fields' }, 400);
    if (!signature) return json(request, { error: 'no_signature' }, 400);

    const own = await env.DB.prepare('SELECT name FROM game_characters WHERE steamid = ? AND unit = ?').bind(row.steamid, unit).all();
    const ownNames = ((own && own.results) || []).map(x => x.name);
    if (ownNames.length && !ownNames.includes(charName)) return json(request, { error: 'bad_character' }, 400);

    const t = now();
    const rate = await env.DB.prepare('SELECT COUNT(*) AS n FROM unit_reports WHERE author_id = ? AND created_at > ?').bind(row.steamid, t - 600).first();
    if (rate && rate.n >= REPORT_RATE) return json(request, { error: 'too_many' }, 429);

    const { photos, sig } = reportFiles(form);
    if (photos.length > REPORT_MAX_PHOTOS) return json(request, { error: 'too_many_photos' }, 400);
    let total = 0;
    for (const f of photos) { if (!REPORT_PHOTO_TYPES[f.type]) return json(request, { error: 'bad_photo' }, 400); total += f.size; }
    if (sig && (sig.type !== 'image/png' || sig.size > 300000)) return json(request, { error: 'bad_signature' }, 400);
    total += sig ? sig.size : 0;
    if (total > REPORT_MAX_TOTAL_BYTES) return json(request, { error: 'too_large' }, 413);

    const id = 'rep_' + t.toString(36) + crypto.randomUUID().replace(/-/g, '').slice(0, 10);
    const siteUrl = 'https://eclipseofwar.com/#report-' + id;
    const main = {
        color: REPORT_COLOR,
        url: siteUrl,
        title: cut('Рапорт · ' + subject, 256),
        description: cut(text, 4000),
        fields: [
            { name: 'Категория', value: cat[0], inline: true },
            { name: 'Адресат', value: addressee, inline: true },
            { name: 'Подразделение', value: cut(unitTitle, 1024), inline: true },
            { name: 'Подал', value: cut(`${charName}\nSteam: ${row.name || '—'} (${row.steamid})`, 1024), inline: false },
            { name: 'Подпись', value: cut(signature, 1024), inline: false },
        ],
        footer: { text: 'Eclipse of War · Рапортация' },
        timestamp: new Date(t * 1000).toISOString(),
    };
    const embeds = [main];
    const files = [];
    photos.forEach((f, i) => {
        const name = `photo_${i + 1}.${REPORT_PHOTO_TYPES[f.type]}`;
        files.push([f, name]);
        if (i === 0) main.image = { url: 'attachment://' + name };
        else embeds.push({ url: siteUrl, color: REPORT_COLOR, image: { url: 'attachment://' + name } }); // галерея в одной плашке
    });
    if (sig) { files.push([sig, 'signature.png']); main.thumbnail = { url: 'attachment://signature.png' }; }
    const payload = {
        username: 'EOW · Рапортация',
        embeds,
        attachments: files.map(([, name], i) => ({ id: i, filename: name })),
        allowed_mentions: { parse: [] },
    };
    const send = (threadId, threadName) => {
        const fd = new FormData();
        fd.append('payload_json', JSON.stringify(threadName ? { ...payload, thread_name: cut(threadName, 100) } : payload));
        files.forEach(([f, name], i) => fd.append(`files[${i}]`, f, name));
        return discordFetch(hook, '?wait=true' + (threadId ? '&thread_id=' + threadId : ''), { method: 'POST', body: fd });
    };
    let r = await send(cat[1], '');
    // если канал вебхука — форум, для «Другое» создаём отдельную ветку
    if (!r.ok && !cat[1] && r.data && r.data.code === 220001) r = await send('', `${cat[0]} · ${subject}`);
    if (!r.ok) { const e = discordError(r); return json(request, e, e.status); }
    const msg = r.data || {};

    await env.DB.prepare(`INSERT INTO unit_reports (id, unit, unit_title, category, addressee, subject, body, signature, char_name,
            author_id, author_name, photos, thread_id, message_id, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`)
        .bind(id, unit, unitTitle, p.category, p.addressee, subject, text, signature, charName, row.steamid, row.name || '',
            photos.length, cat[1] || String(msg.channel_id || ''), String(msg.id || ''), t).run();
    const saved = await env.DB.prepare('SELECT * FROM unit_reports WHERE id = ?').bind(id).first();
    return json(request, { ok: true, report: reportView(saved) });
}

// свежие ссылки на скриншоты и подпись (ссылки Discord CDN со временем протухают)
async function handleReportAttachments(request, env, id) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const rep = await env.DB.prepare('SELECT * FROM unit_reports WHERE id = ?').bind(id).first();
    if (!rep) return json(request, { error: 'not_found' }, 404);
    const allowed = await reportUnitsFor(env, row);
    if (allowed && !allowed.includes(rep.unit)) return json(request, { error: 'unit_forbidden' }, 403);
    const hook = reportsWebhook(env);
    if (!hook || !rep.message_id) return json(request, { photos: [], signature: '' });
    const r = await discordFetch(hook, `/messages/${rep.message_id}` + (rep.thread_id ? '?thread_id=' + rep.thread_id : ''));
    if (!r.ok) { const e = discordError(r); return json(request, e, e.status); }
    const atts = ((r.data && r.data.attachments) || []).filter(a => /^https:\/\/[^"'<>\s]+$/.test(a.url || ''));
    const sig = atts.find(a => a.filename === 'signature.png');
    return json(request, {
        photos: atts.filter(a => a !== sig).map(a => ({ url: a.url, name: a.filename })),
        signature: sig ? sig.url : '',
    });
}

// =================================================================== КАРТИНКИ САЙТА (вместо протухающих ссылок Discord)
// Овнер/администратор/командир загружает картинку → она хранится в D1 и отдаётся по постоянной ссылке /media/<id>.
const MEDIA_MAX_BYTES = 1500000;
const MEDIA_TYPES = ['image/jpeg', 'image/png', 'image/webp', 'image/gif'];
const MEDIA_ID_RE = /^m_[a-z0-9]{8,40}$/;

async function handleMediaUpload(request, env, url) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const r = rolesOf(row);
    if (!(r.owner || r.admin || r.commander)) return json(request, { error: 'forbidden' }, 403);
    if (Number(request.headers.get('Content-Length') || 0) > MEDIA_MAX_BYTES + 100000) return json(request, { error: 'too_large' }, 413);
    let form; try { form = await request.formData(); } catch (e) { return json(request, { error: 'bad_form' }, 400); }
    const file = form.get('file');
    if (!file || typeof file === 'string') return json(request, { error: 'no_file' }, 400);
    if (!MEDIA_TYPES.includes(file.type)) return json(request, { error: 'bad_type' }, 400);
    if (file.size > MEDIA_MAX_BYTES) return json(request, { error: 'too_large' }, 413);
    const t = now();
    const id = 'm_' + t.toString(36) + crypto.randomUUID().replace(/-/g, '').slice(0, 12);
    await env.DB.prepare('INSERT INTO media (id, mime, data, size, created_at, created_by) VALUES (?, ?, ?, ?, ?, ?)')
        .bind(id, file.type, await file.arrayBuffer(), file.size, t, row.steamid).run();
    return json(request, { ok: true, id, url: `${url.origin}/media/${id}` });
}

async function handleMediaGet(request, env, id) {
    const m = await env.DB.prepare('SELECT mime, data FROM media WHERE id = ?').bind(id).first();
    if (!m) return new Response('not found', { status: 404 });
    const body = m.data instanceof ArrayBuffer ? m.data : new Uint8Array(m.data);
    return new Response(body, { headers: {
        'Content-Type': MEDIA_TYPES.includes(m.mime) ? m.mime : 'application/octet-stream',
        'Cache-Control': 'public, max-age=31536000, immutable',
        'X-Content-Type-Options': 'nosniff',
        'Access-Control-Allow-Origin': '*',
    } });
}

// =================================================================== СИНХРОНИЗАЦИЯ С ИГРОВЫМ СЕРВЕРОМ (GMod)
// Игровой сервер сам отправляет данные персонажей (аддон eow_site_sync). Доступа к базе сервера снаружи нет.
// Ключ — секрет GAME_SYNC_KEY (если не задан, используется LOGS_INGEST_KEY). Игрок на сайте видит только своих персонажей.
const GAME_CHAR_ID_RE = /^[A-Za-z0-9_\-:.]{1,64}$/;
const GAME_MAX_CHARS = 500;
const gText = (v, n) => cleanName(String(v == null ? '' : v)).slice(0, n);
const gInt = (v, max = 2e9) => { const n = Math.floor(Number(v)); return Number.isFinite(n) ? Math.max(0, Math.min(max, n)) : 0; };

// подробности персонажа (аддон eow_site_sync v2); всё, чего нет, — пустое
function gameExtra(c) {
    const st = isObj(c.stats) ? c.stats : {};
    return JSON.stringify({
        number: gText(c.number, 8), callsign: gText(c.callsign, 48), spec: gText(c.spec, 48), position: gText(c.position, 48),
        blood: gText(c.blood, 16), levelMax: gInt(c.levelMax, 100000), xpNeed: gInt(c.xpNeed), jediClass: gText(c.jediClass, 32),
        stats: { damage: gInt(st.damage), heals: gInt(st.heals), repairs: gInt(st.repairs), ops: gInt(st.ops), tasks: gInt(st.tasks), hacks: gInt(st.hacks) },
        online: c.online === true, lastSeen: gInt(c.lastSeen),
    });
}

function gameKeyOk(request, env) {
    const key = env.GAME_SYNC_KEY || env.LOGS_INGEST_KEY;
    if (!key || String(key).length < 16) return null;
    const h = request.headers.get('Authorization') || '';
    return safeEqual(h.startsWith('Bearer ') ? h.slice(7) : '', key);
}

async function handleGameSync(request, env) {
    const ok = gameKeyOk(request, env);
    if (ok === null) return json(request, { error: 'sync_not_configured' }, 503);
    if (!ok) return json(request, { error: 'bad_key' }, 401);
    const raw = await request.text();
    if (raw.length > 1500000) return json(request, { error: 'too_large' }, 413);
    let body; try { body = JSON.parse(raw); } catch (e) { return json(request, { error: 'bad_json' }, 400); }
    if (!isObj(body)) return json(request, { error: 'bad_json' }, 400);
    const t = now();
    const chars = (Array.isArray(body.characters) ? body.characters : []).slice(0, GAME_MAX_CHARS);
    const accounts = (Array.isArray(body.accounts) ? body.accounts : []).slice(0, GAME_MAX_CHARS);
    const replace = (Array.isArray(body.replace) ? body.replace : []).map(String).filter(s => /^7656119\d{10}$/.test(s)).slice(0, 200);

    const rows = [];
    let skipped = 0;
    for (const c of chars) {
        const sid = String(c && c.steamid || '');
        const cid = String(c && c.id != null ? c.id : '');
        if (!/^7656119\d{10}$/.test(sid) || !GAME_CHAR_ID_RE.test(cid)) { skipped++; continue; }
        let unit = String(c.unit || '').trim().toLowerCase().slice(0, 64);
        if (unit && !REPORT_UNIT_RE.test(unit)) unit = '';
        rows.push([sid, cid, gText(c.name, 64) || 'Без имени', gText(c.rank, 48), unit, gText(c.unitTitle, 64), gText(c.profession, 64),
            gInt(c.level, 100000), gInt(c.xp), gInt(c.credits), gInt(c.playtime), gInt(c.kills), gInt(c.deaths),
            Math.max(-1e6, Math.min(1e6, Math.floor(Number(c.reputation) || 0))), gInt(c.reprimands, 100), gInt(c.joined) || t, t, gameExtra(c)]);
    }
    const stmts = [];
    // удаляем персонажей, которых больше нет у игрока (сервер прислал полный список по этим SteamID)
    for (const sid of replace) {
        const keep = rows.filter(r => r[0] === sid).map(r => r[1]);
        stmts.push(env.DB.prepare('DELETE FROM game_characters WHERE steamid = ? AND char_id NOT IN (SELECT value FROM json_each(?))').bind(sid, JSON.stringify(keep)));
    }
    if (rows.length) {
        stmts.push(env.DB.prepare(`INSERT INTO game_characters (steamid, char_id, name, rank, unit, unit_title, profession, level, xp, credits,
                playtime, kills, deaths, reputation, reprimands, first_seen, updated_at, extra)
            SELECT json_extract(value,'$[0]'), json_extract(value,'$[1]'), json_extract(value,'$[2]'), json_extract(value,'$[3]'), json_extract(value,'$[4]'),
                json_extract(value,'$[5]'), json_extract(value,'$[6]'), json_extract(value,'$[7]'), json_extract(value,'$[8]'), json_extract(value,'$[9]'),
                json_extract(value,'$[10]'), json_extract(value,'$[11]'), json_extract(value,'$[12]'), json_extract(value,'$[13]'), json_extract(value,'$[14]'),
                json_extract(value,'$[15]'), json_extract(value,'$[16]'), json_extract(value,'$[17]') FROM json_each(?) WHERE true
            ON CONFLICT(steamid, char_id) DO UPDATE SET name = excluded.name, rank = excluded.rank, unit = excluded.unit, unit_title = excluded.unit_title,
                profession = excluded.profession, level = excluded.level, xp = excluded.xp, credits = excluded.credits, playtime = excluded.playtime,
                kills = excluded.kills, deaths = excluded.deaths, reputation = excluded.reputation, reprimands = excluded.reprimands, updated_at = excluded.updated_at,
                extra = excluded.extra`)
            .bind(JSON.stringify(rows)));
    }
    const accRows = accounts.filter(a => a && /^7656119\d{10}$/.test(String(a.steamid || ''))).map(a => [String(a.steamid), gInt(a.donate), t]);
    if (accRows.length) {
        stmts.push(env.DB.prepare(`INSERT INTO game_accounts (steamid, donate, updated_at)
            SELECT json_extract(value,'$[0]'), json_extract(value,'$[1]'), json_extract(value,'$[2]') FROM json_each(?) WHERE true
            ON CONFLICT(steamid) DO UPDATE SET donate = excluded.donate, updated_at = excluded.updated_at`).bind(JSON.stringify(accRows)));
    }
    if (stmts.length) await env.DB.batch(stmts);
    return json(request, { ok: true, characters: rows.length, accounts: accRows.length, skipped });
}

function gameCharView(x) {
    let extra = {};
    try { extra = JSON.parse(x.extra || '{}'); } catch (e) { extra = {}; }
    if (!isObj(extra)) extra = {};
    return {
        ...extra,
        id: x.char_id, name: x.name, rank: x.rank, unit: x.unit, unitTitle: x.unit_title, profession: x.profession,
        level: x.level, xp: x.xp, credits: x.credits, playtime: x.playtime, kills: x.kills, deaths: x.deaths,
        reputation: x.reputation, reprimands: x.reprimands, joined: x.first_seen, updatedAt: x.updated_at,
        // «в игре» — только если сервер присылал данные недавно (онлайн обновляется каждые 5 минут)
        online: extra.online === true && now() - (x.updated_at | 0) < 900,
    };
}

async function handleMyGame(request, env) {
    const row = await authUser(request, env);
    if (!row) return json(request, { error: 'unauthorized' }, 401);
    const { results } = await env.DB.prepare('SELECT * FROM game_characters WHERE steamid = ? ORDER BY updated_at DESC LIMIT 20').bind(row.steamid).all();
    const acc = await env.DB.prepare('SELECT donate, updated_at FROM game_accounts WHERE steamid = ?').bind(row.steamid).first();
    return json(request, {
        characters: (results || []).map(gameCharView),
        account: acc ? { donateBalance: acc.donate | 0, updatedAt: acc.updated_at } : null,
    });
}

export default {
    async fetch(request, env) {
        const url = new URL(request.url);
        if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: corsHeaders(request) });

        if (!env.DB) return json(request, { error: 'D1 база не привязана: добавьте привязку D1 с именем DB' }, 500);
        if (!env.TOKEN_SECRET || env.TOKEN_SECRET.length < 16) return json(request, { error: 'Не задан секрет TOKEN_SECRET (минимум 16 символов)' }, 500);
        await ensureSchema(env.DB);

        try {
            const p = url.pathname.replace(/\/+$/, '') || '/';
            if (request.method === 'GET' && p === '/') return json(request, { ok: true, service: 'Eclipse of War — Steam auth' });
            if (request.method === 'GET' && p === '/auth/steam') return handleSteamStart(request, url);
            if (request.method === 'GET' && p === '/auth/steam/callback') return handleSteamCallback(request, env, url);
            if (request.method === 'GET' && p === '/api/me') return handleMe(request, env);
            if (request.method === 'GET' && p === '/api/users') return handleUsers(request, env);
            const m = p.match(/^\/api\/users\/(7656119\d{10})$/);
            if (request.method === 'POST' && m) return handleUpdateUser(request, env, m[1]);
            if (request.method === 'GET' && p === '/api/content') return handleGetContent(request, env);
            const ck = p.match(/^\/api\/content\/([a-z]{1,20})$/);
            if (request.method === 'POST' && ck) return handleSaveContent(request, env, ck[1]);
            if (request.method === 'POST' && p === '/api/shop/buy') return handleShopBuy(request, env);
            if (request.method === 'GET' && p === '/api/shop/purchases') return handleShopPurchases(request, env);
            if (request.method === 'POST' && p === '/api/logs/ingest') return handleLogsIngest(request, env);
            if (request.method === 'GET' && p === '/api/logs') return handleLogsList(request, env, url);
            if (request.method === 'POST' && p === '/api/beta/apply') return handleBetaApply(request, env);
            if (request.method === 'GET' && p === '/api/beta') return handleBetaList(request, env);
            const bm = p.match(/^\/api\/beta\/(\d{1,9})$/);
            if (request.method === 'POST' && bm) return handleBetaUpdate(request, env, Number(bm[1]));
            if (request.method === 'GET' && p === '/api/discord') return handleDiscordGet(request, env);
            if (request.method === 'POST' && p === '/api/discord/config') return handleDiscordConfig(request, env);
            if (request.method === 'POST' && p === '/api/discord/test') return handleDiscordTest(request, env);
            if (request.method === 'POST' && p === '/api/discord/announce') return handleDiscordAnnounce(request, env);
            const dm = p.match(/^\/api\/discord\/posts\/(\d{1,9})\/delete$/);
            if (request.method === 'POST' && dm) return handleDiscordDelete(request, env, Number(dm[1]));
            if (request.method === 'GET' && p === '/api/reports') return handleReportsList(request, env, url);
            if (request.method === 'POST' && p === '/api/reports') return handleReportCreate(request, env);
            const ra = p.match(/^\/api\/reports\/(rep_[a-z0-9]{6,40})\/attachments$/);
            if (request.method === 'GET' && ra) return handleReportAttachments(request, env, ra[1]);
            if (request.method === 'POST' && p === '/api/media') return handleMediaUpload(request, env, url);
            const md = p.match(/^\/media\/(m_[a-z0-9]{8,40})$/);
            if (request.method === 'GET' && md) return handleMediaGet(request, env, md[1]);
            if (request.method === 'POST' && p === '/api/game/sync') return handleGameSync(request, env);
            if (request.method === 'GET' && p === '/api/me/game') return handleMyGame(request, env);
            return json(request, { error: 'not_found' }, 404);
        } catch (e) {
            return json(request, { error: 'server_error' }, 500);
        }
    },
};
