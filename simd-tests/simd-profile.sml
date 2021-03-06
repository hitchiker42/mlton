type time = Time.time
fun format_timer (nongc_usr:time,nongc_sys:time,
                  gc_usr:time,gc_sys:time,message:string) =
    let
      val fmt = Time.fmt 9
    in
      concat ([message,"NonGC time:\n\tUser:",fmt(nongc_usr),"\n\tSys:",
               fmt(nongc_sys),"\nGC time:\n\tUser:",fmt(gc_usr),"\n\tSys:",
               fmt(gc_sys),"\n"])
    end
fun time (test,message:string) =
    let
      val timer = Timer.startCPUTimer()
      val x = test()
      val stop = Timer.checkCPUTimes(timer)
      val _ = TextIO.print ("Sum = "^Real64.toString x^"\n")
      val str = format_timer(#usr(#nongc(stop)),#sys(#nongc(stop)),
                             #usr(#gc(stop)),#sys(#gc(stop)),message)
    in
      TextIO.print str
    end
fun time32 (test,message:string) =
    let
      val timer = Timer.startCPUTimer()
      val x = test()
      val stop = Timer.checkCPUTimes(timer)
      val _ = TextIO.print ("Sum = "^Real32.toString x^"\n")
      val str = format_timer(#usr(#nongc(stop)),#sys(#nongc(stop)),
                             #usr(#gc(stop)),#sys(#gc(stop)),message)
    in
      TextIO.print str
    end
(*functor SimdTest (structure S:SIMD_REAL
                  structure R:REAL
                  sharing type S.elt = R.real) =
  struct
    type real = R.real
    type t = S.simdReal
    fun simdFold (x:real,a:real array,f:(t*t->t)):real =
        let
          val len = Array.length a
          val t = S.fromArray a
      (*like when unrolling loops we need to deal with excess elements
       *that don't fit exactally in a simd vector, could probably optimize
       *this a bit more*)
          val overflow = len mod S.elements
          fun init (acc:real,n:int) = 
              if n = 0 then acc else
              init(S.toScalar(f(S.fromScalar(acc),
                     S.fromScalar(Array.sub(a,len-1-n)))),n-1)
      (*after we finish looping we fold the elements of the resulant 
       *simd vector by doing some tricks with shuffling*)
          val fin = fn x =>
                       let
                         val y = x
                         val x = S.shuffle(x,y,(0w2,0w3,0w0,0w1))
                         (*or Simd.movhl/movlh?*)
                         val x = f(x,y)
                         val y = S.shuffle(x,y,(0w1,0w0,0w2,0w3))
                         val x = f(x,y)
                       in x end
          fun loop(s,i) =
              if i >= len then fin s else
              loop(f(t,S.fromArrayOffset(a,i)),op+(i,S.elements))
        in S.toScalar(f(loop(t,S.elements),S.fromScalar(init(x,overflow)))) end
    val simdSum = fn (x,a) => simdFold(x,a,S.add)
    val simdProd = fn (x,a) => simdFold(x,a,S.mul)
    fun timeSum (r) =
        let
          val arr:real array = Array.tabulate(154,R.fromInt)
        in
          simdSum(r,arr)
        end
end*)

fun simple_loop (r:real array) =
    let
      val temp = Array.array(2,0.0:real)
      fun acc (sum,index) =
      if index>=(Array.length r)then
        let 
        val _ = TextIO.print((Simd128_Real64.toString sum)^"\n")
        val _ = Simd128_Real64.toArray(temp,sum)
        in Array.foldr Real64.+ (0.0:real) temp end
      else acc(Simd128_Real64.add(Simd128_Real64.fromArrayOffset(r,index),
                                  sum),
                                  index+2)
    in acc(Simd128_Real64.fromArray(r),2) end
local
  type real = Real32.real
  structure S = Simd128_Real32
in
fun dot (A:real array,B:real array,len:int) = 
    let
      val sum = ref (0.0:real)
      val temp = Array.array(4,0.0:real)
      val index = ref 0
      fun loop () =
          if ((!index)+8) > len orelse ((!index)+8) > 100000000 then (!index)
          else
            let
              val n = S.mul(S.fromArrayOffset(A,(!index)),S.fromArrayOffset(B,(!index)))
              val _ = index:=(!index)+4
              val l = S.mul(S.fromArrayOffset(A,(!index)),S.fromArrayOffset(B,(!index)))
              val m = S.hadd(n,l)
              val _ = index:=(!index)+4
              val _ = S.toArray(temp,m)
              val _ = sum:=(!sum)+Array.sub(temp,0)+Array.sub(temp,1)+Array.sub(temp,2)+Array.sub(temp,3)
      in loop() end
      fun fin (i:int) =
          if i >= len then (!sum)
          else (sum:= (!sum)+(Real32.*(Array.sub(A,i),Array.sub(B,i)));fin(i+1))
    in
      fin(loop())
    end
fun software_dot (A:real array,B:real array,len:int) =
    let 
      val index = ref 0
      val sum = ref (0.0:real)
      val _ = while ((!index)<len) do
                    (sum:=(!sum)+(Array.sub(A,(!index))*Array.sub(B,(!index)));index:=(!index)+1)
    in 
      !sum
end
end
val test_arr = Array.tabulate (100000000,Real64.fromInt)
val test_arr2 = Array.tabulate (100000000,fn x => Real64.fromInt(100000000-x))
val test32_arr = Array.tabulate (100000000,Real32.fromInt)
val test32_arr2 = Array.tabulate (100000000,fn x => Real32.fromInt(100000000-x))
val simple_test = fn () => simple_loop(test_arr)
val dot_test = fn () => dot(test32_arr,test32_arr2,100000000)
val dot_test_software = fn () => software_dot(test32_arr,test32_arr2,100000000)
(*structure testC = SimdTest(structure S = Simd128_Real32
                           structure R = Real32)*)
(*structure testSoftware = SimdTest(Simd128_Real32_Software,Real32)*)
val _ = time(simple_test,"Testing the C backend:\n")
val _ = time32(dot_test,"Testing the C backend dot product:\n")
val _ = time(fn () =>(Array.foldl Real64.+ 0.0 test_arr),"Testing Software:\n")
val _ = time32(dot_test_software,"Testing Software dot:\n")
(*val _ = time(testSoftware.timeSum,"Testing the C backend:\n")*)
