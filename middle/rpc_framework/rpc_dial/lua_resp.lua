--
-- Copyright (c) 2020 lalawue
--
-- This library is free software; you can redistribute it and/or modify it
-- under the terms of the MIT license. See LICENSE for details.
--

local Resp = require("resp")
local Log = require("middle.logger").newLogger("[Redis]", "error")

local Dial = {
    _info = nil,
    _data = nil -- support only one arg
}
Dial.__index = Dial

-- set arg only once
function Dial.newRequest(rpc_info, rpc_opt, rpc_args, rpc_body)
    if rpc_info then
        local self = setmetatable({}, Dial)
        self._info = rpc_info
        self._data = rpc_args or rpc_body
        assert(type(self._data) == "table", "Only support table")
        return self
    end
end

function Dial.newResponse(rpc_info, rpc_opt, rpc_body)
    if rpc_info then
        local self = setmetatable({}, Dial)
        self._info = rpc_info
        self._data = rpc_body
        assert(type(self._data) == "table", "Only support table")
        return self
    end
end

function Dial:makePackage()
    if not self._data or #self._data <= 0 then
        Log:error("Invalid data")
        return
    end
    local msg = Resp.encode(unpack(self._data))
    self._data = nil
    return msg
end

return Dial
