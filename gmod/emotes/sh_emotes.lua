--[[
    Эмоции — общие настройки.  Файл: gamemode/modules/animations/sh_emotes.lua
    Клипы эмоций — cl_emotedata.lua, проигрывание — cl_emoteclip.lua, сервер — sv_emotes.lua.
    Сами пункты кругового меню — в sh_stances.lua (поле clip).
]]

FUSION = FUSION or {}
FUSION.Emotes = FUSION.Emotes or {}
local EM = FUSION.Emotes

-- сесть на поверхность: Alt + E, навести камеру на верх стула, ящика, скамьи, уступа
EM.Sit = {
    MaxReach = 95,          -- от ступней до точки по горизонтали
    MinUp = 8,              -- высота поверхности над ступнями: ниже — это пол, персонаж садится на землю
    FloorBelow = 12,        -- пол может быть ниже ступней не больше чем на столько (ступенька, склон)
    MaxUp = 44,             -- выше — нельзя
    MinNormalZ = 0.7,       -- только почти горизонтальный верх
    PelvisUp = 6,           -- таз над поверхностью (умножается на масштаб модели)
    Cooldown = 0.8,
    Model = "models/nova/airboat_seat.mdl",
}

-- упражнения (мини-игра); длительность повтора берётся из клипа, у стойки — replen (sh_stances.lua)
EM.Situps = {
    Len = 2.27,             -- повтор по умолчанию
    Window = 1.4,           -- сколько секунд даётся на нажатие клавиши
    MissPause = 0.8,        -- пауза после промаха
}

-- пока идёт эмоция с lockmove (упражнения), WASD двигать персонажа не должны:
-- они нужны мини-игре. Встать — пробел или присед (снимают стойку, sv_stances.lua).
hook.Add("StartCommand", "EOWEmote.Lock", function(ply, cmd)
    local id = ply:GetNW2String("FusionStance", "")
    if id == "" then return end
    local S = FUSION.Stances
    local st = S and S.ById and S.ById[id]
    if not st or not st.lockmove then return end
    cmd:ClearMovement()
    cmd:RemoveKey(bit.bor(IN_FORWARD, IN_BACK, IN_MOVELEFT, IN_MOVERIGHT))
end)
