(require 'dash)
(require 'cl)
(defmacro vp (&rest vals)
  `(format "Array.app printReal (Array.fromList[%f,%f,%f,%f])" ,@vals))
(defun vp-var (var)
  (format "Array.app printReal %s" var))
(defun vp-fn (a b c d)
  (format "Array.app printReal (Array.fromList[%f,%f,%f,%f])" a b c d))
(defmacro vset (name &rest vals)
  `(format "val %s = Array.fromList[%f,%f,%f,%f]" ,name ,@vals))
(defun vset-fn (a b c d e)
  (format "val %s = Array.fromList[%f,%f,%f,%f]" a b c d e))
(defmacro with-debug-on-error (&rest body)
  `(let ((setq debug-on-error t))
     ,@body))
(setf a-double '(1.0 2.0 3.0 4.0))
(setf b-double (reverse simple))
(setf x-double '(3.7 2.4 9.9 100.0))
(setf y-double '(5.5 8.6 7.5 0.01))
(defun lt (x y) (if (< x y)
                    1 0))
(setf nl ";print \"\\n\"")
(defun simd (fun list1 list2) 
  (-zip-with fun list1 list2))
(defun make-sse2-test ()
  (with-temp-file "C-SSE2_test.sml"
    (insert (concat
             ;;toplevel definitons
             "val print = TextIO.print
fun printReal x = print (Real64.toString x ^ \" \")
local 
  open C_SSE2
in\n"
             (format "%s\n%s\n%s\n%s\n"
                     ;;set values of arguements
                     (apply #'vset-fn (cons "a" a-double))
                     (apply #'vset-fn (cons "b" b-double))
                     (apply #'vset-fn (cons "x" x-double))
                     (apply #'vset-fn (cons "y" y-double)))))
    ;;assoicate elisp functions with sml functions and start looping
    (dolist (funs '(("addpd" +) ("subpd" -) ("mulpd" *) ("divpd" /)
                    ("maxpd" max) ("minpd" min)))
      (let ((funct (first funs))
            (op (second funs)))
        (insert
         ;;create per-function sml code, first run actual sml simd functions and set the results
         ;;to variables. Then write code to print results, first print fxn name, then results
         ;;as calculated via elisp, then sml results, for both sets of data. then loop 
         ;;over all functions. Newlines are inserted after every line(when printed from sml)
         (format "(*%s*)\n%s\n%s
val _ = (%s\n\t;%s\n\t%s\n\t;%s\n\t%s\n\t;%s\n\t%s\n\t;%s\n\t%s)\n"
                 ;;put function in sml comment
                 (upcase funct)
                 ;;run functions in sml
                 (format "val z = %s(x,y)"(upcase funct))
                 (format "val c = %s(a,b)" (upcase funct))
                 ;;print from sml program the name of the function
                 (format "print (\"%s\" ^ \"\\n\")" (upcase funct))
                 ;;run lisp function, insert into sml code as the expected value(and set it to print)
                 (replace-regexp-in-string "-" "~" (apply #'vp-fn (simd op a-double b-double))) nl
                 ;;set sml calculates value to print
                 (vp-var "c") nl
                 ;;again run lisp function, ditto above
                 (replace-regexp-in-string "-" "~" (apply #'vp-fn (simd op x-double y-double)) )nl
                 ;;again set sml vals to print
                 (vp-var "z") nl))))
    (insert "end")))
(make-sse2-test)
