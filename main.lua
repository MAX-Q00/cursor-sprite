--[[
  Cursor Sprite
  -------------
  Shows any built-in game sprite, item icon or game cursor image next to
  your mouse pointer. Pick one from a searchable list or type an item ID.

  Guideline notes for moderators:
    * Display only. A click-through, input-disabled ui.Sprite on the top
      plugin layer is moved to Mouse.GetPosition() each Logic tick. It sends
      no input, menu actions or packets and never blocks clicks.
    * The API has no call to hide or replace the OS/game cursor (only
      per-component cursorConfig on the plugin's own components), so the
      real pointer stays visible and the sprite follows beside it.
    * No permissions. Lists are read at runtime from id.Sprite, config.Obj
      and id.Cursor/config.Cursor; nothing is bundled or transmitted.
    * List is virtualised (fixed row components rebound on paging).
    * 0.1.19: manual X/Y offset (arrows, typed boxes, step 1/5/10/15/90),
      rotation via the documented SpriteData rotationDegrees property, and
      Favorites that save each sprite's offset, size and rotation in this
      plugin's own PersistentDB record. The page number is a typed box.
]]

local PLUGIN_NAME = "Cursor Sprite"
local helpers = require("ui_helpers")
helpers.VERSION = "0.1.27"
local H = helpers

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local KEY = "cursor_sprite"
local state = {}
pcall(function() state = PersistentDB:GetStructuredData(KEY) or {} end)
if type(state) ~= "table" then state = {} end
if state.on == nil then state.on = true end
state.size = state.size or 3      -- index into SIZES
state.pos = state.pos or 1        -- 0.1.3: 1 = On-point (default), 2 = Offset
state.off = nil                   -- 0.1.0-0.1.2 offset list, replaced by state.pos
state.alpha = state.alpha or 1    -- index into ALPHAS
state.set = state.set or "sprite"
-- 0.1.1: new defaults cover the pointer (offset None, 32 px, 100%); applied once.
if not state.v011 then state.size = 3; state.alpha = 1; state.v011 = true end
local function save() pcall(function() PersistentDB:SetStructuredData(KEY, state) end) end

local SIZES = { 16, 24, 32, 48, 64 }
local ALPHAS = { 1.0, 0.75, 0.5, 0.25 }
local function clampIdx(v, n, d) v = tonumber(v); if v == nil or v ~= v then return d end; v = math.floor(v); if v < 1 or v > n then return d end; return v end
state.size = clampIdx(state.size, #SIZES, 3)
-- 0.1.13: size as a percentage of 32 px, 50-400 in 25% steps (old px choice migrated once).
local SCALE_MIN, SCALE_MAX, SCALE_STEP, BASE_PX = 50, 400, 25, 32
local function clampScale(v)
    v = tonumber(v); if v == nil or v ~= v then return 100 end
    v = math.floor(v + 0.5); if v < SCALE_MIN then v = SCALE_MIN elseif v > SCALE_MAX then v = SCALE_MAX end
    return v
end
if state.scale == nil then state.scale = math.floor(SIZES[state.size] * 100 / BASE_PX + 0.5) end
state.scale = clampScale(state.scale)
state.trim = nil   -- 0.1.18: Tip trim removed; saved trims dropped
-- 0.1.19: manual offset (interface units at 100% size, scaled with Size),
-- rotation in degrees, step size, favorites { key -> entry }.
local OFF_MIN, OFF_MAX = -200, 200
local STEPS = { 1, 5, 10, 15, 90 }
local function clampNum(v, lo, hi, d)
    v = tonumber(v); if v == nil or v ~= v then return d end
    v = math.floor(v + 0.5); if v < lo then v = lo elseif v > hi then v = hi end
    return v
end
state.offX = clampNum(state.offX, OFF_MIN, OFF_MAX, 0)
state.offY = clampNum(state.offY, OFF_MIN, OFF_MAX, 0)
state.rot = clampNum(state.rot, 0, 359, 0)
state.step = clampNum(state.step, 1, #STEPS, 1)
if type(state.favs) ~= "table" then state.favs = {} end
state.favMode = state.favMode == true
-- 0.1.23: Recent list (last 8 picks) and 4 presets { scale, rot, offX, offY }.
if type(state.recent) ~= "table" then state.recent = {} end
state.recentMode = state.recentMode == true and not state.favMode
if type(state.presets) ~= "table" then state.presets = {} end
state.preset = clampNum(state.preset, 1, 4, 1)
state.alpha = clampIdx(state.alpha, #ALPHAS, 1)
state.pos = clampIdx(state.pos, 2, 1)
if type(state.on) ~= "boolean" then state.on = true end
local POS_LABEL = { "On-point", "Offset" }
-- Standard arrow pointer at 1x, in window pixels (Windows default arrow is
-- about 12 x 19 px). Offset mode moves the image just past it.
local ARROW_W, ARROW_H = 12, 19
local function cursorScale()
    local v = nil
    pcall(function() v = game.options.CursorScale.setting end)
    if type(v) ~= "number" then return 1 end
    if v >= 50 and v <= 400 then return v / 100 end   -- percentage
    if v >= 1 and v <= 4 then return v end             -- multiplier
    return 1
end
local SETS = { "sprite", "item", "cursor" }
local SET_LABEL = { sprite = "Sprites", item = "Items", cursor = "Cursors" }

-------------------------------------------------------------------------------
-- Lists, read at runtime. Entry: { id, name, lower, spr, hx, hy }
--   sprite: id.Sprite table, else id.Sprite.FromID scan
--   item:   config.Obj.FromID scan (named objects only)
--   cursor: id.Cursor table + config.Cursor (sprite + hotspot)
-------------------------------------------------------------------------------
local lists = {
    sprite = { items = {}, next = nil, max = 40000, step = 1500, source = "" },
    item   = { items = {}, next = nil, max = 65000, step = 800,  source = "" },
    cursor = { items = {}, next = nil, max = 0,     step = 0,    source = "" },
}
-- Display/search form of a name: '_' -> ' ', repeated spaces collapsed, trimmed.
local function nice(n) return (tostring(n or ""):gsub("_", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
local function norm(q) return string.lower(nice(q)) end
local function add(L, e) e.raw = e.name; e.name = nice(e.name); e.lower = norm(e.raw); L.items[#L.items + 1] = e end
local function sortL(L) table.sort(L.items, function(a, b) return a.id < b.id end) end

local function initSprite()
    local L = lists.sprite
    pcall(function()
        for k, v in pairs(id.Sprite) do
            if type(k) == "string" and type(v) == "number" then add(L, { id = v, name = k, spr = v }) end
        end
    end)
    if #L.items > 0 then sortL(L); L.source = "id.Sprite table" else L.items = {}; L.next = 0 end
end
local function initItem() lists.item.next = 0 end
local function initCursor()
    local L = lists.cursor
    pcall(function()
        for k, v in pairs(id.Cursor) do
            if type(k) == "string" and type(v) == "number" then
                local cfg = nil
                pcall(function() cfg = config.Cursor.FromID(v) end)
                if cfg ~= nil then
                    local e = { id = v, name = k }
                    pcall(function() e.spr = cfg.spriteID; e.hx = cfg.hotspotX; e.hy = cfg.hotspotY end)
                    if e.spr ~= nil and e.spr >= 0 then add(L, e) end
                end
            end
        end
    end)
    sortL(L); L.source = #L.items > 0 and "id.Cursor table" or "not available"
end
initSprite(); initItem(); initCursor()

--- One scan step for a list still scanning. Returns true when done.
local function scanStep(kind)
    local L = lists[kind]
    if L.next == nil then return true end
    local stop = math.min(L.max, L.next + L.step)
    for i = L.next, stop do
        if kind == "sprite" then
            local nm = nil
            pcall(function() nm = id.Sprite.FromID(i) end)
            if type(nm) == "string" and nm ~= "" then add(L, { id = i, name = nm, spr = i }) end
        else
            local nm = nil
            pcall(function() local o = config.Obj.FromID(i); if o ~= nil then nm = o.name end end)
            if type(nm) == "string" and nm ~= "" and nm ~= "null" then add(L, { id = i, name = nm }) end
        end
    end
    L.next = stop + 1
    if L.next > L.max then
        L.next = nil
        L.source = #L.items > 0 and (kind == "sprite" and "id.Sprite.FromID scan" or "config.Obj scan") or "not available"
        return true
    end
    return false
end

-------------------------------------------------------------------------------
-- Drawing a selection onto a pair of Sprite components (sprite / item).
-- sel = { kind = "sprite"|"item"|"cursor", id, spr, hx, hy, name }
-------------------------------------------------------------------------------
local function newPair(parent)
    local p = {}
    pcall(function()
        p.s = ui.Sprite.new(parent); p.s.hidden = true
        pcall(function() p.s.clickthrough = true end)
    end)
    pcall(function()
        p.o = ui.Sprite.new(parent); p.o.hidden = true
        pcall(function() p.o.clickthrough = true end)
    end)
    return p
end
local function pairShow(p, sel, x, y, size, alpha, align)
    if p == nil then return end
    local isItem = sel ~= nil and sel.kind == "item"
    local a, b = isItem and p.o or p.s, isItem and p.s or p.o
    pcall(function() b.hidden = true end)
    if sel == nil or a == nil then pcall(function() a.hidden = true end); return end
    pcall(function()
        if p.key ~= sel.kind .. sel.id then
            p.key = sel.kind .. sel.id
            if isItem then a:SetAssociatedObject(sel.id) else a.sprite = sel.spr end
        end
        a:SetSize(size, size)
        if align then a:SetPos(x, y, align[1], align[2]) else a:SetPos(x, y) end
        a.colour = Vector4.new(1, 1, 1, alpha or 1)
        a.hidden = false
    end)
end
local function pairHide(p)
    if p == nil then return end
    pcall(function() p.s.hidden = true end); pcall(function() p.o.hidden = true end)
end

-------------------------------------------------------------------------------
-- Follow-the-mouse overlay
-------------------------------------------------------------------------------
local overlay = nil
local window = nil
local function ensureOverlay()
    if overlay ~= nil then return true end
    local top = helpers.ensureHoverLayer()
    if top == nil then return false end
    -- Directly on the top plugin build layer (the same parent as every
    -- plugin window), raised to the front every tick. No full-screen layer:
    -- if the client ignored clickthrough on it, it would block all clicks.
    overlay = newPair(top)
    pcall(function() overlay.s.enabled = false end)
    pcall(function() overlay.o.enabled = false end)
    return true
end
local itemField, searchField = nil, nil
local function inRect(c, mx, my)
    local hit = false
    pcall(function()
        if c == nil or c.hidden then return end
        local p = c.xyGlobal
        hit = mx > p.x and mx < p.x + c.width and my > p.y and my < p.y + c.height
    end)
    return hit
end
-- Keep the cursor image above every panel (0.1.12). Called each tick, and
-- right after a selection change, panel raise or redraw.
local function raiseOverlay()
    pcall(function()
        if overlay == nil then return end
        if overlay.s ~= nil then overlay.s:MoveToFront() end
        if overlay.o ~= nil then overlay.o:MoveToFront() end
    end)
end
local function overPanel(mx, my)
    local r = nil
    pcall(function() r = helpers.panelRect() end)
    if r == nil then return false end
    return mx >= r.x and my >= r.y and mx <= r.x + r.w and my <= r.y + r.h
end
local numBoxes = {}   -- 0.1.19: typed boxes (offset, rotation, page)
local function overInput(mx, my)
    if inRect(itemField, mx, my) or inRect(searchField, mx, my) then return true end
    for _, f in ipairs(numBoxes) do if inRect(f, mx, my) then return true end end
    return false
end
-- 0.1.23: crosshair on the hotspot (the pointer tip) for 3 s after an edit
local cross, editTicks = nil, 0
local function crossShow(mx, my)
    if cross == nil then
        local top = helpers.ensureHoverLayer()
        if top == nil then return end
        cross = {}
        for i = 1, 2 do pcall(function()
            local r = ui.Rectangle.new(top); r.fill = true
            r.colour = Vector4.new(1.0, 0.25, 0.2, 0.95)
            pcall(function() r.clickthrough = true; r.enabled = false end)
            r.hidden = true
            cross[i] = r
        end) end
    end
    pcall(function()
        local show = editTicks > 0 and mx ~= nil
        for _, r in ipairs(cross) do r.hidden = not show end
        if not show then return end
        cross[1]:SetSize(11, 1); cross[1]:SetPos(math.floor(mx) - 5, math.floor(my))
        cross[2]:SetSize(1, 11); cross[2]:SetPos(math.floor(mx), math.floor(my) - 5)
        for _, r in ipairs(cross) do r:MoveToFront() end
    end)
end
local function tickOverlay()
    if editTicks > 0 then editTicks = editTicks - 1 end
    if not state.on or state.sel == nil then pairHide(overlay); crossShow(nil); return end
    local mx, my = helpers.mouseUI()
    if mx == nil or not ensureOverlay() then pairHide(overlay); return end
    -- 0.1.2: with offset None the image sits right under the pointer, and on
    -- the client it still took the clicks meant for the panel (clickthrough
    -- is not honoured there), so the search and item ID boxes never got
    -- focus. Hide it while the pointer is over this plugin's own panel.
    local size = math.max(1, math.floor(BASE_PX * clampScale(state.scale) / 100 + 0.5))
    local alpha = ALPHAS[state.alpha] or 1
    local sel = state.sel
    local x, y = mx, my
    -- 0.1.5: drawn over everything, including this panel. Only while the
    -- pointer is strictly inside one of the panel's text boxes is the image
    -- nudged off the pointer (Offset maths), so the box itself gets the
    -- click/focus even if the client ignores clickthrough there.
    local nudge = overInput(mx, my)
    if state.pos == 2 or nudge then
        -- Offset: shift by one arrow's width and height (window px scaled by
        -- the game's cursor scale), converted to interface units.
        local rx, uiPerPx = nil, 1
        pcall(function() rx = Mouse.GetX() end)
        if type(rx) == "number" and rx > 0 and mx > 0 then uiPerPx = mx / rx end
        if uiPerPx ~= uiPerPx or uiPerPx < 0.25 or uiPerPx > 4 then uiPerPx = 1 end
        local cs = cursorScale()
        x = mx + math.ceil(ARROW_W * cs * uiPerPx)
        y = my + math.ceil(ARROW_H * cs * uiPerPx)
    else
        -- On-point (0.1.15): image top-left exactly on the pointer tip for
        -- every type and size. No anchor subtraction; size only grows the
        -- image down/right from that corner.
        x, y = mx, my
        -- 0.1.19 rotation: the client rotates the image about its centre
        -- (assumed; not stated in the docs), which moves the top-left
        -- corner. Shift so the rotated image's original top-left corner
        -- stays on the pointer.
        if (state.rot or 0) ~= 0 then
            local h = size / 2
            local a = math.rad(state.rot)
            local ca, sa = math.cos(a), math.sin(a)
            -- corner (-h,-h) from the centre, rotated clockwise (y down)
            local rx, ry = -h * ca + h * sa, -h * sa - h * ca
            x, y = mx - rx - h, my - ry - h
        end
    end
    -- 0.1.19 manual offset on top, scaled with Size (50-400%)
    local k = clampScale(state.scale) / 100
    x = x + (state.offX or 0) * k
    y = y + (state.offY or 0) * k
    if x ~= x or y ~= y or math.abs(x) > 20000 or math.abs(y) > 20000 then x, y = mx, my end  -- NaN/huge guard
    pairShow(overlay, sel, math.floor(x), math.floor(y), size, alpha)
    pcall(function()
        local a = sel.kind == "item" and overlay.o or overlay.s
        if a.rotationDegrees ~= state.rot then a.rotationDegrees = state.rot end
    end)
    raiseOverlay()   -- every tick, also over our own panel (0.1.12)
    crossShow(mx, my)
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------
local ROWS = 10
local RH = 28            -- 0.1.23: row height (24 px icon on a slot tile)
local ICON = 24
local COL_PAD, COL_GAP, CTRL_GAP = 8, 8, 8
local ICON_W, ID_W = 28, 52
local ID_X, NAME_X
-- 0.1.25: adjustable ID column (shared helpers.columns); Name fills.
local cols, idHandle = nil, nil
local function recalcCols()
    if cols ~= nil then ID_W = cols:get("id") end
    ID_X = COL_PAD + ICON_W + COL_GAP
    NAME_X = ID_X + ID_W + COL_GAP
end
recalcCols()
local PANEL_W = 440
local BG = { { 0x24/255, 0x21/255, 0x1E/255 }, { 0x2E/255, 0x2A/255, 0x26/255 } }

local filtered, page = {}, 1
local filterText, lastFilterSeen = "", nil
-- 0.1.6 typing-free fallback: first-letter filter, ID jumps and a keypad.
local LETTERS = { "All" }
for c = string.byte("A"), string.byte("Z") do LETTERS[#LETTERS + 1] = string.char(c) end
LETTERS[#LETTERS + 1] = "0-9"
local letterIdx = 1
local padOpen, padStr = false, ""
local padBtn, letterBtn, padKeys, jumpBtns = nil, nil, {}, {}
local rowCells, rowBgs, headCells, headDiv, listBg = {}, {}, {}, nil, nil
local posBtn = nil
local sizeLbl, sizeMinus, sizePlus, sizeField = nil, nil, nil, nil
local offUI = {}           -- 0.1.19 offset / rotation / favorites controls
local pageLbl, pageField, pageOf, pageShown = nil, nil, nil, nil
local favList = {}
local SIZE_LBL_W, SIZE_TXT_W = 36, 44
local onBtn, setBtn, itemBtn, statusText, selText = nil, nil, nil, nil, nil
local preview = nil
local prevB, pageText, nextB = nil, nil, nil
local pagerY, previewY = 0, 0
local settingsUI = nil
local refresh

local function tw(plain) return helpers.textWidthOf(H.FONT, plain) or (#plain * 7) end
local function commas(n)
    local s2 = tostring(n); local k
    repeat s2, k = string.gsub(s2, "^(%d+)(%d%d%d)", "%1,%2") until k == 0
    return s2
end
local function cur() return lists[state.set] or lists.sprite end
local function rebuildFilterRaw()
    filtered = {}
    local q = norm(helpers.cleanText(filterText, 64))
    for i, e in ipairs(cur().items) do
        local ok = q == "" or tostring(e.id) == q or string.find(e.lower, q, 1, true)
        if ok and letterIdx > 1 then
            local f = string.upper(string.sub(e.name or "", 1, 1))
            if LETTERS[letterIdx] == "0-9" then ok = not f:match("%a") else ok = f == LETTERS[letterIdx] end
        end
        if ok then filtered[#filtered + 1] = i end
    end
end
local function rebuildFilter()
    if not pcall(rebuildFilterRaw) then filtered = {} end
end
local function favKey(kind, id) return tostring(kind) .. ":" .. tostring(id) end
local function rebuildFavs()
    favList = {}
    for k, f in pairs(state.favs) do
        if type(f) == "table" and f.id ~= nil then favList[#favList + 1] = f else state.favs[k] = nil end
    end
    table.sort(favList, function(a, b) return (a.t or 0) > (b.t or 0) end)
end
rebuildFavs()
local function listCount() if state.recentMode then return #state.recent end return state.favMode and #favList or #filtered end
local function pages() return math.max(1, math.ceil(listCount() / ROWS)) end
-- 0.1.22: rows shown on this page, minimum 5, so the list has no empty tail
local MIN_ROWS, lastVis = 5, nil
local function visRows()
    local n = listCount() - (page - 1) * ROWS
    return math.max(MIN_ROWS, math.min(ROWS, n))
end
local function onLabel() return state.on and "Cursor: On" or "Cursor: Off" end
local function setLabel() return "Set: " .. SET_LABEL[state.set] end
local function isSel(e) local s = state.sel; return s ~= nil and s.kind == state.set and s.id == e.id end

local function selDesc()
    local s = state.sel
    if s == nil then return H.lbl("Nothing selected") end
    return H.lbl(SET_LABEL[s.kind] .. " " .. s.id .. ": ") .. H.gold(nice(s.name or "?"))
end

local showVals = function() end
local function choose(e, kind)
    state.sel = { kind = kind, id = e.id, spr = e.spr, hx = e.hx, hy = e.hy, name = e.name }
    -- 0.1.23: Recent list, newest first, 8 entries, no duplicates
    for i = #state.recent, 1, -1 do local r = state.recent[i]; if r.kind == kind and r.id == e.id then table.remove(state.recent, i) end end
    table.insert(state.recent, 1, { kind = kind, id = e.id, spr = e.spr, hx = e.hx, hy = e.hy, name = e.name })
    while #state.recent > 8 do table.remove(state.recent) end
    -- 0.1.19: a favorite restores its saved offset, size and rotation
    local f = state.favs[favKey(kind, e.id)]
    if f then
        state.offX = clampNum(f.offX, OFF_MIN, OFF_MAX, 0); state.offY = clampNum(f.offY, OFF_MIN, OFF_MAX, 0)
        state.scale = clampScale(f.scale); state.rot = clampNum(f.rot, 0, 359, 0)
        pcall(showVals)
    end
    save()
    pcall(tickOverlay)   -- show the new image now, in front
end

-- 0.1.19: Prev  Page [N] of M  Next, centred; N is a typed box.
local PAGE_LBL_W, PAGE_BOX_W = 36, 48
-- 0.1.23 standard pager: -100 -10 Prev Page [N] of M Next +10 +100
local function placePager(textW)
    if prevB == nil then return end
    local w = math.floor(textW or 0) + 2
    local core = 40 + CTRL_GAP + PAGE_LBL_W + PAGE_BOX_W + 6 + w + CTRL_GAP + 40
    local avail = PANEL_W - 2 * COL_PAD
    pcall(function() avail = window.width - 2 * COL_PAD end)
    local show = {}
    local total = core
    for _, pair in ipairs({ { 2, 3 }, { 1, 4 } }) do   -- inner jumps first
        local add = jumpBtns[pair[1]].w + jumpBtns[pair[2]].w + 8
        if total + add <= avail then show[pair[1]], show[pair[2]] = true, true; total = total + add end
    end
    local x = -(total // 2)
    local ty = pagerY + (H.BTN_H - H.ROW_HEIGHT) // 2
    for i = 1, 4 do helpers.safe(function() jumpBtns[i].btn.hidden = not show[i] end) end
    for i = 1, 2 do if show[i] then helpers.safe(function() jumpBtns[i].btn:SetPos(x, pagerY, 0.5, 0.0) end); x = x + jumpBtns[i].w + 4 end end
    helpers.safe(function() prevB:SetPos(x, pagerY, 0.5, 0.0) end); x = x + 40 + CTRL_GAP
    helpers.safe(function() pageLbl:SetPos(x, ty, 0.5, 0.0) end); x = x + PAGE_LBL_W
    helpers.safe(function() pageField:SetPos(x, pagerY, 0.5, 0.0) end); x = x + PAGE_BOX_W + 6
    helpers.safe(function() pageOf:SetSize(w, H.ROW_HEIGHT); pageOf:SetPos(x, ty, 0.5, 0.0) end); x = x + w + CTRL_GAP
    helpers.safe(function() nextB:SetPos(x, pagerY, 0.5, 0.0) end); x = x + 40 + 4
    for i = 3, 4 do if show[i] then helpers.safe(function() jumpBtns[i].btn:SetPos(x, pagerY, 0.5, 0.0) end); x = x + jumpBtns[i].w + 4 end end
end

local function bindRows()
    local L = cur()
    local fav = state.favMode
    for r = 1, ROWS do
        local c = rowCells[r]
        local e, kind
        if state.recentMode then
            e = state.recent[(page - 1) * ROWS + r]; kind = e and e.kind
        elseif fav then
            e = favList[(page - 1) * ROWS + r]; kind = e and e.kind
        else
            local idx = filtered[(page - 1) * ROWS + r]
            e = idx and L.items[idx]; kind = state.set
        end
        c.e, c.kind = e, kind
        helpers.setHidden({ c.name, c.idt }, e == nil)
        helpers.setHidden({ c.off, c.rm }, e == nil or not fav)
        helpers.safe(function() rowBgs[r].hidden = e == nil end)
        if e == nil then pairHide(c.icon); helpers.safe(function() c.tile.hidden = true end)
        else
            local s = state.sel
            local on = s ~= nil and s.kind == kind and s.id == e.id
            helpers.setText(c.name, on and H.gold(nice(e.name)) or H.val(nice(e.name)))
            helpers.setText(c.idt, H.lbl(tostring(e.id)))
            if fav then helpers.setText(c.off, H.lbl(e.offX .. "," .. e.offY .. "  " .. e.scale .. "%  " .. e.rot .. "d")) end
            pairShow(c.icon, { kind = kind, id = e.id, spr = e.spr }, COL_PAD + (ICON_W - ICON) // 2, c.y + (RH - ICON) // 2, ICON, 1)
            helpers.safe(function() c.tile.hidden = false end)
        end
    end
    local n = listCount()
    local first = n == 0 and 0 or (page - 1) * ROWS + 1
    local st
    if state.recentMode then st = n == 0 and "Nothing picked yet: click a row to use it" or (commas(n) .. " recent (newest first)")
    elseif fav then st = n == 0 and "No favorites yet: nudge a sprite or press Save position" or (commas(first) .. "-" .. commas(math.min(n, page * ROWS)) .. " of " .. commas(n) .. " favorites")
    elseif L.next ~= nil then st = "Reading " .. string.lower(SET_LABEL[state.set]) .. "... " .. commas(#L.items)
    elseif #L.items == 0 then st = "No " .. string.lower(SET_LABEL[state.set]) .. " available"
    else st = commas(first) .. "-" .. commas(math.min(n, page * ROWS)) .. " of " .. commas(n) .. " " .. string.lower(SET_LABEL[state.set]) end
    helpers.setText(statusText, H.lbl(st))
    helpers.setText(selText, selDesc())
    pairShow(preview, state.sel, -(COL_PAD + 4 + 32), previewY + 4, 32, 1, { 1.0, 0.0 })
    local pt = "of " .. commas(pages())
    helpers.setText(pageOf, H.lbl(pt))
    if pageShown ~= page then pageShown = page; helpers.safe(function() pageField.content = tostring(page) end) end
    placePager(tw(pt))
end

local function goPage(p)
    page = math.max(1, math.min(pages(), p)); bindRows()
    if visRows() ~= lastVis and refresh then refresh() end   -- list height follows the rows
end

local function layout()
    local y = H.PAD + helpers.TITLE_HEIGHT + 4
    -- 0.1.23 line 1: Cursor on/off, On-point/Offset, Favorites, Recent
    local sx = COL_PAD
    for _, c in ipairs({ { onBtn, 84 }, { posBtn, 84 }, { offUI.favB, 104 }, { offUI.recB, 84 } }) do
        helpers.safe(function() c[1]:SetPos(sx, y) end); sx = sx + c[2] + 4
    end
    y = y + H.BTN_H + CTRL_GAP
    local ty = (H.BTN_H - H.ROW_HEIGHT) // 2
    -- every value: Label [-] [48px box] [+] on one column grid
    local LW = 56
    local function group(gx, gy, g)
        helpers.safe(function() g.lbl:SetPos(gx, gy + ty) end); gx = gx + LW + 4
        helpers.safe(function() g.minus:SetPos(gx, gy) end); gx = gx + H.STEP_BTN_W + 2
        helpers.safe(function() g.box:SetPos(gx, gy) end); gx = gx + H.STEP_FIELD_W + 2
        helpers.safe(function() g.plus:SetPos(gx, gy) end)
        return gx + H.STEP_BTN_W
    end
    local COL2 = COL_PAD + LW + 4 + H.STEP_BTN_W * 2 + H.STEP_FIELD_W + 4 + 16
    -- Look: Set, Size, Rotation (framed preview at the right)
    helpers.safe(function() offUI.lookH:SetPos(COL_PAD, y) end)
    previewY = y + 2
    helpers.safe(function() offUI.frame:SetPos(-(COL_PAD + 40), previewY, 1.0, 0.0) end)
    helpers.safe(function() offUI.prevLbl:SetPos(-(COL_PAD + 40 + 4), previewY + 42, 1.0, 0.0) end)
    y = y + H.ROW_HEIGHT
    helpers.safe(function() setBtn:SetPos(COL_PAD, y) end)
    y = y + H.BTN_H + 4
    group(COL_PAD, y, offUI.size)
    group(COL2, y, offUI.rot)
    y = y + H.BTN_H + CTRL_GAP
    -- Position: Offset X / Y, D-pad, Step, Reset, Save position, presets
    helpers.safe(function() offUI.posH:SetPos(COL_PAD, y) end)
    y = y + H.ROW_HEIGHT
    group(COL_PAD, y, offUI.x)
    group(COL2, y, offUI.y)
    y = y + H.BTN_H + 4
    local DW = 44
    local d = offUI.dpad
    helpers.safe(function() d.up:SetPos(COL_PAD + DW + 2, y) end)
    helpers.safe(function() d.left:SetPos(COL_PAD, y + H.BTN_H + 2) end)
    helpers.safe(function() d.right:SetPos(COL_PAD + 2 * (DW + 2), y + H.BTN_H + 2) end)
    helpers.safe(function() d.down:SetPos(COL_PAD + DW + 2, y + 2 * (H.BTN_H + 2)) end)
    local rx = COL_PAD + 3 * (DW + 2) + 12
    sx = rx
    for _, c in ipairs({ { offUI.stepB, 74 }, { offUI.resetB, 48 }, { offUI.saveB, 96 } }) do
        helpers.safe(function() c[1]:SetPos(sx, y) end); sx = sx + c[2] + 4
    end
    sx = rx
    for _, c in ipairs({ { offUI.preB, 84 }, { offUI.loadB, 44 }, { offUI.storeB, 48 } }) do
        helpers.safe(function() c[1]:SetPos(sx, y + 2 * (H.BTN_H + 2)) end); sx = sx + c[2] + 4
    end
    y = y + 3 * (H.BTN_H + 2) + CTRL_GAP
    -- line 2: merged search / item ID box, Use item, Keypad
    helpers.safe(function() searchField:SetPos(COL_PAD, y) end)
    helpers.safe(function() itemBtn:SetPos(-(COL_PAD + 56 + CTRL_GAP + 64), y, 1.0, 0.0) end)
    helpers.safe(function() padBtn:SetPos(-(COL_PAD + 56), y, 1.0, 0.0) end)
    y = y + H.BTN_H + 4
    for i, k in ipairs(padKeys) do
        helpers.safe(function()
            k.hidden = not padOpen
            if i <= 10 then k:SetPos(COL_PAD + (i - 1) * 30, y) else k:SetPos(COL_PAD + 10 * 30 + 4 + (i - 11) * 48, y) end
        end)
    end
    if padOpen then y = y + H.BTN_H + 4 end
    helpers.safe(function() selText:SetPos(COL_PAD, y) end)
    y = y + H.ROW_HEIGHT + 4
    -- status line, Letter filter at its right
    helpers.safe(function() statusText:SetPos(COL_PAD, y + ty) end)
    helpers.safe(function() letterBtn:SetPos(-(COL_PAD + 100), y, 1.0, 0.0) end)
    y = y + H.BTN_H + 4
    helpers.safe(function() headCells.icon:SetPos(COL_PAD, y) end)
    helpers.safe(function() headCells.idt:SetPos(ID_X, y); headCells.idt:SetSize(ID_W, H.ROW_HEIGHT) end)
    if idHandle then idHandle:place(NAME_X - COL_GAP // 2, y, H.ROW_HEIGHT) end
    helpers.safe(function() headCells.name:SetPos(NAME_X, y) end)
    local fav = state.favMode
    helpers.setText(headCells.name, H.gold(state.recentMode and "Recent" or (fav and "Favorite" or "Name")))
    helpers.setHidden({ headCells.saved }, not fav)
    helpers.safe(function() headCells.saved:SetPos(-(COL_PAD + 60 + 150), y, 1.0, 0.0) end)
    local nameW = fav and -(NAME_X + COL_PAD + 60 + 150 + 4) or -(NAME_X + COL_PAD)
    y = y + H.ROW_HEIGHT
    helpers.safe(function() headDiv:SetPos(COL_PAD, y) end)
    y = y + 2
    local vis = visRows()
    lastVis = vis
    helpers.safe(function() listBg:SetPos(4, y); listBg:SetSize(-8, vis * RH, 1.0, 0.0) end)
    for r = 1, ROWS do
        local c = rowCells[r]; c.y = y
        helpers.safe(function()
            local k = BG[(r % 2) + 1]
            rowBgs[r].colour = Vector4.new(k[1], k[2], k[3], 0.92); rowBgs[r]:SetPos(4, y)
        end)
        helpers.safe(function() c.tile:SetPos(COL_PAD + (ICON_W - 26) // 2, y + (RH - 26) // 2) end)
        helpers.safe(function() c.idt:SetPos(ID_X, y + (RH - H.ROW_HEIGHT) // 2); c.idt:SetSize(ID_W, H.ROW_HEIGHT) end)
        helpers.safe(function() c.name:SetPos(NAME_X, y + (RH - H.ROW_HEIGHT) // 2); c.name:SetSize(nameW, H.ROW_HEIGHT, 1.0, 0.0) end)
        helpers.safe(function() c.off:SetPos(-(COL_PAD + 60 + 150), y + (RH - H.ROW_HEIGHT) // 2, 1.0, 0.0) end)
        helpers.safe(function() c.rm:SetPos(-(COL_PAD + 58), y + (RH - H.BTN_H) // 2, 1.0, 0.0) end)
        if r <= vis then y = y + RH end
    end
    y = y + CTRL_GAP
    pagerY = y
    bindRows()
    y = y + H.BTN_H + CTRL_GAP
    if settingsUI ~= nil then
        settingsUI.open = state.editOpen == true
        y = settingsUI:place(y)
    end
    helpers.fitHeight(y + H.FOOTER_PAD)
end

refresh = function() bindRows(); layout(); helpers.refit(); raiseOverlay() end

local function newText(root, w)
    local t = nil
    pcall(function()
        t = ui.Text.new(root)
        t:SetSize(w, H.ROW_HEIGHT, w < 0 and 1.0 or 0.0, 0.0)
        t.font = H.FONT
        t.content = ""
        t:AlignTo(ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        helpers.shadow(t)
    end)
    return t
end

local function setItemFromBox()
    local t = ""
    pcall(function() t = tostring(itemField.content or "") end)
    local n = helpers.cleanInt(t, 0, 999999)
    if n == nil then helpers.showToast("Type a whole item ID", 3); return end
    local nm = nil
    pcall(function() local o = config.Obj.FromID(n); if o ~= nil then nm = o.name end end)
    if nm == nil then helpers.showToast("No item with ID " .. n, 3); return end
    choose({ id = n, name = nm }, "item")
    bindRows()
end

local function buildPanel(root)
    -- 0.1.24: option pickers are RuneScape-style dropdowns (helpers.dropdown)
    posBtn = helpers.dropdown(root, 0, 0, 84, H.BTN_H, { options = POS_LABEL, name = "pos",
        get = function() return state.pos end, set = function(i) state.pos = i; save() end,
        onChange = function() refresh() end })
    onBtn = helpers.button(root, 0, 0, 84, H.BTN_H, onLabel(), function()
        state.on = not state.on; save(); helpers.setText(onBtn, onLabel(), "label"); refresh()
    end)
    do local L = {}; for i, v in ipairs(SETS) do L[i] = "Set: " .. SET_LABEL[v] end
    setBtn = helpers.dropdown(root, 0, 0, 110, H.BTN_H, { options = L, name = "set",
        get = function() for k, v in ipairs(SETS) do if v == state.set then return k end end; return 1 end,
        set = function(i) state.set = SETS[i]; save() end,
        onChange = function()
            -- 0.1.22: a search typed for one set no longer empties the next one
            filterText, lastFilterSeen = "", ""
            helpers.safe(function() searchField.content = "" end)
            rebuildFilter(); goPage(1); refresh()
        end }) end
    -- 0.1.19: Size, Rotation, Offset X and Offset Y are typed boxes (numbers
    -- only, clamped, applied on Enter or when the box loses focus) with
    -- - and + buttons. Offset changes (arrows, boxes, +/-) also save the
    -- sprite to Favorites with its offset, size and rotation.
    local function signedInt(t)
        t = helpers.cleanText(t, 12)
        local neg = t:find("^%s*%-") ~= nil
        local n = helpers.cleanInt(t, 0, 99999)
        if n == nil then return nil end
        return neg and -n or n
    end
    local function saveFav()
        local sel = state.sel
        if sel == nil then helpers.showToast("Pick a sprite first", 3); return end
        local k = favKey(sel.kind, sel.id)
        state.favs[k] = { kind = sel.kind, id = sel.id, spr = sel.spr, hx = sel.hx, hy = sel.hy, name = sel.name,
            offX = state.offX, offY = state.offY, scale = state.scale, rot = state.rot, t = (state.favSeq or 0) + 1 }
        state.favSeq = (state.favSeq or 0) + 1
        rebuildFavs(); save()
    end
    local function boxSet(box, v) helpers.safe(function() if box.content ~= tostring(v) then box.content = tostring(v) end end) end
    showVals = function()
        boxSet(offUI.size.box, state.scale); boxSet(offUI.rot.box, state.rot)
        boxSet(offUI.x.box, state.offX); boxSet(offUI.y.box, state.offY)
        offUI.stepB:refresh()
        helpers.setText(offUI.favB, state.favMode and "All sprites" or ("Favorites (" .. #favList .. ")"), "label")
        if offUI.recB then helpers.setText(offUI.recB, state.recentMode and "All sprites" or ("Recent (" .. #state.recent .. ")"), "label") end
        if offUI.preB then offUI.preB:refresh() end
    end
    local function apply(field, v, isOffset)
        if field == "scale" then state.scale = clampScale(v)
        elseif field == "rot" then state.rot = ((math.floor(tonumber(v) or 0)) % 360 + 360) % 360
        else state[field] = clampNum(v, OFF_MIN, OFF_MAX, 0) end
        save()
        if isOffset then saveFav() end
        editTicks = 150   -- 0.1.23: crosshair on the hotspot for 3 s
        showVals(); pcall(tickOverlay); bindRows()
    end
    local tips = nil
    local function group(label, lw, bw, field, isOffset, stepFn)
        local g = { lw = lw, bw = bw }
        g.lbl = newText(root, lw); helpers.setText(g.lbl, H.lbl(label))
        g.minus = helpers.button(root, 0, 0, H.STEP_BTN_W, H.BTN_H, "-", function() apply(field, state[field] - stepFn(), isOffset) end)
        g.box = helpers.input(root, 0, 0, H.STEP_FIELD_W, H.BTN_H, "0")
        g.plus = helpers.button(root, 0, 0, H.STEP_BTN_W, H.BTN_H, "+", function() apply(field, state[field] + stepFn(), isOffset) end)
        if tips and tips[field] then for _, c in ipairs({ g.lbl, g.minus, g.box, g.plus }) do helpers.setTip(c, tips[field]) end end
        numBoxes[#numBoxes + 1] = g.box
        pcall(function()
            g.box:Subscribe(ui.Hook.ONCONTENTCHANGED, "cs_" .. field, function(_, cause)
                if cause == ui.InputFieldActionResult.SUBMIT or cause == ui.InputFieldActionResult.SUBMIT_ON_FOCUS_LOSS then
                    local t = ""
                    pcall(function() t = tostring(g.box.content or "") end)
                    local n = signedInt(t)
                    if n == nil then showVals(); return end
                    if field ~= "rot" or n ~= state.rot then apply(field, n, isOffset and n ~= state[field]) end
                end
            end)
        end)
        return g
    end
    local function step() return STEPS[state.step] end
    tips = {
        scale = "Image size as a percent of 32 px (50-400). Type a value or use - / + (25% steps).",
        rot = "Rotation in degrees (0-359). Type a value or use - / + (Step size).",
        offX = "Horizontal shift of the image from the pointer tip, in interface units at 100% size (- left, + right). Saved to Favorites.",
        offY = "Vertical shift of the image from the pointer tip (- up, + down). Saved to Favorites.",
    }
    offUI.lookH = newText(root, 120); helpers.setText(offUI.lookH, H.lbl("Look"))
    offUI.posH = newText(root, 120); helpers.setText(offUI.posH, H.lbl("Position"))
    pcall(function()
        offUI.frame = ui.Rectangle.new(root); offUI.frame.fill = true
        offUI.frame:SetSize(40, 40); offUI.frame.colour = Vector4.new(0x1C/255, 0x1A/255, 0x17/255, 0.95)
        local e = ui.Rectangle.new(offUI.frame); e.fill = false
        e:SetPos(0, 0); e:SetSize(0, 0, 1.0, 1.0); e.colour = Vector4.new(120/255, 104/255, 58/255, 1.0)
    end)
    offUI.prevLbl = newText(root, 48); helpers.setText(offUI.prevLbl, H.lbl("Preview"))
    pcall(function() offUI.prevLbl:AlignTo(ui.AlignMode.CENTRE, ui.AlignMode.CENTRE) end)
    offUI.size = group("Size %", 44, 48, "scale", false, function() return SCALE_STEP end)
    offUI.rot = group("Rotation", 56, 44, "rot", false, step)
    offUI.x = group("Offset X", 56, 48, "offX", true, step)
    offUI.y = group("Offset Y", 56, 48, "offY", true, step)
    sizeLbl, sizeMinus, sizeField, sizePlus = offUI.size.lbl, offUI.size.minus, offUI.size.box, offUI.size.plus
    local function nudge(dx, dy) apply("offX", state.offX + dx * step(), true); apply("offY", state.offY + dy * step(), false) end
    local function rb(label, w, fn) local b = helpers.button(root, 0, 0, w, H.BTN_H, label, fn); offUI.row[#offUI.row + 1] = { c = b, w = w }; return b end
    offUI.row = {}
    -- 0.1.23: plus-shaped D-pad
    offUI.dpad = {
        up = rb("Up", 44, function() nudge(0, -1) end),
        left = rb("Left", 44, function() nudge(-1, 0) end),
        right = rb("Right", 44, function() nudge(1, 0) end),
        down = rb("Down", 44, function() nudge(0, 1) end),
    }
    for _, b in pairs(offUI.dpad) do helpers.setTip(b, function() return "Move the image " .. STEPS[state.step] .. " unit(s). The red crosshair marks the pointer tip for 3 s." end) end
    local function rdd(w, L, get, set, name)
        local d = helpers.dropdown(root, 0, 0, w, H.BTN_H, { options = L, name = name, get = get, set = set, onChange = function() showVals() end })
        offUI.row[#offUI.row + 1] = { c = d, w = w }; return d
    end
    do local L = {}; for i, v in ipairs(STEPS) do L[i] = "Step: " .. v end
    offUI.stepB = rdd(74, L, function() return state.step end, function(i) state.step = i; save() end, "step") end
    helpers.setTip(offUI.stepB.box, "How far one D-pad, - or + click moves or rotates (1, 5, 10, 15, 90).")
    offUI.resetB = rb("Reset", 48, function() state.offX, state.offY = 0, 0; save(); showVals(); editTicks = 150; pcall(tickOverlay) end)
    helpers.setTip(offUI.resetB, "Offset back to 0, 0 (image top-left on the pointer tip).")
    offUI.saveB = rb("Save position", 96, function() saveFav(); showVals(); bindRows(); helpers.showToast("Saved to Favorites", 2) end)
    helpers.setTip(offUI.saveB, "Save this image with its offset, size and rotation to Favorites.")
    offUI.favB = rb("Favorites (0)", 104, function()
        state.favMode = not state.favMode; state.recentMode = false; save(); rebuildFavs(); showVals(); goPage(1); refresh()
    end)
    offUI.recB = rb("Recent (0)", 84, function()
        state.recentMode = not state.recentMode; state.favMode = false; save(); showVals(); goPage(1); refresh()
    end)
    helpers.setTip(offUI.recB, "The last 8 images you picked, newest first.")
    -- 0.1.23 presets: 4 slots of size, rotation and offset
    local function preDesc(i)
        local p = state.presets[i]
        if type(p) ~= "table" then return "Preset " .. i .. ": empty" end
        return "Preset " .. i .. ": " .. p.scale .. "%, " .. p.rot .. " deg, offset " .. p.offX .. "," .. p.offY
    end
    offUI.preB = rdd(84, { "Preset 1", "Preset 2", "Preset 3", "Preset 4" }, function() return state.preset end, function(i) state.preset = i; save() end, "preset")
    helpers.setTip(offUI.preB.box, function() return preDesc(state.preset) .. ". Pick a slot." end)
    offUI.loadB = rb("Load", 44, function()
        local p = state.presets[state.preset]
        if type(p) ~= "table" then helpers.showToast("Preset " .. state.preset .. " is empty: press Store first", 3); return end
        state.scale = clampScale(p.scale); state.rot = clampNum(p.rot, 0, 359, 0)
        state.offX = clampNum(p.offX, OFF_MIN, OFF_MAX, 0); state.offY = clampNum(p.offY, OFF_MIN, OFF_MAX, 0)
        save(); showVals(); editTicks = 150; pcall(tickOverlay)
    end)
    helpers.setTip(offUI.loadB, function() return "Apply " .. preDesc(state.preset) end)
    offUI.storeB = rb("Store", 48, function()
        state.presets[state.preset] = { scale = state.scale, rot = state.rot, offX = state.offX, offY = state.offY }
        save(); showVals(); helpers.showToast("Stored as " .. preDesc(state.preset), 3)
    end)
    helpers.setTip(offUI.storeB, function() return "Store the current size, rotation and offset in Preset " .. state.preset .. " (replaces it)." end)
    showVals()
    -- 0.1.22: one merged "Search name or id" box. It filters the list as
    -- you type; Use item / Enter / the keypad treat it as an item ID.
    searchField = helpers.input(root, 0, 0, 200, H.BTN_H, "Search name or id")
    itemField = searchField
    itemBtn = helpers.button(root, 0, 0, 64, H.BTN_H, "Use item", setItemFromBox)
    local function padShow()
        helpers.safe(function() itemField.content = padStr end)
    end
    padBtn = helpers.button(root, 0, 0, 56, H.BTN_H, "Keypad", function()
        padOpen = not padOpen
        if padOpen then pcall(function() padStr = tostring(itemField.content or ""):gsub("%D", "") end) end
        refresh()
    end)
    for d = 0, 9 do
        local k = helpers.button(root, 0, 0, 26, H.BTN_H, tostring(d), function()
            if #padStr < 6 then padStr = padStr .. d; padShow() end
        end)
        k.hidden = true
        padKeys[#padKeys + 1] = k
    end
    local del = helpers.button(root, 0, 0, 44, H.BTN_H, "Del", function()
        padStr = string.sub(padStr, 1, -2); padShow()
    end)
    local clr = helpers.button(root, 0, 0, 44, H.BTN_H, "Clear", function() padStr = ""; padShow() end)
    local use = helpers.button(root, 0, 0, 44, H.BTN_H, "Use", function() padShow(); setItemFromBox() end)
    for _, k in ipairs({ del, clr, use }) do k.hidden = true; padKeys[#padKeys + 1] = k end
    letterBtn = helpers.dropdown(root, 0, 0, 100, H.BTN_H, { name = "letter",
        options = function() local L = {}; for i, l in ipairs(LETTERS) do L[i] = "Letter: " .. l end; return L end,
        get = function() return letterIdx end, set = function(i) letterIdx = i end,
        onChange = function() rebuildFilter(); goPage(1) end })
    -- 0.1.23: page jumps in the standard pager (was ID jumps)
    for _, n in ipairs({ -100, -10, 10, 100 }) do
        local lbl = (n > 0 and "+" or "") .. n
        local w = #lbl * 8 + 12
        local b = helpers.button(root, 0, 0, w, H.BTN_H, lbl, function() goPage(page + n) end)
        helpers.setTip(b, (n > 0 and "Forward " or "Back ") .. math.abs(n) .. " pages")
        jumpBtns[#jumpBtns + 1] = { w = w, btn = b }
    end
    selText = newText(root, -(2 * COL_PAD + 40))
    helpers.track(selText, "content", 2)
    pcall(function() searchField:SetSize(-(2 * COL_PAD + 64 + 56 + 2 * CTRL_GAP), H.BTN_H, 1.0, 0.0) end)
    -- 0.1.2: refilter as soon as the text changes (the tick poll stays as a fallback).
    pcall(function()
        searchField:Subscribe(ui.Hook.ONCONTENTCHANGED, "csSearch", function(_, _, newContent)
            local t = tostring(newContent or "")
            if t ~= lastFilterSeen then lastFilterSeen = t; filterText = t; rebuildFilter(); goPage(1) end
        end)
    end)
    -- Enter in the item ID box uses the item.
    pcall(function()
        itemField:Subscribe(ui.Hook.ONCONTENTCHANGED, "csItem", function(_, cause)
            if cause == ui.InputFieldActionResult.SUBMIT then
                local t = ""
                pcall(function() t = tostring(itemField.content or "") end)
                if t:match("^%s*%d+%s*$") and state.set == "item" then setItemFromBox() end
            end
        end)
    end)
    statusText = newText(root, -2 * COL_PAD)
    helpers.track(statusText, "content", 2)
    pcall(function()
        listBg = ui.Rectangle.new(root); listBg.fill = true
        listBg.colour = Vector4.new(0x1C/255, 0x1A/255, 0x17/255, 0.94)
    end)
    for r = 1, ROWS do
        pcall(function()
            local bg = ui.Rectangle.new(root); bg.fill = true
            bg:SetSize(-8, RH, 1.0, 0.0); bg.hidden = true
            rowBgs[r] = bg
        end)
    end
    cols = helpers.columns("sprites", { id = { w = 52, min = 36, max = 160 } }, function() recalcCols(); pcall(layout) end)
    recalcCols()
    headCells = { icon = newText(root, ICON_W + 8), idt = newText(root, ID_W), name = newText(root, -(NAME_X + COL_PAD)) }
    helpers.setText(headCells.icon, H.gold("Icon"))
    helpers.setText(headCells.idt, H.gold("ID"))
    idHandle = cols:handle(root, "id", 1)
    helpers.setText(headCells.name, H.gold("Name"))
    headCells.saved = newText(root, 150)
    helpers.setText(headCells.saved, H.gold("Offset  Size  Rot"))
    headCells.saved.hidden = true
    pcall(function()
        headDiv = ui.Rectangle.new(root); headDiv.fill = true
        headDiv:SetSize(-2 * COL_PAD, 1, 1.0, 0.0)
        headDiv.colour = Vector4.new(0.78, 0.70, 0.52, 0.9)
    end)
    for r = 1, ROWS do
        local c = { y = 0 }
        pcall(function()
            c.tile = ui.Rectangle.new(root); c.tile.fill = true
            c.tile:SetSize(26, 26); c.tile.hidden = true
            c.tile.colour = Vector4.new(0x3A/255, 0x33/255, 0x2B/255, 1.0)
            pcall(function() c.tile.clickthrough = true end)
        end)
        c.icon = newPair(root)
        c.idt = newText(root, ID_W)
        c.name = newText(root, -(NAME_X + COL_PAD))
        helpers.track(c.name, "content", 2)
        c.off = newText(root, 150)
        c.rm = helpers.button(root, 0, 0, 56, H.BTN_H, "Remove", function()
            if c.e == nil or not state.favMode then return end
            state.favs[favKey(c.kind, c.e.id)] = nil
            rebuildFavs(); save(); showVals(); goPage(page)
        end)
        helpers.setHidden({ c.off, c.rm }, true)
        for _, t in ipairs({ c.idt, c.name }) do
            helpers.blockClicks(t)
            pcall(function()
                t:Subscribe(ui.Hook.ONCLICK, "pick", function()
                pcall(helpers.raiseWindow)
                    if c.e ~= nil then choose(c.e, c.kind or state.set); bindRows() end
                end)
            end)
        end
        rowCells[r] = c
    end
    preview = newPair(root)
    prevB = helpers.button(root, 0, 0, 40, H.BTN_H, "Prev", function() goPage(page - 1) end)
    pageLbl = newText(root, PAGE_LBL_W); helpers.setText(pageLbl, H.lbl("Page"))
    pageField = helpers.input(root, 0, 0, PAGE_BOX_W, H.BTN_H, "1")
    helpers.setTip(pageField, "Current page. Click, type a page number and press Enter.")
    numBoxes[#numBoxes + 1] = pageField
    pcall(function()
        pageField:Subscribe(ui.Hook.ONCONTENTCHANGED, "csPage", function(_, cause)
            if cause == ui.InputFieldActionResult.SUBMIT or cause == ui.InputFieldActionResult.SUBMIT_ON_FOCUS_LOSS then
                local t = ""
                pcall(function() t = tostring(pageField.content or "") end)
                local n = helpers.cleanInt(helpers.cleanText(t, 8), 1, pages())
                pageShown = nil
                if n then goPage(n) else bindRows() end
            end
        end)
    end)
    pageOf = newText(root, 60)
    nextB = helpers.button(root, 0, 0, 40, H.BTN_H, "Next", function() goPage(page + 1) end)

    local items = helpers.commonItems(function() refresh() end)
    local mine = {
        { label = "Click a row to use it" },
        { label = "Show cursor sprite", options = { "On", "Off" },
          get = function() return state.on and 1 or 2 end,
          set = function(i) state.on = i == 1; save(); helpers.setText(onBtn, onLabel(), "label") end },
        { label = "Position", options = POS_LABEL,
          get = function() return state.pos end,
          set = function(i) state.pos = i; save(); if posBtn then posBtn:refresh() end end },
        { label = "Sprite opacity", options = { "100%", "75%", "50%", "25%" },
          get = function() return state.alpha end, set = function(i) state.alpha = i; save() end },
    }
    for i = #mine, 1, -1 do table.insert(items, 1, mine[i]) end
    settingsUI = helpers.newSettings(root, items, 6)
    settingsUI.onChange = function() refresh() end
    helpers.editToggle(root, function() return state.editOpen == true end, function(v)
        state.editOpen = v; save(); refresh()
    end)
    rebuildFilter()
    refresh()
end

-------------------------------------------------------------------------------
-- Ticks: overlay every Logic tick (50/s); scans and the search box.
-------------------------------------------------------------------------------
local tick = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "csLogic", function()
    helpers.tickToast()
    tick = tick + 1
    local L = cur()
    if L.next ~= nil then
        if scanStep(state.set) then sortL(L); rebuildFilter(); if window then refresh() end
        elseif window and tick % 25 == 0 then rebuildFilter(); bindRows() end
    end
    if window ~= nil and searchField ~= nil and tick % 10 == 0 then
        local t = ""
        pcall(function() t = tostring(searchField.content or "") end)
        if t ~= lastFilterSeen then lastFilterSeen = t; filterText = t; rebuildFilter(); goPage(1) end
    end
    tickOverlay()   -- last, after the panel and hover boxes have been updated/raised
end)

local function tryCreateWindow()
    if window ~= nil then return end
    window = helpers.createWindow(PLUGIN_NAME, PANEL_W, 200, 0.32, 0.18)
    if window ~= nil then
        local ok, err = pcall(buildPanel, window)
        helpers.raiseGrip()
        helpers.diag("lists", { sprites = #lists.sprite.items, cursors = #lists.cursor.items, spriteSource = lists.sprite.source })
        if not ok then helpers.log("[" .. PLUGIN_NAME .. "] ERROR building panel: " .. tostring(err)) end
    end
end
tryCreateWindow()

local retryTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "windowRetry", function()
    if window == nil then
        retryTicks = retryTicks + 1
        if retryTicks >= 50 then retryTicks = 0; tryCreateWindow() end
    end
end)

helpers.afterRaise = raiseOverlay   -- panel click-to-front / drag raise is followed by the image
helpers.installRibbon(PLUGIN_NAME)
helpers.log("[" .. PLUGIN_NAME .. "] loaded")

function PluginShutdown()
    pairHide(overlay)
    save()
    helpers.destroyToast()
    helpers.destroyHover()
    helpers.destroyWindow()
end
