--[[
    Эмоции — клиент.  Файл: gamemode/modules/animations/cl_emoteclip.lua
    Проигрывает анимации из cl_emotedata.lua (Mixamo -> ValveBiped) при построении скелета игрока
    (BuildBonePositions), поверх любой анимации движка:
      • всё тело — лёжа на спине, упражнение пресса, «умолять», сидя на поверхности;
      • верх тела относительно таза — воинское приветствие (ноги идут своей анимацией, можно идти шагом).
    Что играть, решают:
      • стойка из кругового меню с полем clip (sh_stances.lua) — сервер ставит FusionStance;
      • сидение (Alt + E, sv_emotes.lua) — игрок в невидимом сиденье с меткой EOWSit;
      • упражнение пресса — повтор идёт, только когда игрок попал по клавише (мини-игра ниже),
        иначе персонаж лежит в исходном положении.
    Вход и выход из анимации плавные (S.Settings.BlendTime), смена одной эмоции на другую — сразу
    из позы в позу.
]]

FUSION = FUSION or {}
FUSION.Stances = FUSION.Stances or {}
FUSION.Emotes = FUSION.Emotes or {}
FUSION.EmoteClip = FUSION.EmoteClip or {}
local S = FUSION.Stances
local EM = FUSION.Emotes
local EC = FUSION.EmoteClip

-----------------------------------------------------------
-- ДАННЫЕ: распаковка cl_emotedata.lua (тот же формат, что у анимаций с винтовкой)
-----------------------------------------------------------
local ED
local function data()
    if ED then return ED end
    local D = FUSION.EmoteData
    if not D or not D.clips or not D.bones then return nil end
    local ALPHA = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    local val = {}
    for i = 1, 64 do val[ALPHA:byte(i)] = i - 1 end
    local out = { clips = {} }
    for key, c in pairs(D.clips) do
        local s, pos, n = c.q, 1, c.n
        local function series(str)
            local res, a, b = {}, 0, 0
            for i = 1, n do
                local u, mul = 0, 1
                while true do
                    local d = val[str:byte(pos)]
                    pos = pos + 1
                    if d >= 32 then u = u + (d - 32) * mul mul = mul * 32
                    else u = u + d * mul break end
                end
                local r = (u % 2 == 0) and (u / 2) or (-(u + 1) / 2)
                local v = r + ((i == 1 and 0) or (i == 2 and a) or (2 * a - b))
                b, a = a, v
                res[i] = v
            end
            return res
        end
        local bones = D.bones[c.layer] or D.bones.full
        local rot = {}
        for _, bn in ipairs(bones) do
            local X, Y, Z = series(s), series(s), series(s)
            local arr = {}
            for i = 1, n do
                local x, y, z = X[i] / D.q, Y[i] / D.q, Z[i] / D.q
                arr[i] = { x, y, z, math.sqrt(math.max(0, 1 - x * x - y * y - z * z)) }
            end
            rot[bn] = arr
        end
        local pel
        if c.p then
            s, pos = c.p, 1
            local X, Y, Z = series(c.p), series(c.p), series(c.p)
            pel = {}
            for i = 1, n do pel[i] = { X[i] / D.p, Y[i] / D.p, Z[i] / D.p } end
        end
        out.clips[key] = {
            key = key, fps = c.fps, n = n, loop = c.loop, upper = c.layer == "upper", anchor = c.anchor,
            rot = rot, pel = pel, fing = c.f or {},
            len = c.loop and n / c.fps or math.max(n - 1, 1) / c.fps,
        }
    end
    ED = out
    EC.Clips = out.clips
    return ED
end
EC.Data = data

-----------------------------------------------------------
-- МАТЕМАТИКА (таблицы 3x3 по строкам)
-----------------------------------------------------------
local function q2m(q)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    return { { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
             { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
             { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) } }
end
local function mmul(A, B)
    local R = {}
    for i = 1, 3 do
        R[i] = {}
        for j = 1, 3 do R[i][j] = A[i][1] * B[1][j] + A[i][2] * B[2][j] + A[i][3] * B[3][j] end
    end
    return R
end
local function mv(A, v) return { A[1][1] * v[1] + A[1][2] * v[2] + A[1][3] * v[3], A[2][1] * v[1] + A[2][2] * v[2] + A[2][3] * v[3], A[3][1] * v[1] + A[3][2] * v[2] + A[3][3] * v[3] } end
local function quatOf(R)
    local tr = R[1][1] + R[2][2] + R[3][3]
    local x, y, z, w
    if tr > 0 then
        local s = math.sqrt(tr + 1) * 2
        w, x, y, z = 0.25 * s, (R[3][2] - R[2][3]) / s, (R[1][3] - R[3][1]) / s, (R[2][1] - R[1][2]) / s
    elseif R[1][1] > R[2][2] and R[1][1] > R[3][3] then
        local s = math.sqrt(1 + R[1][1] - R[2][2] - R[3][3]) * 2
        w, x, y, z = (R[3][2] - R[2][3]) / s, 0.25 * s, (R[1][2] + R[2][1]) / s, (R[1][3] + R[3][1]) / s
    elseif R[2][2] > R[3][3] then
        local s = math.sqrt(1 + R[2][2] - R[1][1] - R[3][3]) * 2
        w, x, y, z = (R[1][3] - R[3][1]) / s, (R[1][2] + R[2][1]) / s, 0.25 * s, (R[2][3] + R[3][2]) / s
    else
        local s = math.sqrt(1 + R[3][3] - R[1][1] - R[2][2]) * 2
        w, x, y, z = (R[2][1] - R[1][2]) / s, (R[1][3] + R[3][1]) / s, (R[2][3] + R[3][2]) / s, 0.25 * s
    end
    return { x, y, z, w }
end
local function qslerp(a, b, t)
    local dot = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    local sg = 1
    if dot < 0 then dot, sg = -dot, -1 end
    local ka, kb
    if dot > 0.9995 then ka, kb = 1 - t, t
    else
        local th = math.acos(dot)
        local sn = math.sin(th)
        ka, kb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
    end
    local q = { a[1] * ka + b[1] * kb * sg, a[2] * ka + b[2] * kb * sg, a[3] * ka + b[3] * kb * sg, a[4] * ka + b[4] * kb * sg }
    local l = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    return { q[1] / l, q[2] / l, q[3] / l, q[4] / l }
end
local function slerpM(A, B, t)
    if t <= 0 then return A end
    if t >= 1 then return B end
    return q2m(qslerp(quatOf(A), quatOf(B), t))
end
local function rotOf(m)
    local R, s = {}, 1
    for c = 1, 3 do
        local l = math.sqrt(m:GetField(1, c) ^ 2 + m:GetField(2, c) ^ 2 + m:GetField(3, c) ^ 2)
        if c == 1 then s = l end
        for r = 1, 3 do R[r] = R[r] or {} R[r][c] = l > 1e-9 and m:GetField(r, c) / l or 0 end
    end
    return R, s
end
local function setRot(m, R, s)
    for r = 1, 3 do for c = 1, 3 do m:SetField(r, c, R[r][c] * s) end end
end
local function Rz(deg)
    local a = math.rad(deg)
    local c, s = math.cos(a), math.sin(a)
    return { { c, -s, 0 }, { s, c, 0 }, { 0, 0, 1 } }
end
local function ease(x)
    x = math.Clamp(x, 0, 1)
    return x * x * x * (x * (x * 6 - 15) + 10)
end

-----------------------------------------------------------
-- ОСИ МОДЕЛИ: оси данных (SMD: вперёд -Y) -> мир. Как у анимаций с винтовкой: по позе таза
-- в обычной стойке выбирается один из четырёх разворотов, результат запоминается для модели.
-----------------------------------------------------------
local AXES = {
    { { 0, -1, 0 }, { 1, 0, 0 }, { 0, 0, 1 } },
    { { 0, 1, 0 }, { -1, 0, 0 }, { 0, 0, 1 } },
    { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 } },
    { { -1, 0, 0 }, { 0, -1, 0 }, { 0, 0, 1 } },
}
local PELVIS_REF = { { 0.99844, -0.00000, 0.05582 }, { 0.05582, 0.00000, -0.99844 }, { 0.00000, 1.00000, 0.00000 } }
local votes = {}
local function voteAxes(mdl, Rpel, yaw)
    local v = votes[mdl]
    if v and v.done then return end
    v = v or { n = 0, score = { 0, 0, 0, 0 } }
    votes[mdl] = v
    local Ry = Rz(yaw)
    for k, A in ipairs(AXES) do
        local P = mmul(mmul(Ry, A), PELVIS_REF)
        local tr = 0
        for i = 1, 3 do for j = 1, 3 do tr = tr + P[i][j] * Rpel[i][j] end end
        v.score[k] = v.score[k] + tr
    end
    v.n = v.n + 1
    local best = 1
    for k = 2, 4 do if v.score[k] > v.score[best] then best = k end end
    v.best = best
    if v.n >= 20 then v.done = true end
end
local function axesFor(mdl)
    local v = votes[mdl]
    return AXES[(v and v.best) or 1]
end
EC.AxesFor = axesFor

-----------------------------------------------------------
-- СКЕЛЕТ МОДЕЛИ: от верхней кости над тазом (у многих моделей это ValveBiped.Bip01, и позвоночник
-- висит на ней, а не на тазу) — всё, что ниже, в порядке иерархии
-----------------------------------------------------------
local bodyCache = {}
local ANIMB, FINGB = {}, {}
local function bodyInfo(ply)
    local mdl = ply:GetModel() or ""
    local info = bodyCache[mdl]
    if info ~= nil then return info or nil end
    local D = data()
    if not D then return nil end
    if not next(ANIMB) then
        for _, nm in ipairs(FUSION.EmoteData.bones.full) do ANIMB["ValveBiped.Bip01_" .. nm] = nm end
        for _, c in pairs(D.clips) do for nm in pairs(c.fing) do FINGB["ValveBiped.Bip01_" .. nm] = nm end end
    end
    local pel = ply:LookupBone("ValveBiped.Bip01_Pelvis")
    if not pel or not ply:LookupBone("ValveBiped.Bip01_Head1") then bodyCache[mdl] = false return nil end
    local root, guard = pel, 0
    while guard < 8 do
        local p = ply:GetBoneParent(root)
        if not p or p < 0 then break end
        root, guard = p, guard + 1
    end
    local inSet, chain = { [root] = true }, { { idx = root, parent = -1, root = true } }
    for i = 0, ply:GetBoneCount() - 1 do
        if i ~= root then
            local p = ply:GetBoneParent(i)
            if p and inSet[p] then
                inSet[i] = true
                local nm = ply:GetBoneName(i)
                -- таз ставится вместе с корнем — отдельно его не поворачиваем
                chain[#chain + 1] = { idx = i, parent = p, anim = (i ~= pel) and ANIMB[nm] or nil, fing = FINGB[nm], pel = i == pel }
            end
        end
    end
    local hasHead = false
    for _, b in ipairs(chain) do if b.anim == "Head1" then hasHead = true end end
    if not hasHead then bodyCache[mdl] = false return nil end
    local L = { ply:LookupBone("ValveBiped.Bip01_L_Thigh"), ply:LookupBone("ValveBiped.Bip01_L_Calf"), ply:LookupBone("ValveBiped.Bip01_L_Foot") }
    info = { pel = pel, root = root, chain = chain, leg = (L[1] and L[2] and L[3]) and L or nil }
    bodyCache[mdl] = info
    return info
end

local VB_LEG = 34.37        -- бедро -> колено -> щиколотка у эталонного скелета
local ratioCache = {}
local function ratioOf(ply, info)
    local mdl = ply:GetModel() or ""
    local r = ratioCache[mdl]
    if r then return r end
    local L = info.leg
    local a, b, c = L and ply:GetBoneMatrix(L[1]), L and ply:GetBoneMatrix(L[2]), L and ply:GetBoneMatrix(L[3])
    if a and b and c then
        r = ((b:GetTranslation() - a:GetTranslation()):Length() + (c:GetTranslation() - b:GetTranslation()):Length()) / VB_LEG
        if r < 0.5 or r > 2 then r = ply:GetModelScale() or 1 end
        ratioCache[mdl] = r
        return r
    end
    return ply:GetModelScale() or 1
end

-----------------------------------------------------------
-- КЛИП В МОМЕНТ ВРЕМЕНИ
-----------------------------------------------------------
local function sample(clip, t)
    local f = t * clip.fps
    local n = clip.n
    local i0, i1, k
    if clip.loop then
        f = f % n
        i0 = math.floor(f)
        k = f - i0
        i1 = (i0 + 1) % n
    else
        f = math.Clamp(f, 0, n - 1)
        i0 = math.floor(f)
        k = f - i0
        i1 = math.min(i0 + 1, n - 1)
    end
    i0, i1 = i0 + 1, i1 + 1
    local pose = {}
    for name, arr in pairs(clip.rot) do
        pose[name] = (k < 1e-4) and arr[i0] or qslerp(arr[i0], arr[i1], k)
    end
    local pel
    if clip.pel then
        local a, b = clip.pel[i0], clip.pel[i1]
        pel = { a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k, a[3] + (b[3] - a[3]) * k }
    end
    return pose, pel
end

-- время клипа для слоя
local function clipTime(ply, L, clip)
    local now = CurTime()
    if L.reps then
        -- упражнение пресса: повтор играет с момента попадания по клавише, иначе — исходная поза
        local t = now - ply:GetNW2Float("EOWRepT", 0)
        if t < 0 or t > clip.len then return 0 end
        return t
    end
    local t = math.max(0, now - (L.t0 or now))
    if clip.loop then return t end
    return math.min(t, clip.len)
end

-- поза слоя: повороты костей (мир или относительно таза), таз (мир), пальцы
local function layerPose(ply, L, info)
    local D = data()
    local clip = D and D.clips[L.clip]
    if not clip then return nil end
    local pose, pel = sample(clip, clipTime(ply, L, clip))
    local out = { pose = pose, upper = clip.upper, fing = clip.fing }
    if clip.upper then return out end
    local ratio = ratioOf(ply, info)
    local A = axesFor(ply:GetModel() or "")
    if clip.anchor == "seat" then
        local veh = ply:GetVehicle()
        if not IsValid(veh) then return nil end
        local base = veh:LocalToWorld(ply:GetNW2Vector("EOWSitAt", vector_origin))
        local yaw = veh:GetAngles().y + ply:GetNW2Float("EOWSitYaw", 0)
        out.Wr = mmul(Rz(yaw), A)
        local up = (EM.Sit and EM.Sit.PelvisUp) or 6
        local off = mv(out.Wr, { pel[1] * ratio, pel[2] * ratio, 0 })
        out.P = Vector(base.x + off[1], base.y + off[2], base.z + (up + pel[3]) * ratio)
    else
        local org = ply:GetPos()
        out.Wr = mmul(Rz(L.yaw or 0), A)
        local off = mv(out.Wr, { pel[1] * ratio, pel[2] * ratio, 0 })
        out.P = Vector(org.x + off[1], org.y + off[2], org.z + pel[3] * ratio)
    end
    return out
end

-- целевой поворот кости в слое (nil — как в анимации движка)
local function boneTarget(lp, b, RpelNew, Rparent)
    if b.anim then
        local q = lp.pose[b.anim]
        if not q then return nil end
        if lp.upper then return mmul(RpelNew, q2m(q)) end
        return mmul(lp.Wr, q2m(q))
    elseif b.fing then
        local q = lp.fing[b.fing]
        if not q then return nil end
        return mmul(Rparent, q2m(q))
    end
end

-----------------------------------------------------------
-- ПОСТРОЕНИЕ СКЕЛЕТА
-----------------------------------------------------------
function EC.Build(ply)
    local s = ply.eowEmote
    if not s or (s.w or 0) <= 0 then return end
    local info = bodyInfo(ply)
    if not info then return end
    local w = ease(s.w)
    local k = s.prev and ease(s.k or 1) or 1
    local cur = s.cur and layerPose(ply, s.cur, info)
    local prev = (k < 1 and s.prev) and layerPose(ply, s.prev, info) or nil
    if not cur and not prev then return end
    if not cur then cur, prev, k = prev, nil, 1 end

    local old, new = {}, {}
    local RpelNew
    for i, b in ipairs(info.chain) do
        local m = ply:GetBoneMatrix(b.idx)
        if m then
            old[b.idx] = m
            local nm
            if i == 1 then
                -- таз: целевой поворот и место; корень (если таз под ним) едет вместе с тазом
                local pm = (b.idx == info.pel) and m or ply:GetBoneMatrix(info.pel)
                if not pm then return end
                local R, sc = rotOf(pm)
                local p = pm:GetTranslation()
                local function pelOf(lp)
                    if lp.upper or not lp.P then return R, p end
                    return mmul(lp.Wr, q2m(lp.pose.Pelvis)), lp.P
                end
                local T, P = pelOf(cur)
                if prev then
                    local Tp, Pp = pelOf(prev)
                    T, P = slerpM(Tp, T, k), LerpVector(k, Pp, P)
                end
                RpelNew = slerpM(R, T, w)
                local tm = Matrix()
                tm:Set(pm)
                setRot(tm, RpelNew, sc)
                tm:SetTranslation(LerpVector(w, p, P))
                if b.idx == info.pel then
                    nm = tm
                else
                    local inv = pm:GetInverse()
                    if not inv then return end
                    nm = tm * (inv * m)
                end
            else
                local po, pn = old[b.parent], new[b.parent]
                if po and pn then
                    local inv = po:GetInverse()
                    if inv then
                        nm = pn * (inv * m)
                        if b.anim or b.fing then
                            local Rf, sc = rotOf(nm)
                            local Rp = (rotOf(pn))
                            local T = boneTarget(cur, b, RpelNew, Rp) or Rf
                            if prev then T = slerpM(boneTarget(prev, b, RpelNew, Rp) or Rf, T, k) end
                            setRot(nm, slerpM(Rf, T, w), sc)
                        end
                    end
                end
            end
            if nm then new[b.idx] = nm end
        end
    end
    for idx, nm in pairs(new) do ply:SetBoneMatrix(idx, nm) end
end

local function ensureCallback(ply)
    if ply.eowEmoteCB then return end
    ply.eowEmoteCB = ply:AddCallback("BuildBonePositions", function(ent)
        local E = FUSION.EmoteClip
        if E and E.Build then E.Build(ent) end
    end)
end

-----------------------------------------------------------
-- ЧТО ИГРАТЬ: стойка с клипом или сидение; плавный вход/выход и смена эмоции
-----------------------------------------------------------
local function wanted(ply)
    if not ply:Alive() then return nil end
    if ply:InVehicle() then
        if ply:GetNW2Bool("EOWSit", false) then
            local t0 = ply:GetNW2Float("EOWSitT", 0)
            return { id = "sit@" .. t0, clip = "sit", t0 = t0 }
        end
        return nil
    end
    local id = ply:GetNW2String("FusionStance", "")
    if id == "" then return nil end
    local def = S.ById and S.ById[id]
    if not def or not def.clip then return nil end
    local t0 = ply:GetNW2Float("FusionStanceT", 0)
    return { id = id .. "@" .. t0, clip = def.clip, t0 = t0, yaw = ply:GetNW2Float("FusionStanceYaw", 0), reps = def.reps }
end
EC.Wanted = wanted

function EC.Update(ply, now, dur)
    local want = wanted(ply)
    local s = ply.eowEmote
    if want and not (data() and ED.clips[want.clip]) then want = nil end
    if not want and not s then return end
    if not s then
        s = { cur = want, w = 0, k = 1 }
        ply.eowEmote = s
        ensureCallback(ply)
    elseif want and (not s.cur or s.cur.id ~= want.id) then
        if s.cur and s.w > 0 then
            -- из текущей позы (или смеси, если переход ещё идёт) прямо в новую
            s.prev = (s.prev and s.k < 0.5) and s.prev or s.cur
            s.k = 0
        else
            s.prev, s.k = nil, 1
        end
        s.cur = want
        ensureCallback(ply)
    end
    local ft = FrameTime()
    s.w = math.Clamp(s.w + (want and 1 or -1) * ft / dur, 0, 1)
    if s.prev then
        s.k = math.min(1, (s.k or 0) + ft / dur)
        if s.k >= 1 then s.prev = nil end
    end
    if not want and s.w <= 0 then ply.eowEmote = nil end
end

hook.Add("Think", "EOWEmote.Update", function()
    if not data() then return end
    local dur = math.max((S.Settings and S.Settings.BlendTime) or 0.45, 0.05)
    local now = CurTime()
    for _, ply in ipairs(player.GetAll()) do
        EC.Update(ply, now, dur)
        -- оси модели — по обычной стойке (не в эмоции, не сидит, стоит на месте)
        if not ply.eowEmote and ply:Alive() and not ply:InVehicle() and ply:OnGround() and ply:GetNW2String("FusionStance", "") == ""
            and ply:GetVelocity():Length2DSqr() < 25 then
            local mdl = ply:GetModel() or ""
            local v = votes[mdl]
            if not (v and v.done) then
                local pel = ply:LookupBone("ValveBiped.Bip01_Pelvis")
                local m = pel and ply:GetBoneMatrix(pel)
                if m then voteAxes(mdl, (rotOf(m)), ply:GetRenderAngles().y) end
            end
        end
    end
end)


-----------------------------------------------------------
-- СЕСТЬ: Alt + E — точка, куда смотрит камера, уходит на сервер (sv_emotes.lua проверяет и сажает)
-----------------------------------------------------------
local viewOrg, viewAng
hook.Add("RenderScene", "EOWEmote.View", function(origin, angles) viewOrg, viewAng = origin, angles end)

hook.Add("KeyPress", "EOWSit.Key", function(ply, key)
    if key ~= IN_USE or ply ~= LocalPlayer() or not IsFirstTimePredicted() then return end
    if not ply:KeyDown(IN_WALK) or ply:InVehicle() or not ply:Alive() then return end
    local org, ang = viewOrg or ply:EyePos(), viewAng or ply:EyeAngles()
    local tr = util.TraceLine({ start = org, endpos = org + ang:Forward() * 260, filter = ply, mask = MASK_SOLID })
    if not tr.Hit then return end
    netstream.Start("EOWSit.Req", tr.HitPos)
end)


-----------------------------------------------------------
-- УПРАЖНЕНИЕ ПРЕССА: мини-игра. На экране загорается одна из клавиш W A S D — успел нажать её —
-- персонаж делает повтор; промахнулся или не успел — лежит в исходном положении.
-----------------------------------------------------------
local KEYS = { W = KEY_W, A = KEY_A, S = KEY_S, D = KEY_D }
local ORDER = { "W", "A", "S", "D" }
local MG = { key = nil, next = 0, flash = nil, down = {} }
EC.Minigame = MG

local function situpsActive(lp)
    local id = lp:GetNW2String("FusionStance", "")
    local def = id ~= "" and S.ById and S.ById[id]
    return def and def.reps and def or nil
end

local function canType()
    return not (vgui.GetKeyboardFocus() or gui.IsGameUIVisible() or (IsValid(LocalPlayer()) and LocalPlayer():IsTyping()))
end

hook.Add("Think", "EOWSitups.Game", function()
    local lp = LocalPlayer()
    if not IsValid(lp) then return end
    local def = situpsActive(lp)
    local now = RealTime()
    if not def then
        MG.key, MG.on = nil, false
        return
    end
    local cfg = EM.Situps or {}
    if not MG.on then
        MG.on, MG.key, MG.next, MG.flash = true, nil, now + 0.8, nil
        for n in pairs(KEYS) do MG.down[n] = true end           -- нажатые до старта не считаются
    end
    -- нажатия (только новые)
    local pressed
    for n, code in pairs(KEYS) do
        local d = input.IsKeyDown(code)
        if d and not MG.down[n] and canType() then pressed = pressed or n end
        MG.down[n] = d
    end
    local repLeft = (lp:GetNW2Float("EOWRepT", 0) + (cfg.Len or 2.27)) - CurTime()
    if not MG.key then
        if now >= MG.next and repLeft <= 0.05 then
            local pick = ORDER[math.random(1, 4)]
            if pick == MG.last and math.random() < 0.6 then pick = ORDER[math.random(1, 4)] end
            MG.key, MG.last, MG.t0, MG.until_ = pick, pick, now, now + (cfg.Window or 1.4)
        end
        return
    end
    if pressed then
        if pressed == MG.key then
            netstream.Start("EOWSitups.Rep")
            MG.flash = { ok = true, t = now, key = MG.key }
            MG.key, MG.next = nil, now + (cfg.Len or 2.27) + 0.1
            surface.PlaySound("buttons/button14.wav")
        else
            MG.flash = { ok = false, t = now, key = MG.key }
            MG.key, MG.next = nil, now + (cfg.MissPause or 0.8)
            surface.PlaySound("buttons/button10.wav")
        end
    elseif now > MG.until_ then
        MG.flash = { ok = false, t = now, key = MG.key }
        MG.key, MG.next = nil, now + (cfg.MissPause or 0.8)
    end
end)

local fontsMade
local function makeFonts()
    if fontsMade then return end
    fontsMade = true
    local h = ScrH()
    surface.CreateFont("EOWSitups.Key", { font = "Montserrat Bold", extended = true, size = math.max(22, math.floor(h * 0.03)), weight = 700 })
    surface.CreateFont("EOWSitups.Title", { font = "Montserrat SemiBold", extended = true, size = math.max(16, math.floor(h * 0.019)), weight = 600 })
    surface.CreateFont("EOWSitups.Hint", { font = "Montserrat Medium", extended = true, size = math.max(13, math.floor(h * 0.015)), weight = 500 })
end

local RED, DARK, GOOD = Color(214, 37, 34), Color(16, 4, 8, 225), Color(70, 200, 110)
hook.Add("HUDPaint", "EOWSitups.Game", function()
    local lp = LocalPlayer()
    if not IsValid(lp) or not MG.on or not situpsActive(lp) then return end
    makeFonts()
    local now = RealTime()
    local W, H = ScrW(), ScrH()
    local ks = math.floor(H * 0.058)
    local gap = math.floor(ks * 0.16)
    local cx, top = W / 2, math.floor(H * 0.70)
    local boxW, boxH = ks * 3 + gap * 2 + 48, ks * 2 + gap + 96
    local bx, by = cx - boxW / 2, top - 46
    draw.RoundedBox(6, bx, by, boxW, boxH, DARK)
    surface.SetDrawColor(RED.r, RED.g, RED.b, 200)
    surface.DrawRect(bx, by, boxW, 2)
    draw.SimpleText("УПРАЖНЕНИЕ ПРЕССА", "EOWSitups.Title", cx, by + 14, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    -- клавиши крестом: W сверху, A S D снизу
    local pos = { W = { cx - ks / 2, top }, A = { cx - ks * 1.5 - gap, top + ks + gap }, S = { cx - ks / 2, top + ks + gap }, D = { cx + ks / 2 + gap, top + ks + gap } }
    local fl = MG.flash and (now - MG.flash.t < 0.45) and MG.flash or nil
    for _, n in ipairs(ORDER) do
        local x, y = pos[n][1], pos[n][2]
        local bg, fg = Color(40, 10, 14, 230), Color(150, 119, 114)
        if MG.key == n then
            bg, fg = RED, color_white
        elseif fl and fl.key == n then
            bg = fl.ok and GOOD or Color(90, 20, 20, 240)
            fg = color_white
        end
        draw.RoundedBox(4, x, y, ks, ks, bg)
        draw.SimpleText(n, "EOWSitups.Key", x + ks / 2, y + ks / 2, fg, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    -- сколько осталось времени на нажатие
    if MG.key then
        local frac = math.Clamp((MG.until_ - now) / math.max(0.01, MG.until_ - MG.t0), 0, 1)
        local bw = boxW - 32
        surface.SetDrawColor(60, 14, 16, 255)
        surface.DrawRect(cx - bw / 2, top + ks * 2 + gap + 12, bw, 4)
        surface.SetDrawColor(RED.r, RED.g, RED.b, 255)
        surface.DrawRect(cx - bw / 2, top + ks * 2 + gap + 12, bw * frac, 4)
    end
    local status = fl and (fl.ok and "Есть!" or "Мимо") or (MG.key and "Жми " .. MG.key or "...")
    draw.SimpleText(status .. "   ·   повторений: " .. lp:GetNW2Int("EOWReps", 0), "EOWSitups.Hint", cx, top + ks * 2 + gap + 26, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
    draw.SimpleText("Пробел — встать", "EOWSitups.Hint", cx, top + ks * 2 + gap + 46, Color(150, 119, 114), TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
end)
