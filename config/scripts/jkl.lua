-- jkl.lua - JKL shuttle + frame stepping for mpv - v1.7

local speeds = {1, 2, 4, 8}
local dir = 0   -- 1 = forward, -1 = backward, 0 = stopped
local idx = 0

local function set_forward_dir()
    if mp.get_property("play-direction") == "backward" then
        mp.set_property("play-direction", "forward")
    end
end

local function stop()
    dir, idx = 0, 0
    mp.set_property_bool("pause", true)
    mp.set_property_number("speed", 1)
    set_forward_dir()
end

local function shuttle(d)
    if dir == d then
        idx = math.min(idx + 1, #speeds)
    else
        dir, idx = d, 1
    end
    local want = (d > 0) and "forward" or "backward"
    if mp.get_property("play-direction") ~= want then
        mp.set_property("play-direction", want)
    end
    mp.set_property_number("speed", speeds[idx])
    mp.set_property_bool("pause", false)
end

local function toggle()
    if mp.get_property_bool("pause") then
        dir = 0
        shuttle(1)
    else
        stop()
    end
end

-- Audio-only files (or audio with cover art) have no frames to step:
-- step by one timecode frame instead. Keep in sync with AUDIO_TC_FPS in review-ui.lua.
local AUDIO_TC_FPS = 25

local function audio_only()
    local v = mp.get_property_native("current-tracks/video")
    return v == nil or v.albumart == true
end

local function step(cmd)
    dir, idx = 0, 0
    mp.set_property_bool("pause", true)
    mp.set_property_number("speed", 1)
    set_forward_dir()
    if audio_only() then
        local d = (cmd == "frame-step") and 1 or -1
        mp.commandv("no-osd", "seek", d / AUDIO_TC_FPS, "relative+exact")
    else
        mp.command(cmd)
    end
end

-- Keep state in sync if playback is paused some other way (mouse, end of file)
mp.observe_property("pause", "bool", function(_, paused)
    if paused then dir, idx = 0, 0 end
end)

mp.register_event("file-loaded", function()
    dir, idx = 0, 0
    mp.set_property_number("speed", 1)
    set_forward_dir()
end)

mp.add_key_binding(nil, "forward", function() shuttle(1) end)
mp.add_key_binding(nil, "reverse", function() shuttle(-1) end)
mp.add_key_binding(nil, "stop", stop)
mp.add_key_binding(nil, "toggle", toggle)
mp.add_key_binding(nil, "step-forward", function() step("frame-step") end, {repeatable = true})
mp.add_key_binding(nil, "step-back", function() step("frame-back-step") end, {repeatable = true})
