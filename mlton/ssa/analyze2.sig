(* Copyright (C) 1999-2002 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-1999 NEC Research Institute.
 *
 * MLton is released under the GNU General Public License (GPL).
 * Please see the file MLton-LICENSE for license information.
 *)
type int = Int.t
   
signature ANALYZE2_STRUCTS = 
   sig
      include DIRECT_EXP2
   end

signature ANALYZE2 = 
   sig
      include ANALYZE2_STRUCTS
      
      val analyze:
	 {coerce: {from: 'a,
		   to: 'a} -> unit,
	  conApp: {args: 'a vector,
		   con: Con.t} -> 'a,
	  const: Const.t -> 'a,
	  filter: 'a * Con.t * 'a vector -> unit,
	  filterWord: 'a * WordSize.t -> unit,
	  fromType: Type.t -> 'a,
	  layout: 'a -> Layout.t,
	  primApp: {args: 'a vector,
		    prim: Type.t Prim.t,
		    resultType: Type.t,
		    resultVar: Var.t option,
		    targs: Type.t vector} -> 'a,
	  program: Program.t,
	  select: {offset: int,
		   resultType: Type.t,
		   tuple: 'a} -> 'a,
	  tuple: 'a vector -> 'a,
	  useFromTypeOnBinds: bool
	 }
	 -> {
	     value: Var.t -> 'a,
	     func: Func.t -> {args: 'a vector,
			      raises: 'a vector option,
			      returns: 'a vector option},
	     label: Label.t -> 'a vector
	    }
   end