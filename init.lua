---------------------------------------------------------------------------
--- Retain (Dynamic EDID-based Fork)
--
-- @author Kevin Zander &lt;veratil@gmail.com&gt;
-- @copyright 2017 Kevin Zander
-- @module retain
---------------------------------------------------------------------------

local json = require("json")
local awful = require("awful")
local gfs = require("gears.filesystem")
local naughty = require("naughty")

local retain = {tags={},layout={}}

retain.debug = false
retain.tags.savefile = gfs.get_configuration_dir() .. 'retain.json'
retain.tags.defaults = {
    names={"1","2","3","4","5","6","7","8","9"},
    layouts=awful.layout.suit.floating,
}
retain.tags._mytags = {}
retain.tags._loaded = nil

local function debug(txt)
    if retain.debug then
        print("RETAIN: " .. txt)
    end
end

-- DJB2 string hash
local function hash_str(str)
    local hash = 5381
    for i = 1, #str do
        hash = ((hash * 33) + str:byte(i)) % 4294967296
    end
    return string.format("%08x", hash)
end

-- EDID Cache
local _edid_cache = nil
local _edid_cache_time = 0

local function fetch_edid_map()
    local map = {}
    local f = io.popen("xrandr --verbose 2>/dev/null")
    if not f then return map end
    
    local current_out, edid = nil, nil
    for line in f:lines() do
        local o = line:match("^([%w%-]+) connected")
        if o then
            if current_out and edid and #edid > 0 then
                map[current_out] = hash_str(edid)
            end
            current_out = o
            edid = ""
        elseif line:match("^\tEDID:") and current_out then
            -- Start of EDID block
        elseif edid and line:match("^\t\t(%x+)") then
            edid = edid .. line:match("^\t\t(%x+)")
        elseif edid and #edid > 0 and not line:match("^\t\t(%x+)") then
            map[current_out] = hash_str(edid)
            edid = nil
        end
    end
    if current_out and edid and #edid > 0 then
        map[current_out] = hash_str(edid)
    end
    f:close()
    return map
end

local function get_cached_edid_map()
    local now = os.time()
    if _edid_cache and (now - _edid_cache_time) < 5 then
        return _edid_cache
    end
    _edid_cache = fetch_edid_map()
    _edid_cache_time = now
    return _edid_cache
end

-- Generate a unique ID for a screen based on hardware EDIDs
function retain.get_screen_id(s)
    local map = get_cached_edid_map()
    
    local counts = {}
    for _, h in pairs(map) do
        counts[h] = (counts[h] or 0) + 1
    end

    local ids = {}
    for _, out in ipairs(s.outputs or {}) do
        local h = map[out]
        if h then
            if counts[h] > 1 then
                -- Disambiguate identical monitors by appending port name
                table.insert(ids, h .. "_" .. out)
            else
                table.insert(ids, h)
            end
        else
            -- Fallback if no EDID (e.g. virtual display)
            table.insert(ids, "out_" .. out)
        end
    end
    
    if #ids == 0 then return "screen_" .. tostring(s.index) end
    table.sort(ids)
    return table.concat(ids, "+")
end

-- gather the tags of a screen by screen ID
local function gatherTags(scr)
    debug("gatherTags()")
    local tbl = {}
    for i,v in ipairs(scr.tags) do
        debug(v.name .. " " .. v.layout.name)
        tbl[tostring(i)] = {name=v.name, layout=v.layout.name}
    end
    return tbl
end

-- find a layout by name
local function findLayout(name)
    debug("findLayout()")
    for _,l in ipairs(awful.layout.layouts) do
        if l.name == name then
            debug("found " .. name)
            return l
        end
    end
    return nil
end

-- convert _loaded to _mytags for a specific screen ID
local function convertLoadedTags(sid)
    debug("convertLoadedTags()")
    for tid,ttb in pairs(retain.tags._loaded[sid]) do
        local tin = tonumber(tid)
        debug("tag index " .. tid)
        debug(ttb.name .. " " .. ttb.layout)
        if not retain.tags._mytags[sid] then retain.tags._mytags[sid] = {names={},layouts={}} end
        retain.tags._mytags[sid].names[tin] = ttb.name
        retain.tags._mytags[sid].layouts[tin] = findLayout(ttb.layout)
    end
end

-- save all screens
function retain.tags.save_all()
    debug("save_all()")
    for s in screen do
        retain.tags.save(s)
    end
end

-- save tags for a specific screen
function retain.tags.save(scr)
    debug("save()")
    if not scr or type(scr) ~= "screen" then return end
    local si = retain.get_screen_id(scr)
    debug("screen id: " .. si)
    
    local tbl = gatherTags(scr)
    if not retain.tags._loaded then retain.tags._loaded = {} end
    retain.tags._loaded[si] = tbl
    convertLoadedTags(si)
    
    debug("saving file")
    local f = io.open(retain.tags.savefile, 'w')
    f:write(json.encode(retain.tags._loaded))
    f:close()
end

-- load saved tags
function retain.tags.load()
    debug("load()")
    local f = io.open(retain.tags.savefile, 'r')
    if not f then
        debug("file not found")
        naughty.notify({
            preset = naughty.config.presets.critical,
            text = "No save file found",
            title = "retain",
        })
        retain.tags._mytags = retain.tags.defaults
        return
    end
    
    if not retain.tags._loaded then
        debug("_loaded empty")
        retain.tags._loaded = json.decode(f:read("*a"))
        if not retain.tags._loaded or type(retain.tags._loaded) ~= "table" then
            debug("failed to read file")
            retain.tags._loaded = nil
            naughty.notify({
                preset = naughty.config.presets.critical,
                text = "Error in loading json, loading defaults",
                title = "retain",
            })
            retain.tags._mytags = retain.tags.defaults
            f:close()
            return
        end
    end
    f:close()

    -- Check for legacy (index-based) format
    local is_legacy = false
    for k, _ in pairs(retain.tags._loaded) do
        if tonumber(k) then is_legacy = true; break end
    end
    if is_legacy then
        naughty.notify({
            preset = naughty.config.presets.normal,
            text = "Legacy index-based save file detected.\nResetting to defaults to prevent layout corruption.",
            title = "retain",
        })
        retain.tags._loaded = {}
        retain.tags._mytags = {}
        return
    end

    for sid,stb in pairs(retain.tags._loaded) do
        retain.tags._mytags[sid] = {names={},layouts={}}
        for tid,ttb in pairs(stb) do
            local tin = tonumber(tid)
            retain.tags._mytags[sid].names[tin] = ttb.name
            retain.tags._mytags[sid].layouts[tin] = findLayout(ttb.layout)
        end
    end
end

local function getTable(scr, name)
    local s = retain.get_screen_id(scr)
    if retain.tags._mytags[s] then
        if #retain.tags._mytags[s][name] > 0 then
            return retain.tags._mytags[s][name]
        end
    end
    return retain.tags.defaults[name]
end

function retain.tags.getnames(scr)
    return getTable(scr, "names")
end

function retain.tags.getlayouts(scr)
    return getTable(scr, "layouts")
end

function retain.connect_signals()
    screen.connect_signal("removed", retain.tags.save)
    awesome.connect_signal("exit", retain.tags.save_all)
end

return retain