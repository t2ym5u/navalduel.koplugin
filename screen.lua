local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local ButtonDialog    = require("ui/widget/buttondialog")
local ConfirmBox      = require("ui/widget/confirmbox")
local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local ScreenBase = require("screen_base")

local Board     = lrequire("board")
local NavalGrid = lrequire("board_widget")

local RULES_EN = [[
Naval Duel — two readers, one battle

Each player has a reader and hides a fleet on it. The readers never talk to each other: you call your shots aloud, and the reader of the player being shot at gives the answer, so nobody can get it wrong.

Setting up
• Agree on the grid size and on whether ships may touch (menu), so both readers have the same fleet.
• Your fleet is placed at random. Shuffle deals another one. Tap a ship to select it, then tap a cell to move it there; tap the selected ship again to turn it.
• Tap Start battle. Hide your screen!

Playing — take turns
• Your turn: say a cell ("C7"). Your opponent taps that cell on their own reader (My fleet), taps Fire, and reads you the answer: miss, hit, or hit and sunk. Note it on your tracking grid (My shots): tap the cell, then Miss, Hit or Sunk.
• Opponent's turn: they call a cell. Open My fleet, tap that cell, tap Fire, and read them the answer.
• By default ships may not touch, not even at a corner: when you sink a ship, the cells around it are greyed out on your tracking grid.

The first to sink the whole enemy fleet wins. Undo takes back the last thing you entered.
]]

local RULES_FR = [[
Bataille navale à deux — deux liseuses, une bataille

Chaque joueur a une liseuse et y cache sa flotte. Les liseuses ne communiquent pas : on annonce ses tirs à voix haute, et c'est la liseuse du joueur visé qui donne la réponse, donc personne ne peut se tromper.

Mise en place
• Mettez-vous d'accord sur la taille de la grille et sur le contact entre navires (menu) : les deux liseuses doivent avoir la même flotte.
• Votre flotte est placée au hasard. Mélanger en propose une autre. Touchez un navire pour le sélectionner, puis une case pour l'y déplacer ; touchez de nouveau le navire sélectionné pour le tourner.
• Touchez Commencer la bataille. Cachez votre écran !

Déroulement — chacun son tour
• À vous : annoncez une case (« C7 »). Votre adversaire touche cette case sur sa liseuse (Ma flotte), touche Tirer et vous lit la réponse : à l'eau, touché, ou touché-coulé. Notez-la sur votre grille de tirs (Mes tirs) : touchez la case, puis À l'eau, Touché ou Coulé.
• À l'adversaire : il annonce une case. Ouvrez Ma flotte, touchez cette case, touchez Tirer et lisez-lui la réponse.
• Par défaut, les navires ne se touchent pas, même par un coin : quand vous coulez un navire, les cases autour sont grisées sur votre grille de tirs.

Le premier qui coule toute la flotte adverse gagne. Annuler reprend la dernière saisie.
]]

local NavalScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function NavalScreen:init()
    self.board = Board.load(self.plugin:loadState())
    if not self.board then self:freshBoard() end
    self.view = self.board.phase == "setup" and "fleet" or (self.plugin:getSetting("view", "fleet"))
    ScreenBase.init(self)
end

function NavalScreen:freshBoard()
    self.board = Board.new{
        n        = self.plugin:getSetting("size", 10),
        touching = self.plugin:getSetting("touching", false),
    }
    self.board:placeRandom()
    self.sel_r, self.sel_c, self.sel_ship = nil, nil, nil
end

function NavalScreen:serializeState()
    return self.board:serialize()
end

function NavalScreen:save()
    self.plugin:saveState(self.board:serialize())
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function NavalScreen:isRoundOver()
    return self.board.phase == "over"
end

function NavalScreen:actionRows()
    local b = self.board
    if b.phase == "setup" then
        return { {
            { text = _("Shuffle"), callback = function() self:onShuffle() end },
            { text = _("Start battle"), callback = function() self:onStartBattle() end },
        } }
    end
    local views = {
        { text = (self.view == "fleet" and "▸ " or "") .. _("My fleet"),
          callback = function() self:setView("fleet") end },
        { text = (self.view == "shots" and "▸ " or "") .. _("My shots"),
          callback = function() self:setView("shots") end },
    }
    if self.view == "fleet" then
        return { views, {
            { text = _("Fire"), callback = function() self:onFire() end },
            { text = _("Undo"), callback = function() self:onUndo() end },
        } }
    end
    return { views, {
        { text = _("Miss"), callback = function() self:onRecord("miss") end },
        { text = _("Hit"),  callback = function() self:onRecord("hit") end },
        { text = _("Sunk"), callback = function() self:onRecord("sunk") end },
        { text = _("Undo"), callback = function() self:onUndo() end },
    } }
end

function NavalScreen:buildLayout()
    local title_bar = self:buildTitleBar(_("Naval Duel"), function()
        return {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = _("Grid size"), callback = function() self:openSizeMenu() end },
            { text = self.plugin:getSetting("touching", false)
                    and _("Ships may touch: yes") or _("Ships may touch: no"),
              callback = function() self:toggleTouching() end },
            self:makeRulesButtonConfig(RULES_EN, RULES_FR),
        }
    end)

    self.status_text:setMaxWidth(self:getControlsWidth())
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar(self:actionRows()),
    }

    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.grid = NavalGrid:new{
        board      = self.board,
        view       = self.view,
        max_width  = budget_w,
        max_height = budget_h,
        getSelectedCell = function() return self.sel_r, self.sel_c end,
        getSelectedShip = function() return self.sel_ship end,
        onCellTapped    = function(r, c) self:onCellTapped(r, c) end,
    }
    self.board_widget = self.grid
    local grid_frame = FrameContainer:new{ padding = 0, margin = 0, bordersize = 0, self.grid }

    if self:isLandscape() then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            grid_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, grid_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

function NavalScreen:rebuild()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function NavalScreen:updateStatus(message)
    local b = self.board
    local status = message
    if not status then
        if b.phase == "setup" then
            status = self.sel_ship and _("Tap a cell to move the ship there, or the ship again to turn it.")
                or _("Tap a ship to move it.")
        elseif b.phase == "over" then
            status = b.winner == "me" and _("You sank the whole enemy fleet. You win!")
                or _("Your fleet is sunk. Your opponent wins.")
        else
            local fleet = #b:fleet()
            status = self:joinStatus(
                T(_("My ships afloat: %1/%2"), b:shipsAfloat(), fleet),
                T(_("Enemy ships sunk: %1/%2"), b.sunk_opponent, fleet))
        end
    end
    ScreenBase.updateStatus(self, status)
end

-- ---------------------------------------------------------------------------
-- Setup
-- ---------------------------------------------------------------------------

function NavalScreen:onShuffle()
    self.board:placeRandom()
    self.sel_ship = nil
    self:save()
    self.grid:refresh()
    self:updateStatus()
end

function NavalScreen:onStartBattle()
    if not self.board:startPlay() then return end
    self.sel_ship, self.sel_r, self.sel_c = nil, nil, nil
    self.view = "fleet"
    self:save()
    self:rebuild()
    self:showMessage(_("The battle starts. Hide your screen from your opponent!"), 3)
end

-- ---------------------------------------------------------------------------
-- Taps
-- ---------------------------------------------------------------------------

function NavalScreen:onCellTapped(r, c)
    local b = self.board
    if b.phase == "setup" then
        local i = b:shipAt(r, c)
        if i and i == self.sel_ship then
            if not b:rotateShip(i) then
                self:updateStatus(_("No room to turn this ship here."))
                return
            end
        elseif i then
            self.sel_ship = i
        elseif self.sel_ship then
            if not b:moveShip(self.sel_ship, r, c) then
                self:updateStatus(_("The ship does not fit there (ships may not touch)."))
                return
            end
        end
        self:save()
        self.grid:refresh()
        self:updateStatus()
        return
    end
    if b.phase ~= "play" then return end
    self.sel_r, self.sel_c = r, c
    self.grid:refresh()
    local name = Board.cellName(r, c)
    if self.view == "fleet" then
        if b.incoming[r][c] then
            self:updateStatus(T(_("%1 was already shot."), name))
        else
            self:updateStatus(T(_("Opponent fires at %1? Tap Fire."), name))
        end
    else
        self:updateStatus(T(_("My shot at %1: tap the answer."), name))
    end
end

function NavalScreen:setView(view)
    if self.view == view then return end
    self.view = view
    self.sel_r, self.sel_c = nil, nil
    self.plugin:saveSetting("view", view)
    self:rebuild()
end

-- ---------------------------------------------------------------------------
-- Play
-- ---------------------------------------------------------------------------

function NavalScreen:onFire()
    local b, r, c = self.board, self.sel_r, self.sel_c
    if b.phase ~= "play" then return end
    if not r then
        self:updateStatus(_("First tap the cell your opponent called."))
        return
    end
    local res, len = b:receive(r, c)
    local name = Board.cellName(r, c)
    local text
    if res == "again" then
        text = T(_("%1 was already shot: tell your opponent to call another cell."), name)
    elseif res == "miss" then
        text = T(_("%1: miss!"), name)
    elseif res == "hit" then
        text = T(_("%1: hit!"), name)
    elseif res == "sunk" then
        text = T(_("%1: hit and sunk! (a ship of %2)"), name, len)
    elseif res == "lost" then
        text = T(_("%1: hit and sunk! That was your last ship."), name)
    end
    self.sel_r, self.sel_c = nil, nil
    self:save()
    self.grid:refresh()
    self:updateStatus()
    self:refreshActionBar()
    if text then self:showMessage(text, res == "lost" and 5 or 3) end
end

function NavalScreen:onRecord(result)
    local b, r, c = self.board, self.sel_r, self.sel_c
    if b.phase ~= "play" then return end
    if not r then
        self:updateStatus(_("First tap the cell you fired at."))
        return
    end
    local won = b:record(r, c, result)
    self.sel_r, self.sel_c = nil, nil
    self:save()
    self.grid:refresh()
    self:updateStatus()
    self:refreshActionBar()
    if won then self:showMessage(_("You sank the whole enemy fleet. You win!"), 5) end
end

function NavalScreen:onUndo()
    local kind = self.board:undo()
    if not kind then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    -- Show the grid the undone entry was on.
    local view = kind == "in" and "fleet" or "shots"
    self:save()
    if view ~= self.view or self.action_bar.round_over then
        self.view = view
        self.plugin:saveSetting("view", view)
        self.sel_r, self.sel_c = nil, nil
        self:rebuild()
    else
        self.grid:refresh()
        self:updateStatus()
    end
end

-- ---------------------------------------------------------------------------
-- New game and settings
-- ---------------------------------------------------------------------------

-- apply (optional) changes a setting once the player has agreed to drop
-- the battle in progress.
function NavalScreen:onNewGame(force, apply)
    if not force and self.board.phase == "play" then
        UIManager:show(ConfirmBox:new{
            text = _("Abandon the battle in progress?"),
            ok_text = _("New game"),
            ok_callback = function() self:onNewGame(true, apply) end,
        })
        return
    end
    if apply then apply() end
    self:freshBoard()
    self.view = "fleet"
    self:save()
    self:rebuild()
end

function NavalScreen:openSizeMenu()
    local dlg
    local buttons = {}
    for _i, n in ipairs(Board.SIZE_ORDER) do
        buttons[#buttons + 1] = { {
            text = T(_("%1×%1 (%2 ships)"), n, #Board.SIZES[n]),
            callback = function()
                UIManager:close(dlg)
                self:onNewGame(false, function() self.plugin:saveSetting("size", n) end)
            end,
        } }
    end
    dlg = ButtonDialog:new{ title = _("Grid size"), buttons = buttons }
    UIManager:show(dlg)
end

function NavalScreen:toggleTouching()
    local touching = not self.plugin:getSetting("touching", false)
    self:onNewGame(false, function() self.plugin:saveSetting("touching", touching) end)
end

return NavalScreen
