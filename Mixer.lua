-- ============================================================
--  OPENRACKS / MIXER  -  console de mixage tactile
--  Hub audio (bloc) ou module "musique / master" (audio_master)
--
--  Utilisation :   mixer          lance la console
--                  mixer diag     affiche getPorts() et les valeurs lues
--
--  Toucher : fader = volume, ON/OFF = coupe, matrice = routage,
--            panneau de droite = ducking + entree de lecture.
--  (Le texte est en ASCII : les accents s'affichent mal dans CC.)
-- ============================================================

local CFG = {
  hub       = nil,    -- nom du peripherique (nil = detection auto)
  surface   = nil,    -- nom du moniteur (nil = 1er moniteur, sinon le terminal)
  textScale = 0.5,    -- echelle du texte du moniteur
  volMax    = 1.0,    -- valeur de volume = 100 % (ajuste si ton hub va plus haut)
  refresh   = 0.1,    -- secondes entre deux rafraichissements
  graphChannel = nil, -- ex: "master" pour utiliser hub.getGraph au lieu de l'historique local
  names = { inputs = {}, outputs = {}, radios = {} },  -- noms perso : names.inputs[1] = "MIC"
  -- Cible envoyee a setRoute(i, cible, on). A ajuster d'apres `mixer diag` / getPorts().
  target = function(kind, idx)
    if kind == "out" then return idx
    elseif kind == "radio" then return "radio" .. idx
    else return "master" end
  end,
}

local C = colors
local PAL = {
  [C.black]     = 0x0D1017, [C.gray]      = 0x1A1F29, [C.lightGray] = 0x364051,
  [C.white]     = 0xE8EEF6, [C.blue]      = 0x6E8EF5, [C.lime]      = 0x3DD68C,
  [C.yellow]    = 0xF6C445, [C.red]       = 0xF05A64, [C.orange]    = 0xFF9D45,
  [C.purple]    = 0xA879FF, [C.pink]      = 0x8793A8, [C.lightBlue] = 0x9FB6FF,
  [C.cyan]      = 0x3CCFE0, [C.green]     = 0x1F8F5A, [C.brown]     = 0x2B3342,
  [C.magenta]   = 0xF06BB5,
}
local GROUPS = {
  { "ENTREES", C.lime }, { "SORTIES", C.lightBlue },
  { "RADIO", C.orange }, { "MASTER", C.white },
}

-- ---------- utilitaires ----------
local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end
local function try(f, ...)
  if not f then return nil end
  local ok, r = pcall(f, ...)
  if ok then return r end
end
local function center(s, w)
  s = tostring(s):sub(1, w)
  local l = math.floor((w - #s) / 2)
  return string.rep(" ", l) .. s .. string.rep(" ", w - #s - l)
end

-- ---------- recherche du hub ----------
local function findHub()
  if CFG.hub then return peripheral.wrap(CFG.hub), CFG.hub end
  for _, n in ipairs(peripheral.getNames()) do
    local set = {}
    for _, k in ipairs(peripheral.getMethods(n) or {}) do set[k] = true end
    if set.getInputCount and set.setRoute then return peripheral.wrap(n), n end
    if set.find and set.getModules then          -- un rack : on cherche le module master
      local ok, r = pcall(peripheral.wrap(n).find, "audio_master")
      if ok and type(r) == "table" and r[1] then return r[1], n end
    end
  end
end

local hub, hubName = findHub()
if not hub then
  printError("Aucun hub audio / module audio_master trouve.")
  printError("Branche le hub (ou le rack) ou renseigne CFG.hub.")
  return
end

local nIn  = try(hub.getInputCount) or 0
local nOut = try(hub.getOutputCount) or 0
local nRad = try(hub.getRadioCount) or 0
local hasMaster = try(hub.hasMaster) ~= false

local args = { ... }
if args[1] == "diag" then
  print("Hub : " .. tostring(hubName))
  print("Entrees " .. nIn .. " | Sorties " .. nOut .. " | Radios " .. nRad .. " | Master " .. tostring(hasMaster))
  print("getPorts() =")
  textutils.pagedPrint(textutils.serialise(try(hub.getPorts) or {}))
  print("getAutoVolume() =")
  print(textutils.serialise(try(hub.getAutoVolume) or {}))
  print("Volume entree 1 = " .. tostring(try(hub.getInputVolume, 1)))
  return
end

-- ---------- bandes (strips) ----------
local strips, targets = {}, {}

local function buildStrips()
  for i = 1, nIn do
    strips[#strips + 1] = { group = 1, kind = "in", idx = i, routes = {},
      label = CFG.names.inputs[i] or tostring(i),
      read = function() return try(hub.isInputEnabled, i), try(hub.getInputVolume, i), try(hub.getInputLevel, i) end,
      setEn = function(on) try(hub.setInputEnabled, i, on) end,
      setVol = function(v) try(hub.setInputVolume, i, v) end }
  end
  for j = 1, nOut do
    strips[#strips + 1] = { group = 2, kind = "out", idx = j,
      label = CFG.names.outputs[j] or ("A" .. j),
      read = function() return try(hub.isOutputEnabled, j), try(hub.getOutputVolume, j), try(hub.getOutputLevel, j) end,
      setEn = function(on) try(hub.setOutputEnabled, j, on) end,
      setVol = function(v) try(hub.setOutputVolume, j, v) end }
    targets[#targets + 1] = { label = "A" .. j, kind = "out", idx = j, color = C.lightBlue }
  end
  for n = 1, nRad do
    strips[#strips + 1] = { group = 3, kind = "radio", idx = n,
      label = CFG.names.radios[n] or ("T" .. n),
      read = function() return try(hub.isRadioEnabled, n), try(hub.getRadioVolume, n), try(hub.getRadioLevel, n) end,
      setEn = function(on) try(hub.setRadioEnabled, on, n) end,
      setVol = function(v) try(hub.setRadioVolume, v, n) end }
    targets[#targets + 1] = { label = "T" .. n, kind = "radio", idx = n, color = C.orange }
  end
  if hasMaster then
    strips[#strips + 1] = { group = 4, kind = "master", idx = 1, label = "MN",
      read = function() return try(hub.isMasterEnabled), try(hub.getMasterVolume), try(hub.getMasterLevel) end,
      setEn = function(on) try(hub.setMasterEnabled, on) end,
      setVol = function(v) try(hub.setMasterVolume, v) end }
    targets[#targets + 1] = { label = "MN", kind = "master", idx = 1, color = C.white }
  end
end
buildStrips()
if #strips == 0 then printError("Le hub ne rapporte aucune entree/sortie.") return end

local masterStrip
for _, s in ipairs(strips) do if s.kind == "master" then masterStrip = s end end

-- ---------- etat ----------
local D = { on = false, level = 0.30, fadeDown = 0.4, fadeUp = 1.5 }
do
  local t = try(hub.getAutoVolume)
  if type(t) == "table" then
    D.on       = (t.on or t.enabled) and true or false
    D.level    = tonumber(t.level) or D.level
    D.fadeDown = tonumber(t.fadeDown) or D.fadeDown
    D.fadeUp   = tonumber(t.fadeUp) or D.fadeUp
  end
end
local function applyDuck() try(hub.setAutoVolume, D.on, D.level, D.fadeDown, D.fadeUp) end
local function adj(key, delta, lo, hi)
  D[key] = clamp(math.floor((D[key] + delta) * 100 + 0.5) / 100, lo, hi)
  applyDuck()
end

local hist, playIn, tick = {}, nil, 0

local function update()
  tick = tick + 1
  for _, s in ipairs(strips) do
    local en, vol, lvl = s.read()
    s.en  = en and true or false
    s.vol = tonumber(vol) or 0
    s.lvl = clamp(tonumber(lvl) or 0, 0, 1)
    if s.kind == "radio" then s.onair = try(hub.isOnAir, s.idx) and true or false end
    if s.kind == "in" and tick % 5 == 1 then
      for t, tg in ipairs(targets) do
        s.routes[t] = try(hub.getRoute, s.idx, CFG.target(tg.kind, tg.idx)) and true or false
      end
    end
  end
  if tick % 5 == 1 then playIn = try(hub.getPlaybackInput) end
  local v = masterStrip and masterStrip.lvl or 0
  hist[#hist + 1] = v
  while #hist > 200 do table.remove(hist, 1) end
end

-- ---------- surface / fenetre ----------
local surface = CFG.surface and peripheral.wrap(CFG.surface) or peripheral.find("monitor") or term.current()
local isTerm = (surface == term.current())
if not isTerm then pcall(surface.setTextScale, CFG.textScale) end

local win, W, H, hits
local cw, gw, X0, px, pw, fy1, fy2, showMatrix, matrixTop = 5, 4, 5, 0, 0, 5, 10, false, 4

local function fill(x, y, w, h, bg)
  if w <= 0 or h <= 0 then return end
  win.setBackgroundColor(bg)
  local s = string.rep(" ", w)
  for r = y, y + h - 1 do win.setCursorPos(x, r) win.write(s) end
end
local function put(x, y, str, fg, bg)
  win.setCursorPos(x, y)
  win.setTextColor(fg or C.white)
  win.setBackgroundColor(bg or C.black)
  win.write(str)
end
local function hit(x, y, w, h, fn) hits[#hits + 1] = { x, y, x + w - 1, y + h - 1, fn } end
local function button(x, y, w, label, fg, bg, fn)
  fill(x, y, w, 1, bg)
  put(x, y, center(label, w), fg, bg)
  hit(x, y, w, 1, fn)
end
local function segBar(x, bottom, r, total, w)
  local g  = math.min(r, math.floor(total * 0.6 + 0.5))
  local y  = math.min(math.max(r - g, 0), math.floor(total * 0.25 + 0.5))
  local rd = r - g - y
  if g  > 0 then fill(x, bottom - g + 1, w, g, C.lime) end
  if y  > 0 then fill(x, bottom - g - y + 1, w, y, C.yellow) end
  if rd > 0 then fill(x, bottom - g - y - rd + 1, w, rd, C.red) end
end

local function layout()
  W, H = surface.getSize()
  win = window.create(surface, 1, 1, W, H, false)
  for c, rgb in pairs(PAL) do pcall(win.setPaletteColor, c, rgb) end
  local seen, ng = {}, 0
  for _, s in ipairs(strips) do if not seen[s.group] then seen[s.group] = true ng = ng + 1 end end
  local gaps, count = ng - 1, #strips
  pw = 0
  if H >= 22 and (W - gw - gaps - 2 - 28) >= count * 5 then pw = 28 end
  local avail = W - gw - gaps - 1 - (pw > 0 and (pw + 1) or 0)
  cw = clamp(math.floor(avail / count), 5, 9)
  X0 = gw + 1
  local x, last = X0, nil
  for _, s in ipairs(strips) do
    if last and s.group ~= last then x = x + 1 end
    s.x, last = x, s.group
    x = x + cw
  end
  if pw > 0 then
    px = x + 1
    pw = math.min(W - px + 1, 46)
    if pw < 26 then pw = 0 end
  end
  local nT = #targets
  local mh = nT + 2
  matrixTop = 4
  showMatrix = nIn > 0 and nT > 0 and H >= mh + 3 + 8 + 4
  fy1 = showMatrix and (matrixTop + mh + 1) or 4
  fy2 = H - 3
end

-- ---------- dessin ----------
local function drawStrip(s)
  local fh = fy2 - fy1 + 1
  local fw = math.max(1, cw - 4)
  local fx = s.x + 1
  local mx = fx + fw + 1

  -- libelle (+ voyant ON AIR pour les radios)
  local lbl = center(s.label, cw)
  if s.kind == "radio" and s.onair then put(s.x, 3, lbl, C.white, C.red)
  else put(s.x, 3, lbl, s.en and C.white or C.pink, C.black) end

  -- fader
  fill(fx, fy1, fw, fh, C.gray)
  fill(mx, fy1, 1, fh, C.gray)
  local f = clamp(s.vol / CFG.volMax, 0, 1)
  local rows = math.floor(f * fh + 0.5)
  if rows > 0 then
    fill(fx, fy2 - rows + 1, fw, rows, s.en and C.blue or C.lightGray)
    fill(fx, fy2 - rows + 1, fw, 1, C.white)
  end
  local lr = math.floor(s.lvl * fh + 0.5)
  if lr > 0 and s.en then segBar(mx, fy2, lr, fh, 1) end
  hit(fx, fy1, fw + 2, fh, function(_, cy)
    local v = clamp((fy2 - cy) / math.max(fh - 1, 1), 0, 1)
    v = math.floor(v * 100 + 0.5) / 100 * CFG.volMax
    s.setVol(v) s.vol = v
  end)

  -- valeur + bouton ON/OFF
  put(s.x, H - 2, center(math.floor(f * 100 + 0.5) .. "%", cw), s.en and C.white or C.pink, C.black)
  button(s.x + 1, H - 1, cw - 2, s.en and "ON" or "OFF",
    s.en and C.black or C.white, s.en and C.lime or C.lightGray,
    function() s.en = not s.en s.setEn(s.en) end)
end

local function drawMatrix()
  local row = matrixTop
  local lastKind
  for t, tg in ipairs(targets) do
    if lastKind and tg.kind ~= lastKind then row = row + 1 end
    lastKind = tg.kind
    put(1, row, tg.label, tg.color, C.black)
    for _, s in ipairs(strips) do
      if s.kind == "in" then
        local on = s.routes[t]
        local cx = s.x + math.floor((cw - 2) / 2)
        fill(cx, row, 2, 1, on and C.lime or C.lightGray)
        local rr = row
        hit(s.x, rr, cw, 1, function()
          local new = not s.routes[t]
          try(hub.setRoute, s.idx, CFG.target(tg.kind, tg.idx), new)
          s.routes[t] = new
        end)
      end
    end
    row = row + 1
  end
end

local function paramRow(y, label, txt, frac, minus, plus)
  put(px, y, label, C.pink, C.black)
  put(px + 7, y, txt, C.white, C.black)
  local bx, bw = px + 14, pw - 14 - 8
  fill(bx, y, bw, 1, C.gray)
  fill(bx, y, math.floor(clamp(frac, 0, 1) * bw + 0.5), 1, C.purple)
  button(px + pw - 7, y, 3, "-", C.white, C.lightGray, minus)
  button(px + pw - 3, y, 3, "+", C.white, C.lightGray, plus)
end

local function drawPanel()
  -- en-tete master
  fill(px, 2, pw, 1, C.purple)
  put(px, 2, center("MASTER / SPECTRE", pw), C.black, C.purple)
  if masterStrip then
    put(px, 3, string.format("NIVEAU %3d%%   VOL %3d%%",
      math.floor(masterStrip.lvl * 100 + 0.5),
      math.floor(clamp(masterStrip.vol / CFG.volMax, 0, 1) * 100 + 0.5)), C.pink, C.black)
  end

  -- spectre (historique du niveau master)
  local dT = H - 7
  local sy1, sy2 = 4, dT - 2
  local sh = sy2 - sy1 + 1
  fill(px, sy1, pw, sh, C.gray)
  local data = hist
  if CFG.graphChannel then
    local g = try(hub.getGraph, CFG.graphChannel, pw)
    if type(g) == "table" and type(g[1]) == "number" then data = g end
  end
  for k = 1, pw do
    local v = data[#data - pw + k]
    if v then
      local r = math.floor(clamp(v, 0, 1) * sh + 0.5)
      if r > 0 then segBar(px + k - 1, sy2, r, sh, 1) end
    end
  end

  -- ducking
  fill(px, dT, pw, 1, C.orange)
  put(px, dT, " DUCKING", C.black, C.orange)
  button(px + pw - 5, dT, 5, D.on and "ON" or "OFF", D.on and C.black or C.white,
    D.on and C.lime or C.lightGray, function() D.on = not D.on applyDuck() end)
  paramRow(dT + 1, "DEPTH", string.format("%.2f", D.level), D.level,
    function() adj("level", -0.05, 0, 1) end, function() adj("level", 0.05, 0, 1) end)
  paramRow(dT + 2, "ATT", string.format("%.1fs", D.fadeDown), D.fadeDown / 5,
    function() adj("fadeDown", -0.1, 0.1, 5) end, function() adj("fadeDown", 0.1, 0.1, 5) end)
  paramRow(dT + 3, "REL", string.format("%.1fs", D.fadeUp), D.fadeUp / 5,
    function() adj("fadeUp", -0.1, 0.1, 5) end, function() adj("fadeUp", 0.1, 0.1, 5) end)

  -- entree de lecture
  put(px, H - 2, "LECTURE", C.pink, C.black)
  put(px + 8, H - 2, tostring(playIn or "-"), C.white, C.black)
  button(px + pw - 7, H - 2, 3, "<", C.white, C.lightGray, function()
    local n = ((tonumber(playIn) or 1) - 2) % math.max(nIn, 1) + 1
    try(hub.setPlaybackInput, n) playIn = n
  end)
  button(px + pw - 3, H - 2, 3, ">", C.white, C.lightGray, function()
    local n = (tonumber(playIn) or 0) % math.max(nIn, 1) + 1
    try(hub.setPlaybackInput, n) playIn = n
  end)
end

local function draw()
  hits = {}
  win.setVisible(false)
  win.setBackgroundColor(C.black)
  win.clear()

  -- barre de titre
  fill(1, 1, W, 1, C.gray)
  put(2, 1, "OPENRACKS", C.lime, C.gray)
  put(12, 1, "/ MIXER", C.pink, C.gray)
  local clock = textutils.formatTime(os.time(), true)
  put(W - #clock, 1, clock, C.white, C.gray)

  -- bandeaux de groupes
  local gx = {}
  for _, s in ipairs(strips) do
    local g = gx[s.group]
    if not g then g = { x1 = s.x } gx[s.group] = g end
    g.x2 = s.x + cw - 1
  end
  for gi, g in pairs(gx) do
    local w = g.x2 - g.x1 + 1
    fill(g.x1, 2, w, 1, GROUPS[gi][2])
    put(g.x1, 2, center(GROUPS[gi][1], w), C.black, GROUPS[gi][2])
  end

  if showMatrix then drawMatrix() end
  for _, s in ipairs(strips) do drawStrip(s) end
  if pw > 0 then drawPanel() end

  if W >= 60 then
    put(2, H, "fader = volume | ON/OFF = coupe | carres = routage", C.brown, C.black)
  end
  win.setVisible(true)
end

local function click(x, y)
  for k = #hits, 1, -1 do
    local h = hits[k]
    if x >= h[1] and x <= h[3] and y >= h[2] and y <= h[4] then
      pcall(h[5], x, y)
      return true
    end
  end
end

-- ---------- boucle principale ----------
local function main()
  layout()
  update() draw()
  local timer = os.startTimer(CFG.refresh)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      update() draw()
      timer = os.startTimer(CFG.refresh)
    elseif ev == "monitor_touch" and not isTerm then
      if click(b, c) then draw() end
    elseif ev == "mouse_click" and isTerm then
      if click(b, c) then draw() end
    elseif ev == "monitor_resize" or ev == "term_resize" then
      layout() draw()
    end
  end
end

local ok, err = pcall(main)
pcall(surface.setBackgroundColor, C.black)
pcall(surface.clear)
pcall(surface.setCursorPos, 1, 1)
if not ok and err ~= "Terminated" then printError(err) end
