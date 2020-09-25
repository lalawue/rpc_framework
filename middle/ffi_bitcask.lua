--
-- Copyright (c) 2020 lalawue
--
-- This library is free software; you can redistribute it and/or modify it
-- under the terms of the MIT license. See LICENSE for details.
--

--[[
    Bitcask for LuaJIT, database content structure relies on
    LuaJIT's cdef structure memory layout
]]
local FileSystem = require("base.ffi_lfs")
local CRCCore = require("middle.ffi_crc32")

local bit = require("bit")
local ffi = require("ffi")
ffi.cdef [[
    // record entry structure
    typedef struct {
        uint32_t time;      // create/modified time
        uint32_t fid;       // file id
        uint32_t offset;    // file offset
        uint32_t ksize;     // key size
        uint32_t vsize;     // value size
        uint32_t crc32;     // CRC32 for key, value
        // key content
        // value content
    } record_t;

    // hint entry structure
    typedef struct {
        uint32_t offset;    // file offset
        uint32_t ksize;     // key size
        // key content
    } hint_t;
]]

-- Internal Interface
--

-- bucket operation

--[[
    create bucket dir and insert into _buckets
]]
local function _bucketCreate(self, name)
    self._buckets[name] = {
        act_fid = 0,
        max_fid = 0,
        free_fids = {}
    }
    FileSystem.mkdir(self._config.dir .. "/" .. name)
end

--[[
    with leading '0'
]]
local function _indexString(fid)
    return string.rep("0", 10 - fid:len()) .. fid
end

--[[
    to path like 'dir/bucket/0000000000.dat'
]]
local function _fidPath(self, fid, bucket_name)
    fid = _indexString(tostring(fid))
    bucket_name = bucket_name or self._bucket_name
    return string.format("%s/%s/%s.dat", self._config.dir, bucket_name, fid)
end

--[[
    get next empty fid slot
]]
local function _nextEmptyFid(bucket_info)
    if #bucket_info.free_fids > 0 then
        bucket_info.act_fid = bucket_info.free_fids[#bucket_info.free_fids]
        table.remove(bucket_info.free_fids)
    else
        bucket_info.act_fid = bucket_info.max_fid + 1
        bucket_info.max_fid = bucket_info.act_fid
    end
    return bucket_info.act_fid
end

--[[
    return active file id, file offset
]]
local function _activeFid(self, bucket_name)
    bucket_name = bucket_name or self._bucket_name
    local bucket_info = self._buckets[bucket_name]
    local act_fid = bucket_info.act_fid
    local offset = 0
    while true do
        local attr = FileSystem.attributes(_fidPath(self, act_fid, bucket_name))
        if attr then
            if attr.size >= self._config.file_size then
                if act_fid ~= bucket_info.max_fid then
                    act_fid = bucket_info.max_fid
                else
                    act_fid = _nextEmptyFid(bucket_info)
                end
            else
                offset = attr.size
                bucket_info.act_fid = act_fid
                break
            end
        else
            break
        end
    end
    return act_fid, offset
end

-- key/value operation

--[[
    content can be string or record_t
]]
local function _newRecord(content)
    local record = ffi.new("record_t")
    if record ~= nil and content then
        if type(content) == "string" then
            ffi.copy(record, content, content:len())
        else
            record.time = content.time
            record.fid = content.fid
            record.offset = content.offset
            record.ksize = content.ksize
            record.vsize = content.vsize
            record.crc32 = content.crc32
        end
    end
    return record
end

local _rsize = ffi.sizeof("record_t")
local _record = ffi.new("record_t")

--[[
    read one record, skip to next record
]]
local function _readRecord(fp, new_record, read_value)
    local content = fp:read(_rsize)
    if content == nil then
        return nil
    end
    local record = _record
    if new_record then
        record = _newRecord(content)
    else
        ffi.copy(record, content, content:len())
    end
    local key = fp:read(record.ksize)
    local value = nil
    if read_value then
        value = fp:read(record.vsize)
    elseif record.vsize > 0 then
        fp:seek("cur", record.vsize)
    end
    return record, key, value
end

--[[
    path may be real fp
]]
local function _writeRecord(path, record, key, value)
    local fp = io.open(path, "ab+")
    if not fp then
        return false
    end
    fp:write(ffi.string(record, ffi.sizeof("record_t")))
    fp:write(key)
    if value then
        fp:write(value)
    end
    fp:close()
    return true
end

--[[
    load db bucket dir to memory structure _buckets, default active '0'
]]
local function _loadBucketsInfo(self)
    local path = self._config.dir
    for dname in FileSystem.dir(path) do
        local dpath = path .. "/" .. dname
        local dattr = FileSystem.attributes(dpath)
        if dattr and dattr.mode == "directory" and dname:sub(1, 1) ~= "." then
            local max_fid = 0
            for fname in FileSystem.dir(dpath) do
                local fpath = dpath .. "/" .. fname
                local fattr = FileSystem.attributes(fpath)
                if fattr and fattr.mode == "file" then
                    local fid = tonumber(fname:sub(1, fname:len() - 4))
                    if fid > max_fid then
                        max_fid = fid
                    end
                end
            end
            -- current bucket active fid
            _bucketCreate(self, dname)
            self._buckets[dname].max_fid = max_fid
        end
    end
    if next(self._buckets) == nil then
        _bucketCreate(self, self._bucket_name)
    end
end

--[[
    load key info
]]
local function _loadKeysInfo(self)
    for _, bucket_info in pairs(self._buckets) do
        local max_fid = bucket_info.max_fid
        for fid = 0, max_fid, 1 do
            local fp = io.open(_fidPath(self, fid), "rb")
            while fp do
                local record, key = _readRecord(fp, true, false)
                if record then
                    if record.vsize > 0 then
                        self._kinfo[key] = record
                    else
                        self._kinfo[key] = nil
                    end
                else
                    fp:close()
                    break
                end
            end
            if not fp and fid < bucket_info.max_fid then
                table.insert(bucket_info.free_fids, fid)
            end
        end
        bucket_info.act_fid = _activeFid(self)
    end
end

-- Public Interface
--

local _M = {}
_M.__index = _M

--[[
    config should be {
        dir = "/path/to/store/data",
        file_size = "data file size",
    }
]]
function _M.opendb(config)
    if not config or type(config.dir) ~= "string" then
        return nil
    end
    FileSystem.mkdir(config.dir)
    local ins = setmetatable({}, _M)
    ins._config = {}
    ins._config.dir = config.dir
    ins._config.file_size = config.file_size or (64 * 1024 * 1024) -- 64M default
    ins._bucket_name = "0"
    ins._buckets = {}
    ins._kinfo = {}
    ins._rminfo = {}
    --[[
        ins structure as
        {
            _config = {
                dir,                    -- db dir
                max_file_size           -- db max file size, keep key/value in one entry in priority
            },
            _bucket_name = '0',         -- db active bucket name
            _buckets = {
                [name] = {
                    act_fid,            -- active file id in bucket
                    max_fid,            -- max file id in bucket
                    free_fids = {       -- free fid slot after delete entries
                    }
                }
            },
            _kinfo = {                  -- record_t map with key index
                [key] = record_t
            }
        }
    ]]
    _loadBucketsInfo(ins)
    _loadKeysInfo(ins)
    return ins
end

--[[
    list all bucket names
]]
function _M:allBuckets()
    local tbl = {}
    for name, _ in pairs(self._buckets) do
        tbl[#tbl + 1] = name
    end
    return tbl
end

--[[
    change to bucket, if bucket not exist, create it
]]
function _M:changeBucket(name)
    if type(name) ~= "string" or name:len() <= 0 then
        return false
    end
    if self._buckets[name] == nil then
        _bucketCreate(self, name)
    end
    self._bucket_name = name
    return true
end

--[[
    list all key names
]]
function _M:allKeys()
    local tbl = {}
    for name, _ in pairs(self._kinfo) do
        tbl[#tbl + 1] = name
    end
    return tbl
end

--[[
    set key value to active bucket
]]
function _M:set(key, value)
    if type(key) ~= "string" or type(value) ~= "string" or key:len() <= 0 or value:len() <= 0 then
        return false
    end
    local record = self._kinfo[key]
    if record ~= nil then
        -- check original value
        local fp = io.open(_fidPath(self, record.fid), "rb")
        if fp then
            fp:seek("set", record.offset + ffi.sizeof("record_t") + record.ksize)
            local nvalue = fp:read(record.vsize)
            fp:close()
            if nvalue == value then
                -- same value
                return true
            end
        end
        -- remove origin record
        record.vsize = 0 -- means to be delete
        local fid = _activeFid(self) -- append to active fid
        if not _writeRecord(_fidPath(self, fid), record, key, nil) then
            return false
        end
    end
    -- create new record
    record = _newRecord()
    record.time = os.time()
    record.ksize = key:len()
    record.vsize = value:len()
    record.fid, record.offset = _activeFid(self)
    record.crc32 = CRCCore.update(0, key .. value)
    self._kinfo[key] = record
    -- write to dat file
    if not _writeRecord(_fidPath(self, record.fid), record, key, value) then
        return false
    end
    return true
end

function _M:get(key)
    if type(key) ~= "string" or key:len() <= 0 then
        return nil
    end
    local record = self._kinfo[key]
    if record == nil then
        return nil
    end
    local fp = io.open(_fidPath(self, record.fid), "rb")
    if not fp then
        return nil
    end
    fp:seek("set", record.offset)
    local _, nkey, nvalue = _readRecord(fp, false, true)
    fp:close()
    if nkey == key and bit.tobit(record.crc32) == CRCCore.update(0, nkey .. nvalue) then
        return nvalue
    else
        return nil
    end
end

function _M:remove(key)
    if type(key) ~= "string" or key:len() <= 0 then
        return false
    end
    local record = self._kinfo[key]
    if record == nil then
        return false
    end
    self._kinfo[key] = nil
    record.vsize = 0 -- means to be delete
    local fid = _activeFid(self) -- append to active fid
    if not _writeRecord(_fidPath(self, fid), record, key, nil) then
        return false
    end
    return true
end

-- garbage collection

--[[
    remove deleted record in buckets dat files
]]
function _M:gc(bucket_name)
    if type(bucket_name) ~= "string" then
        return false
    end
    local bucket_info = self._buckets[bucket_name]
    if bucket_info == nil then
        return false
    end
    -- collect rm record entries, include old entry and rm entry
    local rm_tbl = {}
    for fid = 0, bucket_info.max_fid, 1 do
        local fp = io.open(_fidPath(self, fid, bucket_name), "rb")
        while fp do
            local rm_record = _readRecord(fp, true, false)
            if not rm_record then
                fp:close()
                break
            elseif rm_record.vsize == 0 then
                -- insert origin record
                local sfid = tostring(rm_record.fid)
                if not rm_tbl[sfid] then
                    rm_tbl[sfid] = {}
                end
                table.insert(rm_tbl[sfid], _newRecord(rm_record))
                -- insert rm record in realy place
                sfid = tostring(fid)
                if not rm_tbl[sfid] then
                    rm_tbl[sfid] = {}
                end
                rm_record.fid = fid -- rm record realy fid
                rm_record.offset = fp:seek("cur") - _rsize - rm_record.ksize - rm_record.vsize
                table.insert(rm_tbl[sfid], rm_record)
            end
        end
    end
    -- if no delete entry
    if next(rm_tbl) == nil then
        return true
    end
    -- check in rm_tbl with realy fid, offset
    local function _inTbl(rm_tbl, fid, offset)
        for i, r in ipairs(rm_tbl) do
            if r.fid == fid and r.offset == offset then
                table.remove(rm_tbl, i)
                return true
            end
        end
        return false
    end
    -- merge origin fid, first increase act_fid
    _nextEmptyFid(bucket_info)
    for sfid, tbl in pairs(rm_tbl) do
        local in_fid = tonumber(sfid)
        local in_path = _fidPath(self, in_fid, bucket_name)
        local in_fp = io.open(in_path, "rb")
        local has_skip = false
        while in_fp do
            local in_offset = in_fp:seek("cur")
            local in_record, in_key, in_value = _readRecord(in_fp, true, true)
            if not in_record then
                break
            elseif _inTbl(tbl, in_fid, in_offset) then
                -- has deleted entry, remove original fid file
                has_skip = true
            elseif in_record.vsize > 0 then
                -- update kinfo
                in_record.fid, in_record.offset = _activeFid(self, bucket_name)
                self._kinfo[in_key] = in_record
                -- write to file
                local out_path = _fidPath(self, in_record.fid, bucket_name)
                _writeRecord(out_path, in_record, in_key, in_value)
            end
        end
        in_fp:close()
        if has_skip then
            os.remove(in_path)
        end
        table.insert(bucket_info.free_fids, in_fid)
    end
    return true
end

return _M
