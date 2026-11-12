--[[
    Позы рук для стоек из кругового меню: «Руки на груди», «Руки за спиной», «Поза охранника».
    Файл: gamemode/modules/animations/cl_stancepose.lua

    Раньше эти позы были добавкой к углам костей поверх игровой анимации (ManipulateBoneAngles).
    Анимация под ними всё время другая — руки качаются на ходу, корпус поворачивается за взглядом,
    поэтому добавка ложилась криво: руки «ломались» и проходили сквозь тело.

    Теперь руки ставятся в позу целиком, относительно корпуса, при построении скелета (BuildBonePositions):
    руки на груди — от груди (Spine4), кисти у пояса — от нижнего отдела спины (Spine1), чтобы при повороте
    корпуса за взглядом кисти не ездили по поясу. Ноги и корпус двигаются как обычно, а руки держат позу и на месте, и на ходу.
    Позы собраны по скелету ValveBiped (двухзвенный IK: плечо — локоть — кисть, пальцы сжаты) и
    проверены на модели. Переход — плавный, за S.Settings.BlendTime (sh_stances.lua), как у остальных стоек.
    Какие стойки так работают — поле pose = true в списке стоек (sh_stances.lua).
]]

FUSION = FUSION or {}
FUSION.Stances = FUSION.Stances or {}
FUSION.StancePose = FUSION.StancePose or {}
local S = FUSION.Stances
local SP = FUSION.StancePose

-- Данные поз: кватернионы { x, y, z, w }. Руки — поворот кости относительно anchor, пальцы — относительно родителя.
SP.Data = {
    armsinfront = {
        anchor = "Spine4",
        arm = {   -- поворот относительно кости anchor
            ["L_UpperArm"] = { 0.28386, 0.50763, 0.65988, 0.47571 },
            ["L_Forearm"] = { -0.37364, 0.50519, 0.26564, 0.73117 },
            ["L_Hand"] = { -0.00188, 0.61741, -0.37253, 0.69284 },
            ["R_UpperArm"] = { -0.22430, -0.52967, 0.70884, 0.40827 },
            ["R_Forearm"] = { 0.38558, -0.48220, 0.24828, 0.74643 },
            ["R_Hand"] = { -0.06359, -0.63309, -0.35741, 0.68368 },
        },
        fing = {  -- пальцы: поворот относительно родительской кости
            ["L_Finger0"] = { -0.64760, 0.03053, -0.24894, 0.71952 },
            ["L_Finger01"] = { 0.00000, -0.00014, 0.12966, 0.99156 },
            ["L_Finger02"] = { -0.00000, -0.00016, 0.15126, 0.98849 },
            ["L_Finger1"] = { 0.29480, 0.05179, -0.39486, 0.86862 },
            ["L_Finger11"] = { 0.01511, -0.04155, -0.47562, 0.87854 },
            ["L_Finger12"] = { 0.00956, -0.04316, -0.35688, 0.93310 },
            ["L_Finger2"] = { 0.07013, 0.02378, -0.44176, 0.89407 },
            ["L_Finger21"] = { 0.00469, -0.01161, -0.51157, 0.85915 },
            ["L_Finger22"] = { 0.00281, -0.01219, -0.37087, 0.92860 },
            ["L_Finger3"] = { -0.04225, -0.04077, -0.47302, 0.87910 },
            ["L_Finger31"] = { -0.00424, 0.00998, -0.52660, 0.85004 },
            ["L_Finger32"] = { -0.00244, 0.01057, -0.37108, 0.92854 },
            ["L_Finger4"] = { -0.29627, -0.09241, -0.42345, 0.85110 },
            ["L_Finger41"] = { -0.01423, 0.03197, -0.53800, 0.84222 },
            ["L_Finger42"] = { -0.00787, 0.03410, -0.36741, 0.92940 },
            ["R_Finger0"] = { 0.64666, -0.03227, -0.24872, 0.72037 },
            ["R_Finger01"] = { -0.00000, 0.00087, 0.12966, 0.99156 },
            ["R_Finger02"] = { 0.00000, 0.00102, 0.15126, 0.98849 },
            ["R_Finger1"] = { -0.29453, -0.05306, -0.39505, 0.86854 },
            ["R_Finger11"] = { -0.01470, 0.04042, -0.47595, 0.87842 },
            ["R_Finger12"] = { -0.00930, 0.04199, -0.35723, 0.93303 },
            ["R_Finger2"] = { -0.06974, -0.02506, -0.44173, 0.89408 },
            ["R_Finger21"] = { -0.00421, 0.01043, -0.51166, 0.85912 },
            ["R_Finger22"] = { -0.00253, 0.01096, -0.37097, 0.92858 },
            ["R_Finger3"] = { 0.04264, 0.03950, -0.47320, 0.87903 },
            ["R_Finger31"] = { 0.00473, -0.01114, -0.52652, 0.85008 },
            ["R_Finger32"] = { 0.00272, -0.01180, -0.37099, 0.92856 },
            ["R_Finger4"] = { 0.29619, 0.09161, -0.42334, 0.85127 },
            ["R_Finger41"] = { 0.01469, -0.03300, -0.53776, 0.84233 },
            ["R_Finger42"] = { 0.00812, -0.03519, -0.36715, 0.92946 },
        },
    },
    armsbehind = {
        anchor = "Spine1",
        arm = {   -- поворот относительно кости anchor
            ["L_UpperArm"] = { 0.00815, -0.60365, -0.72087, 0.34042 },
            ["L_Forearm"] = { -0.34206, 0.60712, 0.59718, 0.39721 },
            ["L_Hand"] = { -0.12779, 0.94000, -0.01355, 0.31603 },
            ["R_UpperArm"] = { -0.01966, 0.59115, -0.72080, 0.36138 },
            ["R_Forearm"] = { -0.51887, -0.29585, -0.79040, 0.13604 },
            ["R_Hand"] = { -0.57866, 0.00015, -0.80952, 0.09917 },
        },
        fing = {  -- пальцы: поворот относительно родительской кости
            ["L_Finger0"] = { -0.64760, 0.03053, -0.24894, 0.71952 },
            ["L_Finger01"] = { 0.00000, -0.00014, 0.12966, 0.99156 },
            ["L_Finger02"] = { -0.00000, -0.00016, 0.15126, 0.98849 },
            ["L_Finger1"] = { 0.28916, 0.07729, -0.46906, 0.83090 },
            ["L_Finger11"] = { 0.01868, -0.04007, -0.55038, 0.83374 },
            ["L_Finger12"] = { 0.01143, -0.04271, -0.39724, 0.91665 },
            ["L_Finger2"] = { 0.06753, 0.03040, -0.52542, 0.84762 },
            ["L_Finger21"] = { 0.00578, -0.01110, -0.59156, 0.80617 },
            ["L_Finger22"] = { 0.00345, -0.01203, -0.41896, 0.90792 },
            ["L_Finger3"] = { -0.03775, -0.04496, -0.56232, 0.82484 },
            ["L_Finger31"] = { -0.00526, 0.00949, -0.61257, 0.79034 },
            ["L_Finger32"] = { -0.00299, 0.01043, -0.41917, 0.90784 },
            ["L_Finger4"] = { -0.28391, -0.12535, -0.51708, 0.79769 },
            ["L_Finger41"] = { -0.01749, 0.03031, -0.62309, 0.78137 },
            ["L_Finger42"] = { -0.00964, 0.03364, -0.41555, 0.90890 },
            ["R_Finger0"] = { 0.64666, -0.03227, -0.24872, 0.72037 },
            ["R_Finger01"] = { -0.00000, 0.00087, 0.12966, 0.99156 },
            ["R_Finger02"] = { 0.00000, 0.00102, 0.15126, 0.98849 },
            ["R_Finger1"] = { -0.28509, -0.09105, -0.50504, 0.80955 },
            ["R_Finger11"] = { -0.01986, 0.03816, -0.58654, 0.80878 },
            ["R_Finger12"] = { -0.01293, 0.04102, -0.43719, 0.89834 },
            ["R_Finger2"] = { -0.06558, -0.03453, -0.56186, 0.82390 },
            ["R_Finger21"] = { -0.00562, 0.00974, -0.62624, 0.77955 },
            ["R_Finger22"] = { -0.00338, 0.01073, -0.44268, 0.89661 },
            ["R_Finger3"] = { 0.03633, 0.04537, -0.59793, 0.79944 },
            ["R_Finger31"] = { 0.00623, -0.01037, -0.63970, 0.76853 },
            ["R_Finger32"] = { 0.00364, -0.01155, -0.44270, 0.89659 },
            ["R_Finger4"] = { 0.27821, 0.13682, -0.55130, 0.77456 },
            ["R_Finger41"] = { 0.01860, -0.03096, -0.63640, 0.77051 },
            ["R_Finger42"] = { 0.01086, -0.03445, -0.43895, 0.89779 },
        },
    },
    guard = {
        anchor = "Spine1",
        arm = {   -- поворот относительно кости anchor
            ["L_UpperArm"] = { 0.13315, 0.59643, 0.79094, 0.03101 },
            ["L_Forearm"] = { -0.10765, 0.67392, 0.60208, 0.41442 },
            ["L_Hand"] = { 0.10404, 0.95829, -0.00063, 0.26618 },
            ["R_UpperArm"] = { -0.16937, -0.57706, 0.79812, 0.03625 },
            ["R_Forearm"] = { 0.14649, -0.55718, 0.70767, 0.40902 },
            ["R_Hand"] = { -0.04050, -0.89348, 0.07740, 0.44052 },
        },
        fing = {  -- пальцы: поворот относительно родительской кости
            ["L_Finger0"] = { -0.64760, 0.03053, -0.24894, 0.71952 },
            ["L_Finger01"] = { 0.00000, -0.00014, 0.12966, 0.99156 },
            ["L_Finger02"] = { -0.00000, -0.00016, 0.15126, 0.98849 },
            ["L_Finger1"] = { 0.25254, 0.16067, -0.69721, 0.65139 },
            ["L_Finger11"] = { 0.03259, -0.02987, -0.82754, 0.55966 },
            ["L_Finger12"] = { 0.02210, -0.03829, -0.62095, 0.78260 },
            ["L_Finger2"] = { 0.05527, 0.04930, -0.75598, 0.65039 },
            ["L_Finger21"] = { 0.00923, -0.00846, -0.83161, 0.55522 },
            ["L_Finger22"] = { 0.00626, -0.01084, -0.62616, 0.77959 },
            ["L_Finger3"] = { -0.02248, -0.05424, -0.78432, 0.61757 },
            ["L_Finger31"] = { -0.00799, 0.00733, -0.83169, 0.55513 },
            ["L_Finger32"] = { -0.00542, 0.00940, -0.62634, 0.77947 },
            ["L_Finger4"] = { -0.23307, -0.20492, -0.73302, 0.60529 },
            ["L_Finger41"] = { -0.02580, 0.02365, -0.82921, 0.55783 },
            ["L_Finger42"] = { -0.01749, 0.03031, -0.62309, 0.78137 },
            ["R_Finger0"] = { 0.64666, -0.03227, -0.24872, 0.72037 },
            ["R_Finger01"] = { -0.00000, 0.00087, 0.12966, 0.99156 },
            ["R_Finger02"] = { 0.00000, 0.00102, 0.15126, 0.98849 },
            ["R_Finger1"] = { -0.29453, -0.05306, -0.39505, 0.86854 },
            ["R_Finger11"] = { -0.01470, 0.04042, -0.47595, 0.87842 },
            ["R_Finger12"] = { -0.00930, 0.04199, -0.35723, 0.93303 },
            ["R_Finger2"] = { -0.06974, -0.02506, -0.44173, 0.89408 },
            ["R_Finger21"] = { -0.00421, 0.01043, -0.51166, 0.85912 },
            ["R_Finger22"] = { -0.00253, 0.01096, -0.37097, 0.92858 },
            ["R_Finger3"] = { 0.04264, 0.03950, -0.47320, 0.87903 },
            ["R_Finger31"] = { 0.00473, -0.01114, -0.52652, 0.85008 },
            ["R_Finger32"] = { 0.00272, -0.01180, -0.37099, 0.92856 },
            ["R_Finger4"] = { 0.29619, 0.09161, -0.42334, 0.85127 },
            ["R_Finger41"] = { 0.01469, -0.03300, -0.53776, 0.84233 },
            ["R_Finger42"] = { 0.00812, -0.03519, -0.36715, 0.92946 },
        },
    },
}

local function q2m(q)
    local x, y, z, w = q[1], q[2], q[3], q[4]
    return { { 1 - 2 * (y * y + z * z), 2 * (x * y - z * w), 2 * (x * z + y * w) },
             { 2 * (x * y + z * w), 1 - 2 * (x * x + z * z), 2 * (y * z - x * w) },
             { 2 * (x * z - y * w), 2 * (y * z + x * w), 1 - 2 * (x * x + y * y) } }
end
local function mmul(a, b)
    local r = {}
    for i = 1, 3 do
        r[i] = {}
        for j = 1, 3 do r[i][j] = a[i][1] * b[1][j] + a[i][2] * b[2][j] + a[i][3] * b[3][j] end
    end
    return r
end
local function quatOf(m)
    local tr = m[1][1] + m[2][2] + m[3][3]
    local x, y, z, w
    if tr > 0 then
        local s = math.sqrt(tr + 1) * 2
        w, x, y, z = 0.25 * s, (m[3][2] - m[2][3]) / s, (m[1][3] - m[3][1]) / s, (m[2][1] - m[1][2]) / s
    elseif m[1][1] > m[2][2] and m[1][1] > m[3][3] then
        local s = math.sqrt(1 + m[1][1] - m[2][2] - m[3][3]) * 2
        w, x, y, z = (m[3][2] - m[2][3]) / s, 0.25 * s, (m[1][2] + m[2][1]) / s, (m[1][3] + m[3][1]) / s
    elseif m[2][2] > m[3][3] then
        local s = math.sqrt(1 + m[2][2] - m[1][1] - m[3][3]) * 2
        w, x, y, z = (m[1][3] - m[3][1]) / s, (m[1][2] + m[2][1]) / s, 0.25 * s, (m[2][3] + m[3][2]) / s
    else
        local s = math.sqrt(1 + m[3][3] - m[1][1] - m[2][2]) * 2
        w, x, y, z = (m[2][1] - m[1][2]) / s, (m[1][3] + m[3][1]) / s, (m[2][3] + m[3][2]) / s, 0.25 * s
    end
    return { x, y, z, w }
end
local function slerpM(A, B, t)
    if t <= 0 then return A elseif t >= 1 then return B end
    local a, b = quatOf(A), quatOf(B)
    local dot = a[1] * b[1] + a[2] * b[2] + a[3] * b[3] + a[4] * b[4]
    if dot < 0 then b = { -b[1], -b[2], -b[3], -b[4] } dot = -dot end
    local ka, kb
    if dot > 0.9995 then ka, kb = 1 - t, t
    else
        local th = math.acos(dot)
        local sn = math.sin(th)
        ka, kb = math.sin((1 - t) * th) / sn, math.sin(t * th) / sn
    end
    local q = { a[1] * ka + b[1] * kb, a[2] * ka + b[2] * kb, a[3] * ka + b[3] * kb, a[4] * ka + b[4] * kb }
    local l = math.sqrt(q[1] ^ 2 + q[2] ^ 2 + q[3] ^ 2 + q[4] ^ 2)
    return q2m({ q[1] / l, q[2] / l, q[3] / l, q[4] / l })
end
-- поворот из матрицы кости (без масштаба модели) и сам масштаб
local function rotOf(m)
    local R, s = { {}, {}, {} }, 1
    for c = 1, 3 do
        local l = math.sqrt(m:GetField(1, c) ^ 2 + m:GetField(2, c) ^ 2 + m:GetField(3, c) ^ 2)
        if c == 1 then s = l end
        for r = 1, 3 do R[r][c] = l > 1e-9 and m:GetField(r, c) / l or 0 end
    end
    return R, s
end
local function setRot(m, R, s)
    for r = 1, 3 do for c = 1, 3 do m:SetField(r, c, R[r][c] * s) end end
end

-- матрицы поз считаем один раз
SP.Mats = {}
for id, d in pairs(SP.Data) do
    local m = { arm = {}, fing = {}, anchor = d.anchor or "Spine4" }
    for k, q in pairs(d.arm) do m.arm[k] = q2m(q) end
    for k, q in pairs(d.fing) do m.fing[k] = q2m(q) end
    SP.Mats[id] = m
end

-- кости модели: грудь и всё, что ниже плеч, от родителей к детям
local bodyCache = {}
local function bodyOf(ply)
    local mdl = ply:GetModel() or ""
    local c = bodyCache[mdl]
    if c ~= nil then return c or nil end
    local anchors = { Spine4 = ply:LookupBone("ValveBiped.Bip01_Spine4"), Spine1 = ply:LookupBone("ValveBiped.Bip01_Spine1") }
    anchors.Spine1 = anchors.Spine1 or anchors.Spine4
    local uaL, uaR = ply:LookupBone("ValveBiped.Bip01_L_UpperArm"), ply:LookupBone("ValveBiped.Bip01_R_UpperArm")
    if not anchors.Spine4 or not uaL or not uaR then bodyCache[mdl] = false return nil end
    local list, under = {}, { [uaL] = true, [uaR] = true }
    for i = 0, ply:GetBoneCount() - 1 do
        local p = ply:GetBoneParent(i)
        if i == uaL or i == uaR or (p and p >= 0 and under[p]) then
            under[i] = true
            local name = ply:GetBoneName(i) or ""
            list[#list + 1] = { idx = i, parent = p, key = name:match("^ValveBiped%.Bip01_(.+)$") }
        end
    end
    c = { anchors = anchors, list = list }
    bodyCache[mdl] = c
    return c
end
SP.BodyOf = bodyOf

-- целевой поворот кости в позе src: nil — как в анимации; id позы; { a, b, k } — смесь двух (переход прервали)
local function target(src, key, R, RA, pnR, depth)
    if src == nil then return R end
    if type(src) == "table" then
        if (depth or 0) > 3 then return R end
        return slerpM(target(src.a, key, R, RA, pnR, (depth or 0) + 1), target(src.b, key, R, RA, pnR, (depth or 0) + 1), src.k)
    end
    local m = SP.Mats[src]
    if not m or not key then return R end
    local A = m.arm[key]
    if A then
        local Ra = RA[m.anchor] or RA.Spine4
        return Ra and mmul(Ra, A) or R
    end
    local F = m.fing[key]
    if F and pnR then return mmul(pnR, F) end
    return R
end

function SP.Build(ply)
    local st = ply.eowStancePose
    if not st or (st.from == nil and st.to == nil) then return end
    local body = bodyOf(ply)
    if not body then return end
    local RA = {}
    for name, idx in pairs(body.anchors) do
        local am = ply:GetBoneMatrix(idx)
        if am then RA[name] = (rotOf(am)) end
    end
    if not RA.Spine4 then return end
    local old, new, newR = {}, {}, {}
    for _, b in ipairs(body.list) do
        local m = ply:GetBoneMatrix(b.idx)
        if m then
            old[b.idx] = m
            local nm = Matrix()
            nm:Set(m)
            local po, pn = old[b.parent], new[b.parent]
            if po and pn then
                local inv = po:GetInverse()
                if inv then nm = pn * (inv * m) end
            end
            local R, sc = rotOf(nm)
            local pnR = newR[b.parent] or (po and (rotOf(po))) or nil
            local TA = target(st.from, b.key, R, RA, pnR)
            local TB = target(st.to, b.key, R, RA, pnR)
            if TA ~= R or TB ~= R then
                local T = slerpM(TA, TB, st.k or 1)
                setRot(nm, T, sc)
                R = T
            end
            new[b.idx], newR[b.idx] = nm, R
        end
    end
    for idx, nm in pairs(new) do ply:SetBoneMatrix(idx, nm) end
end

local function ensureCallback(ply)
    if ply.eowStancePoseCB then return end
    ply.eowStancePoseCB = ply:AddCallback("BuildBonePositions", function(ent)
        local sp = FUSION and FUSION.StancePose
        if sp and sp.Build then sp.Build(ent) end
    end)
end

local function ease(x)
    x = math.Clamp(x, 0, 1)
    return x * x * x * (x * (x * 6 - 15) + 10)
end

-- переход между позами: from -> to за BlendTime; смену цели посреди перехода начинаем из текущей смеси
function SP.Update(ply, now, dur)
    -- указывает рукой (G) или сидит в транспорте — позу рук не держим, отдаём руки анимации/указанию
    local free = ply:Alive() and not ply:InVehicle() and not ply:GetNW2Bool("EOWPoint", false)
    local id = free and ply:GetNW2String("FusionStance", "") or ""
    local def = S.ById and S.ById[id]
    local want = (def and def.pose and SP.Mats[id]) and id or nil
    local s = ply.eowStancePose
    if not want and not s then return end
    if not s then
        s = { from = nil, to = want, t0 = now, k = 0 }
        ply.eowStancePose = s
        ensureCallback(ply)
    elseif s.to ~= want then
        local from = s.from
        if s.k < 1 then
            from = { a = s.from, b = s.to, k = s.k }
            if type(from.a) == "table" then from.a = (from.a.k >= 0.5) and from.a.b or from.a.a end   -- не копим вложенность
        else
            from = s.to
        end
        s.from, s.to, s.t0, s.k = from, want, now, 0
        ensureCallback(ply)
    end
    s.k = ease((now - s.t0) / dur)
    if s.k >= 1 then
        s.from = s.to
        if s.to == nil then ply.eowStancePose = nil end
    end
end

hook.Add("Think", "FusionStancePose.Update", function()
    if not S.ById then return end
    local now = CurTime()
    local dur = math.max((S.Settings and S.Settings.BlendTime) or 0.45, 0.05)
    for _, ply in ipairs(player.GetAll()) do SP.Update(ply, now, dur) end
end)
