-- =============================================================
-- АНИМАЦИЯ ПЕРСОНАЖА В МЕНЮ ВЫБОРА
--   Модель models/xdreanims/m_anm_slot_056.mdl (аддон eow_menupose), последовательность menu_combine.
--   Играет с начала, когда персонаж появляется в меню и при каждом переключении слота, дальше идёт по кругу.
--   Модель персонажа надевается на скелет этой анимации (bonemerge) — подходит любая модель со скелетом ValveBiped.
--   Нет файла анимации у игрока или у модели другой скелет — остаются прежние анимации меню.
-- =============================================================
local MENUPOSE_MDL, MENUPOSE_SEQ = "models/xdreanims/m_anm_slot_056.mdl", "menu_combine"
EOWMenuPose = EOWMenuPose or {}
local MP = EOWMenuPose

local function menuPoseEnts()
    if IsValid(MP.anim) and IsValid(MP.char) then return true end
    if MP.failed then return false end
    if IsValid(MP.anim) then MP.anim:Remove() end
    if IsValid(MP.char) then MP.char:Remove() end
    if not util.IsValidModel(MENUPOSE_MDL) then MP.failed = true return false end
    local a = ClientsideModel(MENUPOSE_MDL, RENDERGROUP_OTHER)
    if not IsValid(a) then MP.failed = true return false end
    a:SetNoDraw(true)
    local seq = a:LookupSequence(MENUPOSE_SEQ)
    if not seq or seq < 0 then a:Remove() MP.failed = true return false end
    local c = ClientsideModel("models/ui/swcw/clone_ui.mdl", RENDERGROUP_OTHER)
    if not IsValid(c) then a:Remove() MP.failed = true return false end
    c:SetNoDraw(true)
    c:SetParent(a)
    c:AddEffects(EF_BONEMERGE)
    MP.anim, MP.char, MP.seq = a, c, seq
    return true
end

-- поставить модель персонажа на анимацию меню и запустить её с начала; false — анимация недоступна
local function menuPoseStart(mdl)
    if not mdl or mdl == "" or not menuPoseEnts() then return false end
    MP.char:SetModel(mdl)
    if not MP.char:LookupBone("ValveBiped.Bip01_Pelvis") then return false end
    MP.anim:ResetSequence(MP.seq)
    MP.anim:SetCycle(0)
    MP.t0 = RealTime()
    return true
end

-- нарисовать персонажа в текущем кадре анимации (внутри cam.Start3D сцены меню)
local function menuPoseDraw()
    local a, c = MP.anim, MP.char
    if not IsValid(a) or not IsValid(c) then return false end
    a:SetPos(vector_origin)
    a:SetAngles(angle_zero)
    local len = a:SequenceDuration(MP.seq)
    a:SetCycle(len > 0 and ((RealTime() - (MP.t0 or 0)) / len) % 1 or 0)
    a:InvalidateBoneCache()
    c:InvalidateBoneCache()
    c:SetSubMaterial()
    c:DrawModel()
    return true
end

