--[[
    Эмоции — сервер.  Файл: gamemode/modules/animations/sv_emotes.lua
      • СЕСТЬ на поверхность: Alt + E. Навёл камеру на верх стула, ящика, скамьи или уступа —
        персонаж садится лицом к тому месту, где стоял. Встать — E или пробел.
        Игрок сидит в невидимом сиденье; позу сидя рисует cl_emoteclip.lua (клип sit).
        Навёл на пол у ног — персонаж садится на землю (стойка «Сидеть на земле»).
      • УПРАЖНЕНИЯ (пресс, приседания): клиент сообщает о попадании по клавише — сервер
        засчитывает повтор, и все видят, как персонаж его делает.
      • ACT SALUTE: вместо жеста движка — своё воинское приветствие (стойка salute).
    Настройки — sh_emotes.lua.
]]

FUSION = FUSION or {}
FUSION.Emotes = FUSION.Emotes or {}
FUSION.Stances = FUSION.Stances or {}
local EM = FUSION.Emotes
local S = FUSION.Stances

EOWSit = EOWSit or {}

local OKCLASS = {
    prop_physics = true, prop_physics_multiplayer = true, prop_physics_override = true,
    prop_dynamic = true, prop_dynamic_override = true, func_brush = true,
}

local SAY = {
    far = "Подойди ближе, чтобы сесть",
    flat = "Сесть можно только на ровный верх",
    high = "Слишком высоко, чтобы сесть",
    low = "Слишком низко, чтобы сесть",
    room = "Над этим местом мало места",
    ent = "На это сесть нельзя",
    see = "Не видно, куда садиться",
    enter = "Не получилось сесть",
}
function EOWSit.Say(ply, why)
    local msg = SAY[why] or why
    if nwt and nwt.util and nwt.util.Notify then nwt.util.Notify("red", ply, msg) else ply:ChatPrint(msg) end
end

-- проверка точки: верх поверхности рядом с игроком, видно из глаз, сверху есть место
local function sitCheck(ply, pos)
    local SIT = EM.Sit
    local feet = ply:GetPos()
    if Vector(pos.x - feet.x, pos.y - feet.y, 0):Length() > SIT.MaxReach then return nil, "far" end
    local tr = util.TraceLine({ start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 16), filter = ply, mask = MASK_SOLID })
    if not tr.Hit or tr.StartSolid or tr.HitSky or tr.HitNormal.z < SIT.MinNormalZ then return nil, "flat" end
    local ent = tr.Entity
    if not tr.HitWorld then
        if not IsValid(ent) or not OKCLASS[ent:GetClass()] or ent:IsPlayer() then return nil, "ent" end
    end
    local up = tr.HitPos.z - feet.z
    if up > SIT.MaxUp then return nil, "high" end
    if up < SIT.MinUp then return nil, "low" end
    local filt = IsValid(ent) and { ply, ent } or ply
    local see = util.TraceLine({ start = ply:EyePos(), endpos = tr.HitPos + Vector(0, 0, 3), filter = filt, mask = MASK_SOLID })
    if see.Hit and see.Fraction < 0.97 then return nil, "see" end
    local head = util.TraceLine({ start = tr.HitPos + Vector(0, 0, 2), endpos = tr.HitPos + Vector(0, 0, 40), filter = filt, mask = MASK_SOLID })
    if head.Hit then return nil, "room" end
    return tr
end
EOWSit.Check = sitCheck

local function makeSeat(pos, yaw)
    local seat = ents.Create("prop_vehicle_prisoner_pod")
    if not IsValid(seat) then return end
    seat:SetModel(EM.Sit.Model)
    seat:SetKeyValue("vehiclescript", "scripts/vehicles/prisoner_pod.txt")
    seat:SetKeyValue("limitview", "0")
    seat:SetPos(pos)
    seat:SetAngles(Angle(0, yaw - 90, 0))
    seat:Spawn()
    seat:Activate()
    seat:SetNotSolid(true)
    seat:SetCollisionGroup(COLLISION_GROUP_WORLD)
    local phys = seat:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) phys:EnableCollisions(false) phys:Sleep() end
    seat:DrawShadow(false)
    seat:SetRenderMode(RENDERMODE_TRANSALPHA)
    seat:SetColor(Color(255, 255, 255, 0))
    seat:SetNoDraw(true)
    seat.PhysgunDisabled = true
    seat.m_tblToolsAllowed = {}
    seat.eowSit = true
    seat:SetNWBool("playerdynseat", true)
    return seat
end

-- точка сидения и направление — для клиентов, в координатах сиденья (сиденье может ехать вместе с пропом)
local function syncNW(ply, seat)
    if not IsValid(ply) or not IsValid(seat) then return end
    ply:SetNW2Vector("EOWSitAt", seat:WorldToLocal(seat.eowSurf))
    ply:SetNW2Float("EOWSitYaw", math.NormalizeAngle(seat.eowFace - seat:GetAngles().y))
end

local function bonePos(ply, name)
    local id = ply:LookupBone("ValveBiped.Bip01_" .. name)
    return id and ply:GetBonePosition(id) or nil
end

-- подгонка сиденья, чтобы камера оказалась на высоте сидящего: развернуть колени куда надо,
-- затем поставить таз позы движка на точку
function EOWSit.Fit(ply, seat, pass)
    if not IsValid(ply) or not IsValid(seat) or ply:GetVehicle() ~= seat then return end
    local function again() if pass < 6 then timer.Simple(0.1, function() EOWSit.Fit(ply, seat, pass + 1) end) else EOWSit.Done(seat) end end
    ply:SetupBones()
    local P, L, R = bonePos(ply, "Pelvis"), bonePos(ply, "L_Calf"), bonePos(ply, "R_Calf")
    if not (P and L and R) then EOWSit.Done(seat) return end
    local K = (L + R) * 0.5
    local fwd = Vector(K.x - P.x, K.y - P.y, 0)
    if math.abs(K.z - P.z) > 14 or fwd:Length() < 6 then again() return end
    local dy = math.NormalizeAngle(seat.eowFace - fwd:Angle().y)
    if math.abs(dy) > 8 then
        local sp = seat:GetPos() - P
        sp:Rotate(Angle(0, dy, 0))
        seat:SetPos(P + sp)
        seat:SetAngles(Angle(0, seat:GetAngles().y + dy, 0))
        syncNW(ply, seat)
        again()
        return
    end
    local want = seat.eowSurf + Vector(0, 0, EM.Sit.PelvisUp * (ply:GetModelScale() or 1))
    local d = want - P
    if d:Length() > 0.5 then
        seat:SetPos(seat:GetPos() + Vector(math.Clamp(d.x, -48, 48), math.Clamp(d.y, -48, 48), math.Clamp(d.z, -48, 48)))
        syncNW(ply, seat)
        if d:Length() > 4 and pass < 6 then again() return end
    end
    EOWSit.Done(seat)
end

-- подгонка закончена: если сидим на пропе — прикрепить сиденье к нему
function EOWSit.Done(seat)
    if not IsValid(seat) or seat.eowDone then return end
    seat.eowDone = true
    local ent = seat.eowOn
    if IsValid(ent) then seat:SetParent(ent) end
    syncNW(seat.eowOwner, seat)
end

function EOWSit.Sit(ply, tr)
    local face = (ply:GetPos() - tr.HitPos):Angle().y      -- лицом туда, где стоял
    local seat = makeSeat(tr.HitPos - Vector(0, 0, 18 * (ply:GetModelScale() or 1)), face)
    if not seat then return end
    seat.eowOwner, seat.eowSurf, seat.eowFrom, seat.eowFace = ply, tr.HitPos, ply:GetPos(), face
    seat.eowOn = (not tr.HitWorld) and tr.Entity or nil
    ply:EnterVehicle(seat)
    if ply:GetVehicle() ~= seat then seat:Remove() EOWSit.Say(ply, "enter") return end
    ply.eowSitSeat = seat
    syncNW(ply, seat)
    ply:SetNW2Float("EOWSitT", CurTime())
    ply:SetNW2Bool("EOWSit", true)
    timer.Simple(0.1, function() EOWSit.Fit(ply, seat, 1) end)
end

-- запрос с клиента: Alt + E, точка — куда смотрит камера
netstream.Hook("EOWSit.Req", function(ply, pos)
    if not IsValid(ply) or not isvector(pos) then return end
    if not ply:Alive() or ply:InVehicle() or not ply:OnGround() or ply:WaterLevel() >= 2 then return end
    if (ply.eowSitNext or 0) > CurTime() then return end
    ply.eowSitNext = CurTime() + EM.Sit.Cooldown
    -- пол у ног — сесть на землю на месте (поза «Сидеть на земле», лицом туда, куда смотрит)
    local fl = util.TraceLine({ start = pos + Vector(0, 0, 8), endpos = pos - Vector(0, 0, 16), filter = ply, mask = MASK_SOLID })
    if fl.Hit and not fl.StartSolid and fl.HitNormal.z >= EM.Sit.MinNormalZ then
        local up = fl.HitPos.z - ply:GetPos().z
        if up < EM.Sit.MinUp and up > -(EM.Sit.FloorBelow or 12) then
            if S.Start and S.ById and S.ById.groundsit then S.Start(ply, "groundsit") end
            return
        end
    end
    local tr, why = sitCheck(ply, pos)
    if tr then EOWSit.Sit(ply, tr) else EOWSit.Say(ply, why) end
end)

-- встать: E (движок) или пробел
hook.Add("KeyPress", "EOWSit.Key", function(ply, key)
    if key ~= IN_JUMP then return end
    local v = ply:GetVehicle()
    if IsValid(v) and v.eowSit then ply:ExitVehicle() end
end)

-- в чужое невидимое сиденье не сесть
hook.Add("CanPlayerEnterVehicle", "EOWSit.Owner", function(ply, veh)
    if veh.eowSit and veh.eowOwner ~= ply then return false end
end)

hook.Add("PlayerLeaveVehicle", "EOWSit.Leave", function(ply, veh)
    if not IsValid(veh) or not veh.eowSit then return end
    ply.eowSitNext = CurTime() + EM.Sit.Cooldown
    ply.eowSitSeat = nil
    ply:SetNW2Bool("EOWSit", false)
    local from, surf = veh.eowFrom, veh.eowSurf
    timer.Simple(0, function()
        if IsValid(veh) then veh:Remove() end
        if not IsValid(ply) or not ply:Alive() or ply:InVehicle() then return end
        local mins, maxs = ply:OBBMins(), ply:OBBMaxs()
        for _, p in ipairs({ from, surf }) do
            if p then
                p = p + Vector(0, 0, 2)
                local t = util.TraceHull({ start = p, endpos = p, mins = mins, maxs = maxs, filter = ply, mask = MASK_PLAYERSOLID })
                if not t.Hit and p:DistToSqr(ply:GetPos()) < 200 * 200 then ply:SetPos(p) return end
            end
        end
    end)
end)

hook.Add("PlayerDisconnected", "EOWSit.Gone", function(ply)
    if IsValid(ply.eowSitSeat) then ply.eowSitSeat:Remove() end
end)
hook.Add("PlayerDeath", "EOWSit.Death", function(ply) ply:SetNW2Bool("EOWSit", false) end)

-- страховка: пустые сиденья убираем
timer.Create("EOWSit.Clean", 5, 0, function()
    for _, v in ipairs(ents.FindByClass("prop_vehicle_prisoner_pod")) do
        if v.eowSit and not IsValid(v:GetDriver()) and CurTime() - v:GetCreationTime() > 2 then v:Remove() end
    end
end)


-----------------------------------------------------------
-- УПРАЖНЕНИЯ: попадание по клавише = один повтор (видят все)
-----------------------------------------------------------
netstream.Hook("EOWSitups.Rep", function(ply)
    if not IsValid(ply) or not ply:Alive() then return end
    local id = ply:GetNW2String("FusionStance", "")
    local st = S.ById and S.ById[id]
    if not st or not st.reps then return end
    local now = CurTime()
    if now - ply:GetNW2Float("EOWRepT", 0) < (st.replen or EM.Situps.Len or 2.27) * 0.9 then return end
    ply:SetNW2Float("EOWRepT", now)
    ply:SetNW2Int("EOWReps", ply:GetNW2Int("EOWReps", 0) + 1)
end)


-----------------------------------------------------------
-- ACT SALUTE: своё воинское приветствие (стойка salute: клип salute в cl_emoteclip.lua)
-----------------------------------------------------------
hook.Add("PlayerShouldTaunt", "EOWAct.Salute", function(ply, act)
    if act ~= ACT_GMOD_TAUNT_SALUTE then return end
    if ply:Alive() and not ply:InVehicle() and S.Start and S.ById and S.ById.salute and (ply.fusionStanceNext or 0) <= CurTime() then
        ply.fusionStanceNext = CurTime() + 0.3
        S.Start(ply, "salute")
    end
    return false                -- жест движка не нужен
end)
