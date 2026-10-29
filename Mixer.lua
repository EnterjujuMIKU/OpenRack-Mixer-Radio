-- ============================================================
--  OPENRACKS / MIXER v2
--  Console de mixage tactile + lecteur de liens (YouTube, MP3, webradio)
--
--  mixer                    lance la console
--  mixer diag               infos hub (getPorts, volumes...)
--  mixer diag <url>         teste openAudio/readAudio sur un lien
--
--  Commandes (terminal de l'ordinateur, ou chat avec "!") :
--    add <lien>   play [lien]   stop   next   prev   jump <n>   rm <n>
--    clear   loop   shuffle   list   help
--
--  YouTube / SoundCloud / recherche texte : via un serveur YouCube (websocket).
--  Un lien direct .mp3 ou une webradio passe par l'antenne.
--  Texte en ASCII : les accents s'affichent mal dans CC.
-- ============================================================

local CFG = {
  hub       = nil,     -- nom du peripherique hub (nil = auto)
  antenna   = nil,     -- nom de l'antenne (nil = auto)
  surface   = nil,     -- nom du moniteur (nil = 1er moniteur, sinon terminal)
  textScale = 0.5,
  volMax    = 1.0,     -- valeur de volume = 100 %
  fastPoll  = 0.15,    -- lecture des niveaux (s)
  slowPoll  = 1.5,     -- lecture des volumes / ON / routes (s)
  draw      = 0.1,     -- cadence max de redessin (s)

  -- serveurs YouCube (essayes dans l'ordre). Si tu heberges le tien : "ws://127.0.0.1:5000" en premier.
  -- Tu peux aussi faire : set youcube.server wss://ton-serveur
  youcube   = { "wss://yc.tweaked-programs.cc", "wss://youcube.knijn.one", "wss://youcube.onrender.com" },
  ycTimeout = 60,      -- secondes max d'attente d'une reponse du serveur
  ycHosts   = { "youtu", "soundcloud", "bandcamp" },
  chunk     = 16384,   -- taille demandee a readAudio
  emptyLimit = 200,    -- lectures vides avant de considerer le flux fini
  musicVol  = 1.0,     -- volume passe a playAudio (le mixeur regle le reste)
  maxQueue  = 500,
  chatAdmins = {},     -- {"Pseudo1"} = seuls ces joueurs pilotent par chat ({} = tous)
  stateFile = "/mixer_state.json",
  graphChannel = nil,  -- ex: "master" pour hub.getGraph au lieu de l'historique local
  names = { inputs = {}, outputs = {}, radios = {} },
  -- cible envoyee a setRoute(i, cible, on) : a ajuster d'apres `mixer diag`
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
local floor, max, min = math.floor, math.max, math.min
local function clamp(v, lo, hi) return max(lo, min(hi, v)) end
local function try(f, ...)
  if not f then return nil end
  local ok, r = pcall(f, ...)
  if ok then return r end
end
local function center(s, w)
  s = tostring(s):sub(1, w)
  local l = floor((w - #s) / 2)
  return string.rep(" ", l) .. s .. string.rep(" ", w - #s - l)
end
local ACC = {
  ["\195\169"] = "e", ["\195\168"] = "e", ["\195\170"] = "e", ["\195\171"] = "e",
  ["\195\160"] = "a", ["\195\162"] = "a", ["\195\164"] = "a", ["\195\174"] = "i",
  ["\195\175"] = "i", ["\195\180"] = "o", ["\195\182"] = "o", ["\195\185"] = "u",
  ["\195\187"] = "u", ["\195\188"] = "u", ["\195\167"] = "c", ["\195\177"] = "n",
  ["\195\137"] = "E", ["\195\136"] = "E", ["\195\128"] = "A", ["\195\135"] = "C",
}
local function asc(s)
  s = tostring(s or "")
  for k, v in pairs(ACC) do s = s:gsub(k, v) end
  s = s:gsub("[\194-\244][\128-\191]*", "?")
  s = s:gsub("%c", "")
  return s
end
local function enc(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end
local function fmtTime(sec)
  sec = floor(sec or 0)
  return string.format("%d:%02d", floor(sec / 60), sec % 60)
end
local function describe(v, depth)
  depth = depth or 0
  if type(v) ~= "table" then return type(v) .. ":" .. tostring(v) end
  if depth > 1 then return "{...}" end
  local parts, n = {}, 0
  for k, x in pairs(v) do
    n = n + 1
    if n > 8 then parts[#parts + 1] = "..." break end
    parts[#parts + 1] = tostring(k) .. "=" .. describe(x, depth + 1)
  end
  return "{" .. table.concat(parts, ", ") .. "} (#=" .. #v .. ")"
end

-- ---------- recherche des peripheriques ----------
local function methodSet(n)
  local set = {}
  for _, k in ipairs(peripheral.getMethods(n) or {}) do set[k] = true end
  return set
end
local function findDev(need, rackType, forced)
  if forced then return peripheral.wrap(forced), forced end
  local names = peripheral.getNames()
  for _, n in ipairs(names) do
    if need(methodSet(n)) then return peripheral.wrap(n), n end
  end
  for _, n in ipairs(names) do
    local set = methodSet(n)
    if set.find and set.getModules then
      local ok, r = pcall(peripheral.wrap(n).find, rackType)
      if ok and type(r) == "table" and r[1] then return r[1], n end
    end
  end
end

local hub, hubName = findDev(function(s) return s.getInputCount and s.setRoute end, "audio_master", CFG.hub)
if not hub then
  printError("Aucun hub audio / module audio_master trouve.")
  return
end
local antenna = findDev(function(s) return s.openAudio and s.readAudio end, "antenna", CFG.antenna)
local chatBox = peripheral.find("chat_box")

local nIn  = try(hub.getInputCount) or 0
local nOut = try(hub.getOutputCount) or 0
local nRad = try(hub.getRadioCount) or 0
local hasMaster = try(hub.hasMaster) ~= false

local args = { ... }
if args[1] == "diag" then
  print("Hub : " .. tostring(hubName) .. " | antenne : " .. tostring(antenna ~= nil))
  print("Entrees " .. nIn .. " | Sorties " .. nOut .. " | Radios " .. nRad .. " | Master " .. tostring(hasMaster))
  print("getPorts() = " .. describe(try(hub.getPorts) or {}))
  print("getAutoVolume() = " .. describe(try(hub.getAutoVolume) or {}))
  print("Volume entree 1 = " .. tostring(try(hub.getInputVolume, 1)))
  if not args[2] then return end
end

-- ---------- bandes (strips) ----------
local strips, targets = {}, {}
local function newStrip(t) t.en, t.vol, t.lvl, t.routes = false, 0, 0, {} strips[#strips + 1] = t end

for i = 1, nIn do
  newStrip { group = 1, kind = "in", idx = i, label = CFG.names.inputs[i] or tostring(i),
    rdEn  = function() return try(hub.isInputEnabled, i) end,
    rdVol = function() return try(hub.getInputVolume, i) end,
    rdLvl = function() return try(hub.getInputLevel, i) end,
    setEn = function(on) try(hub.setInputEnabled, i, on) end,
    setVol = function(v) try(hub.setInputVolume, i, v) end }
end
for j = 1, nOut do
  newStrip { group = 2, kind = "out", idx = j, label = CFG.names.outputs[j] or ("A" .. j),
    rdEn  = function() return try(hub.isOutputEnabled, j) end,
    rdVol = function() return try(hub.getOutputVolume, j) end,
    rdLvl = function() return try(hub.getOutputLevel, j) end,
    setEn = function(on) try(hub.setOutputEnabled, j, on) end,
    setVol = function(v) try(hub.setOutputVolume, j, v) end }
  targets[#targets + 1] = { label = "A" .. j, kind = "out", idx = j, color = C.lightBlue }
end
for n = 1, nRad do
  newStrip { group = 3, kind = "radio", idx = n, label = CFG.names.radios[n] or ("T" .. n),
    rdEn  = function() return try(hub.isRadioEnabled, n) end,
    rdVol = function() return try(hub.getRadioVolume, n) end,
    rdLvl = function() return try(hub.getRadioLevel, n) end,
    setEn = function(on) try(hub.setRadioEnabled, on, n) end,
    setVol = function(v) try(hub.setRadioVolume, v, n) end }
  targets[#targets + 1] = { label = "T" .. n, kind = "radio", idx = n, color = C.orange }
end
local masterStrip
if hasMaster then
  newStrip { group = 4, kind = "master", idx = 1, label = "MN",
    rdEn  = function() return try(hub.isMasterEnabled) end,
    rdVol = function() return try(hub.getMasterVolume) end,
    rdLvl = function() return try(hub.getMasterLevel) end,
    setEn = function(on) try(hub.setMasterEnabled, on) end,
    setVol = function(v) try(hub.setMasterVolume, v) end }
  masterStrip = strips[#strips]
  targets[#targets + 1] = { label = "MN", kind = "master", idx = 1, color = C.white }
end
if #strips == 0 then printError("Le hub ne rapporte aucune entree/sortie.") return end

-- ---------- etat ----------
local dirty = true
local MSG = { text = "", t = 0 }
local function msg(t) MSG.text = asc(t) MSG.t = os.clock() + 6 dirty = true end

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
  D[key] = clamp(floor((D[key] + delta) * 100 + 0.5) / 100, lo, hi)
  applyDuck() dirty = true
end

local P = { queue = {}, cur = 0, playing = false, loop = true, shuffle = false, gen = 0, t0 = 0 }
local hist, playIn = {}, nil

local function saveState()
  local q = {}
  for _, e in ipairs(P.queue) do q[#q + 1] = { title = e.title, url = e.url, dur = e.dur, expand = e.expand } end
  local f = fs.open(CFG.stateFile, "w")
  if f then
    f.write(textutils.serialiseJSON({ queue = q, cur = P.cur, loop = P.loop, shuffle = P.shuffle, duck = D }))
    f.close()
  end
end
local function loadState()
  if not fs.exists(CFG.stateFile) then return false end
  local f = fs.open(CFG.stateFile, "r")
  if not f then return false end
  local t = textutils.unserialiseJSON(f.readAll())
  f.close()
  if type(t) ~= "table" then return false end
  for _, e in ipairs(t.queue or {}) do P.queue[#P.queue + 1] = { title = e.title, url = e.url, dur = e.dur, expand = e.expand } end
  P.cur = clamp(tonumber(t.cur) or 0, 0, #P.queue)
  if t.loop ~= nil then P.loop = t.loop end
  if t.shuffle ~= nil then P.shuffle = t.shuffle end
  if type(t.duck) == "table" then
    for k, v in pairs(t.duck) do if D[k] ~= nil then D[k] = v end end
    applyDuck()
  end
  return true
end

-- ---------- YouCube (websocket) / file de lecture ----------
local B64 = {}
do
  local al = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  for i = 1, #al do B64[al:byte(i)] = i - 1 end
end
local function b64dec(str)
  local out, n = {}, 0
  for i = 1, #str - 3, 4 do
    local a, b, c, d = str:byte(i, i + 3)
    local x = (B64[a] or 0) * 262144 + (B64[b] or 0) * 4096 + (B64[c] or 0) * 64 + (B64[d] or 0)
    local b1, b2, b3 = floor(x / 65536), floor(x / 256) % 256, x % 256
    n = n + 1
    if c == 61 then out[n] = string.char(b1)
    elseif d == 61 then out[n] = string.char(b1, b2)
    else out[n] = string.char(b1, b2, b3) end
  end
  return table.concat(out)
end

local function useYouCube(url)
  if not url:find("://", 1, true) then return true end   -- texte libre = recherche
  local u = url:lower()
  for _, h in ipairs(CFG.ycHosts) do if u:find(h, 1, true) then return true end end
  return false
end

local ycWs
local function wsOpen(url, timeout)
  if not (http and http.websocketAsync) then return nil, "http.websocket indisponible" end
  local okReq, err = http.websocketAsync(url)
  if not okReq then return nil, err end
  local t = os.startTimer(timeout)
  while true do
    local ev, a, b = os.pullEvent()
    if ev == "websocket_success" and a == url then os.cancelTimer(t) return b
    elseif ev == "websocket_failure" and a == url then os.cancelTimer(t) return nil, b
    elseif ev == "timer" and a == t then return nil, "timeout" end
  end
end
local function ycClose()
  if ycWs then pcall(ycWs.close) ycWs = nil end
end
local function ycConnect()
  if ycWs then return ycWs end
  local list = {}
  local custom = settings and settings.get("youcube.server")
  if custom then list[#list + 1] = custom end
  for _, u in ipairs(CFG.youcube) do list[#list + 1] = u end
  local lastErr
  for _, url in ipairs(list) do
    local ws, err = wsOpen(url, 6)
    if ws then ycWs = ws msg("YouCube: " .. url) return ws end
    lastErr = err
  end
  error("aucun serveur YouCube joignable (" .. tostring(lastErr) .. ")")
end
local function ycSend(ws, t) ws.send(textutils.serialiseJSON(t)) end
local function ycWait(ws, action, gen, timeout)
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    if P.gen ~= gen then return nil end
    local raw = ws.receive(2)
    if raw then
      local d = textutils.unserialiseJSON(raw)
      if type(d) == "table" then
        if d.action == "error" then error(tostring(d.message)) end
        if d.action == "status" and d.message then msg(d.message) end
        if d.action == action then return d end
      end
    end
  end
  error("serveur YouCube: pas de reponse")
end

local function addLink(text)
  if #P.queue >= CFG.maxQueue then msg("File pleine") return 0 end
  if useYouCube(text) then
    P.queue[#P.queue + 1] = { title = asc(text), url = text, expand = text:find("list=", 1, true) ~= nil }
    return 1
  end
  P.queue[#P.queue + 1] = { title = asc(text:match("([^/]+)$") or text), url = text }
  return 1
end

local function wake() os.queueEvent("mixer_player") end
local function stopPlayback() P.gen = P.gen + 1 P.playing = false dirty = true end
local function playIndex(i)
  if not P.queue[i] then return end
  P.gen = P.gen + 1 P.cur = i P.playing = true dirty = true wake()
end
local function nextIndex(dir)
  local n = #P.queue
  if n == 0 then return nil end
  if P.shuffle and dir > 0 and n > 1 then
    local i
    repeat i = math.random(n) until i ~= P.cur
    return i
  end
  local i = P.cur + dir
  if i > n then if P.loop then i = 1 else return nil end end
  if i < 1 then i = n end
  return i
end
local function skip(dir)
  local i = nextIndex(dir)
  if i then playIndex(i) else stopPlayback() end
end
local function togglePlay()
  if P.playing then stopPlayback()
  elseif #P.queue > 0 then playIndex(P.cur > 0 and P.cur or 1) end
end

local function waitSpeaker()
  local t = os.startTimer(0.1)
  while true do
    local ev, a = os.pullEvent()
    if ev == "speaker_audio_empty" then os.cancelTimer(t) return end
    if ev == "timer" and a == t then return end
  end
end

local function antennaStream(e, gen)
  if not antenna then error("pas d'antenne (module antenna)") end
  local r = antenna.openAudio(e.url)
  local id = type(r) == "table" and (r.id or r[1]) or r
  if not id then error("openAudio: " .. describe(r)) end
  P.t0 = os.clock()
  local empties = 0
  while P.gen == gen and P.playing do
    local t = antenna.readAudio(id, CFG.chunk)
    if t == nil or t == false then break end
    local ended = type(t) == "table" and (t.eof or t.done or t.finished or t.ended)
    local pcm = t
    if type(t) == "table" then pcm = t.samples or t.audio or t.data or t end
    if type(pcm) == "table" and #pcm > 0 then
      empties = 0
      while P.gen == gen and not hub.playAudio(pcm, CFG.musicVol) do waitSpeaker() end
    else
      empties = empties + 1
      if empties > CFG.emptyLimit then break end
      sleep(0.05)
    end
    if ended then break end
  end
  pcall(antenna.close, id)
  if P.gen ~= gen then pcall(hub.stop) end
end

local function ycStream(e, gen)
  local okDf, dfpwm = pcall(require, "cc.audio.dfpwm")
  if not okDf then error("cc.audio.dfpwm absent (CC: Tweaked trop ancien)") end
  local ws = ycConnect()
  ycSend(ws, { action = "request_media", url = e.url })
  local media = ycWait(ws, "media", gen, CFG.ycTimeout)
  if not media then return end
  if media.title then e.title = asc(media.title) end
  -- playlist : on insere les autres titres apres celui-ci
  if e.expand and type(media.playlist_videos) == "table" then
    local ids = media.playlist_videos
    if type(ids[1]) == "table" then ids = ids[1] end
    local pos
    for i, q in ipairs(P.queue) do if q == e then pos = i end end
    if pos then
      for k, id in ipairs(ids) do
        if #P.queue >= CFG.maxQueue then break end
        table.insert(P.queue, pos + k, { title = tostring(id), url = "https://www.youtube.com/watch?v=" .. tostring(id) })
      end
      msg("+" .. #ids .. " titres (playlist)")
    end
  end
  e.expand = false
  saveState() dirty = true

  local dec = dfpwm.make_decoder()
  P.t0 = os.clock()
  local idx = 0
  ycSend(ws, { action = "get_chunk", chunkindex = 0, id = media.id })
  local d = ycWait(ws, "chunk", gen, CFG.ycTimeout)
  while d and P.gen == gen and P.playing do
    local raw = b64dec(d.chunk or "")
    if #raw == 0 then break end
    local buf = dec(raw)
    while P.gen == gen and not hub.playAudio(buf, CFG.musicVol) do waitSpeaker() end
    if P.gen ~= gen then break end
    idx = idx + 1
    ycSend(ws, { action = "get_chunk", chunkindex = idx, id = media.id })   -- prefetch pendant la lecture
    d = ycWait(ws, "chunk", gen, CFG.ycTimeout)
  end
  if P.gen ~= gen then pcall(hub.stop) end
end

local function streamEntry(e, gen)
  if useYouCube(e.url) then
    local ok, err = pcall(ycStream, e, gen)
    if not ok then ycClose() error(err, 0) end
  else
    antennaStream(e, gen)
  end
end

local function playerLoop()
  local fails = 0
  while true do
    local e = P.playing and P.queue[P.cur]
    if not e then
      os.pullEvent("mixer_player")
    else
      local gen = P.gen
      local ok, err = pcall(streamEntry, e, gen)
      if P.gen == gen then
        if ok then fails = 0 else fails = fails + 1 msg("Lecture: " .. tostring(err):sub(1, 70)) end
        if fails >= 3 then stopPlayback() fails = 0
        else
          local i = nextIndex(1)
          if i then P.cur = i P.gen = P.gen + 1 dirty = true else stopPlayback() end
          if not ok then sleep(1) end
        end
      end
    end
  end
end

-- ---------- commandes ----------
local cmdQ = {}
local function submit(line) cmdQ[#cmdQ + 1] = line os.queueEvent("mixer_cmdq") end

local function runCmd(line)
  local cmd, rest = line:match("^!?(%S+)%s*(.*)$")
  if not cmd then return end
  cmd = cmd:lower()
  if cmd == "add" and rest ~= "" then
    local n = addLink(rest) if n > 0 then msg("+" .. n .. " titre(s)") end
    saveState()
  elseif cmd == "play" then
    if rest ~= "" then
      local first = #P.queue + 1
      local n = addLink(rest)
      if n > 0 then msg("+" .. n .. " titre(s)") playIndex(first) saveState() end
    else togglePlay() if P.playing then else end end
  elseif cmd == "stop" or cmd == "pause" then stopPlayback()
  elseif cmd == "next" then skip(1)
  elseif cmd == "prev" then skip(-1)
  elseif cmd == "jump" then playIndex(tonumber(rest) or 0)
  elseif cmd == "rm" then
    local i = tonumber(rest)
    if i and P.queue[i] then
      table.remove(P.queue, i)
      if i < P.cur then P.cur = P.cur - 1
      elseif i == P.cur then stopPlayback() P.cur = min(P.cur, #P.queue) end
      saveState() dirty = true
    end
  elseif cmd == "clear" then stopPlayback() P.queue = {} P.cur = 0 saveState() msg("File videe")
  elseif cmd == "loop" then P.loop = not P.loop saveState() dirty = true
  elseif cmd == "shuffle" then P.shuffle = not P.shuffle saveState() dirty = true
  elseif cmd == "list" then
    for i, e in ipairs(P.queue) do print(string.format("%s%3d %s", i == P.cur and ">" or " ", i, e.title)) end
  elseif cmd == "help" then
    print("add <lien> | play [lien] | stop | next | prev | jump n | rm n")
    print("clear | loop | shuffle | list")
  end
end

local function cmdLoop()
  while true do
    if #cmdQ == 0 then os.pullEvent("mixer_cmdq")
    else pcall(runCmd, table.remove(cmdQ, 1)) end
  end
end

local isTerm
local function consoleLoop()
  term.clear() term.setCursorPos(1, 1)
  print("OPENRACKS MIXER - tape 'help'")
  print("add <lien YouTube ou recherche>")
  while true do
    write("> ")
    local l = read()
    if l and l ~= "" then submit(l) end
  end
end

local function chatLoop()
  while true do
    local _, user, message = os.pullEvent("chat")
    if type(message) == "string" and message:sub(1, 1) == "!" then
      local ok = #CFG.chatAdmins == 0
      for _, a in ipairs(CFG.chatAdmins) do if a == user then ok = true end end
      if ok then submit(message:sub(2)) end
    end
  end
end

-- ---------- surface / fenetre ----------
local surface = CFG.surface and peripheral.wrap(CFG.surface) or peripheral.find("monitor") or term.current()
isTerm = (surface == term.current())
local surfaceName = (not isTerm) and peripheral.getName(surface) or nil
if not isTerm then pcall(surface.setTextScale, CFG.textScale) end

local win, W, H, hits
local cw, gw, X0, px, pw, fy1, fy2, showMatrix, matrixTop = 5, 4, 5, 0, 0, 5, 10, false, 4
local L = {}

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
  local g  = min(r, floor(total * 0.6 + 0.5))
  local y  = min(max(r - g, 0), floor(total * 0.25 + 0.5))
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
  cw = clamp(floor(avail / count), 5, 9)
  X0 = gw + 1
  local x, last = X0, nil
  for _, s in ipairs(strips) do
    if last and s.group ~= last then x = x + 1 end
    s.x, last = x, s.group
    x = x + cw
  end
  if pw > 0 then
    px = x + 1
    pw = min(W - px + 1, 46)
    if pw < 26 then pw = 0 end
  end
  local nT = #targets
  local mh = nT + 2
  matrixTop = 4
  showMatrix = nIn > 0 and nT > 0 and H >= mh + 3 + 8 + 4
  fy1 = showMatrix and (matrixTop + mh + 1) or 4
  fy2 = H - 3
  -- panneau de droite
  L.dT = H - 7
  L.sh = clamp(floor((L.dT - 2 - 6 + 1) * 0.35), 3, 10)
  L.sy2 = L.dT - 2
  L.sy1 = L.sy2 - L.sh + 1
  L.qTop = 6
  L.qn = max(0, L.sy1 - 3 - L.qTop + 1)
  dirty = true
end

-- ---------- dessin ----------
local function drawStrip(s)
  local fh = fy2 - fy1 + 1
  local fw = max(1, cw - 4)
  local fx = s.x + 1
  local mx = fx + fw + 1

  local lbl = center(asc(s.label), cw)
  if s.kind == "radio" and s.onair then put(s.x, 3, lbl, C.white, C.red)
  else put(s.x, 3, lbl, s.en and C.white or C.pink, C.black) end

  fill(fx, fy1, fw, fh, C.gray)
  fill(mx, fy1, 1, fh, C.gray)
  local f = clamp(s.vol / CFG.volMax, 0, 1)
  local rows = floor(f * fh + 0.5)
  if rows > 0 then
    fill(fx, fy2 - rows + 1, fw, rows, s.en and C.blue or C.lightGray)
    fill(fx, fy2 - rows + 1, fw, 1, C.white)
  end
  local lr = floor(s.lvl * fh + 0.5)
  if lr > 0 and s.en then segBar(mx, fy2, lr, fh, 1) end
  hit(fx, fy1, fw + 2, fh, function(_, cy)
    local v = clamp((fy2 - cy) / max(fh - 1, 1), 0, 1)
    v = floor(v * 100 + 0.5) / 100 * CFG.volMax
    s.vol = v s.hold = os.clock() + 1.5
    s.setVol(v)
  end)

  put(s.x, H - 2, center(floor(f * 100 + 0.5) .. "%", cw), s.en and C.white or C.pink, C.black)
  button(s.x + 1, H - 1, cw - 2, s.en and "ON" or "OFF",
    s.en and C.black or C.white, s.en and C.lime or C.lightGray,
    function() s.en = not s.en s.hold = os.clock() + 1.5 s.setEn(s.en) end)
end

local function drawMatrix()
  local row, lastKind = matrixTop, nil
  for t, tg in ipairs(targets) do
    if lastKind and tg.kind ~= lastKind then row = row + 1 end
    lastKind = tg.kind
    put(1, row, tg.label, tg.color, C.black)
    for _, s in ipairs(strips) do
      if s.kind == "in" then
        local cx = s.x + floor((cw - 2) / 2)
        fill(cx, row, 2, 1, s.routes[t] and C.lime or C.lightGray)
        hit(s.x, row, cw, 1, function()
          local new = not s.routes[t]
          s.routes[t] = new s.rhold = os.clock() + 1.5
          try(hub.setRoute, s.idx, CFG.target(tg.kind, tg.idx), new)
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
  fill(bx, y, floor(clamp(frac, 0, 1) * bw + 0.5), 1, C.purple)
  button(px + pw - 7, y, 3, "-", C.white, C.lightGray, minus)
  button(px + pw - 3, y, 3, "+", C.white, C.lightGray, plus)
end

local function drawMusic()
  fill(px, 2, pw, 1, C.purple)
  put(px, 2, center("MUSIQUE (" .. #P.queue .. ")", pw), C.black, C.purple)

  -- titre (defilant)
  local e = P.queue[P.cur]
  local line = (P.playing and "> " or "| ") .. (e and e.title or "-- aucun titre --")
  if #line > pw then
    local off = P.playing and (floor(os.clock() * 4) % (#line + 3)) or 0
    line = (line .. "   " .. line):sub(off + 1, off + pw)
  end
  put(px, 3, line .. string.rep(" ", pw - #line), C.white, C.black)

  -- progression
  local el = P.playing and (os.clock() - P.t0) or 0
  local tstr = fmtTime(el) .. ((e and e.dur) and ("/" .. fmtTime(e.dur)) or "")
  local bw = pw - #tstr - 1
  fill(px, 4, bw, 1, C.gray)
  if e and e.dur and e.dur > 0 then
    fill(px, 4, floor(clamp(el / e.dur, 0, 1) * bw), 1, C.purple)
  elseif P.playing then
    fill(px + min(floor(os.clock() * 6) % bw, bw - 2), 4, 2, 1, C.purple)
  end
  put(px + bw + 1, 4, tstr, C.pink, C.black)

  -- boutons
  local b = floor((pw - 4) / 5)
  local btns = {
    { "<<", C.white, C.lightGray, function() skip(-1) end },
    { P.playing and "STOP" or "PLAY", C.black, P.playing and C.red or C.lime, togglePlay },
    { ">>", C.white, C.lightGray, function() skip(1) end },
    { "LOOP", P.loop and C.black or C.white, P.loop and C.purple or C.lightGray,
      function() P.loop = not P.loop saveState() end },
    { "MIX", P.shuffle and C.black or C.white, P.shuffle and C.purple or C.lightGray,
      function() P.shuffle = not P.shuffle saveState() end },
  }
  for k, bt in ipairs(btns) do button(px + (k - 1) * (b + 1), 5, b, bt[1], bt[2], bt[3], bt[4]) end

  -- file d'attente
  if L.qn > 0 then
    if #P.queue == 0 then
      put(px, L.qTop, "File vide. add <lien ou recherche>", C.pink, C.black)
      if L.qn > 1 then put(px, L.qTop + 1, "ou chat : !add <lien>", C.pink, C.black) end
    else
      local top = clamp(P.cur - floor(L.qn / 2), 1, max(1, #P.queue - L.qn + 1))
      for k = 1, L.qn do
        local i = top + k - 1
        local q = P.queue[i]
        if not q then break end
        local txt = string.format("%2d %s", i, q.title):sub(1, pw)
        txt = txt .. string.rep(" ", pw - #txt)
        local y = L.qTop + k - 1
        if i == P.cur then put(px, y, txt, C.black, P.playing and C.lime or C.yellow)
        else put(px, y, txt, C.white, C.black) end
        hit(px, y, pw, 1, function() playIndex(i) end)
      end
    end
  end
end

local function drawPanel()
  drawMusic()
  -- spectre
  put(px, L.sy1 - 1, string.format("MASTER %3d%%", masterStrip and floor(masterStrip.lvl * 100 + 0.5) or 0), C.pink, C.black)
  fill(px, L.sy1, pw, L.sh, C.gray)
  local data = hist
  if CFG.graphChannel then
    local g = try(hub.getGraph, CFG.graphChannel, pw)
    if type(g) == "table" and type(g[1]) == "number" then data = g end
  end
  for k = 1, pw do
    local v = data[#data - pw + k]
    if v then
      local r = floor(clamp(v, 0, 1) * L.sh + 0.5)
      if r > 0 then segBar(px + k - 1, L.sy2, r, L.sh, 1) end
    end
  end
  -- ducking
  local dT = L.dT
  fill(px, dT, pw, 1, C.orange)
  put(px, dT, " DUCKING", C.black, C.orange)
  button(px + pw - 5, dT, 5, D.on and "ON" or "OFF", D.on and C.black or C.white,
    D.on and C.lime or C.lightGray, function() D.on = not D.on applyDuck() saveState() end)
  paramRow(dT + 1, "DEPTH", string.format("%.2f", D.level), D.level,
    function() adj("level", -0.05, 0, 1) saveState() end, function() adj("level", 0.05, 0, 1) saveState() end)
  paramRow(dT + 2, "ATT", string.format("%.1fs", D.fadeDown), D.fadeDown / 5,
    function() adj("fadeDown", -0.1, 0.1, 5) saveState() end, function() adj("fadeDown", 0.1, 0.1, 5) saveState() end)
  paramRow(dT + 3, "REL", string.format("%.1fs", D.fadeUp), D.fadeUp / 5,
    function() adj("fadeUp", -0.1, 0.1, 5) saveState() end, function() adj("fadeUp", 0.1, 0.1, 5) saveState() end)
  -- entree de lecture
  put(px, H - 2, "LECTURE", C.pink, C.black)
  put(px + 8, H - 2, tostring(playIn or "-"), C.white, C.black)
  button(px + pw - 7, H - 2, 3, "<", C.white, C.lightGray, function()
    local n = ((tonumber(playIn) or 1) - 2) % max(nIn, 1) + 1
    try(hub.setPlaybackInput, n) playIn = n
  end)
  button(px + pw - 3, H - 2, 3, ">", C.white, C.lightGray, function()
    local n = (tonumber(playIn) or 0) % max(nIn, 1) + 1
    try(hub.setPlaybackInput, n) playIn = n
  end)
end

local function draw()
  hits = {}
  win.setVisible(false)
  win.setBackgroundColor(C.black)
  win.clear()

  fill(1, 1, W, 1, C.gray)
  put(2, 1, "OPENRACKS", C.lime, C.gray)
  put(12, 1, "/ MIXER", C.pink, C.gray)
  local clock = textutils.formatTime(os.time(), true)
  put(W - #clock, 1, clock, C.white, C.gray)

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

  if os.clock() < MSG.t then put(2, H, MSG.text:sub(1, W - 2), C.yellow, C.black)
  elseif W >= 60 then put(2, H, "fader = volume | ON/OFF = coupe | carres = routage", C.brown, C.black) end
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

-- ---------- lecture de l'etat (en parallele : ~1 tick au lieu de N) ----------
local function pall(fns)
  if #fns == 0 then return end
  for i, f in ipairs(fns) do fns[i] = function() pcall(f) end end
  parallel.waitForAll(table.unpack(fns))
end

local function pollFast()
  local fns = {}
  for _, s in ipairs(strips) do
    if s.en then
      fns[#fns + 1] = function()
        local v = clamp(tonumber(s.rdLvl()) or 0, 0, 1)
        if math.abs(v - s.lvl) > 0.02 then s.lvl = v dirty = true end
      end
    elseif s.lvl ~= 0 then s.lvl = 0 dirty = true end
    if s.kind == "radio" then
      fns[#fns + 1] = function()
        local o = try(hub.isOnAir, s.idx) and true or false
        if o ~= s.onair then s.onair = o dirty = true end
      end
    end
  end
  pall(fns)
  local v = masterStrip and masterStrip.lvl or 0
  if not masterStrip then for _, s in ipairs(strips) do if s.kind == "out" then v = max(v, s.lvl) end end end
  local prev = hist[#hist] or 0
  hist[#hist + 1] = v
  while #hist > 200 do table.remove(hist, 1) end
  if v > 0 or prev > 0 then dirty = true end
end

local function pollSlow()
  local fns, now = {}, os.clock()
  for _, s in ipairs(strips) do
    fns[#fns + 1] = function()
      local en = s.rdEn() and true or false
      if now >= (s.hold or 0) and en ~= s.en then s.en = en dirty = true end
    end
    fns[#fns + 1] = function()
      local v = tonumber(s.rdVol())
      if v and now >= (s.hold or 0) and math.abs(v - s.vol) > 0.001 then s.vol = v dirty = true end
    end
    if s.kind == "in" then
      for t, tg in ipairs(targets) do
        fns[#fns + 1] = function()
          local r = try(hub.getRoute, s.idx, CFG.target(tg.kind, tg.idx)) and true or false
          if now >= (s.rhold or 0) and r ~= s.routes[t] then s.routes[t] = r dirty = true end
        end
      end
    end
  end
  fns[#fns + 1] = function()
    local p = try(hub.getPlaybackInput)
    if p ~= playIn then playIn = p dirty = true end
  end
  pall(fns)
end

local function pollLoop()
  local nextSlow = os.clock() + CFG.slowPoll
  while true do
    pollFast()
    if os.clock() >= nextSlow then pollSlow() nextSlow = os.clock() + CFG.slowPoll end
    sleep(CFG.fastPoll)
  end
end

-- ---------- interface ----------
local function uiLoop()
  local lastAnim = -1
  draw() dirty = false
  local timer = os.startTimer(CFG.draw)
  while true do
    local ev, a, b, c = os.pullEvent()
    if ev == "timer" and a == timer then
      local ak = (P.playing or os.clock() < MSG.t) and floor(os.clock() * 3) or 0
      if dirty or ak ~= lastAnim then lastAnim = ak dirty = false draw() end
      timer = os.startTimer(CFG.draw)
    elseif (ev == "monitor_touch" and not isTerm and a == surfaceName) or (ev == "mouse_click" and isTerm) then
      if click(b, c) then dirty = false draw() end
    elseif ev == "monitor_resize" or ev == "term_resize" then
      layout() draw() dirty = false
    end
  end
end


if args[1] == "diag" and args[2] then
  local url = args[2]
  if useYouCube(url) then
    local ws = ycConnect()
    ycSend(ws, { action = "request_media", url = url })
    local m = ycWait(ws, "media", P.gen, CFG.ycTimeout)
    print("media -> " .. describe(m))
    ycSend(ws, { action = "get_chunk", chunkindex = 0, id = m.id })
    local c = ycWait(ws, "chunk", P.gen, CFG.ycTimeout)
    print("chunk0 -> " .. #(c.chunk or "") .. " caracteres base64, " .. #b64dec(c.chunk or "") .. " octets")
    ycClose()
  else
    if not antenna then printError("Pas d'antenne trouvee.") return end
    local r = antenna.openAudio(url)
    print("openAudio -> " .. describe(r))
    local id = type(r) == "table" and (r.id or r[1]) or r
    sleep(1.5)
    print("readAudio -> " .. describe(antenna.readAudio(id, 256)))
    print("getInfo   -> " .. describe(try(antenna.getInfo, id)))
    pcall(antenna.close, id)
  end
  return
end

local function main()
  loadState()
  layout()
  pollSlow() pollFast()
  local fns = { uiLoop, pollLoop, playerLoop, cmdLoop }
  if not isTerm then fns[#fns + 1] = consoleLoop end
  if chatBox then fns[#fns + 1] = chatLoop end
  parallel.waitForAny(table.unpack(fns))
end

local ok, err = pcall(main)
try(hub.stop)
pcall(surface.setBackgroundColor, C.black)
pcall(surface.clear)
pcall(surface.setCursorPos, 1, 1)
if not ok and err ~= "Terminated" then printError(err) end
