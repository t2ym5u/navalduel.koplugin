local Blitbuffer     = require("ffi/blitbuffer")
local Font           = require("ui/font")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local RenderText     = require("ui/rendertext")
local UIManager      = require("ui/uimanager")

local C_BG     = Blitbuffer.COLOR_WHITE
local C_FG     = Blitbuffer.COLOR_BLACK
local C_GRID   = Blitbuffer.COLOR_GRAY_9
local C_SHIP   = Blitbuffer.COLOR_GRAY_7
local C_WATER  = Blitbuffer.COLOR_GRAY_E

local function bsearchFont(font_name, lo, hi, max_w, max_h, sample)
    local best = lo
    while lo <= hi do
        local mid  = math.floor((lo + hi) / 2)
        local face = Font:getFace(font_name, mid)
        local m    = RenderText:sizeUtf8Text(0, math.huge, face, sample, true, false)
        if m.x <= max_w and (m.y_top + m.y_bottom) <= max_h then
            best = mid
            lo   = mid + 1
        else
            hi   = mid - 1
        end
    end
    return best
end

local function centeredText(bb, text, face, cx, cy, color)
    local m = RenderText:sizeUtf8Text(0, math.huge, face, text, true, false)
    local tx = cx - math.floor(m.x / 2)
    local ty = cy + math.floor((m.y_top - m.y_bottom) / 2)
    RenderText:renderUtf8Text(bb, tx, ty, face, text, true, false, color or C_FG)
end

-- ---------------------------------------------------------------------------
-- NavalGrid — one of the player's two grids, with A..J / 1..10 labels.
--   view = "fleet": my ships and the opponent's shots at them
--   view = "shots": my shots and what the opponent answered
-- ---------------------------------------------------------------------------

local NavalGrid = InputContainer:extend{
    board      = nil,
    view       = "fleet",
    max_width  = 0,
    max_height = 0,
    getSelectedCell = nil,   -- function() -> r, c
    getSelectedShip = nil,   -- function() -> ship index (setup)
    onCellTapped    = nil,   -- function(r, c)
}

function NavalGrid:init()
    local n = self.board.n
    local cell = math.floor(math.min(self.max_width / (n + 1), self.max_height / (n + 1)))
    cell = math.max(cell, 12)
    self.cell  = cell
    self.band  = cell
    self.dimen = Geom:new{ w = cell * (n + 1), h = cell * (n + 1) }
    local fit = math.floor(cell * 0.55)
    self.label_face = Font:getFace("cfont", bsearchFont("cfont", 6, math.max(6, cell), fit, fit, "10"))
    self.ges_events = {
        TapCell = { GestureRange:new{ ges = "tap", range = function() return self.paint_rect end } },
    }
end

function NavalGrid:cellOrigin(r, c)
    return self.paint_rect.x + self.band + (c - 1) * self.cell,
           self.paint_rect.y + self.band + (r - 1) * self.cell
end

function NavalGrid:onTapCell(_, ges)
    if not self.paint_rect then return false end
    local lx = ges.pos.x - self.paint_rect.x - self.band
    local ly = ges.pos.y - self.paint_rect.y - self.band
    if lx < 0 or ly < 0 then return true end
    local c = math.floor(lx / self.cell) + 1
    local r = math.floor(ly / self.cell) + 1
    local n = self.board.n
    if r >= 1 and r <= n and c >= 1 and c <= n and self.onCellTapped then
        self.onCellTapped(r, c)
    end
    return true
end

local function cross(bb, x, y, size, thick, color)
    local pad = math.floor(size * 0.22)
    local len = size - 2 * pad
    for i = 0, len do
        bb:paintRect(x + pad + i - math.floor(thick / 2), y + pad + i - math.floor(thick / 2), thick, thick, color)
        bb:paintRect(x + pad + i - math.floor(thick / 2), y + size - pad - i - math.floor(thick / 2), thick, thick, color)
    end
end

function NavalGrid:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local board, n, cell, band = self.board, self.board.n, self.cell, self.band
    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Labels: letters across the top, numbers down the side.
    for i = 1, n do
        centeredText(bb, string.char(64 + i), self.label_face,
            x + band + (i - 1) * cell + math.floor(cell / 2), y + math.floor(band / 2))
        centeredText(bb, tostring(i), self.label_face,
            x + math.floor(band / 2), y + band + (i - 1) * cell + math.floor(cell / 2))
    end

    local thick = math.max(2, math.floor(cell / 10))
    for r = 1, n do
        for c = 1, n do
            local cx, cy = self:cellOrigin(r, c)
            if self.view == "fleet" then
                local ship = board:shipAt(r, c)
                local shot = board.incoming[r][c]
                if ship then
                    local sunk = board.phase ~= "setup" and board:shipSunk(ship)
                    bb:paintRect(cx, cy, cell, cell, sunk and C_FG or C_SHIP)
                    if shot == "hit" and not sunk then cross(bb, cx, cy, cell, thick, C_FG) end
                    if sunk then cross(bb, cx, cy, cell, thick, C_BG) end
                elseif shot == "miss" then
                    bb:paintCircle(cx + math.floor(cell / 2), cy + math.floor(cell / 2),
                        math.max(2, math.floor(cell / 8)), C_FG)
                end
            else
                local v = board.shots[r][c]
                if v == "miss" then
                    bb:paintCircle(cx + math.floor(cell / 2), cy + math.floor(cell / 2),
                        math.max(2, math.floor(cell / 8)), C_FG)
                elseif v == "water" then
                    bb:paintRect(cx, cy, cell, cell, C_WATER)
                elseif v == "hit" then
                    cross(bb, cx, cy, cell, thick, C_FG)
                elseif v == "sunk" then
                    bb:paintRect(cx, cy, cell, cell, C_FG)
                    cross(bb, cx, cy, cell, thick, C_BG)
                end
            end
        end
    end

    -- Grid lines, outer frame heavier.
    local gx, gy = x + band, y + band
    for i = 0, n do
        local w = (i == 0 or i == n) and 2 or 1
        local col = (i == 0 or i == n) and C_FG or C_GRID
        bb:paintRect(gx + i * cell - (i == n and w - 1 or 0), gy, w, n * cell, col)
        bb:paintRect(gx, gy + i * cell - (i == n and w - 1 or 0), n * cell, w, col)
    end

    -- Selected ship (setup) and selected cell: heavy outline.
    local frame = math.max(3, math.floor(cell / 8))
    local si = self.getSelectedShip and self.getSelectedShip()
    if si and board.ships[si] then
        local s = board.ships[si]
        local sx, sy = self:cellOrigin(s.r, s.c)
        local w = s.dir == "h" and s.len * cell or cell
        local h = s.dir == "v" and s.len * cell or cell
        bb:paintBorder(sx - 1, sy - 1, w + 2, h + 2, frame, C_FG)
    end
    local r, c = nil, nil
    if self.getSelectedCell then r, c = self.getSelectedCell() end
    if r then
        local sx, sy = self:cellOrigin(r, c)
        bb:paintBorder(sx - 1, sy - 1, cell + 2, cell + 2, frame, C_FG)
    end
end

function NavalGrid:refresh()
    UIManager:setDirty(self, function()
        return "ui", self.paint_rect or self.dimen
    end)
end

return NavalGrid
