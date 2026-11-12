package.path = "./?.lua;./common/?.lua;" .. package.path
local Board = dofile("board.lua")
local Duo = require("duo")

local function fleetCells(b)
    local n = 0
    for _, s in ipairs(b.ships) do n = n + s.len end
    return n
end

describe("fleet placement", function()
    it("places every ship legally, for every size and both touching rules", function()
        for _, n in ipairs(Board.SIZE_ORDER) do
            for _, touching in ipairs({ false, true }) do
                for seed = 1, 40 do
                    local b = Board.new{ n = n, touching = touching }
                    assert.is_true(b:placeRandom(Duo.rng(seed):fn()))
                    assert.equals(#Board.SIZES[n], #b.ships)
                    for i, s in ipairs(b.ships) do
                        assert.is_true(b:fits(s, i), "ship " .. i .. " seed " .. seed)
                    end
                    local covered = 0
                    for r = 1, n do
                        for c = 1, n do
                            if b:shipAt(r, c) then covered = covered + 1 end
                        end
                    end
                    assert.equals(fleetCells(b), covered)
                end
            end
        end
    end)

    it("keeps ships apart, diagonals included, unless touching is allowed", function()
        local b = Board.new{ n = 10 }
        b.ships = { { len = 3, r = 1, c = 1, dir = "h" } }
        assert.is_false(b:fits({ len = 2, r = 2, c = 4, dir = "h" }))
        assert.is_true(b:fits({ len = 2, r = 3, c = 1, dir = "h" }))
        b.touching = true
        assert.is_true(b:fits({ len = 2, r = 2, c = 4, dir = "h" }))
        assert.is_false(b:fits({ len = 2, r = 1, c = 3, dir = "v" }))
    end)

    it("moves and rotates only to legal places, sliding back from the edge", function()
        local b = Board.new{ n = 8 }
        b.ships = { { len = 4, r = 1, c = 1, dir = "h" }, { len = 2, r = 8, c = 7, dir = "h" } }
        assert.is_true(b:moveShip(1, 4, 7))
        assert.same({ len = 4, r = 4, c = 5, dir = "h" }, b.ships[1])
        assert.is_true(b:rotateShip(1))
        assert.same({ len = 4, r = 4, c = 5, dir = "v" }, b.ships[1])
        assert.is_false(b:moveShip(2, 7, 6))   -- would touch ship 1's tail
        assert.is_true(b:rotateShip(2))         -- slides up from row 8
        assert.same({ len = 2, r = 7, c = 7, dir = "v" }, b.ships[2])
    end)
end)

describe("shots received", function()
    local function readyBoard()
        local b = Board.new{ n = 8 }
        b.ships = {
            { len = 4, r = 1, c = 1, dir = "h" },
            { len = 3, r = 3, c = 1, dir = "v" },
            { len = 3, r = 3, c = 8, dir = "v" },
            { len = 2, r = 8, c = 3, dir = "h" },
            { len = 2, r = 5, c = 5, dir = "h" },
        }
        assert.is_true(b:startPlay())
        return b
    end

    it("answers miss, hit, sunk and again", function()
        local b = readyBoard()
        assert.equals("miss", b:receive(2, 2))
        assert.equals("again", b:receive(2, 2))
        assert.equals("hit", b:receive(5, 5))
        local res, len = b:receive(5, 6)
        assert.equals("sunk", res)
        assert.equals(2, len)
        assert.equals(4, b:shipsAfloat())
    end)

    it("ends the game on the last ship, and undo reopens it", function()
        local b = readyBoard()
        local last
        for _, s in ipairs(b.ships) do
            for _, p in ipairs(Board.cells(s)) do last = b:receive(p[1], p[2]) end
        end
        assert.equals("lost", last)
        assert.equals("over", b.phase)
        assert.equals("opponent", b.winner)
        assert.equals("in", b:undo())
        assert.equals("play", b.phase)
        assert.equals(1, b:shipsAfloat())
    end)
end)

describe("shots fired", function()
    it("marks a sunk ship and the water around it", function()
        local b = Board.new{ n = 8 }
        b:placeRandom(Duo.rng(1):fn())
        b:startPlay()
        b:record(4, 4, "hit")
        b:record(4, 5, "hit")
        b:record(4, 6, "sunk")
        for c = 4, 6 do assert.equals("sunk", b.shots[4][c]) end
        assert.equals("water", b.shots[3][3])
        assert.equals("water", b.shots[5][7])
        assert.is_nil(b.shots[2][4])
        assert.equals(1, b.sunk_opponent)
        b:undo()
        assert.equals("hit", b.shots[4][5])
        assert.is_nil(b.shots[4][6])
        assert.is_nil(b.shots[3][3])
        assert.equals(0, b.sunk_opponent)
    end)

    it("leaves the water alone when ships may touch", function()
        local b = Board.new{ n = 8, touching = true }
        b:placeRandom(Duo.rng(2):fn())
        b:startPlay()
        b:record(2, 2, "sunk")
        assert.is_nil(b.shots[1][1])
    end)

    it("wins once the whole fleet is sunk", function()
        local b = Board.new{ n = 8 }
        b:placeRandom(Duo.rng(3):fn())
        b:startPlay()
        local won
        for i = 1, #b:fleet() do won = b:record(i, 1, "sunk") end
        assert.is_true(won)
        assert.equals("me", b.winner)
    end)
end)

describe("save", function()
    it("round-trips a game in progress", function()
        local b = Board.new{ n = 10 }
        b:placeRandom(Duo.rng(4):fn())
        b:startPlay()
        b:receive(1, 1)
        b:record(5, 5, "hit")
        local t = b:serialize()
        local b2 = Board.load(t)
        assert.same(t, b2:serialize())
        assert.is_true(b2:canUndo())
    end)

    it("refuses broken saves", function()
        assert.is_nil(Board.load(nil))
        assert.is_nil(Board.load({ n = 9, ships = {} }))
        assert.is_nil(Board.load({ n = 8, ships = {} }))
    end)

    it("names cells like the players call them", function()
        assert.equals("A1", Board.cellName(1, 1))
        assert.equals("J10", Board.cellName(10, 10))
    end)
end)
