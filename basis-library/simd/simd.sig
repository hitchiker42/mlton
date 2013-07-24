signature SIMD_REAL =
sig
  val vecSize:Int32.int (*size of the simd vector 128 or 256,
                          *hopefully later any multiple of 128*)
  val realSize:Int32.int (*size of real, 32/64*)
  type t (* high level type *)
  type elem (* element type*)
(*load/store*)
  val fromArray:elem array -> t
  val fromArraySlice:elem slice -> t
  val set:elem list -> t
  val set1:elem -> t
  val fromScalar:elem -> t
  val toScalar:t -> elem(*e = lowest element in t*)
(* because of toScalar we can get any element of a simd vector,
 * albeit not super efficently, via shuffling.*)
(*math*)
  val add:t*t->t
  val sub:t*t->t
  val mul:t*t->t
  val div:t*t->t
  val sqrt:t*t->t
  val min:t*t->t
  val max:t*t->t
(*HADD(HSUB follows same pattern
 *SRC :|X7|X6|X5|X4|X3|X2|X1|X0|
 *DEST:|Y7|Y6|Y5|Y4|Y3|Y2|Y1|Y0| (*or SRC2*)
 *END :|Y6+Y7|Y4+Y5|X6+X7|X4+X5|Y2+Y3|X0+Y1|X2+X3|X0+X1|*)
  val hadd:t*t->t(*horozontal add*)
  val hsub:t*t->t(*horozontal sub*)
  val addsub:t*t->t(*add odd indices, sub even indices*)
(*bitwise, no shifts for floating pt numbers, for obvious reasons*)
  val andb:t*t->t
  val xorb:t*t->t
  val orb: t*t->t
  val andnb:t*t->t
  val notb:t->t (*0xff..ff and opperand = ! opperand*)
(*(*Round/Convert*)
  val vroundp:t*t*word8.word->wordx.t(*actual round instruction*)
  (*Need to implement these myself,all are just round with a different imm*)
  (*Also need to make theme take a type argument to determine size*)
  val vround:t*t*int->wordx.t(*imm=00*)
  val vceil:t*t*int->wordx.t(*imm=01*)
  val vfloor:t*t*int->wordx.t(*imm=10*)
  val vtrunc:t*t*int->wordx.t(*imm=11*)
(*these are a lot more complicated, but we should be able to just have a from
 *and a to function and pick the right instruction based on the types*)
  val vcvt2f:WordX.t->t
  val vcvt2i:t->WordX.t*)
(*SSE has 8 float comparisons, AVX has 32 so we implement comparisons using
 *a datatype of possible comparisions*)
  datatype cmp(*type of comparison predicates, its just an integer*)
  val cmp: t*t*cmp->t
(*return true if any of the comparisons return true, uses maskmove
   fun cmpBool(s1,s2,cmp) =
      let
         val s3 = cmp(s1,s2,s3)
      in op=(0.0,maskmove(s3)
   end
 *)
  val cmpBool: t*t*cmp -> bool
(*return a list of booleans, one for each comparison*)
  val cmpBools: t*t*cmp -> bool list
(*(*unpack/shuffle/blend,etc*)
  val shuffle:t*t*word8.word->t
  val blend:t*t*t->t
  val extract:t*word8.word -> e*)
end

signature SIMD_WORD = sig
(*integer instructios are not promoted to 256 bit vectors in avx
 *thus all vector integer types are 128 bit(assuming we ignore mmx)
 *avx still provides 3 opperannd instructions and unaligned access
 *so it is still quite useful. the only note are for insructinons
 *than don't support the avx exensions(I believe there aren't any)*)
  val vec_size:SimdSize.t
  val word_size:WordSize.prim
  type t
  type t2 (* t with element size of word_size*2 *)
(*Math*)
(*S & US suffixs are for signed and unsigned saturation, saturation means
 *values don't wraparound, ie in an unsigned byte 255+1->0 w/o saturation
 *but 255+1->255 w/ saturation*)
  val vadd:t*t->t
  val vadds:t*t->t
  val vaddus:t*t->t
  val vsub:t*t->t
  val vsubs:t*t->t
  val vsubus:t*t->t
  val vmin:t*t->t
  val vmax:t*t->t
  val vpmadd:t*t->t2(*multiply adjecent elements of t and add adjectent
                     *elements of t2 intermediates to get t2 (unsigned)*)
  val vmadds:t*t->t2(*same as vpmadd but with signed*)
  val vmulh:t*t->t (*multiply t*t and take low bytes of t2 results*)
  val vmull:t*t->t (*multiply t*t and take higt bytes of t2 results*)
  val vmulo:t*t->t2 (*multiply odd elements of t,t and return t2 result*)
  val vmule:t*t->t2 (*shift arguments left element_size bytes and do vmulo*)
  val vhadd:t*t->t(*same convention as floating point hadd*)
  val vhsub:t*t->t
  val vabs:t->t
(*bitwise*)
  val vand:t*t->t
  val vnor:t*t->t
  val vor: t*t->t
  val vxor:t*t->t
  val vandn:t*t->t
  val vnot:t->t(*vandn 0xff..ff*t->t*)
(*sa=arathmatic shift(preserve sign) sl=logical shift(fill w/zeros*)
  val vsar:t*t->t
  val vslr:t*t->t
  val vsll:t*t->t
(*we can also logically shift a full 128bit vector left/right*)
(*Comparison*)
  datatype cmp
  val vcmp:v*v*cmp->v
  (*this is all we get for builtin integer comparison*)
  val vcmpeq:t*t->t
  val vcmpgt:t*t->t
(*so i'll need to write these myself
 *vcmpne(!=),vcmpgep(= | >),vcmplt(!(> | =)),vcmple(!>)
 *vcmpngt(!>),vcmpnge(!(= | >)),vcmpnlt(> | =),vcmpnle(>)*)
  val vblend:t*t*t->t(*maybe?*)
end
signature SIMD_AVAIL =
sig
  val sse3:bool
  val ssse3:bool
  val sse4.1:bool
  val sse4.2:bool
  val avx:bool
  val avx2:bool
end
signature SIMD_REAL_STRUCTS =
sig
  structure SimdSize:SIMD_SIZE
  structure RealSize:REAL_SIZE
  structure SimdAvail:SIMD_AVAIL
end
