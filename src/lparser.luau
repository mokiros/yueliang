--[[--------------------------------------------------------------------

  lparser.lua
  Lua 5 parser in Lua
  This file is part of Yueliang.

  Copyright (c) 2005-2007 Kein-Hong Man <khman@users.sf.net>
  The COPYRIGHT file describes the conditions
  under which this software may be distributed.

  See the ChangeLog for more information.

----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- Notes:
-- * some unused C code that were not converted are kept as comments
-- * LUA_COMPAT_VARARG option changed into a comment block
-- * for value/size specific code added, look for 'NOTE: '
--
-- Not implemented:
-- * luaX_newstring not needed by this Lua implementation
-- * luaG_checkcode() in assert is not currently implemented
--
-- Added:
-- * some constants added from various header files
-- * luaY.LUA_QS used in error_expected, check_match (from luaconf.h)
-- * luaY.LUA_QL needed for error messages (from luaconf.h)
-- * luaY.growvector (from lmem.h) -- skeleton only, limit checking
-- * luaY.SHRT_MAX (from <limits.h>) for registerlocalvar
-- * luaY.newproto (from lfunc.c)
-- * luaY.int2fb (from lobject.c)
-- * NOTE: HASARG_MASK, for implementing a VARARG_HASARG bit operation
-- * NOTE: value-specific code for VARARG_NEEDSARG to replace a bitop
--
-- Changed in 5.1.x:
-- * various code changes are not detailed...
-- * names of constants may have changed, e.g. added a LUAI_ prefix
-- * struct expkind: added VKNUM, VVARARG; VCALL's info changed?
-- * struct expdesc: added nval
-- * struct FuncState: upvalues data type changed to upvaldesc
-- * macro hasmultret is new
-- * function checklimit moved to parser from lexer
-- * functions anchor_token, errorlimit, checknext are new
-- * checknext is new, equivalent to 5.0.x's check, see check too
-- * luaY.next and luaY.lookahead moved to lexer
-- * break keyword no longer skipped in luaY.breakstat
-- * function new_localvarstr replaced by new_localvarliteral
-- * registerlocalvar limits local variables to SHRT_MAX
-- * create_local deleted, new_localvarliteral used instead
-- * constant LUAI_MAXUPVALUES increased to 60
-- * constants MAXPARAMS, LUA_MAXPARSERLEVEL, MAXSTACK removed
-- * function interface changed: singlevaraux, singlevar
-- * enterlevel and leavelevel uses nCcalls to track call depth
-- * added a name argument to main entry function, luaY.parser
-- * function luaY_index changed to yindex
-- * luaY.int2fb()'s table size encoding format has been changed
-- * luaY.log2() no longer needed for table constructors
-- * function code_params deleted, functionality folded in parlist
-- * vararg flags handling (is_vararg) changes; also see VARARG_*
-- * LUA_COMPATUPSYNTAX section for old-style upvalues removed
-- * repeatstat() calls chunk() instead of block()
-- * function interface changed: cond, test_then_block
-- * while statement implementation considerably simplified; MAXEXPWHILE
--   and EXTRAEXP no longer required, no limits to the complexity of a
--   while condition
-- * repeat, forbody statement implementation has major changes,
--   mostly due to new scoping behaviour of local variables
-- * OPR_MULT renamed to OPR_MUL
----------------------------------------------------------------------]]

--requires luaP, luaX, luaK
local luaX = require("./llex")
local luaP = require("./lopcodes")
local luaK = require("./lcode")

local luaY = {}

--[[--------------------------------------------------------------------
-- Expression descriptor
-- * expkind changed to string constants; luaY.assignment was the only
--   function to use a relational operator with this enumeration
-- VVOID       -- no value
-- VNIL        -- no value
-- VTRUE       -- no value
-- VFALSE      -- no value
-- VK          -- info = index of constant in 'k'
-- VKNUM       -- nval = numerical value
-- VLOCAL      -- info = local register
-- VUPVAL,     -- info = index of upvalue in 'upvalues'
-- VGLOBAL     -- info = index of table; aux = index of global name in 'k'
-- VINDEXED    -- info = table register; aux = index register (or 'k')
-- VJMP        -- info = instruction pc
-- VRELOCABLE  -- info = instruction pc
-- VNONRELOC   -- info = result register
-- VCALL       -- info = instruction pc
-- VVARARG     -- info = instruction pc
} ----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- * expdesc in Lua 5.1.x has a union u and another struct s; this Lua
--   implementation ignores all instances of u and s usage
-- struct expdesc:
--   k  -- (enum: expkind)
--   info, aux -- (int, int)
--   nval -- (lua_Number)
--   t  -- patch list of 'exit when true'
--   f  -- patch list of 'exit when false'
----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- struct upvaldesc:
--   k  -- (lu_byte)
--   info -- (lu_byte)
----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- state needed to generate code for a given function
-- struct FuncState:
--   f  -- current function header (table: Proto)
--   h  -- table to find (and reuse) elements in 'k' (table: Table)
--   prev  -- enclosing function (table: FuncState)
--   ls  -- lexical state (table: LexState)
--   L  -- copy of the Lua state (table: lua_State)
--   bl  -- chain of current blocks (table: BlockCnt)
--   pc  -- next position to code (equivalent to 'ncode')
--   lasttarget   -- 'pc' of last 'jump target'
--   jpc  -- list of pending jumps to 'pc'
--   freereg  -- first free register
--   nk  -- number of elements in 'k'
--   np  -- number of elements in 'p'
--   nlocvars  -- number of elements in 'locvars'
--   nactvar  -- number of active local variables
--   upvalues[LUAI_MAXUPVALUES]  -- upvalues (table: upvaldesc)
--   actvar[LUAI_MAXVARS]  -- declared-variable stack
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- constants used by parser
-- * picks up duplicate values from luaX if required
------------------------------------------------------------------------
luaY.LUA_QS = luaX.LUA_QS or "'%s'" -- (from luaconf.h)

luaY.SHRT_MAX = 32767 -- (from <limits.h>)
luaY.LUAI_MAXVARS = 200 -- (luaconf.h)
luaY.LUAI_MAXUPVALUES = 60 -- (luaconf.h)
luaY.MAX_INT = luaX.MAX_INT or 2147483645 -- (from llimits.h)
-- * INT_MAX-2 for 32-bit systems
luaY.LUAI_MAXCCALLS = 200 -- (from luaconf.h)

luaY.VARARG_HASARG = 1 -- (from lobject.h)
-- NOTE: HASARG_MASK is value-specific
luaY.HASARG_MASK = 2 -- this was added for a bitop in parlist()
luaY.VARARG_ISVARARG = 2
-- NOTE: there is some value-specific code that involves VARARG_NEEDSARG
luaY.VARARG_NEEDSARG = 4

luaY.LUA_MULTRET = -1 -- (lua.h)

--[[--------------------------------------------------------------------
-- other functions
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- LUA_QL describes how error messages quote program elements.
-- CHANGE it if you want a different appearance. (from luaconf.h)
------------------------------------------------------------------------
function luaY.LUA_QL(x)
	return "'" .. x .. "'"
end

------------------------------------------------------------------------
-- this is a stripped-down luaM_growvector (from lmem.h) which is a
-- macro based on luaM_growaux (in lmem.c); all the following does is
-- reproduce the size limit checking logic of the original function
-- so that error behaviour is identical; all arguments preserved for
-- convenience, even those which are unused
-- * set the t field to nil, since this originally does a sizeof(t)
-- * size (originally a pointer) is never updated, their final values
--   are set by luaY.close_func(), so overall things should still work
------------------------------------------------------------------------
function luaY.growvector(L, v, nelems, size, t, limit, e)
	if nelems >= limit then
		error(e) -- was luaG_runerror
	end
end

------------------------------------------------------------------------
-- initialize a new function prototype structure (from lfunc.c)
-- * used only in open_func()
------------------------------------------------------------------------
function luaY.newproto(L)
	local f = {} -- Proto
	-- luaC_link(L, obj2gco(f), LUA_TPROTO); /* GC */
	f.k = {}
	f.sizek = 0
	f.p = {}
	f.sizep = 0
	f.code = {}
	f.sizecode = 0
	f.sizelineinfo = 0
	f.sizeupvalues = 0
	f.nups = 0
	f.upvalues = {}
	f.numparams = 0
	f.is_vararg = 0
	f.maxstacksize = 0
	f.lineinfo = {}
	f.sizelocvars = 0
	f.locvars = {}
	f.lineDefined = 0
	f.lastlinedefined = 0
	f.source = nil
	return f
end

------------------------------------------------------------------------
-- converts an integer to a "floating point byte", represented as
-- (eeeeexxx), where the real value is (1xxx) * 2^(eeeee - 1) if
-- eeeee != 0 and (xxx) otherwise.
------------------------------------------------------------------------
function luaY.int2fb(x)
	local e = 0 -- exponent
	while x >= 16 do
		x = math.floor((x + 1) / 2)
		e = e + 1
	end
	if x < 8 then
		return x
	else
		return ((e + 1) * 8) + (x - 8)
	end
end

--[[--------------------------------------------------------------------
-- parser functions
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- true of the kind of expression produces multiple return values
------------------------------------------------------------------------
function luaY.hasmultret(k)
	return k == "VCALL" or k == "VVARARG"
end

------------------------------------------------------------------------
-- convenience function to access active local i, returns entry
------------------------------------------------------------------------
function luaY.getlocvar(fs, i)
	return fs.f.locvars[fs.actvar[i]]
end

------------------------------------------------------------------------
-- check a limit, string m provided as an error message
------------------------------------------------------------------------
function luaY.checklimit(fs, v, l, m)
	if v > l then
		luaY.errorlimit(fs, l, m)
	end
end

--[[--------------------------------------------------------------------
-- nodes for block list (list of active blocks)
-- struct BlockCnt:
--   previous  -- chain (table: BlockCnt)
--   breaklist  -- list of jumps out of this loop
--   nactvar  -- # active local variables outside the breakable structure
--   upval  -- true if some variable in the block is an upvalue (boolean)
--   isbreakable  -- true if 'block' is a loop (boolean)
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- prototypes for recursive non-terminal functions
------------------------------------------------------------------------
-- prototypes deleted; not required in Lua

------------------------------------------------------------------------
-- reanchor if last token is has a constant string, see close_func()
-- * used only in close_func()
------------------------------------------------------------------------
function luaY.anchor_token(ls)
	if ls.t.token == "TK_NAME" or ls.t.token == "TK_STRING" then
		-- not relevant to Lua implementation of parser
		-- local ts = ls.t.seminfo
		-- luaX_newstring(ls, getstr(ts), ts->tsv.len); /* C */
	end
end

------------------------------------------------------------------------
-- throws a syntax error if token expected is not there
------------------------------------------------------------------------
function luaY.error_expected(ls, token)
	luaX.syntaxerror(ls, string.format(luaY.LUA_QS .. " expected", luaX.token2str(ls, token)))
end

------------------------------------------------------------------------
-- prepares error message for display, for limits exceeded
-- * used only in checklimit()
------------------------------------------------------------------------
function luaY.errorlimit(fs, limit, what)
	local msg = (fs.f.linedefined == 0) and string.format("main function has more than %d %s", limit, what)
		or string.format("function at line %d has more than %d %s", fs.f.linedefined, limit, what)
	luaX.lexerror(fs.ls, msg, 0)
end

------------------------------------------------------------------------
-- tests for a token, returns outcome
-- * return value changed to boolean
------------------------------------------------------------------------
function luaY.testnext(ls, c)
	if ls.t.token == c then
		luaX.next(ls)
		return true
	else
		return false
	end
end

------------------------------------------------------------------------
-- check for existence of a token, throws error if not found
------------------------------------------------------------------------
function luaY.check(ls, c)
	if ls.t.token ~= c then
		luaY.error_expected(ls, c)
	end
end

------------------------------------------------------------------------
-- verify existence of a token, then skip it
------------------------------------------------------------------------
function luaY.checknext(ls, c)
	luaY.check(ls, c)
	luaX.next(ls)
end

------------------------------------------------------------------------
-- throws error if condition not matched
------------------------------------------------------------------------
function luaY.check_condition(ls, c, msg)
	if not c then
		luaX.syntaxerror(ls, msg)
	end
end

------------------------------------------------------------------------
-- verifies token conditions are met or else throw error
------------------------------------------------------------------------
function luaY.check_match(ls, what, who, where)
	if not luaY.testnext(ls, what) then
		if where == ls.linenumber then
			luaY.error_expected(ls, what)
		else
			luaX.syntaxerror(
				ls,
				string.format(
					luaY.LUA_QS .. " expected (to close " .. luaY.LUA_QS .. " at line %d)",
					luaX.token2str(ls, what),
					luaX.token2str(ls, who),
					where
				)
			)
		end
	end
end

------------------------------------------------------------------------
-- expect that token is a name, return the name
------------------------------------------------------------------------
function luaY.str_checkname(ls)
	luaY.check(ls, "TK_NAME")
	local ts = ls.t.seminfo
	luaX.next(ls)
	return ts
end

------------------------------------------------------------------------
-- initialize a struct expdesc, expression description data structure
------------------------------------------------------------------------
function luaY.init_exp(e, k, i)
	e.f, e.t = luaK.NO_JUMP, luaK.NO_JUMP
	e.k = k
	e.info = i
end

------------------------------------------------------------------------
-- adds given string s in string pool, sets e as VK
------------------------------------------------------------------------
function luaY.codestring(ls, e, s)
	luaY.init_exp(e, "VK", luaK.stringK(ls.fs, s))
end

------------------------------------------------------------------------
-- consume a name token, adds it to string pool, sets e as VK
------------------------------------------------------------------------
function luaY.checkname(ls, e)
	luaY.codestring(ls, e, luaY.str_checkname(ls))
end

------------------------------------------------------------------------
-- creates struct entry for a local variable
-- * used only in new_localvar()
------------------------------------------------------------------------
function luaY.registerlocalvar(ls, varname)
	local fs = ls.fs
	local f = fs.f
	luaY.growvector(ls.L, f.locvars, fs.nlocvars, f.sizelocvars, nil, luaY.SHRT_MAX, "too many local variables")
	-- loop to initialize empty f.locvar positions not required
	f.locvars[fs.nlocvars] = {} -- LocVar
	f.locvars[fs.nlocvars].varname = varname
	-- luaC_objbarrier(ls.L, f, varname) /* GC */
	local nlocvars = fs.nlocvars
	fs.nlocvars = fs.nlocvars + 1
	return nlocvars
end

------------------------------------------------------------------------
-- creates a new local variable given a name and an offset from nactvar
-- * used in fornum(), forlist(), parlist(), body()
------------------------------------------------------------------------
function luaY.new_localvarliteral(ls, v, n)
	luaY.new_localvar(ls, v, n)
end

------------------------------------------------------------------------
-- register a local variable, set in active variable list
------------------------------------------------------------------------
function luaY.new_localvar(ls, name, n)
	local fs = ls.fs
	luaY.checklimit(fs, fs.nactvar + n + 1, luaY.LUAI_MAXVARS, "local variables")
	fs.actvar[fs.nactvar + n] = luaY.registerlocalvar(ls, name)
end

------------------------------------------------------------------------
-- adds nvars number of new local variables, set debug information
------------------------------------------------------------------------
function luaY.adjustlocalvars(ls, nvars)
	local fs = ls.fs
	fs.nactvar = fs.nactvar + nvars
	for i = nvars, 1, -1 do
		luaY.getlocvar(fs, fs.nactvar - i).startpc = fs.pc
	end
end

------------------------------------------------------------------------
-- removes a number of locals, set debug information
------------------------------------------------------------------------
function luaY.removevars(ls, tolevel)
	local fs = ls.fs
	while fs.nactvar > tolevel do
		fs.nactvar = fs.nactvar - 1
		luaY.getlocvar(fs, fs.nactvar).endpc = fs.pc
	end
end

------------------------------------------------------------------------
-- returns an existing upvalue index based on the given name, or
-- creates a new upvalue struct entry and returns the new index
-- * used only in singlevaraux()
------------------------------------------------------------------------
function luaY.indexupvalue(fs, name, v)
	local f = fs.f
	for i = 0, f.nups - 1 do
		if fs.upvalues[i].k == v.k and fs.upvalues[i].info == v.info then
			assert(f.upvalues[i] == name)
			return i
		end
	end
	-- new one
	luaY.checklimit(fs, f.nups + 1, luaY.LUAI_MAXUPVALUES, "upvalues")
	luaY.growvector(fs.L, f.upvalues, f.nups, f.sizeupvalues, nil, luaY.MAX_INT, "")
	-- loop to initialize empty f.upvalues positions not required
	f.upvalues[f.nups] = name
	-- luaC_objbarrier(fs->L, f, name); /* GC */
	assert(v.k == "VLOCAL" or v.k == "VUPVAL")
	-- this is a partial copy; only k & info fields used
	fs.upvalues[f.nups] = { k = v.k, info = v.info }
	local nups = f.nups
	f.nups = f.nups + 1
	return nups
end

------------------------------------------------------------------------
-- search the local variable namespace of the given fs for a match
-- * used only in singlevaraux()
------------------------------------------------------------------------
function luaY.searchvar(fs, n)
	for i = fs.nactvar - 1, 0, -1 do
		if n == luaY.getlocvar(fs, i).varname then
			return i
		end
	end
	return -1 -- not found
end

------------------------------------------------------------------------
-- * mark upvalue flags in function states up to a given level
-- * used only in singlevaraux()
------------------------------------------------------------------------
function luaY.markupval(fs, level)
	local bl = fs.bl
	while bl and bl.nactvar > level do
		bl = bl.previous
	end
	if bl then
		bl.upval = true
	end
end

------------------------------------------------------------------------
-- handle locals, globals and upvalues and related processing
-- * search mechanism is recursive, calls itself to search parents
-- * used only in singlevar()
------------------------------------------------------------------------
function luaY.singlevaraux(fs, n, var, base)
	if fs == nil then -- no more levels?
		luaY.init_exp(var, "VGLOBAL", luaP.NO_REG) -- default is global variable
		return "VGLOBAL"
	else
		local v = luaY.searchvar(fs, n) -- look up at current level
		if v >= 0 then
			luaY.init_exp(var, "VLOCAL", v)
			if base == 0 then
				luaY.markupval(fs, v) -- local will be used as an upval
			end
			return "VLOCAL"
		else -- not found at current level; try upper one
			if luaY.singlevaraux(fs.prev, n, var, 0) == "VGLOBAL" then
				return "VGLOBAL"
			end
			var.info = luaY.indexupvalue(fs, n, var) -- else was LOCAL or UPVAL
			var.k = "VUPVAL" -- upvalue in this level
			return "VUPVAL"
		end --if v
	end --if fs
end

------------------------------------------------------------------------
-- consume a name token, creates a variable (global|local|upvalue)
-- * used in prefixexp(), funcname()
------------------------------------------------------------------------
function luaY.singlevar(ls, var)
	local varname = luaY.str_checkname(ls)
	local fs = ls.fs
	if luaY.singlevaraux(fs, varname, var, 1) == "VGLOBAL" then
		var.info = luaK.stringK(fs, varname) -- info points to global name
	end
end

------------------------------------------------------------------------
-- adjust RHS to match LHS in an assignment
-- * used in assignment(), forlist(), localstat()
------------------------------------------------------------------------
function luaY.adjust_assign(ls, nvars, nexps, e)
	local fs = ls.fs
	local extra = nvars - nexps
	if luaY.hasmultret(e.k) then
		extra = extra + 1 -- includes call itself
		if extra <= 0 then
			extra = 0
		end
		luaK.setreturns(fs, e, extra) -- last exp. provides the difference
		if extra > 1 then
			luaK.reserveregs(fs, extra - 1)
		end
	else
		if e.k ~= "VVOID" then
			luaK.exp2nextreg(fs, e)
		end -- close last expression
		if extra > 0 then
			local reg = fs.freereg
			luaK.reserveregs(fs, extra)
			luaK._nil(fs, reg, extra)
		end
	end
end

------------------------------------------------------------------------
-- tracks and limits parsing depth, assert check at end of parsing
------------------------------------------------------------------------
function luaY.enterlevel(ls)
	ls.L.nCcalls = ls.L.nCcalls + 1
	if ls.L.nCcalls > luaY.LUAI_MAXCCALLS then
		luaX.lexerror(ls, "chunk has too many syntax levels", 0)
	end
end

------------------------------------------------------------------------
-- tracks parsing depth, a pair with luaY.enterlevel()
------------------------------------------------------------------------
function luaY.leavelevel(ls)
	ls.L.nCcalls = ls.L.nCcalls - 1
end

------------------------------------------------------------------------
-- enters a code unit, initializes elements
------------------------------------------------------------------------
function luaY.enterblock(fs, bl, isbreakable)
	bl.breaklist = luaK.NO_JUMP
	bl.isbreakable = isbreakable
	bl.nactvar = fs.nactvar
	bl.upval = false
	bl.previous = fs.bl
	fs.bl = bl
	assert(fs.freereg == fs.nactvar)
end

------------------------------------------------------------------------
-- leaves a code unit, close any upvalues
------------------------------------------------------------------------
function luaY.leaveblock(fs)
	local bl = fs.bl
	fs.bl = bl.previous
	luaY.removevars(fs.ls, bl.nactvar)
	if bl.upval then
		luaK.codeABC(fs, "OP_CLOSE", bl.nactvar, 0, 0)
	end
	-- a block either controls scope or breaks (never both)
	assert(not bl.isbreakable or not bl.upval)
	assert(bl.nactvar == fs.nactvar)
	fs.freereg = fs.nactvar -- free registers
	luaK.patchtohere(fs, bl.breaklist)
end

------------------------------------------------------------------------
-- implement the instantiation of a function prototype, append list of
-- upvalues after the instantiation instruction
-- * used only in body()
------------------------------------------------------------------------
function luaY.pushclosure(ls, func, v)
	local fs = ls.fs
	local f = fs.f
	luaY.growvector(ls.L, f.p, fs.np, f.sizep, nil, luaP.MAXARG_Bx, "constant table overflow")
	-- loop to initialize empty f.p positions not required
	f.p[fs.np] = func.f
	fs.np = fs.np + 1
	-- luaC_objbarrier(ls->L, f, func->f); /* C */
	luaY.init_exp(v, "VRELOCABLE", luaK.codeABx(fs, "OP_CLOSURE", 0, fs.np - 1))
	for i = 0, func.f.nups - 1 do
		local o = (func.upvalues[i].k == "VLOCAL") and "OP_MOVE" or "OP_GETUPVAL"
		luaK.codeABC(fs, o, 0, func.upvalues[i].info, 0)
	end
end

------------------------------------------------------------------------
-- opening of a function
------------------------------------------------------------------------
function luaY.open_func(ls, fs)
	local L = ls.L
	local f = luaY.newproto(ls.L)
	fs.f = f
	fs.prev = ls.fs -- linked list of funcstates
	fs.ls = ls
	fs.L = L
	ls.fs = fs
	fs.pc = 0
	fs.lasttarget = -1
	fs.jpc = luaK.NO_JUMP
	fs.freereg = 0
	fs.nk = 0
	fs.np = 0
	fs.nlocvars = 0
	fs.nactvar = 0
	fs.bl = nil
	f.source = ls.source
	f.maxstacksize = 2 -- registers 0/1 are always valid
	fs.h = {} -- constant table; was luaH_new call
	-- anchor table of constants and prototype (to avoid being collected)
	-- sethvalue2s(L, L->top, fs->h); incr_top(L); /* C */
	-- setptvalue2s(L, L->top, f); incr_top(L);
end

------------------------------------------------------------------------
-- closing of a function
------------------------------------------------------------------------
function luaY.close_func(ls)
	local L = ls.L
	local fs = ls.fs
	local f = fs.f
	luaY.removevars(ls, 0)
	luaK.ret(fs, 0, 0) -- final return
	-- luaM_reallocvector deleted for f->code, f->lineinfo, f->k, f->p,
	-- f->locvars, f->upvalues; not required for Lua table arrays
	f.sizecode = fs.pc
	f.sizelineinfo = fs.pc
	f.sizek = fs.nk
	f.sizep = fs.np
	f.sizelocvars = fs.nlocvars
	f.sizeupvalues = f.nups
	--assert(luaG_checkcode(f))  -- currently not implemented
	assert(fs.bl == nil)
	ls.fs = fs.prev
	-- the following is not required for this implementation; kept here
	-- for completeness
	-- L->top -= 2;  /* remove table and prototype from the stack */
	-- last token read was anchored in defunct function; must reanchor it
	if fs then
		luaY.anchor_token(ls)
	end
end

------------------------------------------------------------------------
-- parser initialization function
-- * note additional sub-tables needed for LexState, FuncState
------------------------------------------------------------------------
function luaY.parser(L, z, buff, name)
	local lexstate = {} -- LexState
	lexstate.t = {}
	lexstate.lookahead = {}
	local funcstate = {} -- FuncState
	funcstate.upvalues = {}
	funcstate.actvar = {}
	-- the following nCcalls initialization added for convenience
	L.nCcalls = 0
	lexstate.buff = buff
	luaX.setinput(L, lexstate, z, name)
	luaY.open_func(lexstate, funcstate)
	funcstate.f.is_vararg = luaY.VARARG_ISVARARG -- main func. is always vararg
	luaX.next(lexstate) -- read first token
	luaY.chunk(lexstate)
	luaY.check(lexstate, "TK_EOS")
	luaY.close_func(lexstate)
	assert(funcstate.prev == nil)
	assert(funcstate.f.nups == 0)
	assert(lexstate.fs == nil)
	return funcstate.f
end

--[[--------------------------------------------------------------------
-- GRAMMAR RULES
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- parse a function name suffix, for function call specifications
-- * used in primaryexp(), funcname()
------------------------------------------------------------------------
function luaY.field(ls, v)
	-- field -> ['.' | ':'] NAME
	local fs = ls.fs
	local key = {} -- expdesc
	luaK.exp2anyreg(fs, v)
	luaX.next(ls) -- skip the dot or colon
	luaY.checkname(ls, key)
	luaK.indexed(fs, v, key)
end

------------------------------------------------------------------------
-- parse a table indexing suffix, for constructors, expressions
-- * used in recfield(), primaryexp()
------------------------------------------------------------------------
function luaY.yindex(ls, v)
	-- index -> '[' expr ']'
	luaX.next(ls) -- skip the '['
	luaY.expr(ls, v)
	luaK.exp2val(ls.fs, v)
	luaY.checknext(ls, "]")
end

--[[--------------------------------------------------------------------
-- Rules for Constructors
----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- struct ConsControl:
--   v  -- last list item read (table: struct expdesc)
--   t  -- table descriptor (table: struct expdesc)
--   nh  -- total number of 'record' elements
--   na  -- total number of array elements
--   tostore  -- number of array elements pending to be stored
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- parse a table record (hash) field
-- * used in constructor()
------------------------------------------------------------------------
function luaY.recfield(ls, cc)
	-- recfield -> (NAME | '['exp1']') = exp1
	local fs = ls.fs
	local reg = ls.fs.freereg
	local key, val = {}, {} -- expdesc
	if ls.t.token == "TK_NAME" then
		luaY.checklimit(fs, cc.nh, luaY.MAX_INT, "items in a constructor")
		luaY.checkname(ls, key)
	else -- ls->t.token == '['
		luaY.yindex(ls, key)
	end
	cc.nh = cc.nh + 1
	luaY.checknext(ls, "=")
	local rkkey = luaK.exp2RK(fs, key)
	luaY.expr(ls, val)
	luaK.codeABC(fs, "OP_SETTABLE", cc.t.info, rkkey, luaK.exp2RK(fs, val))
	fs.freereg = reg -- free registers
end

------------------------------------------------------------------------
-- emit a set list instruction if enough elements (LFIELDS_PER_FLUSH)
-- * used in constructor()
------------------------------------------------------------------------
function luaY.closelistfield(fs, cc)
	if cc.v.k == "VVOID" then
		return
	end -- there is no list item
	luaK.exp2nextreg(fs, cc.v)
	cc.v.k = "VVOID"
	if cc.tostore == luaP.LFIELDS_PER_FLUSH then
		luaK.setlist(fs, cc.t.info, cc.na, cc.tostore) -- flush
		cc.tostore = 0 -- no more items pending
	end
end

------------------------------------------------------------------------
-- emit a set list instruction at the end of parsing list constructor
-- * used in constructor()
------------------------------------------------------------------------
function luaY.lastlistfield(fs, cc)
	if cc.tostore == 0 then
		return
	end
	if luaY.hasmultret(cc.v.k) then
		luaK.setmultret(fs, cc.v)
		luaK.setlist(fs, cc.t.info, cc.na, luaY.LUA_MULTRET)
		cc.na = cc.na - 1 -- do not count last expression (unknown number of elements)
	else
		if cc.v.k ~= "VVOID" then
			luaK.exp2nextreg(fs, cc.v)
		end
		luaK.setlist(fs, cc.t.info, cc.na, cc.tostore)
	end
end

------------------------------------------------------------------------
-- parse a table list (array) field
-- * used in constructor()
------------------------------------------------------------------------
function luaY.listfield(ls, cc)
	luaY.expr(ls, cc.v)
	luaY.checklimit(ls.fs, cc.na, luaY.MAX_INT, "items in a constructor")
	cc.na = cc.na + 1
	cc.tostore = cc.tostore + 1
end

------------------------------------------------------------------------
-- parse a table constructor
-- * used in funcargs(), simpleexp()
------------------------------------------------------------------------
function luaY.constructor(ls, t)
	-- constructor -> '{' [ field { fieldsep field } [ fieldsep ] ] '}'
	-- field -> recfield | listfield
	-- fieldsep -> ',' | ';'
	local fs = ls.fs
	local line = ls.linenumber
	local pc = luaK.codeABC(fs, "OP_NEWTABLE", 0, 0, 0)
	local cc = {} -- ConsControl
	cc.v = {}
	cc.na, cc.nh, cc.tostore = 0, 0, 0
	cc.t = t
	luaY.init_exp(t, "VRELOCABLE", pc)
	luaY.init_exp(cc.v, "VVOID", 0) -- no value (yet)
	luaK.exp2nextreg(ls.fs, t) -- fix it at stack top (for gc)
	luaY.checknext(ls, "{")
	repeat
		assert(cc.v.k == "VVOID" or cc.tostore > 0)
		if ls.t.token == "}" then
			break
		end
		luaY.closelistfield(fs, cc)
		local c = ls.t.token

		if c == "TK_NAME" then -- may be listfields or recfields
			luaX.lookahead(ls)
			if ls.lookahead.token ~= "=" then -- expression?
				luaY.listfield(ls, cc)
			else
				luaY.recfield(ls, cc)
			end
		elseif c == "[" then -- constructor_item -> recfield
			luaY.recfield(ls, cc)
		else -- constructor_part -> listfield
			luaY.listfield(ls, cc)
		end
	until not luaY.testnext(ls, ",") and not luaY.testnext(ls, ";")
	luaY.check_match(ls, "}", "{", line)
	luaY.lastlistfield(fs, cc)
	luaP.SETARG_B(fs.f.code[pc], luaY.int2fb(cc.na)) -- set initial array size
	luaP.SETARG_C(fs.f.code[pc], luaY.int2fb(cc.nh)) -- set initial table size
end

-- }======================================================================

------------------------------------------------------------------------
-- parse the arguments (parameters) of a function declaration
-- * used in body()
------------------------------------------------------------------------
function luaY.parlist(ls)
	-- parlist -> [ param { ',' param } ]
	local fs = ls.fs
	local f = fs.f
	local nparams = 0
	f.is_vararg = 0
	if ls.t.token ~= ")" then -- is 'parlist' not empty?
		repeat
			local c = ls.t.token
			if c == "TK_NAME" then -- param -> NAME
				luaY.new_localvar(ls, luaY.str_checkname(ls), nparams)
				nparams = nparams + 1
			elseif c == "TK_DOTS" then -- param -> `...'
				luaX.next(ls)
				-- [[
				-- #if defined(LUA_COMPAT_VARARG)
				-- use `arg' as default name
				luaY.new_localvarliteral(ls, "arg", nparams)
				nparams = nparams + 1
				f.is_vararg = luaY.VARARG_HASARG + luaY.VARARG_NEEDSARG
				-- #endif
				--]]
				f.is_vararg = f.is_vararg + luaY.VARARG_ISVARARG
			else
				luaX.syntaxerror(ls, "<name> or " .. luaY.LUA_QL("...") .. " expected")
			end
		until f.is_vararg ~= 0 or not luaY.testnext(ls, ",")
	end --if
	luaY.adjustlocalvars(ls, nparams)
	-- NOTE: the following works only when HASARG_MASK is 2!
	f.numparams = fs.nactvar - (f.is_vararg % luaY.HASARG_MASK)
	luaK.reserveregs(fs, fs.nactvar) -- reserve register for parameters
end

------------------------------------------------------------------------
-- parse function declaration body
-- * used in simpleexp(), localfunc(), funcstat()
------------------------------------------------------------------------
function luaY.body(ls, e, needself, line)
	-- body ->  '(' parlist ')' chunk END
	local new_fs = {} -- FuncState
	new_fs.upvalues = {}
	new_fs.actvar = {}
	luaY.open_func(ls, new_fs)
	new_fs.f.lineDefined = line
	luaY.checknext(ls, "(")
	if needself then
		luaY.new_localvarliteral(ls, "self", 0)
		luaY.adjustlocalvars(ls, 1)
	end
	luaY.parlist(ls)
	luaY.checknext(ls, ")")
	luaY.chunk(ls)
	new_fs.f.lastlinedefined = ls.linenumber
	luaY.check_match(ls, "TK_END", "TK_FUNCTION", line)
	luaY.close_func(ls)
	luaY.pushclosure(ls, new_fs, e)
end

------------------------------------------------------------------------
-- parse a list of comma-separated expressions
-- * used is multiple locations
------------------------------------------------------------------------
function luaY.explist1(ls, v)
	-- explist1 -> expr { ',' expr }
	local n = 1 -- at least one expression
	luaY.expr(ls, v)
	while luaY.testnext(ls, ",") do
		luaK.exp2nextreg(ls.fs, v)
		luaY.expr(ls, v)
		n = n + 1
	end
	return n
end

------------------------------------------------------------------------
-- parse the parameters of a function call
-- * contrast with parlist(), used in function declarations
-- * used in primaryexp()
------------------------------------------------------------------------
function luaY.funcargs(ls, f)
	local fs = ls.fs
	local args = {} -- expdesc
	local nparams
	local line = ls.linenumber
	local c = ls.t.token
	if c == "(" then -- funcargs -> '(' [ explist1 ] ')'
		if line ~= ls.lastline then
			luaX.syntaxerror(ls, "ambiguous syntax (function call x new statement)")
		end
		luaX.next(ls)
		if ls.t.token == ")" then -- arg list is empty?
			args.k = "VVOID"
		else
			luaY.explist1(ls, args)
			luaK.setmultret(fs, args)
		end
		luaY.check_match(ls, ")", "(", line)
	elseif c == "{" then -- funcargs -> constructor
		luaY.constructor(ls, args)
	elseif c == "TK_STRING" then -- funcargs -> STRING
		luaY.codestring(ls, args, ls.t.seminfo)
		luaX.next(ls) -- must use 'seminfo' before 'next'
	else
		luaX.syntaxerror(ls, "function arguments expected")
		return
	end
	assert(f.k == "VNONRELOC")
	local base = f.info -- base register for call
	if luaY.hasmultret(args.k) then
		nparams = luaY.LUA_MULTRET -- open call
	else
		if args.k ~= "VVOID" then
			luaK.exp2nextreg(fs, args) -- close last argument
		end
		nparams = fs.freereg - (base + 1)
	end
	luaY.init_exp(f, "VCALL", luaK.codeABC(fs, "OP_CALL", base, nparams + 1, 2))
	luaK.fixline(fs, line)
	fs.freereg = base + 1 -- call remove function and arguments and leaves
	-- (unless changed) one result
end

--[[--------------------------------------------------------------------
-- Expression parsing
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- parses an expression in parentheses or a single variable
-- * used in primaryexp()
------------------------------------------------------------------------
function luaY.prefixexp(ls, v)
	-- prefixexp -> NAME | '(' expr ')'
	local c = ls.t.token
	if c == "(" then
		local line = ls.linenumber
		luaX.next(ls)
		luaY.expr(ls, v)
		luaY.check_match(ls, ")", "(", line)
		luaK.dischargevars(ls.fs, v)
	elseif c == "TK_NAME" then
		luaY.singlevar(ls, v)
	else
		luaX.syntaxerror(ls, "unexpected symbol")
	end --if c
	return
end

------------------------------------------------------------------------
-- parses a prefixexp (an expression in parentheses or a single variable)
-- or a function call specification
-- * used in simpleexp(), assignment(), exprstat()
------------------------------------------------------------------------
function luaY.primaryexp(ls, v)
	-- primaryexp ->
	--    prefixexp { '.' NAME | '[' exp ']' | ':' NAME funcargs | funcargs }
	local fs = ls.fs
	luaY.prefixexp(ls, v)
	while true do
		local c = ls.t.token
		if c == "." then -- field
			luaY.field(ls, v)
		elseif c == "[" then -- '[' exp1 ']'
			local key = {} -- expdesc
			luaK.exp2anyreg(fs, v)
			luaY.yindex(ls, key)
			luaK.indexed(fs, v, key)
		elseif c == ":" then -- ':' NAME funcargs
			local key = {} -- expdesc
			luaX.next(ls)
			luaY.checkname(ls, key)
			luaK._self(fs, v, key)
			luaY.funcargs(ls, v)
		elseif c == "(" or c == "TK_STRING" or c == "{" then -- funcargs
			luaK.exp2nextreg(fs, v)
			luaY.funcargs(ls, v)
		else
			return
		end --if c
	end --while
end

------------------------------------------------------------------------
-- parses general expression types, constants handled here
-- * used in subexpr()
------------------------------------------------------------------------
function luaY.simpleexp(ls, v)
	-- simpleexp -> NUMBER | STRING | NIL | TRUE | FALSE | ... |
	--              constructor | FUNCTION body | primaryexp
	local c = ls.t.token
	if c == "TK_NUMBER" then
		luaY.init_exp(v, "VKNUM", 0)
		v.nval = ls.t.seminfo
	elseif c == "TK_STRING" then
		luaY.codestring(ls, v, ls.t.seminfo)
	elseif c == "TK_NIL" then
		luaY.init_exp(v, "VNIL", 0)
	elseif c == "TK_TRUE" then
		luaY.init_exp(v, "VTRUE", 0)
	elseif c == "TK_FALSE" then
		luaY.init_exp(v, "VFALSE", 0)
	elseif c == "TK_DOTS" then -- vararg
		local fs = ls.fs
		luaY.check_condition(
			ls,
			fs.f.is_vararg ~= 0,
			"cannot use " .. luaY.LUA_QL("...") .. " outside a vararg function"
		)
		-- NOTE: the following substitutes for a bitop, but is value-specific
		local is_vararg = fs.f.is_vararg
		if is_vararg >= luaY.VARARG_NEEDSARG then
			fs.f.is_vararg = is_vararg - luaY.VARARG_NEEDSARG -- don't need 'arg'
		end
		luaY.init_exp(v, "VVARARG", luaK.codeABC(fs, "OP_VARARG", 0, 1, 0))
	elseif c == "{" then -- constructor
		luaY.constructor(ls, v)
		return
	elseif c == "TK_FUNCTION" then
		luaX.next(ls)
		luaY.body(ls, v, false, ls.linenumber)
		return
	else
		luaY.primaryexp(ls, v)
		return
	end --if c
	luaX.next(ls)
end

------------------------------------------------------------------------
-- Translates unary operators tokens if found, otherwise returns
-- OPR_NOUNOPR. getunopr() and getbinopr() are used in subexpr().
-- * used in subexpr()
------------------------------------------------------------------------
function luaY.getunopr(op)
	if op == "TK_NOT" then
		return "OPR_NOT"
	elseif op == "-" then
		return "OPR_MINUS"
	elseif op == "#" then
		return "OPR_LEN"
	else
		return "OPR_NOUNOPR"
	end
end

------------------------------------------------------------------------
-- Translates binary operator tokens if found, otherwise returns
-- OPR_NOBINOPR. Code generation uses OPR_* style tokens.
-- * used in subexpr()
------------------------------------------------------------------------
luaY.getbinopr_table = {
	["+"] = "OPR_ADD",
	["-"] = "OPR_SUB",
	["*"] = "OPR_MUL",
	["/"] = "OPR_DIV",
	["%"] = "OPR_MOD",
	["^"] = "OPR_POW",
	["TK_CONCAT"] = "OPR_CONCAT",
	["TK_NE"] = "OPR_NE",
	["TK_EQ"] = "OPR_EQ",
	["<"] = "OPR_LT",
	["TK_LE"] = "OPR_LE",
	[">"] = "OPR_GT",
	["TK_GE"] = "OPR_GE",
	["TK_AND"] = "OPR_AND",
	["TK_OR"] = "OPR_OR",
}
function luaY.getbinopr(op)
	local opr = luaY.getbinopr_table[op]
	if opr then
		return opr
	else
		return "OPR_NOBINOPR"
	end
end

------------------------------------------------------------------------
-- the following priority table consists of pairs of left/right values
-- for binary operators (was a static const struct); grep for ORDER OPR
-- * the following struct is replaced:
--   static const struct {
--     lu_byte left;  /* left priority for each binary operator */
--     lu_byte right; /* right priority */
--   } priority[] = {  /* ORDER OPR */
------------------------------------------------------------------------
luaY.priority = {
	{ 6, 6 },
	{ 6, 6 },
	{ 7, 7 },
	{ 7, 7 },
	{ 7, 7 }, -- `+' `-' `/' `%'
	{ 10, 9 },
	{ 5, 4 }, -- power and concat (right associative)
	{ 3, 3 },
	{ 3, 3 }, -- equality
	{ 3, 3 },
	{ 3, 3 },
	{ 3, 3 },
	{ 3, 3 }, -- order
	{ 2, 2 },
	{ 1, 1 }, -- logical (and/or)
}

luaY.UNARY_PRIORITY = 8 -- priority for unary operators

------------------------------------------------------------------------
-- Parse subexpressions. Includes handling of unary operators and binary
-- operators. A subexpr is given the rhs priority level of the operator
-- immediately left of it, if any (limit is -1 if none,) and if a binop
-- is found, limit is compared with the lhs priority level of the binop
-- in order to determine which executes first.
------------------------------------------------------------------------

------------------------------------------------------------------------
-- subexpr -> (simpleexp | unop subexpr) { binop subexpr }
-- where 'binop' is any binary operator with a priority higher than 'limit'
-- * for priority lookups with luaY.priority[], 1=left and 2=right
-- * recursively called
-- * used in expr()
------------------------------------------------------------------------
function luaY.subexpr(ls, v, limit)
	luaY.enterlevel(ls)
	local uop = luaY.getunopr(ls.t.token)
	if uop ~= "OPR_NOUNOPR" then
		luaX.next(ls)
		luaY.subexpr(ls, v, luaY.UNARY_PRIORITY)
		luaK.prefix(ls.fs, uop, v)
	else
		luaY.simpleexp(ls, v)
	end
	-- expand while operators have priorities higher than 'limit'
	local op = luaY.getbinopr(ls.t.token)
	while op ~= "OPR_NOBINOPR" and luaY.priority[luaK.BinOpr[op] + 1][1] > limit do
		local v2 = {} -- expdesc
		luaX.next(ls)
		luaK.infix(ls.fs, op, v)
		-- read sub-expression with higher priority
		local nextop = luaY.subexpr(ls, v2, luaY.priority[luaK.BinOpr[op] + 1][2])
		luaK.posfix(ls.fs, op, v, v2)
		op = nextop
	end
	luaY.leavelevel(ls)
	return op -- return first untreated operator
end

------------------------------------------------------------------------
-- Expression parsing starts here. Function subexpr is entered with the
-- left operator (which is non-existent) priority of -1, which is lower
-- than all actual operators. Expr information is returned in parm v.
-- * used in multiple locations
------------------------------------------------------------------------
function luaY.expr(ls, v)
	luaY.subexpr(ls, v, 0)
end

-- }====================================================================

--[[--------------------------------------------------------------------
-- Rules for Statements
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- checks next token, used as a look-ahead
-- * returns boolean instead of 0|1
-- * used in retstat(), chunk()
------------------------------------------------------------------------
function luaY.block_follow(token)
	if token == "TK_ELSE" or token == "TK_ELSEIF" or token == "TK_END" or token == "TK_UNTIL" or token == "TK_EOS" then
		return true
	else
		return false
	end
end

------------------------------------------------------------------------
-- parse a code block or unit
-- * used in multiple functions
------------------------------------------------------------------------
function luaY.block(ls)
	-- block -> chunk
	local fs = ls.fs
	local bl = {} -- BlockCnt
	luaY.enterblock(fs, bl, false)
	luaY.chunk(ls)
	assert(bl.breaklist == luaK.NO_JUMP)
	luaY.leaveblock(fs)
end

------------------------------------------------------------------------
-- structure to chain all variables in the left-hand side of an
-- assignment
-- struct LHS_assign:
--   prev  -- (table: struct LHS_assign)
--   v  -- variable (global, local, upvalue, or indexed) (table: expdesc)
------------------------------------------------------------------------

------------------------------------------------------------------------
-- check whether, in an assignment to a local variable, the local variable
-- is needed in a previous assignment (to a table). If so, save original
-- local value in a safe place and use this safe copy in the previous
-- assignment.
-- * used in assignment()
------------------------------------------------------------------------
function luaY.check_conflict(ls, lh, v)
	local fs = ls.fs
	local extra = fs.freereg -- eventual position to save local variable
	local conflict = false
	while lh do
		if lh.v.k == "VINDEXED" then
			if lh.v.info == v.info then -- conflict?
				conflict = true
				lh.v.info = extra -- previous assignment will use safe copy
			end
			if lh.v.aux == v.info then -- conflict?
				conflict = true
				lh.v.aux = extra -- previous assignment will use safe copy
			end
		end
		lh = lh.prev
	end
	if conflict then
		luaK.codeABC(fs, "OP_MOVE", fs.freereg, v.info, 0) -- make copy
		luaK.reserveregs(fs, 1)
	end
end

------------------------------------------------------------------------
-- parse a variable assignment sequence
-- * recursively called
-- * used in exprstat()
------------------------------------------------------------------------
function luaY.assignment(ls, lh, nvars)
	local e = {} -- expdesc
	-- test was: VLOCAL <= lh->v.k && lh->v.k <= VINDEXED
	local c = lh.v.k
	luaY.check_condition(ls, c == "VLOCAL" or c == "VUPVAL" or c == "VGLOBAL" or c == "VINDEXED", "syntax error")
	if luaY.testnext(ls, ",") then -- assignment -> ',' primaryexp assignment
		local nv = {} -- LHS_assign
		nv.v = {}
		nv.prev = lh
		luaY.primaryexp(ls, nv.v)
		if nv.v.k == "VLOCAL" then
			luaY.check_conflict(ls, lh, nv.v)
		end
		luaY.checklimit(ls.fs, nvars, luaY.LUAI_MAXCCALLS - ls.L.nCcalls, "variables in assignment")
		luaY.assignment(ls, nv, nvars + 1)
	else -- assignment -> '=' explist1
		luaY.checknext(ls, "=")
		local nexps = luaY.explist1(ls, e)
		if nexps ~= nvars then
			luaY.adjust_assign(ls, nvars, nexps, e)
			if nexps > nvars then
				ls.fs.freereg = ls.fs.freereg - (nexps - nvars) -- remove extra values
			end
		else
			luaK.setoneret(ls.fs, e) -- close last expression
			luaK.storevar(ls.fs, lh.v, e)
			return -- avoid default
		end
	end
	luaY.init_exp(e, "VNONRELOC", ls.fs.freereg - 1) -- default assignment
	luaK.storevar(ls.fs, lh.v, e)
end

------------------------------------------------------------------------
-- parse condition in a repeat statement or an if control structure
-- * used in repeatstat(), test_then_block()
------------------------------------------------------------------------
function luaY.cond(ls)
	-- cond -> exp
	local v = {} -- expdesc
	luaY.expr(ls, v) -- read condition
	if v.k == "VNIL" then
		v.k = "VFALSE"
	end -- 'falses' are all equal here
	luaK.goiftrue(ls.fs, v)
	return v.f
end

------------------------------------------------------------------------
-- parse a break statement
-- * used in statements()
------------------------------------------------------------------------
function luaY.breakstat(ls)
	-- stat -> BREAK
	local fs = ls.fs
	local bl = fs.bl
	local upval = false
	while bl and not bl.isbreakable do
		if bl.upval then
			upval = true
		end
		bl = bl.previous
	end
	if not bl then
		luaX.syntaxerror(ls, "no loop to break")
	end
	if upval then
		luaK.codeABC(fs, "OP_CLOSE", bl.nactvar, 0, 0)
	end
	bl.breaklist = luaK.concat(fs, bl.breaklist, luaK.jump(fs))
end

------------------------------------------------------------------------
-- parse a while-do control structure, body processed by block()
-- * with dynamic array sizes, MAXEXPWHILE + EXTRAEXP limits imposed by
--   the function's implementation can be removed
-- * used in statements()
------------------------------------------------------------------------
function luaY.whilestat(ls, line)
	-- whilestat -> WHILE cond DO block END
	local fs = ls.fs
	local bl = {} -- BlockCnt
	luaX.next(ls) -- skip WHILE
	local whileinit = luaK.getlabel(fs)
	local condexit = luaY.cond(ls)
	luaY.enterblock(fs, bl, true)
	luaY.checknext(ls, "TK_DO")
	luaY.block(ls)
	luaK.patchlist(fs, luaK.jump(fs), whileinit)
	luaY.check_match(ls, "TK_END", "TK_WHILE", line)
	luaY.leaveblock(fs)
	luaK.patchtohere(fs, condexit) -- false conditions finish the loop
end

------------------------------------------------------------------------
-- parse a repeat-until control structure, body parsed by chunk()
-- * used in statements()
------------------------------------------------------------------------
function luaY.repeatstat(ls, line)
	-- repeatstat -> REPEAT block UNTIL cond
	local fs = ls.fs
	local repeat_init = luaK.getlabel(fs)
	local bl1, bl2 = {}, {} -- BlockCnt
	luaY.enterblock(fs, bl1, true) -- loop block
	luaY.enterblock(fs, bl2, false) -- scope block
	luaX.next(ls) -- skip REPEAT
	luaY.chunk(ls)
	luaY.check_match(ls, "TK_UNTIL", "TK_REPEAT", line)
	local condexit = luaY.cond(ls) -- read condition (inside scope block)
	if not bl2.upval then -- no upvalues?
		luaY.leaveblock(fs) -- finish scope
		luaK.patchlist(ls.fs, condexit, repeat_init) -- close the loop
	else -- complete semantics when there are upvalues
		luaY.breakstat(ls) -- if condition then break
		luaK.patchtohere(ls.fs, condexit) -- else...
		luaY.leaveblock(fs) -- finish scope...
		luaK.patchlist(ls.fs, luaK.jump(fs), repeat_init) -- and repeat
	end
	luaY.leaveblock(fs) -- finish loop
end

------------------------------------------------------------------------
-- parse the single expressions needed in numerical for loops
-- * used in fornum()
------------------------------------------------------------------------
function luaY.exp1(ls)
	local e = {} -- expdesc
	luaY.expr(ls, e)
	local k = e.k
	luaK.exp2nextreg(ls.fs, e)
	return k
end

------------------------------------------------------------------------
-- parse a for loop body for both versions of the for loop
-- * used in fornum(), forlist()
------------------------------------------------------------------------
function luaY.forbody(ls, base, line, nvars, isnum)
	-- forbody -> DO block
	local bl = {} -- BlockCnt
	local fs = ls.fs
	luaY.adjustlocalvars(ls, 3) -- control variables
	luaY.checknext(ls, "TK_DO")
	local prep = isnum and luaK.codeAsBx(fs, "OP_FORPREP", base, luaK.NO_JUMP) or luaK.jump(fs)
	luaY.enterblock(fs, bl, false) -- scope for declared variables
	luaY.adjustlocalvars(ls, nvars)
	luaK.reserveregs(fs, nvars)
	luaY.block(ls)
	luaY.leaveblock(fs) -- end of scope for declared variables
	luaK.patchtohere(fs, prep)
	local endfor = isnum and luaK.codeAsBx(fs, "OP_FORLOOP", base, luaK.NO_JUMP)
		or luaK.codeABC(fs, "OP_TFORLOOP", base, 0, nvars)
	luaK.fixline(fs, line) -- pretend that `OP_FOR' starts the loop
	luaK.patchlist(fs, isnum and endfor or luaK.jump(fs), prep + 1)
end

------------------------------------------------------------------------
-- parse a numerical for loop, calls forbody()
-- * used in forstat()
------------------------------------------------------------------------
function luaY.fornum(ls, varname, line)
	-- fornum -> NAME = exp1,exp1[,exp1] forbody
	local fs = ls.fs
	local base = fs.freereg
	luaY.new_localvarliteral(ls, "(for index)", 0)
	luaY.new_localvarliteral(ls, "(for limit)", 1)
	luaY.new_localvarliteral(ls, "(for step)", 2)
	luaY.new_localvar(ls, varname, 3)
	luaY.checknext(ls, "=")
	luaY.exp1(ls) -- initial value
	luaY.checknext(ls, ",")
	luaY.exp1(ls) -- limit
	if luaY.testnext(ls, ",") then
		luaY.exp1(ls) -- optional step
	else -- default step = 1
		luaK.codeABx(fs, "OP_LOADK", fs.freereg, luaK.numberK(fs, 1))
		luaK.reserveregs(fs, 1)
	end
	luaY.forbody(ls, base, line, 1, true)
end

------------------------------------------------------------------------
-- parse a generic for loop, calls forbody()
-- * used in forstat()
------------------------------------------------------------------------
function luaY.forlist(ls, indexname)
	-- forlist -> NAME {,NAME} IN explist1 forbody
	local fs = ls.fs
	local e = {} -- expdesc
	local nvars = 0
	local base = fs.freereg
	-- create control variables
	luaY.new_localvarliteral(ls, "(for generator)", nvars)
	nvars = nvars + 1
	luaY.new_localvarliteral(ls, "(for state)", nvars)
	nvars = nvars + 1
	luaY.new_localvarliteral(ls, "(for control)", nvars)
	nvars = nvars + 1
	-- create declared variables
	luaY.new_localvar(ls, indexname, nvars)
	nvars = nvars + 1
	while luaY.testnext(ls, ",") do
		luaY.new_localvar(ls, luaY.str_checkname(ls), nvars)
		nvars = nvars + 1
	end
	luaY.checknext(ls, "TK_IN")
	local line = ls.linenumber
	luaY.adjust_assign(ls, 3, luaY.explist1(ls, e), e)
	luaK.checkstack(fs, 3) -- extra space to call generator
	luaY.forbody(ls, base, line, nvars - 3, false)
end

------------------------------------------------------------------------
-- initial parsing for a for loop, calls fornum() or forlist()
-- * used in statements()
------------------------------------------------------------------------
function luaY.forstat(ls, line)
	-- forstat -> FOR (fornum | forlist) END
	local fs = ls.fs
	local bl = {} -- BlockCnt
	luaY.enterblock(fs, bl, true) -- scope for loop and control variables
	luaX.next(ls) -- skip `for'
	local varname = luaY.str_checkname(ls) -- first variable name
	local c = ls.t.token
	if c == "=" then
		luaY.fornum(ls, varname, line)
	elseif c == "," or c == "TK_IN" then
		luaY.forlist(ls, varname)
	else
		luaX.syntaxerror(ls, luaY.LUA_QL("=") .. " or " .. luaY.LUA_QL("in") .. " expected")
	end
	luaY.check_match(ls, "TK_END", "TK_FOR", line)
	luaY.leaveblock(fs) -- loop scope (`break' jumps to this point)
end

------------------------------------------------------------------------
-- parse part of an if control structure, including the condition
-- * used in ifstat()
------------------------------------------------------------------------
function luaY.test_then_block(ls)
	-- test_then_block -> [IF | ELSEIF] cond THEN block
	luaX.next(ls) -- skip IF or ELSEIF
	local condexit = luaY.cond(ls)
	luaY.checknext(ls, "TK_THEN")
	luaY.block(ls) -- `then' part
	return condexit
end

------------------------------------------------------------------------
-- parse an if control structure
-- * used in statements()
------------------------------------------------------------------------
function luaY.ifstat(ls, line)
	-- ifstat -> IF cond THEN block {ELSEIF cond THEN block} [ELSE block] END
	local fs = ls.fs
	local escapelist = luaK.NO_JUMP
	local flist = luaY.test_then_block(ls) -- IF cond THEN block
	while ls.t.token == "TK_ELSEIF" do
		escapelist = luaK.concat(fs, escapelist, luaK.jump(fs))
		luaK.patchtohere(fs, flist)
		flist = luaY.test_then_block(ls) -- ELSEIF cond THEN block
	end
	if ls.t.token == "TK_ELSE" then
		escapelist = luaK.concat(fs, escapelist, luaK.jump(fs))
		luaK.patchtohere(fs, flist)
		luaX.next(ls) -- skip ELSE (after patch, for correct line info)
		luaY.block(ls) -- 'else' part
	else
		escapelist = luaK.concat(fs, escapelist, flist)
	end
	luaK.patchtohere(fs, escapelist)
	luaY.check_match(ls, "TK_END", "TK_IF", line)
end

------------------------------------------------------------------------
-- parse a local function statement
-- * used in statements()
------------------------------------------------------------------------
function luaY.localfunc(ls)
	local v, b = {}, {} -- expdesc
	local fs = ls.fs
	luaY.new_localvar(ls, luaY.str_checkname(ls), 0)
	luaY.init_exp(v, "VLOCAL", fs.freereg)
	luaK.reserveregs(fs, 1)
	luaY.adjustlocalvars(ls, 1)
	luaY.body(ls, b, false, ls.linenumber)
	luaK.storevar(fs, v, b)
	-- debug information will only see the variable after this point!
	luaY.getlocvar(fs, fs.nactvar - 1).startpc = fs.pc
end

------------------------------------------------------------------------
-- parse a local variable declaration statement
-- * used in statements()
------------------------------------------------------------------------
function luaY.localstat(ls)
	-- stat -> LOCAL NAME {',' NAME} ['=' explist1]
	local nvars = 0
	local nexps
	local e = {} -- expdesc
	repeat
		luaY.new_localvar(ls, luaY.str_checkname(ls), nvars)
		nvars = nvars + 1
	until not luaY.testnext(ls, ",")
	if luaY.testnext(ls, "=") then
		nexps = luaY.explist1(ls, e)
	else
		e.k = "VVOID"
		nexps = 0
	end
	luaY.adjust_assign(ls, nvars, nexps, e)
	luaY.adjustlocalvars(ls, nvars)
end

------------------------------------------------------------------------
-- parse a function name specification
-- * used in funcstat()
------------------------------------------------------------------------
function luaY.funcname(ls, v)
	-- funcname -> NAME {field} [':' NAME]
	local needself = false
	luaY.singlevar(ls, v)
	while ls.t.token == "." do
		luaY.field(ls, v)
	end
	if ls.t.token == ":" then
		needself = true
		luaY.field(ls, v)
	end
	return needself
end

------------------------------------------------------------------------
-- parse a function statement
-- * used in statements()
------------------------------------------------------------------------
function luaY.funcstat(ls, line)
	-- funcstat -> FUNCTION funcname body
	local v, b = {}, {} -- expdesc
	luaX.next(ls) -- skip FUNCTION
	local needself = luaY.funcname(ls, v)
	luaY.body(ls, b, needself, line)
	luaK.storevar(ls.fs, v, b)
	luaK.fixline(ls.fs, line) -- definition 'happens' in the first line
end

------------------------------------------------------------------------
-- parse a function call with no returns or an assignment statement
-- * used in statements()
------------------------------------------------------------------------
function luaY.exprstat(ls)
	-- stat -> func | assignment
	local fs = ls.fs
	local v = {} -- LHS_assign
	v.v = {}
	luaY.primaryexp(ls, v.v)
	if v.v.k == "VCALL" then -- stat -> func
		luaP.SETARG_C(luaK.getcode(fs, v.v), 1) -- call statement uses no results
	else -- stat -> assignment
		v.prev = nil
		luaY.assignment(ls, v, 1)
	end
end

------------------------------------------------------------------------
-- parse a return statement
-- * used in statements()
------------------------------------------------------------------------
function luaY.retstat(ls)
	-- stat -> RETURN explist
	local fs = ls.fs
	local e = {} -- expdesc
	local first, nret -- registers with returned values
	luaX.next(ls) -- skip RETURN
	if luaY.block_follow(ls.t.token) or ls.t.token == ";" then
		first, nret = 0, 0 -- return no values
	else
		nret = luaY.explist1(ls, e) -- optional return values
		if luaY.hasmultret(e.k) then
			luaK.setmultret(fs, e)
			if e.k == "VCALL" and nret == 1 then -- tail call?
				luaP.SET_OPCODE(luaK.getcode(fs, e), "OP_TAILCALL")
				assert(luaP.GETARG_A(luaK.getcode(fs, e)) == fs.nactvar)
			end
			first = fs.nactvar
			nret = luaY.LUA_MULTRET -- return all values
		else
			if nret == 1 then -- only one single value?
				first = luaK.exp2anyreg(fs, e)
			else
				luaK.exp2nextreg(fs, e) -- values must go to the 'stack'
				first = fs.nactvar -- return all 'active' values
				assert(nret == fs.freereg - first)
			end
		end --if
	end --if
	luaK.ret(fs, first, nret)
end

------------------------------------------------------------------------
-- initial parsing for statements, calls a lot of functions
-- * returns boolean instead of 0|1
-- * used in chunk()
------------------------------------------------------------------------
function luaY.statement(ls)
	local line = ls.linenumber -- may be needed for error messages
	local c = ls.t.token
	if c == "TK_IF" then -- stat -> ifstat
		luaY.ifstat(ls, line)
		return false
	elseif c == "TK_WHILE" then -- stat -> whilestat
		luaY.whilestat(ls, line)
		return false
	elseif c == "TK_DO" then -- stat -> DO block END
		luaX.next(ls) -- skip DO
		luaY.block(ls)
		luaY.check_match(ls, "TK_END", "TK_DO", line)
		return false
	elseif c == "TK_FOR" then -- stat -> forstat
		luaY.forstat(ls, line)
		return false
	elseif c == "TK_REPEAT" then -- stat -> repeatstat
		luaY.repeatstat(ls, line)
		return false
	elseif c == "TK_FUNCTION" then -- stat -> funcstat
		luaY.funcstat(ls, line)
		return false
	elseif c == "TK_LOCAL" then -- stat -> localstat
		luaX.next(ls) -- skip LOCAL
		if luaY.testnext(ls, "TK_FUNCTION") then -- local function?
			luaY.localfunc(ls)
		else
			luaY.localstat(ls)
		end
		return false
	elseif c == "TK_RETURN" then -- stat -> retstat
		luaY.retstat(ls)
		return true -- must be last statement
	elseif c == "TK_BREAK" then -- stat -> breakstat
		luaX.next(ls) -- skip BREAK
		luaY.breakstat(ls)
		return true -- must be last statement
	else
		luaY.exprstat(ls)
		return false -- to avoid warnings
	end --if c
end

------------------------------------------------------------------------
-- parse a chunk, which consists of a bunch of statements
-- * used in parser(), body(), block(), repeatstat()
------------------------------------------------------------------------
function luaY.chunk(ls)
	-- chunk -> { stat [';'] }
	local islast = false
	luaY.enterlevel(ls)
	while not islast and not luaY.block_follow(ls.t.token) do
		islast = luaY.statement(ls)
		luaY.testnext(ls, ";")
		assert(ls.fs.f.maxstacksize >= ls.fs.freereg and ls.fs.freereg >= ls.fs.nactvar)
		ls.fs.freereg = ls.fs.nactvar -- free registers
	end
	luaY.leavelevel(ls)
end

-- }======================================================================

return luaY
