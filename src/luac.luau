--[[--------------------------------------------------------------------

  luac.lua
  Primitive luac in Lua
  This file is part of Yueliang.

  Copyright (c) 2005-2007 Kein-Hong Man <khman@users.sf.net>
  The COPYRIGHT file describes the conditions
  under which this software may be distributed.

  See the ChangeLog for more information.

----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- Notes:
-- * based on luac.lua in the test directory of the 5.1.2 distribution
-- * usage: lua luac.lua file.lua
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- load and initialize the required modules
------------------------------------------------------------------------
local luaZ = require("./lzio")
local luaX = require("./llex")
local luaP = require("./lopcodes")
local luaU = require("./ldump")
local luaK = require("./lcode")
local luaY = require("./lparser")

luaX:init() -- required by llex
local LuaState = {} -- dummy, not actually used, but retained since
-- the intention is to complete a straight port

------------------------------------------------------------------------
-- interfacing to yueliang
------------------------------------------------------------------------

return function(source, name)
	name = name or "compiled-lua"
	-- luaZ:make_getF returns a file chunk reader
	-- luaZ:init returns a zio input stream
	local zio = luaZ:init(luaZ:make_getF(source), nil)
	if not zio then
		return
	end
	-- luaY:parser parses the input stream
	-- func is the function prototype in tabular form; in C, func can
	-- now be used directly by the VM, this can't be done in Lua

	local func = luaY:parser(LuaState, zio, nil, "@" .. name)
	-- luaU:make_setS returns a string chunk writer
	local writer, buff = luaU:make_setS()
	-- luaU:dump builds a binary chunk
	luaU:dump(LuaState, func, writer, buff)
	-- a string.dump equivalent in returned

	return buff.data
end
