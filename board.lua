-- ---------------------------------------------------------------------------
-- board.lua — Naval Duel: one player's side of a two-reader battleship game.
-- Pure Lua, no UI.
--
-- Each player places a fleet on their own reader. Shots are called aloud
-- ("C7"); the player being shot at taps the cell on their reader, which
-- answers miss, hit or sunk -- so nobody can get the answer wrong. The
-- answer is called back and the shooter records it on their own tracking
-- grid. Neither reader knows anything about the other: this board holds
--   * the fleet and the shots received (`incoming`), and
--   * the shots fired and what the opponent answered (`shots`).
--
-- Cells are (r, c), 1-based. Phases: "setup" (placing ships), "play",
-- "over" (`winner` = "me" or "opponent").
-- ---------------------------------------------------------------------------

local Board = {}
Board.__index = Board

-- Grid sizes and their fleets (ship lengths, longest first).
Board.SIZES = {
    [8]  = { 4, 3, 3, 2, 2 },
    [10] = { 5, 4, 3, 3, 2 },
}
Board.SIZE_ORDER = { 8, 10 }

-- Ship placements tried by placeRandom before starting over (a crowded grid
-- with no touching can paint itself into a corner).
Board.PLACE_TRIES = 200

function Board.new(o)
    o = o or {}
    local self = setmetatable({}, Board)
    self.n        = Board.SIZES[o.n] and o.n or 10
    self.touching = o.touching == true
    self.phase    = o.phase or "setup"
    self.winner   = o.winner
    self.ships    = o.ships or {}
    -- incoming[r][c]: nil (not shot), "miss", "hit"
    self.incoming = o.incoming or {}
    -- shots[r][c]: nil, "miss", "hit", "sunk", "water" (deduced: next to a
    -- sunk ship, so no ship can be there when ships may not touch)
    self.shots    = o.shots or {}
    self.history  = o.history or {}
    self.sunk_opponent = o.sunk_opponent or 0
    for r = 1, self.n do
        self.incoming[r] = self.incoming[r] or {}
        self.shots[r] = self.shots[r] or {}
    end
    return self
end

function Board:fleet()
    return Board.SIZES[self.n]
end

function Board:serialize()
    return {
        n = self.n, touching = self.touching, phase = self.phase, winner = self.winner,
        ships = self.ships, incoming = self.incoming, shots = self.shots,
        history = self.history, sunk_opponent = self.sunk_opponent,
    }
end

function Board.load(t)
    if type(t) ~= "table" or not Board.SIZES[t.n] or type(t.ships) ~= "table" then return nil end
    local b = Board.new(t)
    if #b.ships ~= #b:fleet() then return nil end
    return b
end

-- ---------------------------------------------------------------------------
-- Ships
-- ---------------------------------------------------------------------------

-- Cells of a ship { len, r, c, dir = "h"|"v" }.
function Board.cells(ship)
    local out = {}
    for i = 0, ship.len - 1 do
        if ship.dir == "h" then
            out[#out + 1] = { ship.r, ship.c + i }
        else
            out[#out + 1] = { ship.r + i, ship.c }
        end
    end
    return out
end

-- Index of the ship covering (r, c), or nil.
function Board:shipAt(r, c)
    for i, s in ipairs(self.ships) do
        for _, p in ipairs(Board.cells(s)) do
            if p[1] == r and p[2] == c then return i end
        end
    end
end

-- Can `ship` stand there, ignoring the ship at index `skip`?
function Board:fits(ship, skip)
    local n = self.n
    for _, p in ipairs(Board.cells(ship)) do
        if p[1] < 1 or p[1] > n or p[2] < 1 or p[2] > n then return false end
    end
    local gap = self.touching and 0 or 1
    for i, other in ipairs(self.ships) do
        if i ~= skip then
            for _, p in ipairs(Board.cells(ship)) do
                for _, q in ipairs(Board.cells(other)) do
                    if math.abs(p[1] - q[1]) <= gap and math.abs(p[2] - q[2]) <= gap then
                        return false
                    end
                end
            end
        end
    end
    return true
end

-- Places the whole fleet at random. rnd(m) -> 1..m.
function Board:placeRandom(rnd)
    rnd = rnd or math.random
    local fleet = self:fleet()
    for _try = 1, 50 do
        self.ships = {}
        local ok = true
        for _, len in ipairs(fleet) do
            local placed = false
            for _t = 1, Board.PLACE_TRIES do
                local dir = rnd(2) == 1 and "h" or "v"
                local maxr = dir == "v" and self.n - len + 1 or self.n
                local maxc = dir == "h" and self.n - len + 1 or self.n
                local ship = { len = len, r = rnd(maxr), c = rnd(maxc), dir = dir }
                if self:fits(ship) then
                    self.ships[#self.ships + 1] = ship
                    placed = true
                    break
                end
            end
            if not placed then ok = false break end
        end
        if ok then return true end
    end
    return false
end

-- Moves ship i so that its first cell is (r, c). False if it does not fit.
function Board:moveShip(i, r, c)
    local s = self.ships[i]
    if not s or self.phase ~= "setup" then return false end
    local moved = { len = s.len, r = r, c = c, dir = s.dir }
    -- A ship that would run off the edge slides back inside.
    if moved.dir == "h" then moved.c = math.min(moved.c, self.n - s.len + 1)
    else moved.r = math.min(moved.r, self.n - s.len + 1) end
    if not self:fits(moved, i) then return false end
    self.ships[i] = moved
    return true
end

-- Turns ship i a quarter turn around its first cell (sliding it back
-- inside the grid if needed). False if it does not fit.
function Board:rotateShip(i)
    local s = self.ships[i]
    if not s or self.phase ~= "setup" then return false end
    local turned = { len = s.len, r = s.r, c = s.c, dir = s.dir == "h" and "v" or "h" }
    if turned.dir == "h" then turned.c = math.min(turned.c, self.n - s.len + 1)
    else turned.r = math.min(turned.r, self.n - s.len + 1) end
    if not self:fits(turned, i) then return false end
    self.ships[i] = turned
    return true
end

function Board:startPlay()
    if self.phase ~= "setup" or #self.ships ~= #self:fleet() then return false end
    self.phase = "play"
    return true
end

-- ---------------------------------------------------------------------------
-- Shots received
-- ---------------------------------------------------------------------------

function Board:shipSunk(i)
    for _, p in ipairs(Board.cells(self.ships[i])) do
        if self.incoming[p[1]][p[2]] ~= "hit" then return false end
    end
    return true
end

function Board:shipsAfloat()
    local n = 0
    for i = 1, #self.ships do
        if not self:shipSunk(i) then n = n + 1 end
    end
    return n
end

-- The opponent fires at (r, c). Returns "miss", "hit", "sunk" (with the
-- ship's length) or "lost" (that was the last ship), or "again" if that
-- cell was already shot (nothing changes).
function Board:receive(r, c)
    if self.phase ~= "play" then return nil end
    if self.incoming[r][c] then return "again" end
    local i = self:shipAt(r, c)
    self.incoming[r][c] = i and "hit" or "miss"
    self.history[#self.history + 1] = { kind = "in", r = r, c = c }
    if not i then return "miss" end
    if not self:shipSunk(i) then return "hit" end
    if self:shipsAfloat() == 0 then
        self.phase, self.winner = "over", "opponent"
        return "lost", self.ships[i].len
    end
    return "sunk", self.ships[i].len
end

-- ---------------------------------------------------------------------------
-- Shots fired
-- ---------------------------------------------------------------------------

-- The run of hit/sunk cells through (r, c) along the line they form (a lone
-- cell is a ship of one direction-less cell).
function Board:hitRun(r, c)
    local function isHit(rr, cc)
        if rr < 1 or rr > self.n or cc < 1 or cc > self.n then return false end
        local v = self.shots[rr][cc]
        return v == "hit" or v == "sunk"
    end
    local horiz = isHit(r, c - 1) or isHit(r, c + 1)
    local dr, dc = 0, 1
    if not horiz then dr, dc = 1, 0 end
    local run = { { r, c } }
    for _, sgn in ipairs({ -1, 1 }) do
        local rr, cc = r + sgn * dr, c + sgn * dc
        while isHit(rr, cc) do
            run[#run + 1] = { rr, cc }
            rr, cc = rr + sgn * dr, cc + sgn * dc
        end
    end
    return run
end

-- Records the answer to my shot at (r, c): "miss", "hit" or "sunk". On
-- "sunk", the whole ship turns sunk and, when ships may not touch, the
-- water around it is marked. Returns true once the opponent's last ship
-- is sunk.
function Board:record(r, c, result)
    if self.phase ~= "play" then return false end
    local before = {}
    local function set(rr, cc, v)
        before[#before + 1] = { rr, cc, self.shots[rr][cc] }
        self.shots[rr][cc] = v
    end
    set(r, c, result == "miss" and "miss" or "hit")
    if result == "sunk" then
        local run = self:hitRun(r, c)
        for _, p in ipairs(run) do set(p[1], p[2], "sunk") end
        if not self.touching then
            for _, p in ipairs(run) do
                for dr = -1, 1 do
                    for dc = -1, 1 do
                        local rr, cc = p[1] + dr, p[2] + dc
                        if rr >= 1 and rr <= self.n and cc >= 1 and cc <= self.n
                           and self.shots[rr][cc] == nil then
                            set(rr, cc, "water")
                        end
                    end
                end
            end
        end
        self.sunk_opponent = self.sunk_opponent + 1
    end
    self.history[#self.history + 1] = { kind = "out", before = before, sunk = result == "sunk" }
    if self.sunk_opponent >= #self:fleet() then
        self.phase, self.winner = "over", "me"
        return true
    end
    return false
end

function Board:canUndo()
    return #self.history > 0
end

-- Takes back the last thing entered (a shot received or a shot recorded),
-- including the end of the game it caused.
function Board:undo()
    local h = table.remove(self.history)
    if not h then return nil end
    if h.kind == "in" then
        self.incoming[h.r][h.c] = nil
    else
        for i = #h.before, 1, -1 do
            local b = h.before[i]
            self.shots[b[1]][b[2]] = b[3]
        end
        if h.sunk then self.sunk_opponent = self.sunk_opponent - 1 end
    end
    if self.phase == "over" then
        self.phase, self.winner = "play", nil
    end
    return h.kind
end

-- "A1".."J10": column letter, row number.
function Board.cellName(r, c)
    return string.char(64 + c) .. r
end

return Board
