(* Copyright (C) 1999-2002 Henry Cejtin, Matthew Fluet, Suresh
 *    Jagannathan, and Stephen Weeks.
 * Copyright (C) 1997-1999 NEC Research Institute.
 *
 * MLton is released under the GNU General Public License (GPL).
 * Please see the file MLton-LICENSE for license information.
 *)

functor x86GenerateTransfers(S: X86_GENERATE_TRANSFERS_STRUCTS): X86_GENERATE_TRANSFERS =
struct

  open S
  open x86
  open x86JumpInfo
  open x86LoopInfo
  open x86Liveness
  open LiveInfo
  open Liveness

  local
     open Runtime
  in
     structure CFunction = CFunction
  end

  val rec ones : int -> word
    = fn 0 => 0wx0
       | n => Word.orb(Word.<<(ones (n-1), 0wx1),0wx1)

  val tracer = x86.tracer
  val tracerTop = x86.tracerTop

  structure x86LiveTransfers 
    = x86LiveTransfers(structure x86 = x86
		       structure x86MLton = x86MLton
		       structure x86Liveness = x86Liveness
		       structure x86JumpInfo = x86JumpInfo
		       structure x86LoopInfo = x86LoopInfo)

  val pointerSize = x86MLton.pointerSize
  val wordSize = x86MLton.wordSize

  val normalRegs =
    let
      val transferRegs
	=
	  (*
	  Register.eax::
	  Register.al::
	  *)
	  Register.ebx::
	  Register.bl::
	  Register.ecx::
	  Register.cl::
	  Register.edx:: 
	  Register.dl::
	  Register.edi::
	  Register.esi::
	  (*
	  Register.esp::
	  Register.ebp::
	  *)
	  nil
     in
	{frontierReg = Register.esp,
	 stackTopReg = Register.ebp,
	 transferRegs = fn Entry.Jump _ => transferRegs
	                 | Entry.CReturn _ => Register.eax::Register.al::transferRegs
			 | _ => []}
     end

  val reserveEspRegs =
    let
      val transferRegs
	=
	  (*
	  Register.eax::
	  Register.al::
	  *)
	  Register.ebx::
	  Register.bl::
	  Register.ecx::
	  Register.cl::
	  Register.edx:: 
	  Register.dl::
	  (*
	  Register.edi::
          *)
	  Register.esi::
          (*
	  Register.esp::
	  Register.ebp::
	  *)
	  nil
     in
	{frontierReg = Register.edi,
	 stackTopReg = Register.ebp,
	 transferRegs = fn Entry.Jump _ => transferRegs
	                 | Entry.CReturn _ => Register.eax::Register.al::transferRegs
			 | _ => []}
     end

  val transferFltRegs : Entry.t -> Int.t = fn Entry.Jump _ => 6
                                            | Entry.CReturn _ => 6
					    | _ => 0

  val indexReg = x86.Register.eax

  val stackTop = x86MLton.gcState_stackTopContents
  val frontier = x86MLton.gcState_frontierContents

  datatype gef = GEF of {generate : gef -> 
			            {label : Label.t,
				     falling : bool,
				     unique : bool} -> 
				    Assembly.t AppendList.t,
			 effect : gef -> 
			          {label : Label.t,
				   transfer : Transfer.t} ->
				  Assembly.t AppendList.t,
			 fall : gef ->
			        {label : Label.t,
				 live : LiveSet.t} ->
				Assembly.t AppendList.t}

  fun generateTransfers {chunk as Chunk.T {data, blocks, ...},
			 optimize: int,
			 newProfileLabel: x86.ProfileLabel.t -> x86.ProfileLabel.t,
			 liveInfo : x86Liveness.LiveInfo.t,
			 jumpInfo : x86JumpInfo.t,
			 reserveEsp: bool}
    = let
	 val {frontierReg, stackTopReg, transferRegs} =
	    if reserveEsp
	       then reserveEspRegs
	    else normalRegs
	val allClasses = !x86MLton.Classes.allClasses
	val livenessClasses = !x86MLton.Classes.livenessClasses
	val livenessClasses = ClassSet.add(livenessClasses, 
					   x86MLton.Classes.StaticNonTemp)
	val nonlivenessClasses = ClassSet.-(allClasses, livenessClasses)
	val holdClasses = !x86MLton.Classes.holdClasses
	val nonholdClasses = ClassSet.-(allClasses, holdClasses)
	val volatileClasses = !x86MLton.Classes.volatileClasses
	val nonvolatileClasses = ClassSet.-(allClasses, volatileClasses)
	val farflushClasses = ClassSet.-(nonlivenessClasses, holdClasses)
	val nearflushClasses = ClassSet.-(nonlivenessClasses, holdClasses)
	val runtimeClasses = !x86MLton.Classes.runtimeClasses
	val nonruntimeClasses = ClassSet.-(allClasses, runtimeClasses)
	val threadflushClasses = ClassSet.-(runtimeClasses, holdClasses)
	val cstaticClasses = !x86MLton.Classes.cstaticClasses
	val heapClasses = !x86MLton.Classes.heapClasses
	val ccallflushClasses = ClassSet.+(cstaticClasses, heapClasses)
	  
	fun removeHoldMemLocs memlocs
	  = MemLocSet.subset
	    (memlocs, 
	     fn m => not (ClassSet.contains(holdClasses, MemLoc.class m)))

	val stackAssume = {register = stackTopReg,
			   memloc = stackTop (),
			   weight = 1024,
			   sync = false,
			   reserve = false}
	val frontierAssume = {register = frontierReg,
			      memloc = frontier (),
			      weight = 2048,
			      sync = false,
			      reserve = false}
	val cStackAssume = {register = Register.esp,
			    memloc = x86MLton.c_stackPContents,
			    weight = 2048, (* ??? *)
			    sync = false,
			    reserve = true}

	fun blockAssumes l =
	   let
	      val l = frontierAssume :: stackAssume :: l
	   in
	      Assembly.directive_assume {assumes = if reserveEsp
						      then cStackAssume :: l
						   else l}
	   end
	   
	fun runtimeTransfer live setup trans
	  = AppendList.appends
	    [AppendList.single
	     (Assembly.directive_force
	      {commit_memlocs = removeHoldMemLocs live,
	       commit_classes = ClassSet.empty,
	       remove_memlocs = MemLocSet.empty,
	       remove_classes = ClassSet.empty,
	       dead_memlocs = MemLocSet.empty,
	       dead_classes = ClassSet.empty}),
	     setup,
	     AppendList.fromList
	     [(Assembly.directive_clearflt ()),
	      (Assembly.directive_force
	       {commit_memlocs = MemLocSet.empty,
		commit_classes = farflushClasses,
		remove_memlocs = MemLocSet.empty,
		remove_classes = ClassSet.empty,
		dead_memlocs = MemLocSet.empty,
		dead_classes = ClassSet.empty})],
	     trans]

	fun runtimeEntry l = AppendList.cons (blockAssumes [], l)

	fun farEntry l = AppendList.cons (blockAssumes [], l)

	fun farTransfer live setup trans
	  = AppendList.appends
	    [AppendList.single
	     (Assembly.directive_force
	      {commit_memlocs = removeHoldMemLocs live,
	       commit_classes = ClassSet.empty,
	       remove_memlocs = MemLocSet.empty,
	       remove_classes = ClassSet.empty,
	       dead_memlocs = MemLocSet.empty,
	       dead_classes = ClassSet.empty}),
	     setup,
	     AppendList.fromList
	     [(Assembly.directive_cache
	       {caches = [{register = stackTopReg,
			   memloc = stackTop (),
			   reserve = true},
			  {register = frontierReg,
			   memloc = frontier (),
			   reserve = true}]}),
	      (Assembly.directive_clearflt ()),
	      (Assembly.directive_force
	       {commit_memlocs = MemLocSet.empty,
		commit_classes = farflushClasses,
		remove_memlocs = MemLocSet.empty,
		remove_classes = ClassSet.empty,
		dead_memlocs = MemLocSet.empty,
		dead_classes = ClassSet.empty})],
	     trans]

	val profileStackTopCommit' = 
	  x86.Assembly.directive_force
	  {commit_memlocs = MemLocSet.singleton (stackTop ()),
	   commit_classes = ClassSet.empty,
	   remove_memlocs = MemLocSet.empty,
	   remove_classes = ClassSet.empty,
	   dead_memlocs = MemLocSet.empty,
	   dead_classes = ClassSet.empty}
	val profileStackTopCommit =
	  if !Control.profile <> Control.ProfileNone
	    then AppendList.single profileStackTopCommit'
	    else AppendList.empty
	    
	val _
	  = Assert.assert
	    ("verifyLiveInfo",
	     fn () => x86Liveness.LiveInfo.verifyLiveInfo {chunk = chunk,
							   liveInfo = liveInfo})
	val _
	  = Assert.assert
	    ("verifyJumpInfo", 
	     fn () => x86JumpInfo.verifyJumpInfo {chunk = chunk,
						  jumpInfo = jumpInfo})

	val _
	  = Assert.assert
	    ("verifyEntryTransfer", 
	     fn () => x86EntryTransfer.verifyEntryTransfer {chunk = chunk})

	local
	  val gotoInfo as {get: Label.t -> {block:Block.t},
			   set,
			   destroy}
	    = Property.destGetSetOnce
	      (Label.plist, Property.initRaise ("gotoInfo", Label.layout))

	  val labels
	    = List.fold
	      (blocks, [],
	       fn (block as Block.T {entry, ...}, labels)
	        => let
		     val label = Entry.label entry
		   in
		     set(label, {block = block}) ;
		     label::labels
		   end)
	      
	  fun loop labels
	    = let
		val (labels, b)
		  = List.fold
		    (labels, ([], false),
		     fn (label, (labels, b))
		      => case x86JumpInfo.getNear (jumpInfo, label)
			   of x86JumpInfo.Count 0 
			    => let
				 val {block as Block.T {transfer, ...}}
				   = get label
			       in
				 List.foreach 
				 (Transfer.nearTargets transfer,
				  fn label 
				   => x86JumpInfo.decNear (jumpInfo, label));
				 (labels, true)
			       end
			    | _ => (label::labels, b))
	      in
		if b
		  then loop labels
		  else List.map (labels, #block o get)
	      end
	  val blocks = loop labels
	    
	  val _ = destroy ()
	in
	  val chunk = Chunk.T {data = data, blocks = blocks}
	end

	val loopInfo
	  = x86LoopInfo.createLoopInfo {chunk = chunk, farLoops = false}
	val isLoopHeader
	  = fn label => isLoopHeader(loopInfo, label)
	                handle _ => false

	val liveTransfers
	  = x86LiveTransfers.computeLiveTransfers
	    {chunk = chunk,
	     transferRegs = transferRegs,
	     transferFltRegs = transferFltRegs,
	     liveInfo = liveInfo,
	     jumpInfo = jumpInfo,
	     loopInfo = loopInfo}
	    handle exn
	     => Error.reraise (exn, "x86LiveTransfers.computeLiveTransfers")

	val getLiveRegsTransfers
	  = #1 o x86LiveTransfers.getLiveTransfers
	val getLiveFltRegsTransfers
	  = #2 o x86LiveTransfers.getLiveTransfers

	val layoutInfo as {get = getLayoutInfo : Label.t -> Block.t option,
			   set = setLayoutInfo,
			   destroy = destLayoutInfo}
	  = Property.destGetSet(Label.plist, 
				Property.initRaise ("layoutInfo", Label.layout))
	val _ 
	  = List.foreach
	    (blocks,
	     fn block as Block.T {entry, ...}
	      => let
		   val label = Entry.label entry
		 in 
		   setLayoutInfo(label, SOME block)
		 end)

 	val profileLabel as {get = getProfileLabel : Label.t -> ProfileLabel.t option,
			     set = setProfileLabel,
			     destroy = destProfileLabel}
	  = Property.destGetSetOnce
	    (Label.plist, 
	     Property.initRaise ("profileLabel", Label.layout))
	val _ 
	  = List.foreach
	    (blocks,
	     fn block as Block.T {entry, profileLabel, ...}
	      => let
		   val label = Entry.label entry
		 in 
		   setProfileLabel(label, profileLabel)
		 end)

	local	
	  val stack = ref []
	  val queue = ref (Queue.empty ())
	in
	  fun enque x = queue := Queue.enque(!queue, x)
	  fun push x = stack := x::(!stack)

	  fun deque () = (case (!stack)
			    of [] => (case Queue.deque(!queue)
					of NONE => NONE
					 | SOME(x, queue') => (queue := queue';
							       SOME x))
			     | x::stack' => (stack := stack';
					     SOME x))
	end

	fun pushCompensationBlock {label, id}
	  = let
	      val label' = Label.new label
	      val live = getLive(liveInfo, label)
	      val profileLabel = getProfileLabel label
	      val profileLabel' = Option.map (profileLabel, newProfileLabel)
	      val block
		= Block.T {entry = Entry.jump {label = label'},
			   profileLabel = profileLabel',
			   statements 
			   = (Assembly.directive_restoreregalloc
			      {live = MemLocSet.add
			              (MemLocSet.add
				       (LiveSet.toMemLocSet live,
					stackTop ()),
			              frontier ()),
			       id = id})::
			     nil,
			   transfer = Transfer.goto {target = label}}
	    in
	      setLive(liveInfo, label', live);
	      setProfileLabel(label', profileLabel');
	      incNear(jumpInfo, label');
	      Assert.assert("pushCompensationBlock",
			    fn () => getNear(jumpInfo, label') = Count 1);
	      x86LiveTransfers.setLiveTransfersEmpty(liveTransfers, label');
	      setLayoutInfo(label', SOME block);
	      push label';
	      label'
	    end

	val c_stackP = x86MLton.c_stackPContentsOperand

	fun cacheEsp () =
	   if reserveEsp
	      then AppendList.empty
	   else
	      AppendList.single
	      ((* explicit cache in case there are no args *)
	       Assembly.directive_cache 
	       {caches = [{register = Register.esp,
			   memloc = valOf (Operand.deMemloc c_stackP),
			   reserve = true}]})

	fun unreserveEsp () =
	   if reserveEsp
	      then AppendList.empty
	   else AppendList.single (Assembly.directive_unreserve 
				   {registers = [Register.esp]})

	datatype z = datatype Entry.t
	datatype z = datatype Transfer.t
	fun generateAll (gef as GEF {generate,effect,fall})
	                {label, falling, unique} : 
			Assembly.t AppendList.t
	  = (case getLayoutInfo label
	       of NONE => AppendList.empty
	        | SOME (Block.T {entry, profileLabel, statements, transfer})
		=> let
		     val _ = setLayoutInfo(label, NONE)

(*
		     val isLoopHeader = fn _ => false
*)

		       
		     fun near label =
			let
			   val align =
			      if isLoopHeader label handle _ => false
				 then
				    AppendList.single
				    (Assembly.pseudoop_p2align 
				     (Immediate.const_int 4,
				      NONE,
				      SOME (Immediate.const_int 7)))
			      else if falling
				      then AppendList.empty
				   else
				      AppendList.single
				      (Assembly.pseudoop_p2align
				       (Immediate.const_int 4, 
					NONE, 
					NONE))
			   val assumes =
			      if falling andalso unique
				 then AppendList.empty
			      else
				 (* near entry & live transfer assumptions *)
				 AppendList.fromList
				 [(blockAssumes
				   (List.map
				    (getLiveRegsTransfers
				     (liveTransfers, label),
				     fn (memloc,register,sync)
				     => {register = register,
					 memloc = memloc,
					 sync = sync, 
					 weight = 1024,
					 reserve = false}))),
				  (Assembly.directive_fltassume
				   {assumes
				    = (List.map
				       (getLiveFltRegsTransfers
					(liveTransfers, label),
					fn (memloc,sync)
					=> {memloc = memloc,
					    sync = sync,
					    weight = 1024}))})]
			in
			   AppendList.appends
			   [align,
			    AppendList.single 
			    (Assembly.label label),
			    AppendList.fromList 
			    (ProfileLabel.toAssemblyOpt profileLabel),
			    assumes]
			end
		     val pre
		       = case entry
			   of Jump {label}
			    => near label
			    | CReturn {dst, frameInfo, func, label}
			    => let
				 fun getReturn ()
				   = case dst 
				       of NONE => AppendList.empty
				        | SOME (dst, dstsize)
					=> (case Size.class dstsize
					      of Size.INT
					       => AppendList.single
						  (x86.Assembly.instruction_mov
						   {dst = dst,
						    src = Operand.memloc
						          (MemLoc.cReturnTempContents 
							   dstsize),
						    size = dstsize})
					       | Size.FLT
					       => AppendList.single
						  (x86.Assembly.instruction_pfmov
						   {dst = dst,
						    src = Operand.memloc
						          (MemLoc.cReturnTempContents 
							   dstsize),
						    size = dstsize})
					       | _ => Error.bug "CReturn")
			       in
				 case frameInfo of
				   SOME fi =>
				      let
					  val FrameInfo.T {size, frameLayoutsIndex}
					    = fi
					  val finish
					    = AppendList.appends
					      [let	
						 val stackTop 
						   = x86MLton.gcState_stackTopContentsOperand ()
						 val bytes 
						   = x86.Operand.immediate_const_int (~ size)
					       in
						 AppendList.cons
						 ((* stackTop += bytes *)
						  x86.Assembly.instruction_binal 
						  {oper = x86.Instruction.ADD,
						   dst = stackTop,
						   src = bytes, 
						   size = pointerSize},
						 profileStackTopCommit)
					       end,
					       (* assignTo dst *)
					       getReturn ()]
					in
					  AppendList.appends
					  [AppendList.fromList
					   [Assembly.pseudoop_p2align 
					    (Immediate.const_int 4, NONE, NONE),
					    Assembly.pseudoop_long 
					    [Immediate.const_int frameLayoutsIndex],
					    Assembly.label label],
					   AppendList.fromList
					   (ProfileLabel.toAssemblyOpt profileLabel),
					   if CFunction.maySwitchThreads func
					     then (* entry from far assumptions *)
					          farEntry finish
					     else (* near entry & live transfer assumptions *)
					          AppendList.append
						  (AppendList.fromList
						   [(blockAssumes
						     (List.map
						      (getLiveRegsTransfers
						       (liveTransfers, label),
						       fn (memloc,register,sync)
						       => {register = register,
							   memloc = memloc,
							   sync = sync, 
							   weight = 1024,
							   reserve = false}))),
						    (Assembly.directive_fltassume
						     {assumes
						      = (List.map
							 (getLiveFltRegsTransfers
							  (liveTransfers, label),
							  fn (memloc,sync)
							  => {memloc = memloc,
							      sync = sync,
							      weight = 1024}))})],
						   finish)]
					end
				 | NONE => 
				      AppendList.append (near label, getReturn ())
			       end
			    | Func {label,...}
			    => AppendList.appends
			       [AppendList.fromList
				[Assembly.pseudoop_p2align 
				 (Immediate.const_int 4, NONE, NONE),
				 Assembly.pseudoop_global label,
				 Assembly.label label],
				AppendList.fromList
				(ProfileLabel.toAssemblyOpt profileLabel),
				(* entry from far assumptions *)
				(farEntry AppendList.empty)]
			    | Cont {label, 
				    frameInfo = FrameInfo.T {size,
							     frameLayoutsIndex},
				    ...}
			    =>
			       AppendList.appends
			       [AppendList.fromList
				[Assembly.pseudoop_p2align
				 (Immediate.const_int 4, NONE, NONE),
				 Assembly.pseudoop_long
				 [Immediate.const_int frameLayoutsIndex],
				 Assembly.label label],
				AppendList.fromList
				(ProfileLabel.toAssemblyOpt profileLabel),
				(* entry from far assumptions *)
				(farEntry
				 (let
				     val stackTop 
					= x86MLton.gcState_stackTopContentsOperand ()
				     val bytes 
					= x86.Operand.immediate_const_int (~ size)
				  in
				     AppendList.cons
				     ((* stackTop += bytes *)
				      x86.Assembly.instruction_binal 
				      {oper = x86.Instruction.ADD,
				       dst = stackTop,
				       src = bytes, 
				       size = pointerSize},
				      profileStackTopCommit)
				  end))]
		            | Handler {frameInfo = (FrameInfo.T
						    {frameLayoutsIndex, size}),
				       label,
				       ...}
			    => AppendList.appends
			       [AppendList.fromList
				[Assembly.pseudoop_p2align 
				 (Immediate.const_int 4, NONE, NONE),
				 Assembly.pseudoop_long
				 [Immediate.const_int frameLayoutsIndex],
				 Assembly.label label],
				AppendList.fromList
				(ProfileLabel.toAssemblyOpt profileLabel),
				(* entry from far assumptions *)
				(farEntry
				 (let
				     val stackTop 
					= x86MLton.gcState_stackTopContentsOperand ()
				     val bytes 
					= x86.Operand.immediate_const_int (~ size)
				  in
				     AppendList.cons
				     ((* stackTop += bytes *)
				      x86.Assembly.instruction_binal 
				      {oper = x86.Instruction.ADD,
				       dst = stackTop,
				       src = bytes, 
				       size = pointerSize},
				      profileStackTopCommit)
				  end))]
		     val pre
		       = AppendList.appends
		         [if !Control.Native.commented > 1
			    then AppendList.single
			         (Assembly.comment (Entry.toString entry))
			    else AppendList.empty,
			  if !Control.Native.commented > 2
			    then AppendList.single
			         (Assembly.comment 
				  (LiveSet.fold
				   (getLive(liveInfo, label),
				    "",
				    fn (memloc, s)
				     => concat [s, 
						MemLoc.toString memloc, 
						" "])))
			    else AppendList.empty,
			  pre]

		     val (statements,live)
		       = List.foldr
		         (statements,
			  ([], 
			   #liveIn (livenessTransfer {transfer = transfer, 
						      liveInfo = liveInfo})),
			  fn (assembly,(statements,live))
			   => let
				val live as {liveIn,dead, ...}
				  = livenessAssembly {assembly = assembly,
						      live = live}
			      in
				(if LiveSet.isEmpty dead
				   then assembly::statements
				   else assembly::
				        (Assembly.directive_force
					 {commit_memlocs = MemLocSet.empty,
					  commit_classes = ClassSet.empty,
					  remove_memlocs = MemLocSet.empty,
					  remove_classes = ClassSet.empty,
					  dead_memlocs = LiveSet.toMemLocSet dead,
					  dead_classes = ClassSet.empty})::
					statements,
				 liveIn)
			      end)

		     val statements = AppendList.fromList statements

		     val transfer = effect gef {label = label, 
						transfer = transfer}
		   in
		     AppendList.appends 
		     [pre,
		      statements,
		      transfer]
		   end)
	  
	and effectDefault (gef as GEF {generate,effect,fall})
	                  {label, transfer} : Assembly.t AppendList.t
	  = AppendList.append
	    (if !Control.Native.commented > 1
	       then AppendList.single
		    (Assembly.comment
		     (Transfer.toString transfer))
	       else AppendList.empty,
	     case transfer
	       of Goto {target}
		=> fall gef
		        {label = target,
			 live = getLive(liveInfo, target)}
		| Iff {condition, truee, falsee}
		=> let
		     val condition_neg
		       = Instruction.condition_negate condition

		     val truee_live
		       = getLive(liveInfo, truee)
		     val truee_live_length
		       = LiveSet.size truee_live

		     val falsee_live
		       = getLive(liveInfo, falsee)
		     val falsee_live_length
		       = LiveSet.size falsee_live

		     fun fall_truee ()
		       = let
			   val id = Directive.Id.new ()
			   val falsee'
			     = pushCompensationBlock {label = falsee,
						      id = id};
			 in
			   AppendList.append
			   (AppendList.fromList
			    [Assembly.directive_force
			     {commit_memlocs = MemLocSet.empty,
			      commit_classes = nearflushClasses,
			      remove_memlocs = MemLocSet.empty,
			      remove_classes = ClassSet.empty,
			      dead_memlocs = MemLocSet.empty,
			      dead_classes = ClassSet.empty},
			     Assembly.directive_saveregalloc
			     {live = MemLocSet.add
			             (MemLocSet.add
				      (LiveSet.toMemLocSet falsee_live,
				       stackTop ()),
				      frontier ()),
			      id = id},
			     Assembly.instruction_jcc
			     {condition = condition_neg,
			      target = Operand.label falsee'}],
			    (fall gef 
			          {label = truee,
				   live = truee_live}))
			 end

		     fun fall_falsee ()
		       = let
			   val id = Directive.Id.new ()
			   val truee' = pushCompensationBlock {label = truee,
							       id = id};
			 in
			   AppendList.append
			   (AppendList.fromList
			    [Assembly.directive_force
			     {commit_memlocs = MemLocSet.empty,
			      commit_classes = nearflushClasses,
			      remove_memlocs = MemLocSet.empty,
			      remove_classes = ClassSet.empty,
			      dead_memlocs = MemLocSet.empty,
			      dead_classes = ClassSet.empty},
			     Assembly.directive_saveregalloc
			     {live = MemLocSet.add
			             (MemLocSet.add
				      (LiveSet.toMemLocSet truee_live,
				       stackTop ()),
				      frontier ()),
			      id = id},
			     Assembly.instruction_jcc
			     {condition = condition,
			      target = Operand.label truee'}],
			    (fall gef 
			          {label = falsee,
				   live = falsee_live}))
			 end
		   in
		     case (getLayoutInfo truee,
			   getLayoutInfo falsee)
		       of (NONE, SOME _) => fall_falsee ()
			| (SOME _, NONE) => fall_truee ()
			| _ 
			=> let
			     fun default' ()
			       = if truee_live_length <= falsee_live_length
				   then fall_falsee ()
				   else fall_truee ()

			     fun default ()
			       = case (getNear(jumpInfo, truee),
				       getNear(jumpInfo, falsee))
				   of (Count 1, Count 1) => default' ()
				    | (Count 1, _) => fall_truee ()
				    | (_, Count 1) => fall_falsee ()
				    | _ => default' ()
			   in 
			     case (getLoopDistance(loopInfo, label, truee),
				   getLoopDistance(loopInfo, label, falsee))
			       of (NONE, NONE) => default ()
				| (SOME _, NONE) => fall_truee ()
				| (NONE, SOME _) => fall_falsee ()
			        | (SOME dtruee, SOME dfalsee)
				=> (case Int.compare(dtruee, dfalsee)
				      of EQUAL => default ()
				       | LESS => fall_falsee ()
				       | MORE => fall_truee ())
			   end
		   end
		| Switch {test, cases, default}
		=> let
		     val {dead, ...}
		       = livenessTransfer {transfer = transfer,
					   liveInfo = liveInfo}

		     val size
		       = case Operand.size test
			   of SOME size => size
			    | NONE => Size.LONG

		     val default_live
		       = getLive(liveInfo, default)

		     val cases
		       = Transfer.Cases.map'
		         (cases,
			  fn (k, target)
			   => let
				val target_live
				  = getLive(liveInfo, target)
				val id = Directive.Id.new ()
				val target' = pushCompensationBlock 
				              {label = target,
					       id = id}
			      in
				AppendList.fromList
				[Assembly.instruction_cmp
				 {src1 = test,
				  src2 = Operand.immediate_const k,
				  size = size},
				 Assembly.directive_saveregalloc
				 {live = MemLocSet.add
				         (MemLocSet.add
					  (LiveSet.toMemLocSet target_live,
					   stackTop ()),
					  frontier ()),
				  id = id},
				 Assembly.instruction_jcc
				 {condition = Instruction.E,
				  target = Operand.label target'}]
			      end,
			  fn (c, target) => (Immediate.Char c, target),
			  fn (i, target) => (Immediate.Int i, target),
			  fn (w, target) => (Immediate.Word w, target))
		   in
		     AppendList.appends
		     [AppendList.single
		      (Assembly.directive_force
		       {commit_memlocs = MemLocSet.empty,
			commit_classes = nearflushClasses,
			remove_memlocs = MemLocSet.empty,
			remove_classes = ClassSet.empty,
			dead_memlocs = MemLocSet.empty,
			dead_classes = ClassSet.empty}),
		      AppendList.appends cases,
		      if LiveSet.isEmpty dead
			then AppendList.empty
			else AppendList.single
			     (Assembly.directive_force
			      {commit_memlocs = MemLocSet.empty,
			       commit_classes = ClassSet.empty,
			       remove_memlocs = MemLocSet.empty,
			       remove_classes = ClassSet.empty,
			       dead_memlocs = LiveSet.toMemLocSet dead,
			       dead_classes = ClassSet.empty}),
		      (fall gef
		            {label = default,
			     live = default_live})]
		   end
                | Tail {target, live}
		=> (* flushing at far transfer *)
		   (farTransfer live
		    AppendList.empty
		    (AppendList.single
		     (Assembly.instruction_jmp
		      {target = Operand.label target,
		       absolute = false})))
		| NonTail {target, live, return, handler, size}
		=> let
		     val _ = enque return
		     val _ = case handler
			       of SOME handler => enque handler
				| NONE => ()

		     val stackTopTemp
		       = x86MLton.stackTopTempContentsOperand ()
		     val stackTopTempMinusWordDeref'
		       = x86MLton.stackTopTempMinusWordDeref ()
		     val stackTopTempMinusWordDeref
		       = x86MLton.stackTopTempMinusWordDerefOperand ()
		     val stackTop 
		       = x86MLton.gcState_stackTopContentsOperand ()
		     val stackTopMinusWordDeref'
		       = x86MLton.gcState_stackTopMinusWordDeref ()
		     val stackTopMinusWordDeref
		       = x86MLton.gcState_stackTopMinusWordDerefOperand ()
		     val bytes 
		       = x86.Operand.immediate_const_int size

		     val liveReturn = x86Liveness.LiveInfo.getLive(liveInfo, return)
		     val liveHandler 
		       = case handler
			   of SOME handler
			    => x86Liveness.LiveInfo.getLive(liveInfo, handler)
			    | _ => LiveSet.empty
		     val live = MemLocSet.unions [live,
						  LiveSet.toMemLocSet liveReturn,
						  LiveSet.toMemLocSet liveHandler]
		   in
		     (* flushing at far transfer *)
		     (farTransfer live
		      (if !Control.profile <> Control.ProfileNone
			 then (AppendList.fromList
			       [(* stackTopTemp = stackTop + bytes *)
				x86.Assembly.instruction_mov
				{dst = stackTopTemp,
				 src = stackTop,
				 size = pointerSize},
				x86.Assembly.instruction_binal
				{oper = x86.Instruction.ADD,
				 dst = stackTopTemp,
				 src = bytes,
				 size = pointerSize},
				(* *(stackTopTemp - WORD_SIZE) = return *)
				x86.Assembly.instruction_mov
				{dst = stackTopTempMinusWordDeref,
				 src = Operand.immediate_label return,
				 size = pointerSize},
				x86.Assembly.directive_force
				{commit_memlocs = MemLocSet.singleton stackTopTempMinusWordDeref',
				 commit_classes = ClassSet.empty,
				 remove_memlocs = MemLocSet.empty,
				 remove_classes = ClassSet.empty,
				 dead_memlocs = MemLocSet.empty,
				 dead_classes = ClassSet.empty},
				(* stackTop = stackTopTemp *)
				x86.Assembly.instruction_mov
				{dst = stackTop,
				 src = stackTopTemp,
				 size = pointerSize},
				profileStackTopCommit'])
			 else (AppendList.fromList
			       [(* stackTop += bytes *)
				x86.Assembly.instruction_binal 
				{oper = x86.Instruction.ADD,
				 dst = stackTop,
				 src = bytes, 
				 size = pointerSize},
				(* *(stackTop - WORD_SIZE) = return *)
				x86.Assembly.instruction_mov
				{dst = stackTopMinusWordDeref,
				 src = Operand.immediate_label return,
				 size = pointerSize},
				x86.Assembly.directive_force
				{commit_memlocs = MemLocSet.singleton stackTopMinusWordDeref',
				 commit_classes = ClassSet.empty,
				 remove_memlocs = MemLocSet.empty,
				 remove_classes = ClassSet.empty,
				 dead_memlocs = MemLocSet.empty,
				 dead_classes = ClassSet.empty}]))
		      (AppendList.single
		       (Assembly.instruction_jmp
			{target = Operand.label target,
			 absolute = false})))
		   end
		| Return {live}
		=> let
		     val stackTopMinusWordDeref
		       = x86MLton.gcState_stackTopMinusWordDerefOperand ()
		   in
		     (* flushing at far transfer *)
		     (farTransfer live
		      AppendList.empty
		      (AppendList.single
		       (* jmp *(stackTop - WORD_SIZE) *)
		       (x86.Assembly.instruction_jmp
			{target = stackTopMinusWordDeref,
			 absolute = true})))
		   end
		| Raise {live}
		=> let
		     val exnStack 
		       = x86MLton.gcState_exnStackContentsOperand ()
		     val stackTopTemp
		       = x86MLton.stackTopTempContentsOperand ()
		     val stackTop 
		       = x86MLton.gcState_stackTopContentsOperand ()
		     val stackTopDeref
		       = x86MLton.gcState_stackTopDerefOperand ()
		     val stackBottom 
		       = x86MLton.gcState_stackBottomContentsOperand ()
		    in
		      (* flushing at far transfer *)
		      (farTransfer live
		       (if !Control.profile <> Control.ProfileNone
			  then (AppendList.fromList
				[(* stackTopTemp = stackBottom + exnStack *)
				 x86.Assembly.instruction_mov
				 {dst = stackTopTemp,
				  src = stackBottom,
				  size = pointerSize},
				 x86.Assembly.instruction_binal
				 {oper = x86.Instruction.ADD,
				  dst = stackTopTemp,
				  src = exnStack,
				  size = pointerSize},
				 (* stackTop = stackTopTemp *)
				 x86.Assembly.instruction_mov
				 {dst = stackTop,
				  src = stackTopTemp,
				  size = pointerSize},
				 profileStackTopCommit'])
			  else (AppendList.fromList
				[(* stackTop = stackBottom + exnStack *)
				 x86.Assembly.instruction_mov
				 {dst = stackTop,
				  src = stackBottom,
				  size = pointerSize},
				 x86.Assembly.instruction_binal
				 {oper = x86.Instruction.ADD,
				  dst = stackTop,
				  src = exnStack,
				  size = pointerSize}]))
		       (AppendList.single
			(* jmp *(stackTop - WORD_SIZE) *)
			(x86.Assembly.instruction_jmp
			 {target = x86MLton.gcState_stackTopMinusWordDerefOperand (),
			  absolute = true})))
		    end
	        | CCall {args, dstsize, frameInfo, func, return, target}
		=> let
		     val CFunction.T {convention,
				      maySwitchThreads,
				      modifiesFrontier,
				      modifiesStackTop, ...} = func
		     val stackTopMinusWordDeref
		       = x86MLton.gcState_stackTopMinusWordDerefOperand ()
		     val {dead, ...}
		       = livenessTransfer {transfer = transfer,
					   liveInfo = liveInfo}
		     val c_stackP = x86MLton.c_stackPContentsOperand
		     val c_stackPDerefDouble = x86MLton.c_stackPDerefDoubleOperand
		     val applyFFTemp = x86MLton.applyFFTempContentsOperand
		     val (pushArgs, size_args)
		       = List.fold
		         (args, (AppendList.empty, 0),
			  fn ((arg, size), (assembly_args, size_args)) =>
			  (AppendList.append
			   (if Size.eq (size, Size.DBLE)
			      then AppendList.fromList
			   	   [Assembly.instruction_binal
				    {oper = Instruction.SUB,
				     dst = c_stackP,
				     src = Operand.immediate_const_int 8,
				     size = pointerSize},
				    Assembly.instruction_pfmov
				    {src = arg,
				     dst = c_stackPDerefDouble,
				     size = size}]
			    else if Size.eq (size, Size.BYTE)
			      then AppendList.fromList
			           [Assembly.instruction_movx
				    {oper = Instruction.MOVZX,
				     dst = applyFFTemp,
				     src = arg,
				     dstsize = wordSize,
				     srcsize = size},
				    Assembly.instruction_ppush
				    {src = applyFFTemp,
				     base = c_stackP,
				     size = wordSize}]
			    else AppendList.single
				 (Assembly.instruction_ppush
				  {src = arg,
				   base = c_stackP,
				   size = size}),
				 assembly_args),
			   (Size.toBytes size) + size_args))
		     val flush =
			case frameInfo of
			   SOME (FrameInfo.T {size, ...}) =>
			        (* Entering runtime *)
			        let
				  val return = valOf return
				  val _ = enque return
				    
				  val stackTopTemp
				    = x86MLton.stackTopTempContentsOperand ()
				  val stackTopTempMinusWordDeref'
				    = x86MLton.stackTopTempMinusWordDeref ()
				  val stackTopTempMinusWordDeref
				    = x86MLton.stackTopTempMinusWordDerefOperand ()
				  val stackTop 
				    = x86MLton.gcState_stackTopContentsOperand ()
				  val stackTopMinusWordDeref'
				    = x86MLton.gcState_stackTopMinusWordDeref ()
				  val stackTopMinusWordDeref
				    = x86MLton.gcState_stackTopMinusWordDerefOperand ()
				  val bytes = x86.Operand.immediate_const_int size
				    
				  val live =
				    x86Liveness.LiveInfo.getLive(liveInfo, return)
				  val {defs, ...} = Transfer.uses_defs_kills transfer
				  val live = 
				    List.fold
				    (defs,
				     live,
				     fn (oper,live) =>
				     case Operand.deMemloc oper of
				       SOME memloc =>  LiveSet.remove (live, memloc)
				     | NONE => live)
				in
				  (runtimeTransfer (LiveSet.toMemLocSet live)
				   (if !Control.profile <> Control.ProfileNone
				      then (AppendList.fromList
					    [(* stackTopTemp = stackTop + bytes *)
					     x86.Assembly.instruction_mov
					     {dst = stackTopTemp,
					      src = stackTop,
					      size = pointerSize},
					     x86.Assembly.instruction_binal
					     {oper = x86.Instruction.ADD,
					      dst = stackTopTemp,
					      src = bytes,
					      size = pointerSize},
					     (* *(stackTopTemp - WORD_SIZE) = return *)
					     x86.Assembly.instruction_mov
					     {dst = stackTopTempMinusWordDeref,
					      src = Operand.immediate_label return,
					      size = pointerSize},
					     x86.Assembly.directive_force
					     {commit_memlocs = MemLocSet.singleton stackTopTempMinusWordDeref',
					      commit_classes = ClassSet.empty,
					      remove_memlocs = MemLocSet.empty,
					      remove_classes = ClassSet.empty,
					      dead_memlocs = MemLocSet.empty,
					      dead_classes = ClassSet.empty},
					     (* stackTop = stackTopTemp *)
					     x86.Assembly.instruction_mov
					     {dst = stackTop,
					      src = stackTopTemp,
					      size = pointerSize},
					     profileStackTopCommit'])
				      else (AppendList.fromList
					    [(* stackTop += bytes *)
					     x86.Assembly.instruction_binal 
					     {oper = x86.Instruction.ADD,
					      dst = stackTop,
					      src = bytes, 
					      size = pointerSize},
					     (* *(stackTop - WORD_SIZE) = return *)
					     x86.Assembly.instruction_mov
					     {dst = stackTopMinusWordDeref,
					      src = Operand.immediate_label return,
					      size = pointerSize},
					     x86.Assembly.directive_force
					     {commit_memlocs = MemLocSet.singleton stackTopMinusWordDeref',
					      commit_classes = ClassSet.empty,
					      remove_memlocs = MemLocSet.empty,
					      remove_classes = ClassSet.empty,
					      dead_memlocs = MemLocSet.empty,
					      dead_classes = ClassSet.empty}]))
				   (AppendList.single
				    (Assembly.directive_force
				     {commit_memlocs = LiveSet.toMemLocSet live,
				      commit_classes = runtimeClasses,
				      remove_memlocs = MemLocSet.empty,
				      remove_classes = ClassSet.empty,
				      dead_memlocs = MemLocSet.empty,
				      dead_classes = ClassSet.empty})))
				end
			 | NONE => 
			        AppendList.single
			        (Assembly.directive_force
				 {commit_memlocs = let
						     val s = MemLocSet.empty
						     val s = if modifiesFrontier
							       then MemLocSet.add
								    (s, frontier ())
							       else s
						     val s = if modifiesStackTop
							       then MemLocSet.add
								    (s, stackTop ())
							       else s
						   in
						     s
						   end,
				  commit_classes = ccallflushClasses,
				  remove_memlocs = MemLocSet.empty,
				  remove_classes = ClassSet.empty,
				  dead_memlocs = LiveSet.toMemLocSet dead,
				  dead_classes = ClassSet.empty})
		     val call 
		       = AppendList.fromList
		         [Assembly.directive_ccall (),
			  Assembly.instruction_call
			  {target = Operand.label target,
			   absolute = false}]
		     val kill
		       = if isSome frameInfo
			   then AppendList.single
			        (Assembly.directive_force
				 {commit_memlocs = MemLocSet.empty,
				  commit_classes = ClassSet.empty,
				  remove_memlocs = MemLocSet.empty,
				  remove_classes = ClassSet.empty,
				  dead_memlocs = MemLocSet.empty,
				  dead_classes = runtimeClasses})
			   else AppendList.single
			        (Assembly.directive_force
				 {commit_memlocs = MemLocSet.empty,
				  commit_classes = ClassSet.empty,
				  remove_memlocs = MemLocSet.empty,
				  remove_classes = ClassSet.empty,
				  dead_memlocs = let
						   val s = MemLocSet.empty
						   val s = if modifiesFrontier
							     then MemLocSet.add
							          (s, frontier ())
							     else s
						   val s = if modifiesStackTop
							     then MemLocSet.add
							          (s, stackTop ())
							     else s
						 in
						   s
						 end,
				  dead_classes = ccallflushClasses})
		     val getResult
		       = case dstsize
			   of NONE => AppendList.empty
			    | SOME dstsize
			    => (case Size.class dstsize
				  of Size.INT
				   => AppendList.single
				      (Assembly.directive_return
				       {memloc = MemLoc.cReturnTempContents dstsize})
				   | Size.FLT 
				   => AppendList.single
				      (Assembly.directive_fltreturn
				       {memloc = MemLoc.cReturnTempContents dstsize})
				   | _ => Error.bug "CCall")
		     val fixCStack =
			if size_args > 0
			   andalso convention = CFunction.Convention.Cdecl
			   then (AppendList.single
				 (Assembly.instruction_binal
				  {oper = Instruction.ADD,
				   dst = c_stackP,
				   src = Operand.immediate_const_int size_args,
				   size = pointerSize}))
			   else AppendList.empty
		     val continue
		       = if maySwitchThreads
			   then (* Returning from runtime *)
			        (farTransfer MemLocSet.empty
				 AppendList.empty
				 (AppendList.single
				  (* jmp *(stackTop - WORD_SIZE) *)
				  (x86.Assembly.instruction_jmp
				   {target = stackTopMinusWordDeref,
				    absolute = true})))
			 else case return
				of NONE => AppendList.empty
				 | SOME l => (if isSome frameInfo
						then (* Don't need to trampoline,
						      * since didn't switch threads,
						      * but can't fall because
						      * frame layout data is prefixed
						      * to l's code; use fallNone
						      * to force a jmp with near
						      * jump assumptions.
						      *)
						     fallNone
						else fall)
				             gef 
					     {label = l,
					      live = getLive (liveInfo, l)}
		   in
		     AppendList.appends
		     [cacheEsp (),
		      pushArgs,
		      flush,
		      call,
		      kill,
		      getResult,
		      fixCStack,
		      unreserveEsp (),
		      continue]
		   end)

        and effectJumpTable (gef as GEF {generate,effect,fall})
	                     {label, transfer} : Assembly.t AppendList.t
	  = case transfer
	      of Switch {test, cases, default}
	       => let
		    val {dead, ...}
		      = livenessTransfer {transfer = transfer,
					  liveInfo = liveInfo}

		    fun reduce(cases,
			       ops as {zero,
				       even,
				       incFn, decFn, halfFn,
				       ltFn, gtFn,
				       min, minFn,
				       max, maxFn,
				       range})
		      = let
			  fun reduce' cases
			    = let
				val (minK,maxK,length,
				     allEven,allOdd)
				  = List.fold
				    (cases,
				     (max, min, 0,
				      true, true),
				     fn ((k,target),
					 (minK,maxK,length,
					  allEven,allOdd))
				      => let
					   val isEven = even k
					 in
					   (minFn(k,minK),
					    maxFn(k,maxK),
					    length + 1,
					    allEven andalso isEven,
					    allOdd andalso not isEven)
					 end)
			      in
				if length > 1 andalso
				   (allEven orelse allOdd)
				  then let
					 val f = if allOdd
						   then halfFn o decFn
						   else halfFn
					 val cases' 
					   = List.map
					     (cases,
					      fn (k,target)
					       => (f k, target))
					     
					 val (cases'', 
					      minK'', maxK'', length'',
					      shift'', mask'')
					   = reduce' cases'

					 val shift' = 1 + shift''
					 val mask' 
					   = Word.orb
					     (Word.<<(mask'', 0wx1),
					      if allOdd
						then 0wx1
						else 0wx0)
				       in
					 (cases'', 
					  minK'', maxK'', length'',
					  shift', mask')
				       end
				  else (cases, 
					minK, maxK, length,
					0, 0wx0)
			      end
			in 
			  reduce' cases
			end
		      
		    fun doitTable(cases,
				  ops as {zero,
					  even,
					  incFn, decFn, halfFn,
					  ltFn, gtFn,
					  min, minFn,
					  max, maxFn,
					  range},
				  minK, maxK, rangeK, shift, mask,
				  constFn)
		      = let
			  val jump_table_label
			    = Label.newString "jumpTable"

			  val idT = Directive.Id.new ()
			  val defaultT = pushCompensationBlock
			                 {label = default,
					  id = idT}

			  val rec filler 
			    = fn ([],_) => []
			       | (cases as (i,target)::cases',j)
			       => if i = j
				    then let
					   val target'
					     = pushCompensationBlock
					       {label = target,
						id = idT}
					 in 
					   (Immediate.label target')::
					   (filler(cases', incFn j))
					 end 
				    else (Immediate.label defaultT)::
				         (filler(cases, incFn j))

			  val jump_table = filler (cases, minK)

			  val default_live = getLive(liveInfo, default)
			  val live
			    = List.fold
			      (cases,
			       default_live,
			       fn ((i,target), live)
			        => LiveSet.+(live, getLive(liveInfo, target)))

			  val indexTemp
			    = MemLoc.imm 
			      {base = Immediate.label (Label.fromString "indexTemp"),
			       index = Immediate.const_int 0,
			       scale = Scale.Four,
			       size = Size.LONG,
			       class = MemLoc.Class.Temp}
			  val checkTemp
			    = MemLoc.imm 
			      {base = Immediate.label (Label.fromString "checkTemp"),
			       index = Immediate.const_int 0,
			       scale = Scale.Four,
			       size = Size.LONG,
			       class = MemLoc.Class.Temp}
			  val address
			    = MemLoc.basic
			      {base = Immediate.label jump_table_label,
			       index = indexTemp,
			       scale = Scale.Four,
			       size = Size.LONG,
			       class = MemLoc.Class.Code}
			      
			  val size 
			    = case Operand.size test
				of SOME size => size
				 | NONE => Size.LONG
			  val indexTemp' = indexTemp
			  val indexTemp = Operand.memloc indexTemp
			  val checkTemp' = checkTemp
			  val checkTemp = Operand.memloc checkTemp
			  val address = Operand.memloc address
			in
			  AppendList.appends
			  [if Size.lt(size, Size.LONG)
			     then AppendList.single
			          (Assembly.instruction_movx
				   {oper = Instruction.MOVZX,
				    src = test,
				    srcsize = size,
				    dst = indexTemp,
				    dstsize = Size.LONG})
			     else AppendList.single
			          (Assembly.instruction_mov
				   {src = test,
				    dst = indexTemp,
				    size = Size.LONG}),
			   if LiveSet.isEmpty dead
			     then AppendList.empty
			     else AppendList.single
			          (Assembly.directive_force
				   {commit_memlocs = MemLocSet.empty,
				    commit_classes = ClassSet.empty,
				    remove_memlocs = MemLocSet.empty,
				    remove_classes = ClassSet.empty,
				    dead_memlocs = LiveSet.toMemLocSet dead,
				    dead_classes = ClassSet.empty}),
			   if shift > 0
			     then let
				    val idC = Directive.Id.new ()
				    val defaultC = pushCompensationBlock
				                   {label = default,
						    id = idC}
				    val _ = incNear(jumpInfo, default)
				  in
				    AppendList.appends
				    [AppendList.fromList
				     [Assembly.instruction_mov
				      {src = indexTemp,
				       dst = checkTemp,
				       size = Size.LONG},
				      Assembly.instruction_binal
				      {oper = Instruction.AND,
				       src = Operand.immediate_const_word 
				             (ones shift),
				       dst = checkTemp,
				       size = Size.LONG}],
				     if mask = 0wx0
				       then AppendList.empty
				       else AppendList.single
					    (Assembly.instruction_binal
					     {oper = Instruction.SUB,
					      src = Operand.immediate_const_word mask,
					      dst = checkTemp,
					      size = Size.LONG}),
				     AppendList.fromList
				     [Assembly.directive_force
				      {commit_memlocs = MemLocSet.empty,
				       commit_classes = nearflushClasses,
				       remove_memlocs = MemLocSet.empty,
				       remove_classes = ClassSet.empty,
				       dead_memlocs = MemLocSet.singleton checkTemp',
				       dead_classes = ClassSet.empty},
				      Assembly.directive_saveregalloc
				      {id = idC,
				       live = MemLocSet.add
				              (MemLocSet.add
					       (LiveSet.toMemLocSet default_live,
						stackTop ()),
					       frontier ())},
				      Assembly.instruction_jcc
				      {condition = Instruction.NZ,
				       target = Operand.label defaultC},
				      Assembly.instruction_sral
				      {oper = Instruction.SAR,
				       count = Operand.immediate_const_int shift,
				       dst = indexTemp,
				       size = Size.LONG}]]
				  end
			     else AppendList.empty,
			   if minK = zero
			     then AppendList.empty
			     else AppendList.single
			          (Assembly.instruction_binal
				   {oper = Instruction.SUB,
				    src = Operand.immediate (constFn minK),
				    dst = indexTemp,
				    size = Size.LONG}),
			  AppendList.fromList
			  [Assembly.directive_force
			   {commit_memlocs = MemLocSet.empty,
			    commit_classes = nearflushClasses,
			    remove_memlocs = MemLocSet.empty,
			    remove_classes = ClassSet.empty,
			    dead_memlocs = MemLocSet.empty,
			    dead_classes = ClassSet.empty},
			   Assembly.directive_cache
			   {caches = [{register = indexReg,
				       memloc = indexTemp',
				       reserve = false}]},
			   Assembly.instruction_cmp
			   {src1 = indexTemp,
			    src2 = Operand.immediate_const_int rangeK,
			    size = Size.LONG},
			   Assembly.directive_saveregalloc
			   {id = idT,
			    live = MemLocSet.add
				   (MemLocSet.add
				    (LiveSet.toMemLocSet live,
				     stackTop ()),
				    frontier ())},
			   Assembly.instruction_jcc
			   {condition = Instruction.AE,
			    target = Operand.label defaultT},
			   Assembly.instruction_jmp
			   {target = address,
			    absolute = true},
			   Assembly.directive_force
			   {commit_memlocs = MemLocSet.empty,
			    commit_classes = ClassSet.empty,
			    remove_memlocs = MemLocSet.empty,
			    remove_classes = ClassSet.empty,
			    dead_memlocs = MemLocSet.singleton indexTemp',
			    dead_classes = ClassSet.empty}],
			  AppendList.fromList
			  [Assembly.pseudoop_data (),
			   Assembly.pseudoop_p2align 
			   (Immediate.const_int 4, NONE, NONE),
			   Assembly.label jump_table_label,
			   Assembly.pseudoop_long jump_table,
			   Assembly.pseudoop_text ()]]
			end

		    fun doit(cases,
			     ops as {zero,
				     even,
				     incFn, decFn, halfFn,
				     ltFn, gtFn,
				     min, minFn,
				     max, maxFn,
				     range},
			     constFn)
		      = let
			  val (cases, 
			       minK, maxK, length,
			       shift, mask) 
			    = reduce(cases, ops)
			    
			  val rangeK 
			    = SOME (range(minK,maxK))
			      handle Overflow
			       => NONE
			in
			  if length >= 8 
			     andalso
			     (isSome rangeK
			      andalso
			      valOf rangeK <= 2 * length)
			    then let
				   val rangeK = valOf rangeK

				   val cases 
				     = List.insertionSort
				       (cases, 
					fn ((k,target),(k',target')) 
					 => ltFn(k,k'))
				 in 
				   doitTable(cases, 
					     ops,
					     minK, maxK, rangeK,
					     shift, mask,
					     constFn)
				 end
			    else effectDefault gef
			                       {label = label, 
						transfer = transfer}
			end
		  in
		    case cases
		      of Transfer.Cases.Char cases
		       => doit
			  (cases,
			   {zero = #"\000",
			    even = fn c => (Char.ord c) mod 2 = 0,
			    incFn = Char.succ,
			    decFn = Char.pred,
			    halfFn = fn c => Char.chr((Char.ord c) div 2),
			    ltFn = Char.<,
			    gtFn = Char.>,
			    min = Char.minChar,
			    minFn = Char.min,
			    max = Char.maxChar,
			    maxFn = Char.max,
			    range = fn (min,max) => ((Char.ord max) - 
						     (Char.ord min)) + 1},
			   Immediate.const_char)
		       | Transfer.Cases.Int cases
		       => doit
			  (cases,
			   {zero = 0,
			    even = fn i => i mod 2 = 0,
			    incFn = fn i => i + 1,
			    decFn = fn i => i - 1,
			    halfFn = fn i => i div 2,
			    ltFn = Int.<,
			    gtFn = Int.>,
			    min = Int.minInt,
			    minFn = Int.min,
			    max = Int.maxInt,
			    maxFn = Int.max,
			    range = fn (min,max) => max - min + 1},
			   Immediate.const_int)
		       | Transfer.Cases.Word cases
		       => doit
			  (cases,
			   {zero = 0wx0,
			    even = fn w => Word.mod(w,0wx2) = 0wx0,
			    incFn = fn x => Word.+(x,0wx1),
			    decFn = fn x => Word.-(x,0wx1),
			    halfFn = fn x => Word.div(x,0wx2),
			    ltFn = Word.<,
			    gtFn = Word.>,
			    min = 0wx0,
			    minFn = Word.min,
			    max = 0wxFFFFFFFF,
			    maxFn = Word.max,
			    range = fn (min,max) => ((Word.toInt max) -
						     (Word.toInt min) + 
						     1)},
			   Immediate.const_word)
		  end
	       | _ => effectDefault gef 
		                    {label = label,
				     transfer = transfer}

	and fallNone (gef as GEF {generate,effect,fall})
	             {label, live} : Assembly.t AppendList.t
	  = let
	      val liveRegsTransfer = getLiveRegsTransfers
		                     (liveTransfers, label)
	      val liveFltRegsTransfer = getLiveFltRegsTransfers
		                        (liveTransfers, label)

	      val live
		= List.fold
		  (liveRegsTransfer,
		   live,
		   fn ((memloc,_,_),live)
		    => LiveSet.remove(live,memloc))
	      val live
		= List.fold
		  (liveFltRegsTransfer,
		   live,
		   fn ((memloc,_),live)
		    => LiveSet.remove(live,memloc))

	      fun default ()
		= AppendList.fromList
		  ((* flushing at near transfer *)
		   (Assembly.directive_cache
		    {caches = [{register = stackTopReg,
				memloc = stackTop (),
				reserve = true},
			       {register = frontierReg,
				memloc = frontier (),
				reserve = true}]})::
		   (Assembly.directive_fltcache
		    {caches 
		     = List.map
		       (liveFltRegsTransfer,
			fn (memloc,sync) 
			 => {memloc = memloc})})::
		   (Assembly.directive_cache
		    {caches
		     = List.map
		       (liveRegsTransfer,
			fn (temp,register,sync)
			 => {register = register,
			     memloc = temp,
			     reserve = true})})::
		   (Assembly.directive_force
		    {commit_memlocs = LiveSet.toMemLocSet live,
		     commit_classes = nearflushClasses,
		     remove_memlocs = MemLocSet.empty,
		     remove_classes = ClassSet.empty,
		     dead_memlocs = MemLocSet.empty,
		     dead_classes = ClassSet.empty})::
		   (Assembly.instruction_jmp
		    {target = Operand.label label,
		     absolute = false})::
		   (Assembly.directive_unreserve
		    {registers
		     = (stackTopReg)::
		       (frontierReg)::
		       (List.map
			(liveRegsTransfer,
			 fn (temp,register,sync)
			  => register))})::
		   nil)
	    in
	      case getLayoutInfo label
		of NONE
		 => default ()
		 | SOME (block as Block.T {entry,...})
		 => (push label;
		     default ())
	    end

	and fallDefault (gef as GEF {generate,effect,fall})
	                {label, live} : Assembly.t AppendList.t
	  = let	
	      datatype z = datatype x86JumpInfo.status
	      val liveRegsTransfer = getLiveRegsTransfers
		                     (liveTransfers, label)
	      val liveFltRegsTransfer = getLiveFltRegsTransfers
		                        (liveTransfers, label)

	      val live
		= List.fold
		  (liveRegsTransfer,
		   live,
		   fn ((memloc,_,_),live)
		    => LiveSet.remove(live,memloc))
	      val live
		= List.fold
		  (liveFltRegsTransfer,
		   live,
		   fn ((memloc,_),live)
		    => LiveSet.remove(live,memloc))

	      fun default jmp
		= AppendList.appends
		  [AppendList.fromList
		   [(* flushing at near transfer *)
		    (Assembly.directive_cache
		     {caches = [{register = stackTopReg,
				 memloc = stackTop (),
				 reserve = true},
				{register = frontierReg,
				 memloc = frontier (),
				 reserve = true}]}),
		    (Assembly.directive_fltcache
		     {caches 
		      = List.map
		        (liveFltRegsTransfer,
			 fn (memloc,sync) 
			  => {memloc = memloc})}),
		    (Assembly.directive_cache
		     {caches
		      = List.map
		        (liveRegsTransfer,
			 fn (temp,register,sync)
			  => {register = register,
			      memloc = temp,
			      reserve = true})}),
		    (Assembly.directive_force
		     {commit_memlocs = LiveSet.toMemLocSet live,
		      commit_classes = nearflushClasses,
		      remove_memlocs = MemLocSet.empty,
		      remove_classes = ClassSet.empty,
		      dead_memlocs = MemLocSet.empty,
		      dead_classes = ClassSet.empty})],
		   if jmp
		     then AppendList.single
		          (Assembly.instruction_jmp
			   {target = Operand.label label,
			    absolute = false})
		     else AppendList.empty,
		   AppendList.single
		   (Assembly.directive_unreserve
		    {registers
		     = (stackTopReg)::
		       (frontierReg)::
		       (List.map
			(liveRegsTransfer,
			 fn (temp,register,sync)
			  => register))})]
	    in
	      case getLayoutInfo label
		of NONE 
		 => default true
		 | SOME (block as Block.T {entry,...})
		 => (case getNear(jumpInfo, label)
		       of Count 1 
			=> generate gef
			            {label = label,
				     falling = true,
				     unique = true}
		        | _ => AppendList.append
			       (default false,
				AppendList.cons
				(Assembly.directive_reset (),
				 (generate gef
				           {label = label,
					    falling = true,
					    unique = false}))))
	    end
	  
	fun make {generate, effect, fall}
	  = generate (GEF {generate = generate,
			   effect = effect,
			   fall = fall})

	val generate
	  = case optimize 
	      of 0 => make {generate = generateAll,
			    effect = effectDefault,
			    fall = fallNone}
	       | _ => make {generate = generateAll,
			    effect = effectJumpTable,
			    fall = fallDefault}

	val _ = List.foreach
	        (blocks,
		 fn Block.T {entry, ...}
		  => (case entry
			of Func {label, ...} => enque label
			 | _ => ()))
	fun doit () : Assembly.t list list
	  = (case deque ()
	       of NONE => []
	        | SOME label
		=> (case AppendList.toList (generate {label = label,
						      falling = false,
						      unique = false})
		      of [] => doit ()
		       | block => block::(doit ())))
	val assembly = doit ()
	val _ = destLayoutInfo ()
	val _ = destProfileLabel ()
      in
	data::assembly
      end

  val (generateTransfers, generateTransfers_msg)
    = tracerTop
      "generateTransfers"
      generateTransfers

  fun generateTransfers_totals ()
    = (generateTransfers_msg ();
       Control.indent ();
       x86Liveness.LiveInfo.verifyLiveInfo_msg ();
       x86JumpInfo.verifyJumpInfo_msg ();
       x86EntryTransfer.verifyEntryTransfer_msg ();
       x86LoopInfo.createLoopInfo_msg ();
       x86LiveTransfers.computeLiveTransfers_totals ();
       Control.unindent ())
end
