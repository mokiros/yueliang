--[[--------------------------------------------------------------------

  lcode.lua
  Lua 5 code generator in Lua
  This file is part of Yueliang.

  Copyright (c) 2005-2007 Kein-Hong Man <khman@users.sf.net>
  The COPYRIGHT file describes the conditions
  under which this software may be distributed.

  See the ChangeLog for more information.

----------------------------------------------------------------------]]

--[[--------------------------------------------------------------------
-- Notes:
-- * one function manipulate a pointer argument with a simple data type
--   (can't be emulated by a table, ambiguous), now returns that value:
--   luaK.concat(fs, l1, l2)
-- * luaM_growvector uses the faux luaY.growvector, for limit checking
-- * some function parameters changed to boolean, additional code
--   translates boolean back to 1/0 for instruction fields
--
-- Not implemented:
-- * NOTE there is a failed assert in luaK.addk, a porting problem
--
-- Added:
-- * constant MAXSTACK from llimits.h
-- * luaK.ttisnumber(o) (from lobject.h)
-- * luaK.nvalue(o) (from lobject.h)
-- * luaK.setnilvalue(o) (from lobject.h)
-- * luaK.setnvalue(o, x) (from lobject.h)
-- * luaK.setbvalue(o, x) (from lobject.h)
-- * luaK.sethvalue(o, x) (from lobject.h), parameter L deleted
-- * luaK.setsvalue(o, x) (from lobject.h), parameter L deleted
-- * luaK.numadd, luaK.numsub, luaK.nummul, luaK.numdiv, luaK.nummod,
--   luaK.numpow, luaK.numunm, luaK.numisnan (from luaconf.h)
-- * copyexp(e1, e2) added in luaK.posfix to copy expdesc struct
--
-- Changed in 5.1.x:
-- * enum BinOpr has a new entry, OPR_MOD
-- * enum UnOpr has a new entry, OPR_LEN
-- * binopistest, unused in 5.0.x, has been deleted
-- * macro setmultret is new
-- * functions isnumeral, luaK_ret, boolK are new
-- * funcion nilK was named nil_constant in 5.0.x
-- * function interface changed: need_value, patchtestreg, concat
-- * TObject now a TValue
-- * functions luaK_setreturns, luaK_setoneret are new
-- * function luaK.setcallreturns deleted, to be replaced by:
--   luaK.setmultret, luaK.ret, luaK.setreturns, luaK.setoneret
-- * functions constfolding, codearith, codecomp are new
-- * luaK.codebinop has been deleted
-- * function luaK_setlist is new
-- * OPR_MULT renamed to OPR_MUL
----------------------------------------------------------------------]]

-- requires luaP, luaX, luaY
local luaP = require("./lopcodes")
local luaX = require("./llex")

-- Prevent circular dependency
local luaY = {
	LUA_MULTRET = -1,
}

local luaK = {}

------------------------------------------------------------------------
-- constants used by code generator
------------------------------------------------------------------------
-- maximum stack for a Lua function
luaK.MAXSTACK = 250 -- (from llimits.h)

--[[--------------------------------------------------------------------
-- other functions
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- emulation of TValue macros (these are from lobject.h)
-- * TValue is a table since lcode passes references around
-- * tt member field removed, using Lua's type() instead
-- * for setsvalue, sethvalue, parameter L (deleted here) in lobject.h
--   is used in an assert for testing, see checkliveness(g,obj)
------------------------------------------------------------------------
function luaK.ttisnumber(o)
	if o then
		return type(o.value) == "number"
	else
		return false
	end
end
function luaK.nvalue(o)
	return o.value
end
function luaK.setnilvalue(o)
	o.value = nil
end
function luaK.setsvalue(o, x)
	o.value = x
end
luaK.setnvalue = luaK.setsvalue
luaK.sethvalue = luaK.setsvalue
luaK.setbvalue = luaK.setsvalue

------------------------------------------------------------------------
-- The luai_num* macros define the primitive operations over numbers.
-- * this is not the entire set of primitive operations from luaconf.h
-- * used in luaK.constfolding()
------------------------------------------------------------------------
function luaK.numadd(a, b)
	return a + b
end
function luaK.numsub(a, b)
	return a - b
end
function luaK.nummul(a, b)
	return a * b
end
function luaK.numdiv(a, b)
	return a / b
end
function luaK.nummod(a, b)
	return a % b
end
-- ((a) - floor((a)/(b))*(b)) /* actual, for reference */
function luaK.numpow(a, b)
	return a ^ b
end
function luaK.numunm(a)
	return -a
end
function luaK.numisnan(a)
	return not a == a
end
-- a NaN cannot equal another NaN

--[[--------------------------------------------------------------------
-- code generator functions
----------------------------------------------------------------------]]

------------------------------------------------------------------------
-- Marks the end of a patch list. It is an invalid value both as an absolute
-- address, and as a list link (would link an element to itself).
------------------------------------------------------------------------
luaK.NO_JUMP = -1

------------------------------------------------------------------------
-- grep "ORDER OPR" if you change these enums
------------------------------------------------------------------------
luaK.BinOpr = {
	OPR_ADD = 0,
	OPR_SUB = 1,
	OPR_MUL = 2,
	OPR_DIV = 3,
	OPR_MOD = 4,
	OPR_POW = 5,
	OPR_CONCAT = 6,
	OPR_NE = 7,
	OPR_EQ = 8,
	OPR_LT = 9,
	OPR_LE = 10,
	OPR_GT = 11,
	OPR_GE = 12,
	OPR_AND = 13,
	OPR_OR = 14,
	OPR_NOBINOPR = 15,
}

-- * UnOpr is used by luaK.prefix's op argument, but not directly used
--   because the function receives the symbols as strings, e.g. "OPR_NOT"
luaK.UnOpr = {
	OPR_MINUS = 0,
	OPR_NOT = 1,
	OPR_LEN = 2,
	OPR_NOUNOPR = 3,
}

------------------------------------------------------------------------
-- returns the instruction object for given e (expdesc), was a macro
------------------------------------------------------------------------
function luaK.getcode(fs, e)
	return fs.f.code[e.info]
end

------------------------------------------------------------------------
-- codes an instruction with a signed Bx (sBx) field, was a macro
-- * used in luaK.jump(), (lparser) luaY.forbody()
------------------------------------------------------------------------
function luaK.codeAsBx(fs, o, A, sBx)
	return luaK.codeABx(fs, o, A, sBx + luaP.MAXARG_sBx)
end

------------------------------------------------------------------------
-- set the expdesc e instruction for multiple returns, was a macro
------------------------------------------------------------------------
function luaK.setmultret(fs, e)
	luaK.setreturns(fs, e, luaY.LUA_MULTRET)
end

------------------------------------------------------------------------
-- there is a jump if patch lists are not identical, was a macro
-- * used in luaK.exp2reg(), luaK.exp2anyreg(), luaK.exp2val()
------------------------------------------------------------------------
function luaK.hasjumps(e)
	return e.t ~= e.f
end

------------------------------------------------------------------------
-- true if the expression is a constant number (for constant folding)
-- * used in constfolding(), infix()
------------------------------------------------------------------------
function luaK.isnumeral(e)
	return e.k == "VKNUM" and e.t == luaK.NO_JUMP and e.f == luaK.NO_JUMP
end

------------------------------------------------------------------------
-- codes loading of nil, optimization done if consecutive locations
-- * used in luaK.discharge2reg(), (lparser) luaY.adjust_assign()
------------------------------------------------------------------------
function luaK._nil(fs, from, n)
	if fs.pc > fs.lasttarget then -- no jumps to current position?
		if fs.pc == 0 then -- function start?
			if from >= fs.nactvar then
				return -- positions are already clean
			end
		else
			local previous = fs.f.code[fs.pc - 1]
			if luaP.GET_OPCODE(previous) == "OP_LOADNIL" then
				local pfrom = luaP.GETARG_A(previous)
				local pto = luaP.GETARG_B(previous)
				if pfrom <= from and from <= pto + 1 then -- can connect both?
					if from + n - 1 > pto then
						luaP.SETARG_B(previous, from + n - 1)
					end
					return
				end
			end
		end
	end
	luaK.codeABC(fs, "OP_LOADNIL", from, from + n - 1, 0) -- else no optimization
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.jump(fs)
	local jpc = fs.jpc -- save list of jumps to here
	fs.jpc = luaK.NO_JUMP
	local j = luaK.codeAsBx(fs, "OP_JMP", 0, luaK.NO_JUMP)
	j = luaK.concat(fs, j, jpc) -- keep them on hold
	return j
end

------------------------------------------------------------------------
-- codes a RETURN instruction
-- * used in luaY.close_func(), luaY.retstat()
------------------------------------------------------------------------
function luaK.ret(fs, first, nret)
	luaK.codeABC(fs, "OP_RETURN", first, nret + 1, 0)
end

------------------------------------------------------------------------
--
-- * used in luaK.jumponcond(), luaK.codecomp()
------------------------------------------------------------------------
function luaK.condjump(fs, op, A, B, C)
	luaK.codeABC(fs, op, A, B, C)
	return luaK.jump(fs)
end

------------------------------------------------------------------------
--
-- * used in luaK.patchlistaux(), luaK.concat()
------------------------------------------------------------------------
function luaK.fixjump(fs, pc, dest)
	local jmp = fs.f.code[pc]
	local offset = dest - (pc + 1)
	assert(dest ~= luaK.NO_JUMP)
	if math.abs(offset) > luaP.MAXARG_sBx then
		luaX.syntaxerror(fs.ls, "control structure too long")
	end
	luaP.SETARG_sBx(jmp, offset)
end

------------------------------------------------------------------------
-- returns current 'pc' and marks it as a jump target (to avoid wrong
-- optimizations with consecutive instructions not in the same basic block).
-- * used in multiple locations
-- * fs.lasttarget tested only by luaK._nil() when optimizing OP_LOADNIL
------------------------------------------------------------------------
function luaK.getlabel(fs)
	fs.lasttarget = fs.pc
	return fs.pc
end

------------------------------------------------------------------------
--
-- * used in luaK.need_value(), luaK.removevalues(), luaK.patchlistaux(),
--   luaK.concat()
------------------------------------------------------------------------
function luaK.getjump(fs, pc)
	local offset = luaP.GETARG_sBx(fs.f.code[pc])
	if offset == luaK.NO_JUMP then -- point to itself represents end of list
		return luaK.NO_JUMP -- end of list
	else
		return (pc + 1) + offset -- turn offset into absolute position
	end
end

------------------------------------------------------------------------
--
-- * used in luaK.need_value(), luaK.patchtestreg(), luaK.invertjump()
------------------------------------------------------------------------
function luaK.getjumpcontrol(fs, pc)
	local pi = fs.f.code[pc]
	local ppi = fs.f.code[pc - 1]
	if pc >= 1 and luaP.testTMode(luaP.GET_OPCODE(ppi)) ~= 0 then
		return ppi
	else
		return pi
	end
end

------------------------------------------------------------------------
-- check whether list has any jump that do not produce a value
-- (or produce an inverted value)
-- * return value changed to boolean
-- * used only in luaK.exp2reg()
------------------------------------------------------------------------
function luaK.need_value(fs, list)
	while list ~= luaK.NO_JUMP do
		local i = luaK.getjumpcontrol(fs, list)
		if luaP.GET_OPCODE(i) ~= "OP_TESTSET" then
			return true
		end
		list = luaK.getjump(fs, list)
	end
	return false -- not found
end

------------------------------------------------------------------------
--
-- * used in luaK.removevalues(), luaK.patchlistaux()
------------------------------------------------------------------------
function luaK.patchtestreg(fs, node, reg)
	local i = luaK.getjumpcontrol(fs, node)
	if luaP.GET_OPCODE(i) ~= "OP_TESTSET" then
		return false -- cannot patch other instructions
	end
	if reg ~= luaP.NO_REG and reg ~= luaP.GETARG_B(i) then
		luaP.SETARG_A(i, reg)
	else -- no register to put value or register already has the value
		-- due to use of a table as i, i cannot be replaced by another table
		-- so the following is required; there is no change to ARG_C
		luaP.SET_OPCODE(i, "OP_TEST")
		local b = luaP.GETARG_B(i)
		luaP.SETARG_A(i, b)
		luaP.SETARG_B(i, 0)
		-- *i = CREATE_ABC(OP_TEST, GETARG_B(*i), 0, GETARG_C(*i)); /* C */
	end
	return true
end

------------------------------------------------------------------------
--
-- * used only in luaK.codenot()
------------------------------------------------------------------------
function luaK.removevalues(fs, list)
	while list ~= luaK.NO_JUMP do
		luaK.patchtestreg(fs, list, luaP.NO_REG)
		list = luaK.getjump(fs, list)
	end
end

------------------------------------------------------------------------
--
-- * used in luaK.dischargejpc(), luaK.patchlist(), luaK.exp2reg()
------------------------------------------------------------------------
function luaK.patchlistaux(fs, list, vtarget, reg, dtarget)
	while list ~= luaK.NO_JUMP do
		local _next = luaK.getjump(fs, list)
		if luaK.patchtestreg(fs, list, reg) then
			luaK.fixjump(fs, list, vtarget)
		else
			luaK.fixjump(fs, list, dtarget) -- jump to default target
		end
		list = _next
	end
end

------------------------------------------------------------------------
--
-- * used only in luaK.code()
------------------------------------------------------------------------
function luaK.dischargejpc(fs)
	luaK.patchlistaux(fs, fs.jpc, fs.pc, luaP.NO_REG, fs.pc)
	fs.jpc = luaK.NO_JUMP
end

------------------------------------------------------------------------
--
-- * used in (lparser) luaY.whilestat(), luaY.repeatstat(), luaY.forbody()
------------------------------------------------------------------------
function luaK.patchlist(fs, list, target)
	if target == fs.pc then
		luaK.patchtohere(fs, list)
	else
		assert(target < fs.pc)
		luaK.patchlistaux(fs, list, target, luaP.NO_REG, target)
	end
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.patchtohere(fs, list)
	luaK.getlabel(fs)
	fs.jpc = luaK.concat(fs, fs.jpc, list)
end

------------------------------------------------------------------------
-- * l1 was a pointer, now l1 is returned and callee assigns the value
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.concat(fs, l1, l2)
	if l2 == luaK.NO_JUMP then
		return l1
	elseif l1 == luaK.NO_JUMP then
		return l2
	else
		local list = l1
		local _next = luaK.getjump(fs, list)
		while _next ~= luaK.NO_JUMP do -- find last element
			list = _next
			_next = luaK.getjump(fs, list)
		end
		luaK.fixjump(fs, list, l2)
	end
	return l1
end

------------------------------------------------------------------------
--
-- * used in luaK.reserveregs(), (lparser) luaY.forlist()
------------------------------------------------------------------------
function luaK.checkstack(fs, n)
	local newstack = fs.freereg + n
	if newstack > fs.f.maxstacksize then
		if newstack >= luaK.MAXSTACK then
			luaX.syntaxerror(fs.ls, "function or expression too complex")
		end
		fs.f.maxstacksize = newstack
	end
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.reserveregs(fs, n)
	luaK.checkstack(fs, n)
	fs.freereg = fs.freereg + n
end

------------------------------------------------------------------------
--
-- * used in luaK.freeexp(), luaK.dischargevars()
------------------------------------------------------------------------
function luaK.freereg(fs, reg)
	if not luaP.ISK(reg) and reg >= fs.nactvar then
		fs.freereg = fs.freereg - 1
		assert(reg == fs.freereg)
	end
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.freeexp(fs, e)
	if e.k == "VNONRELOC" then
		luaK.freereg(fs, e.info)
	end
end

------------------------------------------------------------------------
-- * TODO NOTE implementation is not 100% correct, since the assert fails
-- * luaH_set, setobj deleted; direct table access used instead
-- * used in luaK.stringK(), luaK.numberK(), luaK.boolK(), luaK.nilK()
------------------------------------------------------------------------
function luaK.addk(fs, k, v)
	local L = fs.L
	local idx = fs.h[k.value]
	--TValue *idx = luaH_set(L, fs->h, k); /* C */
	local f = fs.f
	if luaK.ttisnumber(idx) then
		--TODO this assert currently FAILS (last tested for 5.0.2)
		--assert(fs.f.k[luaK.nvalue(idx)] == v)
		--assert(luaO_rawequalObj(&fs->f->k[cast_int(nvalue(idx))], v)); /* C */
		return luaK.nvalue(idx)
	else -- constant not found; create a new entry
		idx = {}
		luaK.setnvalue(idx, fs.nk)
		fs.h[k.value] = idx
		-- setnvalue(idx, cast_num(fs->nk)); /* C */
		-- luaY.growvector(L, f.k, fs.nk, f.sizek, nil, luaP.MAXARG_Bx, "constant table overflow")
		-- loop to initialize empty f.k positions not required
		f.k[fs.nk] = v
		-- setobj(L, &f->k[fs->nk], v); /* C */
		-- luaC_barrier(L, f, v); /* GC */
		local nk = fs.nk
		fs.nk = fs.nk + 1
		return nk
	end
end

------------------------------------------------------------------------
-- creates and sets a string object
-- * used in (lparser) luaY.codestring(), luaY.singlevar()
------------------------------------------------------------------------
function luaK.stringK(fs, s)
	local o = {} -- TValue
	luaK.setsvalue(o, s)
	return luaK.addk(fs, o, o)
end

------------------------------------------------------------------------
-- creates and sets a number object
-- * used in luaK.prefix() for negative (or negation of) numbers
-- * used in (lparser) luaY.simpleexp(), luaY.fornum()
------------------------------------------------------------------------
function luaK.numberK(fs, r)
	local o = {} -- TValue
	luaK.setnvalue(o, r)
	return luaK.addk(fs, o, o)
end

------------------------------------------------------------------------
-- creates and sets a boolean object
-- * used only in luaK.exp2RK()
------------------------------------------------------------------------
function luaK.boolK(fs, b)
	local o = {} -- TValue
	luaK.setbvalue(o, b)
	return luaK.addk(fs, o, o)
end

------------------------------------------------------------------------
-- creates and sets a nil object
-- * used only in luaK.exp2RK()
------------------------------------------------------------------------
function luaK.nilK(fs)
	local k, v = {}, {} -- TValue
	luaK.setnilvalue(v)
	-- cannot use nil as key; instead use table itself to represent nil
	luaK.sethvalue(k, fs.h)
	return luaK.addk(fs, k, v)
end

------------------------------------------------------------------------
--
-- * used in luaK.setmultret(), (lparser) luaY.adjust_assign()
------------------------------------------------------------------------
function luaK.setreturns(fs, e, nresults)
	if e.k == "VCALL" then -- expression is an open function call?
		luaP.SETARG_C(luaK.getcode(fs, e), nresults + 1)
	elseif e.k == "VVARARG" then
		luaP.SETARG_B(luaK.getcode(fs, e), nresults + 1)
		luaP.SETARG_A(luaK.getcode(fs, e), fs.freereg)
		luaK.reserveregs(fs, 1)
	end
end

------------------------------------------------------------------------
--
-- * used in luaK.dischargevars(), (lparser) luaY.assignment()
------------------------------------------------------------------------
function luaK.setoneret(fs, e)
	if e.k == "VCALL" then -- expression is an open function call?
		e.k = "VNONRELOC"
		e.info = luaP.GETARG_A(luaK.getcode(fs, e))
	elseif e.k == "VVARARG" then
		luaP.SETARG_B(luaK.getcode(fs, e), 2)
		e.k = "VRELOCABLE" -- can relocate its simple result
	end
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.dischargevars(fs, e)
	local k = e.k
	if k == "VLOCAL" then
		e.k = "VNONRELOC"
	elseif k == "VUPVAL" then
		e.info = luaK.codeABC(fs, "OP_GETUPVAL", 0, e.info, 0)
		e.k = "VRELOCABLE"
	elseif k == "VGLOBAL" then
		e.info = luaK.codeABx(fs, "OP_GETGLOBAL", 0, e.info)
		e.k = "VRELOCABLE"
	elseif k == "VINDEXED" then
		luaK.freereg(fs, e.aux)
		luaK.freereg(fs, e.info)
		e.info = luaK.codeABC(fs, "OP_GETTABLE", 0, e.info, e.aux)
		e.k = "VRELOCABLE"
	elseif k == "VVARARG" or k == "VCALL" then
		luaK.setoneret(fs, e)
	else
		-- there is one value available (somewhere)
	end
end

------------------------------------------------------------------------
--
-- * used only in luaK.exp2reg()
------------------------------------------------------------------------
function luaK.code_label(fs, A, b, jump)
	luaK.getlabel(fs) -- those instructions may be jump targets
	return luaK.codeABC(fs, "OP_LOADBOOL", A, b, jump)
end

------------------------------------------------------------------------
--
-- * used in luaK.discharge2anyreg(), luaK.exp2reg()
------------------------------------------------------------------------
function luaK.discharge2reg(fs, e, reg)
	luaK.dischargevars(fs, e)
	local k = e.k
	if k == "VNIL" then
		luaK._nil(fs, reg, 1)
	elseif k == "VFALSE" or k == "VTRUE" then
		luaK.codeABC(fs, "OP_LOADBOOL", reg, (e.k == "VTRUE") and 1 or 0, 0)
	elseif k == "VK" then
		luaK.codeABx(fs, "OP_LOADK", reg, e.info)
	elseif k == "VKNUM" then
		luaK.codeABx(fs, "OP_LOADK", reg, luaK.numberK(fs, e.nval))
	elseif k == "VRELOCABLE" then
		local pc = luaK.getcode(fs, e)
		luaP.SETARG_A(pc, reg)
	elseif k == "VNONRELOC" then
		if reg ~= e.info then
			luaK.codeABC(fs, "OP_MOVE", reg, e.info, 0)
		end
	else
		assert(e.k == "VVOID" or e.k == "VJMP")
		return -- nothing to do...
	end
	e.info = reg
	e.k = "VNONRELOC"
end

------------------------------------------------------------------------
--
-- * used in luaK.jumponcond(), luaK.codenot()
------------------------------------------------------------------------
function luaK.discharge2anyreg(fs, e)
	if e.k ~= "VNONRELOC" then
		luaK.reserveregs(fs, 1)
		luaK.discharge2reg(fs, e, fs.freereg - 1)
	end
end

------------------------------------------------------------------------
--
-- * used in luaK.exp2nextreg(), luaK.exp2anyreg(), luaK.storevar()
------------------------------------------------------------------------
function luaK.exp2reg(fs, e, reg)
	luaK.discharge2reg(fs, e, reg)
	if e.k == "VJMP" then
		e.t = luaK.concat(fs, e.t, e.info) -- put this jump in 't' list
	end
	if luaK.hasjumps(e) then
		local final -- position after whole expression
		local p_f = luaK.NO_JUMP -- position of an eventual LOAD false
		local p_t = luaK.NO_JUMP -- position of an eventual LOAD true
		if luaK.need_value(fs, e.t) or luaK.need_value(fs, e.f) then
			local fj = (e.k == "VJMP") and luaK.NO_JUMP or luaK.jump(fs)
			p_f = luaK.code_label(fs, reg, 0, 1)
			p_t = luaK.code_label(fs, reg, 1, 0)
			luaK.patchtohere(fs, fj)
		end
		final = luaK.getlabel(fs)
		luaK.patchlistaux(fs, e.f, final, reg, p_f)
		luaK.patchlistaux(fs, e.t, final, reg, p_t)
	end
	e.f, e.t = luaK.NO_JUMP, luaK.NO_JUMP
	e.info = reg
	e.k = "VNONRELOC"
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.exp2nextreg(fs, e)
	luaK.dischargevars(fs, e)
	luaK.freeexp(fs, e)
	luaK.reserveregs(fs, 1)
	luaK.exp2reg(fs, e, fs.freereg - 1)
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.exp2anyreg(fs, e)
	luaK.dischargevars(fs, e)
	if e.k == "VNONRELOC" then
		if not luaK.hasjumps(e) then -- exp is already in a register
			return e.info
		end
		if e.info >= fs.nactvar then -- reg. is not a local?
			luaK.exp2reg(fs, e, e.info) -- put value on it
			return e.info
		end
	end
	luaK.exp2nextreg(fs, e) -- default
	return e.info
end

------------------------------------------------------------------------
--
-- * used in luaK.exp2RK(), luaK.prefix(), luaK.posfix()
-- * used in (lparser) luaY.yindex()
------------------------------------------------------------------------
function luaK.exp2val(fs, e)
	if luaK.hasjumps(e) then
		luaK.exp2anyreg(fs, e)
	else
		luaK.dischargevars(fs, e)
	end
end

------------------------------------------------------------------------
--
-- * used in multiple locations
------------------------------------------------------------------------
function luaK.exp2RK(fs, e)
	luaK.exp2val(fs, e)
	local k = e.k
	if k == "VKNUM" or k == "VTRUE" or k == "VFALSE" or k == "VNIL" then
		if fs.nk <= luaP.MAXINDEXRK then -- constant fit in RK operand?
			-- converted from a 2-deep ternary operator expression
			if e.k == "VNIL" then
				e.info = luaK.nilK(fs)
			else
				e.info = (e.k == "VKNUM") and luaK.numberK(fs, e.nval) or luaK.boolK(fs, e.k == "VTRUE")
			end
			e.k = "VK"
			return luaP.RKASK(e.info)
		end
	elseif k == "VK" then
		if e.info <= luaP.MAXINDEXRK then -- constant fit in argC?
			return luaP.RKASK(e.info)
		end
	else
		-- default
	end
	-- not a constant in the right range: put it in a register
	return luaK.exp2anyreg(fs, e)
end

------------------------------------------------------------------------
--
-- * used in (lparser) luaY.assignment(), luaY.localfunc(), luaY.funcstat()
------------------------------------------------------------------------
function luaK.storevar(fs, var, ex)
	local k = var.k
	if k == "VLOCAL" then
		luaK.freeexp(fs, ex)
		luaK.exp2reg(fs, ex, var.info)
		return
	elseif k == "VUPVAL" then
		local e = luaK.exp2anyreg(fs, ex)
		luaK.codeABC(fs, "OP_SETUPVAL", e, var.info, 0)
	elseif k == "VGLOBAL" then
		local e = luaK.exp2anyreg(fs, ex)
		luaK.codeABx(fs, "OP_SETGLOBAL", e, var.info)
	elseif k == "VINDEXED" then
		local e = luaK.exp2RK(fs, ex)
		luaK.codeABC(fs, "OP_SETTABLE", var.info, var.aux, e)
	else
		assert(0) -- invalid var kind to store
	end
	luaK.freeexp(fs, ex)
end

------------------------------------------------------------------------
--
-- * used only in (lparser) luaY.primaryexp()
------------------------------------------------------------------------
function luaK._self(fs, e, key)
	luaK.exp2anyreg(fs, e)
	luaK.freeexp(fs, e)
	local func = fs.freereg
	luaK.reserveregs(fs, 2)
	luaK.codeABC(fs, "OP_SELF", func, e.info, luaK.exp2RK(fs, key))
	luaK.freeexp(fs, key)
	e.info = func
	e.k = "VNONRELOC"
end

------------------------------------------------------------------------
--
-- * used in luaK.goiftrue(), luaK.codenot()
------------------------------------------------------------------------
function luaK.invertjump(fs, e)
	local pc = luaK.getjumpcontrol(fs, e.info)
	assert(
		luaP.testTMode(luaP.GET_OPCODE(pc)) ~= 0
			and luaP.GET_OPCODE(pc) ~= "OP_TESTSET"
			and luaP.GET_OPCODE(pc) ~= "OP_TEST"
	)
	luaP.SETARG_A(pc, (luaP.GETARG_A(pc) == 0) and 1 or 0)
end

------------------------------------------------------------------------
--
-- * used in luaK.goiftrue(), luaK.goiffalse()
------------------------------------------------------------------------
function luaK.jumponcond(fs, e, cond)
	if e.k == "VRELOCABLE" then
		local ie = luaK.getcode(fs, e)
		if luaP.GET_OPCODE(ie) == "OP_NOT" then
			fs.pc = fs.pc - 1 -- remove previous OP_NOT
			return luaK.condjump(fs, "OP_TEST", luaP.GETARG_B(ie), 0, cond and 0 or 1)
		end
		-- else go through
	end
	luaK.discharge2anyreg(fs, e)
	luaK.freeexp(fs, e)
	return luaK.condjump(fs, "OP_TESTSET", luaP.NO_REG, e.info, cond and 1 or 0)
end

------------------------------------------------------------------------
--
-- * used in luaK.infix(), (lparser) luaY.cond()
------------------------------------------------------------------------
function luaK.goiftrue(fs, e)
	local pc -- pc of last jump
	luaK.dischargevars(fs, e)
	local k = e.k
	if k == "VK" or k == "VKNUM" or k == "VTRUE" then
		pc = luaK.NO_JUMP -- always true; do nothing
	elseif k == "VFALSE" then
		pc = luaK.jump(fs) -- always jump
	elseif k == "VJMP" then
		luaK.invertjump(fs, e)
		pc = e.info
	else
		pc = luaK.jumponcond(fs, e, false)
	end
	e.f = luaK.concat(fs, e.f, pc) -- insert last jump in `f' list
	luaK.patchtohere(fs, e.t)
	e.t = luaK.NO_JUMP
end

------------------------------------------------------------------------
--
-- * used in luaK.infix()
------------------------------------------------------------------------
function luaK.goiffalse(fs, e)
	local pc -- pc of last jump
	luaK.dischargevars(fs, e)
	local k = e.k
	if k == "VNIL" or k == "VFALSE" then
		pc = luaK.NO_JUMP -- always false; do nothing
	elseif k == "VTRUE" then
		pc = luaK.jump(fs) -- always jump
	elseif k == "VJMP" then
		pc = e.info
	else
		pc = luaK.jumponcond(fs, e, true)
	end
	e.t = luaK.concat(fs, e.t, pc) -- insert last jump in `t' list
	luaK.patchtohere(fs, e.f)
	e.f = luaK.NO_JUMP
end

------------------------------------------------------------------------
--
-- * used only in luaK.prefix()
------------------------------------------------------------------------
function luaK.codenot(fs, e)
	luaK.dischargevars(fs, e)
	local k = e.k
	if k == "VNIL" or k == "VFALSE" then
		e.k = "VTRUE"
	elseif k == "VK" or k == "VKNUM" or k == "VTRUE" then
		e.k = "VFALSE"
	elseif k == "VJMP" then
		luaK.invertjump(fs, e)
	elseif k == "VRELOCABLE" or k == "VNONRELOC" then
		luaK.discharge2anyreg(fs, e)
		luaK.freeexp(fs, e)
		e.info = luaK.codeABC(fs, "OP_NOT", 0, e.info, 0)
		e.k = "VRELOCABLE"
	else
		assert(0) -- cannot happen
	end
	-- interchange true and false lists
	e.f, e.t = e.t, e.f
	luaK.removevalues(fs, e.f)
	luaK.removevalues(fs, e.t)
end

------------------------------------------------------------------------
--
-- * used in (lparser) luaY.field(), luaY.primaryexp()
------------------------------------------------------------------------
function luaK.indexed(fs, t, k)
	t.aux = luaK.exp2RK(fs, k)
	t.k = "VINDEXED"
end

------------------------------------------------------------------------
--
-- * used only in luaK.codearith()
------------------------------------------------------------------------
function luaK.constfolding(op, e1, e2)
	local r
	if not luaK.isnumeral(e1) or not luaK.isnumeral(e2) then
		return false
	end
	local v1 = e1.nval
	local v2 = e2.nval
	if op == "OP_ADD" then
		r = luaK.numadd(v1, v2)
	elseif op == "OP_SUB" then
		r = luaK.numsub(v1, v2)
	elseif op == "OP_MUL" then
		r = luaK.nummul(v1, v2)
	elseif op == "OP_DIV" then
		if v2 == 0 then
			return false
		end -- do not attempt to divide by 0
		r = luaK.numdiv(v1, v2)
	elseif op == "OP_MOD" then
		if v2 == 0 then
			return false
		end -- do not attempt to divide by 0
		r = luaK.nummod(v1, v2)
	elseif op == "OP_POW" then
		r = luaK.numpow(v1, v2)
	elseif op == "OP_UNM" then
		r = luaK.numunm(v1)
	elseif op == "OP_LEN" then
		return false -- no constant folding for 'len'
	else
		assert(0)
		r = 0
	end
	if luaK.numisnan(r) then
		return false
	end -- do not attempt to produce NaN
	e1.nval = r
	return true
end

------------------------------------------------------------------------
--
-- * used in luaK.prefix(), luaK.posfix()
------------------------------------------------------------------------
function luaK.codearith(fs, op, e1, e2)
	if luaK.constfolding(op, e1, e2) then
		return
	else
		local o2 = (op ~= "OP_UNM" and op ~= "OP_LEN") and luaK.exp2RK(fs, e2) or 0
		local o1 = luaK.exp2RK(fs, e1)
		if o1 > o2 then
			luaK.freeexp(fs, e1)
			luaK.freeexp(fs, e2)
		else
			luaK.freeexp(fs, e2)
			luaK.freeexp(fs, e1)
		end
		e1.info = luaK.codeABC(fs, op, 0, o1, o2)
		e1.k = "VRELOCABLE"
	end
end

------------------------------------------------------------------------
--
-- * used only in luaK.posfix()
------------------------------------------------------------------------
function luaK.codecomp(fs, op, cond, e1, e2)
	local o1 = luaK.exp2RK(fs, e1)
	local o2 = luaK.exp2RK(fs, e2)
	luaK.freeexp(fs, e2)
	luaK.freeexp(fs, e1)
	if cond == 0 and op ~= "OP_EQ" then
		-- exchange args to replace by `<' or `<='
		o1, o2 = o2, o1 -- o1 <==> o2
		cond = 1
	end
	e1.info = luaK.condjump(fs, op, cond, o1, o2)
	e1.k = "VJMP"
end

------------------------------------------------------------------------
--
-- * used only in (lparser) luaY.subexpr()
------------------------------------------------------------------------
function luaK.prefix(fs, op, e)
	local e2 = {} -- expdesc
	e2.t, e2.f = luaK.NO_JUMP, luaK.NO_JUMP
	e2.k = "VKNUM"
	e2.nval = 0
	if op == "OPR_MINUS" then
		if not luaK.isnumeral(e) then
			luaK.exp2anyreg(fs, e) -- cannot operate on non-numeric constants
		end
		luaK.codearith(fs, "OP_UNM", e, e2)
	elseif op == "OPR_NOT" then
		luaK.codenot(fs, e)
	elseif op == "OPR_LEN" then
		luaK.exp2anyreg(fs, e) -- cannot operate on constants
		luaK.codearith(fs, "OP_LEN", e, e2)
	else
		assert(0)
	end
end

------------------------------------------------------------------------
--
-- * used only in (lparser) luaY.subexpr()
------------------------------------------------------------------------
function luaK.infix(fs, op, v)
	if op == "OPR_AND" then
		luaK.goiftrue(fs, v)
	elseif op == "OPR_OR" then
		luaK.goiffalse(fs, v)
	elseif op == "OPR_CONCAT" then
		luaK.exp2nextreg(fs, v) -- operand must be on the 'stack'
	elseif
		op == "OPR_ADD"
		or op == "OPR_SUB"
		or op == "OPR_MUL"
		or op == "OPR_DIV"
		or op == "OPR_MOD"
		or op == "OPR_POW"
	then
		if not luaK.isnumeral(v) then
			luaK.exp2RK(fs, v)
		end
	else
		luaK.exp2RK(fs, v)
	end
end

------------------------------------------------------------------------
--
-- * used only in (lparser) luaY.subexpr()
------------------------------------------------------------------------
-- table lookups to simplify testing
luaK.arith_op = {
	OPR_ADD = "OP_ADD",
	OPR_SUB = "OP_SUB",
	OPR_MUL = "OP_MUL",
	OPR_DIV = "OP_DIV",
	OPR_MOD = "OP_MOD",
	OPR_POW = "OP_POW",
}
luaK.comp_op = {
	OPR_EQ = "OP_EQ",
	OPR_NE = "OP_EQ",
	OPR_LT = "OP_LT",
	OPR_LE = "OP_LE",
	OPR_GT = "OP_LT",
	OPR_GE = "OP_LE",
}
luaK.comp_cond = {
	OPR_EQ = 1,
	OPR_NE = 0,
	OPR_LT = 1,
	OPR_LE = 1,
	OPR_GT = 0,
	OPR_GE = 0,
}
function luaK.posfix(fs, op, e1, e2)
	-- needed because e1 = e2 doesn't copy values...
	-- * in 5.0.x, only k/info/aux/t/f copied, t for AND, f for OR
	--   but here, all elements are copied for completeness' sake
	local function copyexp(e1, e2)
		e1.k = e2.k
		e1.info = e2.info
		e1.aux = e2.aux
		e1.nval = e2.nval
		e1.t = e2.t
		e1.f = e2.f
	end
	if op == "OPR_AND" then
		assert(e1.t == luaK.NO_JUMP) -- list must be closed
		luaK.dischargevars(fs, e2)
		e2.f = luaK.concat(fs, e2.f, e1.f)
		copyexp(e1, e2)
	elseif op == "OPR_OR" then
		assert(e1.f == luaK.NO_JUMP) -- list must be closed
		luaK.dischargevars(fs, e2)
		e2.t = luaK.concat(fs, e2.t, e1.t)
		copyexp(e1, e2)
	elseif op == "OPR_CONCAT" then
		luaK.exp2val(fs, e2)
		if e2.k == "VRELOCABLE" and luaP.GET_OPCODE(luaK.getcode(fs, e2)) == "OP_CONCAT" then
			assert(e1.info == luaP.GETARG_B(luaK.getcode(fs, e2)) - 1)
			luaK.freeexp(fs, e1)
			luaP.SETARG_B(luaK.getcode(fs, e2), e1.info)
			e1.k = "VRELOCABLE"
			e1.info = e2.info
		else
			luaK.exp2nextreg(fs, e2) -- operand must be on the 'stack'
			luaK.codearith(fs, "OP_CONCAT", e1, e2)
		end
	else
		-- the following uses a table lookup in place of conditionals
		local arith = luaK.arith_op[op]
		if arith then
			luaK.codearith(fs, arith, e1, e2)
		else
			local comp = luaK.comp_op[op]
			if comp then
				luaK.codecomp(fs, comp, luaK.comp_cond[op], e1, e2)
			else
				assert(0)
			end
		end --if arith
	end --if op
end

------------------------------------------------------------------------
-- adjusts debug information for last instruction written, in order to
-- change the line where item comes into existence
-- * used in (lparser) luaY.funcargs(), luaY.forbody(), luaY.funcstat()
------------------------------------------------------------------------
function luaK.fixline(fs, line)
	fs.f.lineinfo[fs.pc - 1] = line
end

------------------------------------------------------------------------
-- general function to write an instruction into the instruction buffer,
-- sets debug information too
-- * used in luaK.codeABC(), luaK.codeABx()
-- * called directly by (lparser) luaY.whilestat()
------------------------------------------------------------------------
function luaK.code(fs, i, line)
	local f = fs.f
	luaK.dischargejpc(fs) -- 'pc' will change
	-- put new instruction in code array
	-- luaY.growvector(fs.L, f.code, fs.pc, f.sizecode, nil, luaY.MAX_INT, "code size overflow")
	f.code[fs.pc] = i
	-- save corresponding line information
	-- luaY.growvector(fs.L, f.lineinfo, fs.pc, f.sizelineinfo, nil, luaY.MAX_INT, "code size overflow")
	f.lineinfo[fs.pc] = line
	local pc = fs.pc
	fs.pc = fs.pc + 1
	return pc
end

------------------------------------------------------------------------
-- writes an instruction of type ABC
-- * calls luaK.code()
------------------------------------------------------------------------
function luaK.codeABC(fs, o, a, b, c)
	assert(luaP.getOpMode(o) == luaP.OpMode.iABC)
	assert(luaP.getBMode(o) ~= luaP.OpArgMask.OpArgN or b == 0)
	assert(luaP.getCMode(o) ~= luaP.OpArgMask.OpArgN or c == 0)
	return luaK.code(fs, luaP.CREATE_ABC(o, a, b, c), fs.ls.lastline)
end

------------------------------------------------------------------------
-- writes an instruction of type ABx
-- * calls luaK.code(), called by luaK.codeAsBx()
------------------------------------------------------------------------
function luaK.codeABx(fs, o, a, bc)
	assert(luaP.getOpMode(o) == luaP.OpMode.iABx or luaP.getOpMode(o) == luaP.OpMode.iAsBx)
	assert(luaP.getCMode(o) == luaP.OpArgMask.OpArgN)
	return luaK.code(fs, luaP.CREATE_ABx(o, a, bc), fs.ls.lastline)
end

------------------------------------------------------------------------
--
-- * used in (lparser) luaY.closelistfield(), luaY.lastlistfield()
------------------------------------------------------------------------
function luaK.setlist(fs, base, nelems, tostore)
	local c = math.floor((nelems - 1) / luaP.LFIELDS_PER_FLUSH) + 1
	local b = (tostore == luaY.LUA_MULTRET) and 0 or tostore
	assert(tostore ~= 0)
	if c <= luaP.MAXARG_C then
		luaK.codeABC(fs, "OP_SETLIST", base, b, c)
	else
		luaK.codeABC(fs, "OP_SETLIST", base, b, 0)
		luaK.code(fs, luaP.CREATE_Inst(c), fs.ls.lastline)
	end
	fs.freereg = base + 1 -- free registers with list values
end

return luaK
