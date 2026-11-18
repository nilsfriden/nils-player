-- review-ui.lua - fixed info bar + transport bar for mpv - v1.7
--
-- The picture is never covered: the script reserves a strip above and below the
-- video (video-margin-ratio-*) and draws only inside those strips.
--
--   Top bar    : SRC timecode + frame (left)   resolution, fps, codec, audio (right)
--   Bottom bar : scrub bar, transport buttons, shuttle state, duration
--   M          : full MediaInfo report in a side panel (picture shrinks, not covered)
--
-- Source timecode and codec name come from the bundled mi-helper.exe (MediaInfo).
-- Drop-frame timecode is shown with ';' and counted as non-drop.

local ov = mp.create_osd_overlay("ass-events")

-- ---------------------------------------------------------------- style
local C = {
    bar    = "&H161616&",
    sep    = "&H2C2C2C&",
    text   = "&HE6E6E6&",
    dim    = "&H8A8A8A&",
    accent = "&H2E9BFF&",   -- orange (BGR)
    track  = "&H3A3A3A&",
    played = "&H787878&",
    hover  = "&H303030&",
    panel  = "&H101010&",
}
local FONT = "Consolas"

-- ---------------------------------------------------------------- state
local W, H, S = 0, 0, 1
local L = {}                  -- layout, rebuilt on resize
local clip = {}               -- per-file info
local panel = {open = false, lines = {}, top = 1, page = 1}
local mouse = {x = -1, y = -1}
local drag = false
local tc_elapsed = false      -- true: show elapsed time from 00:00:00:00 instead of the file's timecode

-- timecode base and label for the current display mode
local function tc_base()
    if tc_elapsed then return 0 end
    return clip.base or 0
end
local function tc_label()
    if tc_elapsed then return "REL" end
    return clip.label or "REL"
end
-- the elapsed mode is only "overriding" something when the file has its own timecode
local function tc_overridden() return tc_elapsed and clip.label == "SRC" end
local ui_bindings = false
local margins = {t = -1, b = -1, r = -1}

-- ---------------------------------------------------------------- helpers
local function esc(s)
    return (tostring(s):gsub("\\", "\\\\"):gsub("{", "\\{"):gsub("}", "\\}"))
end

local function r(n) return math.floor(n + 0.5) end

local function rect(x0, y0, x1, y1, col)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\p1}m %d %d l %d %d l %d %d l %d %d{\\p0}",
        col, x0, y0, x1, y0, x1, y1, x0, y1)
end

local function shape(path, col)
    return string.format("{\\an7\\pos(0,0)\\bord0\\shad0\\1c%s\\p1}%s{\\p0}", col, path)
end

local function text(x, y, an, size, col, s, clip_rect)
    local c = clip_rect and string.format("\\clip(%d,%d,%d,%d)", clip_rect[1], clip_rect[2], clip_rect[3], clip_rect[4]) or ""
    return string.format("{\\an%d\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\1c%s%s}%s",
        an, x, y, FONT, size, col, c, esc(s))
end

local function in_box(b, x, y)
    return b and x >= b[1] and x < b[3] and y >= b[2] and y < b[4]
end

-- ---------------------------------------------------------------- timecode
local function fps()
    local f = mp.get_property_number("container-fps")
    if not f or f <= 0 then f = mp.get_property_number("estimated-vf-fps") end
    return f
end

local function tc_to_frames(tc, rate)
    local h, m, s, f = tc:match("^(%d+)[:;.](%d+)[:;.](%d+)[:;.](%d+)$")
    if not h then return nil end
    return ((tonumber(h) * 60 + tonumber(m)) * 60 + tonumber(s)) * rate + tonumber(f)
end

local function frames_to_tc(n, rate, drop)
    n = math.max(0, n)
    local f = n % rate
    local ts = math.floor(n / rate)
    return string.format("%02d:%02d:%02d%s%02d",
        math.floor(ts / 3600) % 24, math.floor(ts / 60) % 60, ts % 60, drop and ";" or ":", f)
end

local function fmt_fps(f)
    if not f then return "? fps" end
    local s = string.format("%.3f", f):gsub("0+$", ""):gsub("%.$", "")
    return s .. " fps"
end

-- ---------------------------------------------------------------- clip info
local function helper_path()
    return mp.command_native({"expand-path", "~~exe_dir/mi-helper.exe"})
end

local function run(args)
    local res = mp.command_native({
        name = "subprocess", args = args,
        capture_stdout = true, capture_stderr = true, playback_only = false,
    })
    if res and res.status == 0 and res.stdout then return res.stdout end
    return nil
end

-- ---------------------------------------------------------------- Canon RAW -> proxy
-- .CRM can't be decoded by mpv/FFmpeg. When one is opened, play the matching proxy from
-- the "Proxy" subfolder next to it (Blackmagic Proxy Generator layout): same clip name,
-- optionally with a suffix, any of the extensions below.
local utils = require "mp.utils"
local proxy = {}              -- per load: raw = CRM path, file = proxy path, missing = clip name
local notice = nil            -- shown in the top bar when nothing could be played
local PROXY_EXT = {mov = true, mp4 = true, mxf = true, m4v = true}

local function ext_of(p) return (p:match("%.([^.\\/]+)$") or ""):lower() end
local function stem(f) return (f:gsub("%.[^.]+$", "")):lower() end
local function is_crm(p) return ext_of(p) == "crm" end
local function trim_sep(d) return (d:gsub("[\\/]+$", "")) end
local function is_url(p) return p:match("^%a[%w+.-]*://") ~= nil end

local function find_proxy(crm)
    local dir, file = utils.split_path(crm)
    local base = stem(file)
    local pdir = utils.join_path(dir, "Proxy")
    local exact, prefix
    for _, f in ipairs(utils.readdir(pdir, "files") or {}) do
        if PROXY_EXT[ext_of(f)] then
            local b = stem(f)
            if b == base then exact = f
            elseif not prefix and b:sub(1, #base) == base then prefix = f end
        end
    end
    local hit = exact or prefix
    return hit and utils.join_path(pdir, hit) or nil
end

-- A proxy opened directly: find its RAW in the parent of the Proxy folder
local function find_raw(p)
    local dir, file = utils.split_path(p)
    local parent, last = utils.split_path(trim_sep(dir))
    if last:lower() ~= "proxy" then return nil end
    local base = stem(file)
    for _, f in ipairs(utils.readdir(parent, "files") or {}) do
        if is_crm(f) then
            local b = stem(f)
            if base == b or base:sub(1, #b) == b then return utils.join_path(parent, f) end
        end
    end
    return nil
end

mp.add_hook("on_load", 50, function()
    proxy = {}
    local p = mp.get_property("stream-open-filename") or ""
    if is_url(p) then return end
    if is_crm(p) then
        proxy.raw = p
        local hit = find_proxy(p)
        if hit then
            proxy.file = hit
            mp.set_property("stream-open-filename", hit)
        else
            -- don't let mpv open the RAW (it would play the audio only)
            local _, f = utils.split_path(p)
            proxy.missing = f
            mp.set_property("stream-open-filename", "null://")
        end
    else
        local raw = find_raw(p)
        if raw then proxy.raw, proxy.file = raw, p end
    end
end)

-- Dropping a folder: remove proxies whose RAW is also in the playlist (they'd play twice)
local function dedupe_playlist()
    local pl = mp.get_property_native("playlist") or {}
    local raws = {}
    for _, e in ipairs(pl) do
        if is_crm(e.filename) then
            local d, f = utils.split_path(e.filename)
            raws[#raws + 1] = {dir = trim_sep(d):lower(), base = stem(f)}
        end
    end
    if #raws == 0 then return end
    for i = #pl, 1, -1 do
        local e = pl[i]
        if not e.current and not is_crm(e.filename) then
            local d, f = utils.split_path(e.filename)
            local parent, last = utils.split_path(trim_sep(d))
            if last:lower() == "proxy" then
                parent = trim_sep(parent):lower()
                local b = stem(f)
                for _, rw in ipairs(raws) do
                    if rw.dir == parent and (b == rw.base or b:sub(1, #rw.base) == rw.base) then
                        mp.commandv("playlist-remove", i - 1)
                        break
                    end
                end
            end
        end
    end
end
mp.observe_property("playlist-count", "number", function() mp.add_timeout(0, dedupe_playlist) end)

local function audio_summary()
    local tracks = mp.get_property_native("track-list") or {}
    local n, ch = 0, 0
    for _, t in ipairs(tracks) do
        if t.type == "audio" then
            n = n + 1
            ch = ch + (t["demux-channel-count"] or 0)
        end
    end
    if n == 0 then return "no audio" end
    if n == 1 then return ch .. " ch" end
    return string.format("%d ch / %d trk", ch, n)
end

-- Audio-only files have no frame rate: timecode is shown at this rate.
-- Keep in sync with AUDIO_TC_FPS in jkl.lua.
local AUDIO_TC_FPS = 25

local function is_audio_only()
    local v = mp.get_property_native("current-tracks/video")
    return v == nil or v.albumart == true
end

local function audio_details()
    local ap = mp.get_property_native("audio-params") or {}
    local codec = mp.get_property("audio-codec-name") or ""
    local parts = {}
    if ap.samplerate then
        local k = ap.samplerate / 1000
        parts[#parts + 1] = (k == math.floor(k) and string.format("%d", k) or string.format("%.1f", k)) .. " kHz"
    end
    local bits = codec:match("^pcm_[su](%d+)") or codec:match("^pcm_f(%d+)")
    if bits then
        parts[#parts + 1] = bits .. "-bit PCM"
    elseif codec ~= "" then
        parts[#parts + 1] = codec:upper()
    end
    parts[#parts + 1] = audio_summary()
    return table.concat(parts, "    ")
end

local function load_clip_info()
    clip = {loaded = true, fps = fps(), base = 0, label = "REL", drop = false, codec = nil}
    if is_audio_only() then
        clip.audio_only = true
        clip.fps = AUDIO_TC_FPS
        -- Broadcast WAV: start timecode is stored as samples since midnight
        local tref = tonumber(mp.get_property("metadata/by-key/time_reference") or "")
        local sr = tonumber(mp.get_property("audio-params/samplerate") or "")
            or tonumber((mp.get_property_native("current-tracks/audio") or {})["demux-samplerate"] or "")
        if tref and sr and sr > 0 then
            clip.base = r(tref / sr * AUDIO_TC_FPS)
            clip.label = "SRC"
        end
    end
    local path = proxy.file or mp.get_property("path") or ""
    local is_local = not is_url(path)

    local function info(p)
        local t = {}
        local out = run({helper_path(), "info", p})
        if out then
            for k, v in out:gmatch("([%w_]+)=([^\r\n]*)") do t[k] = v end
        end
        return t
    end

    local kv = is_local and info(path) or {}

    -- RAW original behind a proxy: its resolution and timecode
    if proxy.raw then
        local rk = info(proxy.raw)
        clip.proxy = true
        clip.raw_w, clip.raw_h = tonumber(rk.width), tonumber(rk.height)
        clip.raw_tc = (rk.tc and rk.tc ~= "") and rk.tc or nil
    end

    -- source timecode: mpv metadata, then MediaInfo, then ffprobe on PATH
    local tc = mp.get_property("metadata/by-key/timecode")
    if (not tc or tc == "") and kv.tc and kv.tc ~= "" then tc = kv.tc end
    if (not tc or tc == "") and is_local and not next(kv) then
        local out = run({"ffprobe", "-v", "error",
            "-show_entries", "format_tags=timecode:stream_tags=timecode",
            "-of", "default=noprint_wrappers=1:nokey=1", path})
        tc = out and out:match("(%d+[:;.]%d+[:;.]%d+[:;.]%d+)")
    end
    if tc and tc ~= "" and clip.fps and clip.label ~= "SRC" then
        local n = tc_to_frames(tc:match("(%d+[:;.]%d+[:;.]%d+[:;.]%d+)") or "", r(clip.fps))
        if n then
            clip.base, clip.label, clip.drop = n, "SRC", tc:find(";") ~= nil
        end
    end

    -- codec name
    local fmt, prof, com = kv.format or "", kv.profile or "", kv.commercial or ""
    if com ~= "" and com ~= fmt then
        clip.codec = com
    elseif fmt == "ProRes" and prof ~= "" then
        clip.codec = "ProRes " .. prof
    elseif fmt ~= "" then
        clip.codec = ({AVC = "H.264", HEVC = "H.265"})[fmt] or fmt
    else
        local vf = mp.get_property("video-format") or "?"
        clip.codec = vf:upper()
    end
    if kv.bitdepth and kv.bitdepth ~= "" and not clip.codec:find("ProRes") then
        clip.codec = clip.codec .. " " .. kv.bitdepth .. "-bit"
    end

    -- proxy timecode should match the RAW; flag it if not
    if clip.proxy and clip.raw_tc and clip.fps then
        local rn = tc_to_frames(clip.raw_tc:match("(%d+[:;.]%d+[:;.]%d+[:;.]%d+)") or "", r(clip.fps))
        if rn and (clip.label ~= "SRC" or rn ~= clip.base) then
            clip.tc_mismatch = true
            -- the RAW's timecode is the reference
            clip.base, clip.label = rn, "SRC"
        end
    end
end

-- ---------------------------------------------------------------- layout
local function layout()
    local d = mp.get_property_native("osd-dimensions") or {}
    W, H = d.w or 0, d.h or 0
    S = mp.get_property_number("display-hidpi-scale") or 1
    if S <= 0 then S = 1 end
    if W <= 0 or H <= 0 then return end

    L.top_h = r(30 * S)
    L.bot_h = r(74 * S)
    L.pad = r(12 * S)
    L.fs = r(17 * S)
    L.fs_small = r(15 * S)
    L.top = {0, 0, W, L.top_h}
    -- clickable timecode area (label + timecode) in the top bar
    L.tcbox = {0, 0, L.pad + r(200 * S), L.top_h}
    L.bot = {0, H - L.bot_h, W, H}

    -- scrub bar (click area) and its drawn track
    local sy0 = H - L.bot_h + r(6 * S)
    L.scrub = {L.pad, sy0, W - L.pad, sy0 + r(24 * S)}
    L.track_y = {sy0 + r(9 * S), sy0 + r(15 * S)}

    -- buttons
    local bw, bh = r(42 * S), r(30 * S)
    local by1 = H - r(8 * S)
    local by0 = by1 - bh
    local names = {"start", "back", "rev", "play", "fwd", "step", "end"}
    local x = r(W / 2 - bw * #names / 2)
    L.buttons = {}
    for i, n in ipairs(names) do
        L.buttons[i] = {name = n, box = {x, by0, x + bw, by1}}
        x = x + bw
    end
    L.row2_cy = r((by0 + by1) / 2)

    -- MediaInfo side panel
    L.panel_w = math.min(r(600 * S), math.floor(W * 0.5))
    L.panel = {W - L.panel_w, L.top_h, W, H - L.bot_h}
    L.pfs = r(14 * S)
    L.plh = r(L.pfs * 1.25)
    panel.page = math.max(1, math.floor((L.panel[4] - L.panel[2] - 2 * L.pad - L.plh) / L.plh))
end

local function apply_margins()
    if W <= 0 or H <= 0 then return end
    local t, b = L.top_h / H, L.bot_h / H
    local rr = panel.open and (L.panel_w / W) or 0
    if math.abs(t - margins.t) > 1e-4 then mp.set_property_number("video-margin-ratio-top", t); margins.t = t end
    if math.abs(b - margins.b) > 1e-4 then mp.set_property_number("video-margin-ratio-bottom", b); margins.b = b end
    if math.abs(rr - margins.r) > 1e-4 then mp.set_property_number("video-margin-ratio-right", rr); margins.r = rr end
end

-- ---------------------------------------------------------------- icons
local function icon(name, cx, cy, col)
    local u = S
    local h = r(7 * u)  -- half height
    local function tl(x0, x1) return string.format("m %d %d l %d %d l %d %d ", r(x1), cy - h, r(x0), cy, r(x1), cy + h) end
    local function tr(x0, x1) return string.format("m %d %d l %d %d l %d %d ", r(x0), cy - h, r(x1), cy, r(x0), cy + h) end
    local function bar(x0, x1) return string.format("m %d %d l %d %d l %d %d l %d %d ", r(x0), cy - h, r(x1), cy - h, r(x1), cy + h, r(x0), cy + h) end
    local p
    if name == "start" then p = bar(cx - 8*u, cx - 6*u) .. tl(cx - 6*u, cx + 7*u)
    elseif name == "back" then p = tl(cx - 7*u, cx + 3*u) .. bar(cx + 4*u, cx + 6*u)
    elseif name == "rev" then p = tl(cx - 10*u, cx) .. tl(cx, cx + 10*u)
    elseif name == "play" then p = tr(cx - 6*u, cx + 8*u)
    elseif name == "pause" then p = bar(cx - 6*u, cx - 2*u) .. bar(cx + 2*u, cx + 6*u)
    elseif name == "fwd" then p = tr(cx - 10*u, cx) .. tr(cx, cx + 10*u)
    elseif name == "step" then p = bar(cx - 6*u, cx - 4*u) .. tr(cx - 3*u, cx + 7*u)
    elseif name == "end" then p = tr(cx - 7*u, cx + 6*u) .. bar(cx + 6*u, cx + 8*u)
    end
    return shape(p, col)
end

-- ---------------------------------------------------------------- render
local function render()
    layout()
    if W <= 0 or H <= 0 then return end
    apply_margins()

    local ev = {}
    local function add(s) ev[#ev + 1] = s end

    local pos = mp.get_property_number("time-pos")
    local dur = mp.get_property_number("duration")
    local paused = mp.get_property_bool("pause")
    local speed = mp.get_property_number("speed") or 1
    local backward = mp.get_property("play-direction") == "backward"
    local loaded = clip.loaded and pos ~= nil
    local f = clip.fps
    local rate = f and r(f) or 25

    -- ---------- top bar
    add(rect(0, 0, W, L.top_h, C.bar))
    add(rect(0, L.top_h - 1, W, L.top_h, C.sep))
    local cy = r(L.top_h / 2)
    if loaded and f then
        local frame = r(pos * f)
        local last = dur and (r(dur * f) - 1) or nil
        if in_box(L.tcbox, mouse.x, mouse.y) then
            add(rect(L.tcbox[1], L.tcbox[2], L.tcbox[3], L.tcbox[4] - 1, C.hover))
        end
        add(text(L.pad, cy, 4, L.fs, tc_overridden() and C.accent or C.dim, tc_label()))
        add(text(L.pad + r(42 * S), cy, 4, L.fs, C.text,
            frames_to_tc(tc_base() + frame, rate, clip.drop) .. (clip.drop and " DF" or "")))
        if clip.audio_only then
            add(text(L.pad + r(220 * S), cy, 4, L.fs, C.dim,
                string.format("TC @ %d fps", AUDIO_TC_FPS)))
        else
            add(text(L.pad + r(220 * S), cy, 4, L.fs, C.dim,
                string.format("F %d%s", frame, last and (" / " .. last) or "")))
        end

        if clip.proxy then
            add(text(L.pad + r(400 * S), cy, 4, L.fs, C.accent,
                "PROXY" .. (clip.tc_mismatch and "   TC differs from RAW" or "")))
        end

        local w, h = mp.get_property_number("width"), mp.get_property_number("height")
        local res = (w and h) and string.format("%d\195\151%d", w, h) or ""
        local right = table.concat({res, fmt_fps(f), clip.codec or "", audio_summary()}, "    ")
        if clip.audio_only then
            add(text(W - L.pad, cy, 6, L.fs, C.text, "AUDIO    " .. audio_details()))
        elseif clip.proxy then
            -- RAW resolution in full brightness, then the proxy's own details dimmed
            local raw = (clip.raw_w and clip.raw_h)
                and string.format("RAW %d\195\151%d", clip.raw_w, clip.raw_h) or "RAW"
            add(string.format("{\\an6\\pos(%d,%d)\\fn%s\\fs%d\\bord0\\shad0\\1c%s}%s{\\1c%s}    proxy %s",
                W - L.pad, cy, FONT, L.fs, C.text, esc(raw), C.dim, esc(right)))
        else
            add(text(W - L.pad, cy, 6, L.fs, C.text, right))
        end
    elseif notice then
        add(text(L.pad, cy, 4, L.fs, C.accent, notice))
    else
        add(text(L.pad, cy, 4, L.fs, C.dim, mp.get_property_bool("idle-active")
            and "No file  -  drop a clip on the window" or "Loading..."))
    end

    -- ---------- bottom bar
    add(rect(0, H - L.bot_h, W, H, C.bar))
    add(rect(0, H - L.bot_h, W, H - L.bot_h + 1, C.sep))

    local x0, x1 = L.scrub[1], L.scrub[3]
    local ty0, ty1 = L.track_y[1], L.track_y[2]
    add(rect(x0, ty0, x1, ty1, C.track))
    if loaded and dur and dur > 0 then
        local px = x0 + r((x1 - x0) * math.min(1, math.max(0, pos / dur)))
        add(rect(x0, ty0, px, ty1, C.played))
        add(rect(px - r(1 * S), L.scrub[2] + r(2 * S), px + r(1 * S) + 1, L.scrub[4] - r(2 * S), C.accent))
        -- hover position on the scrub bar: marker on the bar, timecode in the row below
        if not drag and in_box(L.scrub, mouse.x, mouse.y) and f then
            local hf = r(math.min(1, math.max(0, (mouse.x - x0) / (x1 - x0))) * dur * f)
            add(rect(mouse.x, ty0 - r(3 * S), mouse.x + 1, ty1 + r(3 * S), C.text))
            add(text(L.pad + r(130 * S), L.row2_cy, 4, L.fs, C.text,
                "> " .. frames_to_tc(tc_base() + hf, rate, clip.drop)))
        end
    end

    -- buttons
    for _, b in ipairs(L.buttons) do
        local bx = b.box
        local active = (b.name == "rev" and not paused and backward)
                    or (b.name == "fwd" and not paused and not backward and speed > 1)
        if in_box(bx, mouse.x, mouse.y) then add(rect(bx[1], bx[2], bx[3], bx[4], C.hover)) end
        local name = b.name
        if name == "play" and not paused then name = "pause" end
        add(icon(name, r((bx[1] + bx[3]) / 2), L.row2_cy, active and C.accent or C.text))
    end

    -- shuttle state (left) and duration (right)
    local state
    if not loaded then state = ""
    elseif paused then state = "PAUSED"
    else state = string.format("%s %gx", backward and "REV" or "PLAY", speed) end
    add(text(L.pad, L.row2_cy, 4, L.fs, (loaded and not paused) and C.accent or C.dim, state))
    if loaded and dur and f then
        add(text(W - L.pad, L.row2_cy, 6, L.fs, C.dim,
            "DUR " .. frames_to_tc(r(dur * f), rate, clip.drop)))
    end

    -- ---------- MediaInfo panel
    if panel.open then
        local p = L.panel
        add(rect(p[1], p[2], p[3], p[4], C.panel))
        add(rect(p[1], p[2], p[1] + 1, p[4], C.sep))
        local last = math.min(#panel.lines, panel.top + panel.page - 1)
        local y = p[2] + L.pad
        local clipr = {p[1] + L.pad, p[2], p[3] - L.pad, p[4]}
        -- "Name     : value" lines are drawn as two columns so they align with any font
        local vx = p[1] + L.pad + r((L.panel_w - 2 * L.pad) * 0.42)
        local name_clip = {p[1] + L.pad, p[2], vx - r(8 * S), p[4]}
        for i = panel.top, last do
            local line = panel.lines[i]
            local name, val = line:match("^(.-)%s*:%s(.*)$")
            if name and name ~= "" then
                add(text(p[1] + L.pad, y, 7, L.pfs, C.dim, name, name_clip))
                add(text(vx, y, 7, L.pfs, C.text, val, clipr))
            else
                add(text(p[1] + L.pad, y, 7, L.pfs, C.accent, line, clipr))  -- section header
            end
            y = y + L.plh
        end
        add(text(p[1] + L.pad, p[4] - L.pad, 1, L.pfs, C.dim,
            string.format("%d-%d of %d   wheel / Up Down PgUp PgDn   M or Esc closes",
                panel.top, last, #panel.lines), clipr))
    end

    ov.res_x, ov.res_y = W, H
    ov.data = table.concat(ev, "\n")
    ov:update()
end

-- ---------------------------------------------------------------- MediaInfo panel
local function panel_scroll(d)
    local maxtop = math.max(1, #panel.lines - panel.page + 1)
    panel.top = math.max(1, math.min(panel.top + d, maxtop))
    render()
end

local panel_keys = {
    {"UP", function() panel_scroll(-1) end},
    {"DOWN", function() panel_scroll(1) end},
    {"PGUP", function() panel_scroll(-panel.page) end},
    {"PGDWN", function() panel_scroll(panel.page) end},
    {"HOME", function() panel_scroll(-1e6) end},
    {"END", function() panel_scroll(1e6) end},
}

local function panel_close()
    if not panel.open then return end
    panel.open = false
    for i in ipairs(panel_keys) do mp.remove_key_binding("ui-panel-" .. i) end
    mp.remove_key_binding("ui-panel-esc")
    render()
end

local function panel_open()
    local path = proxy.file or mp.get_property("path")
    if not path then return end
    local out = run({helper_path(), "report", path}) or run({"mediainfo", path})
    if not out then
        out = run({"ffprobe", "-v", "error", "-hide_banner", "-show_format", "-show_streams", path})
    end
    if out and proxy.raw then
        -- proxy first, then the RAW original
        local raw = run({helper_path(), "report", proxy.raw})
        out = "PROXY\n" .. out .. "\n\nRAW ORIGINAL\n" .. (raw or "(MediaInfo could not read the RAW file)")
    end
    out = out or "No media info available (mi-helper / mediainfo / ffprobe not found)."
    panel.lines = {}
    for l in (out .. "\n"):gmatch("(.-)\r?\n") do panel.lines[#panel.lines + 1] = l end
    while #panel.lines > 0 and panel.lines[#panel.lines] == "" do panel.lines[#panel.lines] = nil end
    panel.top, panel.open = 1, true
    for i, k in ipairs(panel_keys) do
        mp.add_forced_key_binding(k[1], "ui-panel-" .. i, k[2], {repeatable = true})
    end
    mp.add_forced_key_binding("ESC", "ui-panel-esc", panel_close)
    render()
end

local function toggle_tc()
    tc_elapsed = not tc_elapsed
    render()
end
mp.add_key_binding(nil, "tc-mode", toggle_tc)

mp.add_key_binding(nil, "mediainfo", function()
    if panel.open then panel_close() else panel_open() end
end)

-- ---------------------------------------------------------------- mouse
local function seek_to_x(x)
    local dur = mp.get_property_number("duration")
    if not dur or dur <= 0 then return end
    local frac = math.min(1, math.max(0, (x - L.scrub[1]) / (L.scrub[3] - L.scrub[1])))
    mp.commandv("no-osd", "seek", frac * 100, "absolute-percent", "exact")
end

local actions = {
    start = function() mp.commandv("no-osd", "seek", 0, "absolute", "exact") end,
    back  = function() mp.command("script-binding jkl/step-back") end,
    rev   = function() mp.command("script-binding jkl/reverse") end,
    play  = function() mp.command("script-binding jkl/toggle") end,
    fwd   = function() mp.command("script-binding jkl/forward") end,
    step  = function() mp.command("script-binding jkl/step-forward") end,
    ["end"] = function() mp.commandv("no-osd", "seek", 100, "absolute-percent", "exact") end,
}

local function on_click(t)
    if t.event == "down" then
        if in_box(L.tcbox, mouse.x, mouse.y) then
            toggle_tc()
            return
        end
        if in_box(L.scrub, mouse.x, mouse.y) then
            -- jump (and drag) without changing play state: playing keeps playing
            drag = true
            seek_to_x(mouse.x)
            return
        end
        for _, b in ipairs(L.buttons) do
            if in_box(b.box, mouse.x, mouse.y) then actions[b.name]() return end
        end
    elseif t.event == "up" then
        drag = false
        render()
    end
end

local function on_wheel(d)
    if panel.open and in_box(L.panel, mouse.x, mouse.y) then
        panel_scroll(d * 3)
    elseif in_box(L.bot, mouse.x, mouse.y) or in_box(L.top, mouse.x, mouse.y) then
        mp.command(d > 0 and "script-binding jkl/step-forward" or "script-binding jkl/step-back")
    end
end

local function set_ui_bindings(on)
    if on == ui_bindings then return end
    ui_bindings = on
    if on then
        mp.add_forced_key_binding("MBTN_LEFT", "ui-click", on_click, {complex = true})
        mp.add_forced_key_binding("MBTN_LEFT_DBL", "ui-dbl", function() end)
        mp.add_forced_key_binding("WHEEL_UP", "ui-wup", function() on_wheel(-1) end)
        mp.add_forced_key_binding("WHEEL_DOWN", "ui-wdn", function() on_wheel(1) end)
    else
        for _, n in ipairs({"ui-click", "ui-dbl", "ui-wup", "ui-wdn"}) do mp.remove_key_binding(n) end
    end
end

mp.observe_property("mouse-pos", "native", function(_, m)
    if not m then return end
    mouse.x, mouse.y = m.hover == false and -1 or m.x, m.hover == false and -1 or m.y
    if drag then seek_to_x(m.x) end
    local in_ui = in_box(L.top, mouse.x, mouse.y) or in_box(L.bot, mouse.x, mouse.y)
        or (panel.open and in_box(L.panel, mouse.x, mouse.y))
    set_ui_bindings(in_ui or drag)
    render()
end)

-- ---------------------------------------------------------------- events
mp.register_event("file-loaded", function()
    if panel.open then panel_close() end
    notice = nil
    load_clip_info()
    render()
end)

mp.register_event("end-file", function(e)
    clip = {}
    if proxy.missing then
        notice = "No proxy for " .. proxy.missing .. "  -  open it in Cinema RAW Development"
    elseif e and e.reason == "error" then
        notice = "Could not play this file"
    end
    render()
end)

for _, p in ipairs({"time-pos", "pause", "speed", "play-direction", "duration",
                    "osd-dimensions", "display-hidpi-scale", "width", "height",
                    "container-fps", "track-list", "idle-active", "audio-params"}) do
    mp.observe_property(p, "native", function(name)
        if name == "container-fps" and clip.loaded then clip.fps = fps() end
        render()
    end)
end
