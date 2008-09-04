;;; -*- indent-tabs-mode: nil; outline-regexp: ";;;;+" -*-
;;;
;;; License: Public Domain
;;;
;;;; Introduction
;;;
;;; This is the CMUCL implementation of the `swank-backend' package.

(in-package :swank-backend)

(import-swank-mop-symbols :pcl '(:slot-definition-documentation))

(defun swank-mop:slot-definition-documentation (slot)
  (documentation slot t))

;;;; "Hot fixes"
;;;
;;; Here are necessary bugfixes to the oldest supported version of
;;; CMUCL (currently 18e). Any fixes placed here should also be
;;; submitted to the `cmucl-imp' mailing list and confirmed as
;;; good. When a new release is made that includes the fixes we should
;;; promptly delete them from here. It is enough to be compatible with
;;; the latest release.

(in-package :lisp)

;;; `READ-SEQUENCE' with large sequences has problems in 18e. This new
;;; definition works better.

#-cmu19
(progn
  (let ((s (find-symbol (string :*enable-package-locked-errors*) :lisp)))
    (when s
      (setf (symbol-value s) nil)))

  (defun read-into-simple-string (s stream start end)
    (declare (type simple-string s))
    (declare (type stream stream))
    (declare (type index start end))
    (unless (subtypep (stream-element-type stream) 'character)
      (error 'type-error
             :datum (read-char stream nil #\Null)
             :expected-type (stream-element-type stream)
             :format-control "Trying to read characters from a binary stream."))
    ;; Let's go as low level as it seems reasonable.
    (let* ((numbytes (- end start))
           (total-bytes 0))
      ;; read-n-bytes may return fewer bytes than requested, so we need
      ;; to keep trying.
      (loop while (plusp numbytes) do
            (let ((bytes-read (system:read-n-bytes stream s start numbytes nil)))
              (when (zerop bytes-read)
                (return-from read-into-simple-string total-bytes))
              (incf total-bytes bytes-read)
              (incf start bytes-read)
              (decf numbytes bytes-read)))
      total-bytes))

  (let ((s (find-symbol (string :*enable-package-locked-errors*) :lisp)))
    (when s
      (setf (symbol-value s) t)))

  )

(in-package :swank-backend)


;;;; TCP server
;;;
;;; In CMUCL we support all communication styles. By default we use
;;; `:SIGIO' because it is the most responsive, but it's somewhat
;;; dangerous: CMUCL is not in general "signal safe", and you don't
;;; know for sure what you'll be interrupting. Both `:FD-HANDLER' and
;;; `:SPAWN' are reasonable alternatives.

(defimplementation preferred-communication-style ()
  :sigio)

#-(or darwin mips)
(defimplementation create-socket (host port)
  (let* ((addr (resolve-hostname host))
         (addr (if (not (find-symbol "SOCKET-ERROR" :ext))
                   (ext:htonl addr)
                   addr)))
    (ext:create-inet-listener port :stream :reuse-address t :host addr)))

;; There seems to be a bug in create-inet-listener on Mac/OSX and Irix.
#+(or darwin mips)
(defimplementation create-socket (host port)
  (declare (ignore host))
  (ext:create-inet-listener port :stream :reuse-address t))

(defimplementation local-port (socket)
  (nth-value 1 (ext::get-socket-host-and-port (socket-fd socket))))

(defimplementation close-socket (socket)
  (let ((fd (socket-fd socket)))
    (sys:invalidate-descriptor fd) 
    (ext:close-socket fd)))

(defimplementation accept-connection (socket &key
                                      external-format buffering timeout)
  (declare (ignore timeout))
  (make-socket-io-stream (ext:accept-tcp-connection socket) 
                         (or buffering :full)
                         (or external-format :iso-8859-1)))

;;;;; Sockets

(defun socket-fd (socket)
  "Return the filedescriptor for the socket represented by SOCKET."
  (etypecase socket
    (fixnum socket)
    (sys:fd-stream (sys:fd-stream-fd socket))))

(defun resolve-hostname (hostname)
  "Return the IP address of HOSTNAME as an integer (in host byte-order)."
  (let ((hostent (ext:lookup-host-entry hostname)))
    (car (ext:host-entry-addr-list hostent))))

(defvar *external-format-to-coding-system*
  '((:iso-8859-1
     "latin-1" "latin-1-unix" "iso-latin-1-unix"
     "iso-8859-1" "iso-8859-1-unix")
    #+unicode
    (:utf-8 "utf-8" "utf-8-unix")))

(defimplementation find-external-format (coding-system)
  (car (rassoc-if (lambda (x) (member coding-system x :test #'equal))
                  *external-format-to-coding-system*)))

(defun make-socket-io-stream (fd buffering external-format)
  "Create a new input/output fd-stream for FD."
  #-unicode(declare (ignore external-format))
  (sys:make-fd-stream fd :input t :output t :element-type 'base-char
                      :buffering buffering
                      #+unicode :external-format 
                      #+unicode external-format))

;;;;; Signal-driven I/O

(defimplementation install-sigint-handler (function)
  (sys:enable-interrupt :sigint (lambda (signal code scp)
                                  (declare (ignore signal code scp))
                                  (funcall function))))

(defvar *sigio-handlers* '()
  "List of (key . function) pairs.
All functions are called on SIGIO, and the key is used for removing
specific functions.")

(defun set-sigio-handler ()
  (sys:enable-interrupt :sigio (lambda (signal code scp)
                                 (sigio-handler signal code scp))))

(defun sigio-handler (signal code scp)
  (declare (ignore signal code scp))
  (mapc #'funcall (mapcar #'cdr *sigio-handlers*)))

(defun fcntl (fd command arg)
  "fcntl(2) - manipulate a file descriptor."
  (multiple-value-bind (ok error) (unix:unix-fcntl fd command arg)
    (cond (ok)
          (t (error "fcntl: ~A" (unix:get-unix-error-msg error))))))

(defimplementation add-sigio-handler (socket fn)
  (set-sigio-handler)
  (let ((fd (socket-fd socket)))
    (fcntl fd unix:f-setown (unix:unix-getpid))
    (let ((old-flags (fcntl fd unix:f-getfl 0)))
      (fcntl fd unix:f-setfl (logior old-flags unix:fasync)))
    (assert (not (assoc fd *sigio-handlers*)))
    (push (cons fd fn) *sigio-handlers*)))

(defimplementation remove-sigio-handlers (socket)
  (let ((fd (socket-fd socket)))
    (when (assoc fd *sigio-handlers*)
      (setf *sigio-handlers* (remove fd *sigio-handlers* :key #'car))
      (let ((old-flags (fcntl fd unix:f-getfl 0)))
        (fcntl fd unix:f-setfl (logandc2 old-flags unix:fasync)))
      (sys:invalidate-descriptor fd))
    (assert (not (assoc fd *sigio-handlers*)))
    (when (null *sigio-handlers*)
      (sys:default-interrupt :sigio))))

;;;;; SERVE-EVENT

(defimplementation add-fd-handler (socket fn)
  (let ((fd (socket-fd socket)))
    (sys:add-fd-handler fd :input (lambda (_) _ (funcall fn)))))

(defimplementation remove-fd-handlers (socket)
  (sys:invalidate-descriptor (socket-fd socket)))


;;;; Stream handling
;;; XXX: How come we don't use Gray streams in CMUCL too? -luke (15/May/2004)

(defimplementation make-output-stream (write-string)
  (make-slime-output-stream write-string))

(defimplementation make-input-stream (read-string)
  (make-slime-input-stream read-string))

(defstruct (slime-output-stream
             (:include lisp::lisp-stream
                       (lisp::misc #'sos/misc)
                       (lisp::out #'sos/out)
                       (lisp::sout #'sos/sout))
             (:conc-name sos.)
             (:print-function %print-slime-output-stream)
             (:constructor make-slime-output-stream (output-fn)))
  (output-fn nil :type function)
  (buffer (make-string 8000) :type string)
  (index 0 :type kernel:index)
  (column 0 :type kernel:index)
  (last-flush-time (get-internal-real-time) :type unsigned-byte))

(defun %print-slime-output-stream (s stream d)
  (declare (ignore d))
  (print-unreadable-object (s stream :type t :identity t)))

(defun sos/out (stream char)
  (system:without-interrupts 
    (let ((buffer (sos.buffer stream))
          (index (sos.index stream)))
      (setf (schar buffer index) char)
      (setf (sos.index stream) (1+ index))
      (incf (sos.column stream))
      (when (char= #\newline char)
        (setf (sos.column stream) 0)
        (force-output stream))
      (when (= index (1- (length buffer)))
        (finish-output stream)))
    char))

(defun sos/sout (stream string start end)
  (system:without-interrupts 
    (loop for i from start below end 
          do (sos/out stream (aref string i)))))

(defun log-stream-op (stream operation)
  stream operation
  #+(or)
  (progn 
    (format sys:*tty* "~S @ ~D ~A~%" operation 
            (sos.index stream)
            (/ (- (get-internal-real-time) (sos.last-flush-time stream))
             (coerce internal-time-units-per-second 'double-float)))
    (finish-output sys:*tty*)))
  
(defun sos/misc (stream operation &optional arg1 arg2)
  (declare (ignore arg1 arg2))
  (case operation
    (:finish-output
     (log-stream-op stream operation)
     (system:without-interrupts 
       (let ((end (sos.index stream)))
         (unless (zerop end)
           (let ((s (subseq (sos.buffer stream) 0 end)))
             (setf (sos.index stream) 0)
             (funcall (sos.output-fn stream) s))
           (setf (sos.last-flush-time stream) (get-internal-real-time)))))
     nil)
    (:force-output
     (log-stream-op stream operation)
     (sos/misc-force-output stream)
     nil)
    (:charpos (sos.column stream))
    (:line-length 75)
    (:file-position nil)
    (:element-type 'base-char)
    (:get-command nil)
    (:close nil)
    (t (format *terminal-io* "~&~Astream: ~S~%" stream operation))))

(defun sos/misc-force-output (stream)
  (system:without-interrupts 
    (unless (or (zerop (sos.index stream))
                (loop with buffer = (sos.buffer stream)
                      for i from 0 below (sos.index stream)
                      always (char= (aref buffer i) #\newline)))
      (let ((last (sos.last-flush-time stream))
            (now (get-internal-real-time)))
        (when (> (/ (- now last)
                    (coerce internal-time-units-per-second 'double-float))
                 0.1)
          (finish-output stream))))))

(defstruct (slime-input-stream
             (:include string-stream
                       (lisp::in #'sis/in)
                       (lisp::misc #'sis/misc))
             (:conc-name sis.)
             (:print-function %print-slime-output-stream)
             (:constructor make-slime-input-stream (input-fn)))
  (input-fn nil :type function)
  (buffer   ""  :type string)
  (index    0   :type kernel:index))

(defun sis/in (stream eof-errorp eof-value)
  (let ((index (sis.index stream))
	(buffer (sis.buffer stream)))
    (when (= index (length buffer))
      (let ((string (funcall (sis.input-fn stream))))
        (cond ((zerop (length string))
               (return-from sis/in
                 (if eof-errorp
                     (error (make-condition 'end-of-file :stream stream))
                     eof-value)))
              (t
               (setf buffer string)
               (setf (sis.buffer stream) buffer)
               (setf index 0)))))
    (prog1 (aref buffer index)
      (setf (sis.index stream) (1+ index)))))

(defun sis/misc (stream operation &optional arg1 arg2)
  (declare (ignore arg2))
  (ecase operation
    (:file-position nil)
    (:file-length nil)
    (:unread (setf (aref (sis.buffer stream) 
			 (decf (sis.index stream)))
		   arg1))
    (:clear-input 
     (setf (sis.index stream) 0
			(sis.buffer stream) ""))
    (:listen (< (sis.index stream) (length (sis.buffer stream))))
    (:charpos nil)
    (:line-length nil)
    (:get-command nil)
    (:element-type 'base-char)
    (:close nil)
    (:interactive-p t)))


;;;; Compilation Commands

(defvar *previous-compiler-condition* nil
  "Used to detect duplicates.")

(defvar *previous-context* nil
  "Previous compiler error context.")

(defvar *buffer-name* nil
  "The name of the Emacs buffer we are compiling from.
NIL if we aren't compiling from a buffer.")

(defvar *buffer-start-position* nil)
(defvar *buffer-substring* nil)

(defimplementation call-with-compilation-hooks (function)
  (let ((*previous-compiler-condition* nil)
        (*previous-context* nil)
        (*print-readably* nil))
    (handler-bind ((c::compiler-error #'handle-notification-condition)
                   (c::style-warning  #'handle-notification-condition)
                   (c::warning        #'handle-notification-condition))
      (funcall function))))

(defimplementation swank-compile-file (filename load-p external-format)
  (declare (ignore external-format))
  (clear-xref-info filename)
  (with-compilation-hooks ()
    (let ((*buffer-name* nil)
          (ext:*ignore-extra-close-parentheses* nil))
      (multiple-value-bind (output-file warnings-p failure-p)
          (compile-file filename)
        (unless failure-p
          ;; Cache the latest source file for definition-finding.
          (source-cache-get filename (file-write-date filename))
          (when load-p (load output-file)))
        (values output-file warnings-p failure-p)))))

(defimplementation swank-compile-string (string &key buffer position directory
                                                debug)
  (declare (ignore directory debug))
  (with-compilation-hooks ()
    (let ((*buffer-name* buffer)
          (*buffer-start-position* position)
          (*buffer-substring* string))
      (with-input-from-string (stream string)
        (ext:compile-from-stream 
         stream 
         :source-info `(:emacs-buffer ,buffer 
                        :emacs-buffer-offset ,position
                        :emacs-buffer-string ,string))))))


;;;;; Trapping notes
;;;
;;; We intercept conditions from the compiler and resignal them as
;;; `SWANK:COMPILER-CONDITION's.

(defun handle-notification-condition (condition)
  "Handle a condition caused by a compiler warning."
  (unless (eq condition *previous-compiler-condition*)
    (let ((context (c::find-error-context nil)))
      (setq *previous-compiler-condition* condition)
      (setq *previous-context* context)
      (signal-compiler-condition condition context))))

(defun signal-compiler-condition (condition context)
  (signal (make-condition
           'compiler-condition
           :original-condition condition
           :severity (severity-for-emacs condition)
           :short-message (brief-compiler-message-for-emacs condition)
           :message (long-compiler-message-for-emacs condition context)
           :location (if (read-error-p condition)
                         (read-error-location condition)
                         (compiler-note-location context)))))

(defun severity-for-emacs (condition)
  "Return the severity of CONDITION."
  (etypecase condition
    ((satisfies read-error-p) :read-error)
    (c::compiler-error :error)
    (c::style-warning :note)
    (c::warning :warning)))

(defun read-error-p (condition)
  (eq (type-of condition) 'c::compiler-read-error))

(defun brief-compiler-message-for-emacs (condition)
  "Briefly describe a compiler error for Emacs.
When Emacs presents the message it already has the source popped up
and the source form highlighted. This makes much of the information in
the error-context redundant."
  (princ-to-string condition))

(defun long-compiler-message-for-emacs (condition error-context)
  "Describe a compiler error for Emacs including context information."
  (declare (type (or c::compiler-error-context null) error-context))
  (multiple-value-bind (enclosing source)
      (if error-context
          (values (c::compiler-error-context-enclosing-source error-context)
                  (c::compiler-error-context-source error-context)))
    (format nil "~@[--> ~{~<~%--> ~1:;~A~> ~}~%~]~@[~{==>~%~A~^~%~}~]~A"
            enclosing source condition)))

(defun read-error-location (condition)
  (let* ((finfo (car (c::source-info-current-file c::*source-info*)))
         (file (c::file-info-name finfo))
         (pos (c::compiler-read-error-position condition)))
    (cond ((and (eq file :stream) *buffer-name*)
           (make-location (list :buffer *buffer-name*)
                          (list :position (+ *buffer-start-position* pos))))
          ((and (pathnamep file) (not *buffer-name*))
           (make-location (list :file (unix-truename file))
                          (list :position (1+ pos))))
          (t (break)))))

(defun compiler-note-location (context)
  "Derive the location of a complier message from its context.
Return a `location' record, or (:error REASON) on failure."
  (if (null context)
      (note-error-location)
      (let ((file (c::compiler-error-context-file-name context))
            (source (c::compiler-error-context-original-source context))
            (path
             (reverse (c::compiler-error-context-original-source-path context))))
        (or (locate-compiler-note file source path)
            (note-error-location)))))

(defun note-error-location ()
  "Pseudo-location for notes that can't be located."
  (list :error "No error location available."))

(defun locate-compiler-note (file source source-path)
  (cond ((and (eq file :stream) *buffer-name*)
         ;; Compiling from a buffer
         (let ((position (+ *buffer-start-position*
                            (source-path-string-position
                             source-path *buffer-substring*))))
           (make-location (list :buffer *buffer-name*)
                          (list :position position))))
        ((and (pathnamep file) (null *buffer-name*))
         ;; Compiling from a file
         (make-location (list :file (unix-truename file))
                        (list :position
                              (1+ (source-path-file-position
                                   source-path file)))))
        ((and (eq file :lisp) (stringp source))
         ;; No location known, but we have the source form.
         ;; XXX How is this case triggered?  -luke (16/May/2004) 
         ;; This can happen if the compiler needs to expand a macro
         ;; but the macro-expander is not yet compiled.  Calling the
         ;; (interpreted) macro-expander triggers IR1 conversion of
         ;; the lambda expression for the expander and invokes the
         ;; compiler recursively.
         (make-location (list :source-form source)
                        (list :position 1)))))

(defun unix-truename (pathname)
  (ext:unix-namestring (truename pathname)))


;;;; XREF
;;;
;;; Cross-reference support is based on the standard CMUCL `XREF'
;;; package. This package has some caveats: XREF information is
;;; recorded during compilation and not preserved in fasl files, and
;;; XREF recording is disabled by default. Redefining functions can
;;; also cause duplicate references to accumulate, but
;;; `swank-compile-file' will automatically clear out any old records
;;; from the same filename.
;;;
;;; To enable XREF recording, set `c:*record-xref-info*' to true. To
;;; clear out the XREF database call `xref:init-xref-database'.

(defmacro defxref (name function)
  `(defimplementation ,name (name)
    (xref-results (,function name))))

(defxref who-calls      xref:who-calls)
(defxref who-references xref:who-references)
(defxref who-binds      xref:who-binds)
(defxref who-sets       xref:who-sets)

;;; More types of XREF information were added since 18e:
;;;
#+cmu19
(progn
  (defxref who-macroexpands xref:who-macroexpands)
  ;; XXX
  (defimplementation who-specializes (symbol)
    (let* ((methods (xref::who-specializes (find-class symbol)))
           (locations (mapcar #'method-location methods)))
      (mapcar #'list methods locations))))

(defun xref-results (contexts)
  (mapcar (lambda (xref)
            (list (xref:xref-context-name xref)
                  (resolve-xref-location xref)))
          contexts))

(defun resolve-xref-location (xref)
  (let ((name (xref:xref-context-name xref))
        (file (xref:xref-context-file xref))
        (source-path (xref:xref-context-source-path xref)))
    (cond ((and file source-path)
           (let ((position (source-path-file-position source-path file)))
             (make-location (list :file (unix-truename file))
                            (list :position (1+ position)))))
          (file
           (make-location (list :file (unix-truename file))
                          (list :function-name (string name))))
          (t
           `(:error ,(format nil "Unknown source location: ~S ~S ~S " 
                             name file source-path))))))

(defun clear-xref-info (namestring)
  "Clear XREF notes pertaining to NAMESTRING.
This is a workaround for a CMUCL bug: XREF records are cumulative."
  (when c:*record-xref-info*
    (let ((filename (truename namestring)))
      (dolist (db (list xref::*who-calls*
                        #+cmu19 xref::*who-is-called*
                        #+cmu19 xref::*who-macroexpands*
                        xref::*who-references*
                        xref::*who-binds*
                        xref::*who-sets*))
        (maphash (lambda (target contexts)
                   ;; XXX update during traversal?  
                   (setf (gethash target db)
                         (delete filename contexts 
                                 :key #'xref:xref-context-file
                                 :test #'equalp)))
                 db)))))


;;;; Find callers and callees
;;;
;;; Find callers and callees by looking at the constant pool of
;;; compiled code objects.  We assume every fdefn object in the
;;; constant pool corresponds to a call to that function.  A better
;;; strategy would be to use the disassembler to find actual
;;; call-sites.

(declaim (inline map-code-constants))
(defun map-code-constants (code fn)
  "Call FN for each constant in CODE's constant pool."
  (check-type code kernel:code-component)
  (loop for i from vm:code-constants-offset below (kernel:get-header-data code)
	do (funcall fn (kernel:code-header-ref code i))))

(defun function-callees (function)
  "Return FUNCTION's callees as a list of functions."
  (let ((callees '()))
    (map-code-constants 
     (vm::find-code-object function)
     (lambda (obj)
       (when (kernel:fdefn-p obj)
	 (push (kernel:fdefn-function obj) callees))))
    callees))

(declaim (ext:maybe-inline map-allocated-code-components))
(defun map-allocated-code-components (spaces fn)
  "Call FN for each allocated code component in one of SPACES.  FN
receives the object as argument.  SPACES should be a list of the
symbols :dynamic, :static, or :read-only."
  (dolist (space spaces)
    (declare (inline vm::map-allocated-objects)
             (optimize (ext:inhibit-warnings 3)))
    (vm::map-allocated-objects
     (lambda (obj header size)
       (declare (type fixnum size) (ignore size))
       (when (= vm:code-header-type header)
	 (funcall fn obj)))
     space)))

(declaim (ext:maybe-inline map-caller-code-components))
(defun map-caller-code-components (function spaces fn)
  "Call FN for each code component with a fdefn for FUNCTION in its
constant pool."
  (let ((function (coerce function 'function)))
    (declare (inline map-allocated-code-components))
    (map-allocated-code-components
     spaces 
     (lambda (obj)
       (map-code-constants 
	obj 
	(lambda (constant)
	  (when (and (kernel:fdefn-p constant)
		     (eq (kernel:fdefn-function constant)
			 function))
	    (funcall fn obj))))))))

(defun function-callers (function &optional (spaces '(:read-only :static 
						      :dynamic)))
  "Return FUNCTION's callers.  The result is a list of code-objects."
  (let ((referrers '()))
    (declare (inline map-caller-code-components))
    ;;(ext:gc :full t)
    (map-caller-code-components function spaces 
                                (lambda (code) (push code referrers)))
    referrers))

(defun debug-info-definitions (debug-info)
  "Return the defintions for a debug-info.  This should only be used
for code-object without entry points, i.e., byte compiled
code (are theree others?)"
  ;; This mess has only been tested with #'ext::skip-whitespace, a
  ;; byte-compiled caller of #'read-char .
  (check-type debug-info (and (not c::compiled-debug-info) c::debug-info))
  (let ((name (c::debug-info-name debug-info))
        (source (c::debug-info-source debug-info)))
    (destructuring-bind (first) source 
      (ecase (c::debug-source-from first)
        (:file 
         (list (list name
                     (make-location 
                      (list :file (unix-truename (c::debug-source-name first)))
                      (list :function-name (string name))))))))))

(defun code-component-entry-points (code)
  "Return a list ((NAME LOCATION) ...) of function definitons for
the code omponent CODE."
  (let ((names '()))
    (do ((f (kernel:%code-entry-points code) (kernel::%function-next f)))
        ((not f))
      (let ((name (kernel:%function-name f)))
        (when (ext:valid-function-name-p name)
          (push (list name (function-location f)) names))))
    names))

(defimplementation list-callers (symbol)
  "Return a list ((NAME LOCATION) ...) of callers."
  (let ((components (function-callers symbol))
        (xrefs '()))
    (dolist (code components)
      (let* ((entry (kernel:%code-entry-points code))
             (defs (if entry
                       (code-component-entry-points code)
                       ;; byte compiled stuff
                       (debug-info-definitions 
                        (kernel:%code-debug-info code)))))
        (setq xrefs (nconc defs xrefs))))
    xrefs))

(defimplementation list-callees (symbol)
  (let ((fns (function-callees symbol)))
    (mapcar (lambda (fn)
              (list (kernel:%function-name fn)
                    (function-location fn)))
            fns)))


;;;; Resolving source locations
;;;
;;; Our mission here is to "resolve" references to code locations into
;;; actual file/buffer names and character positions. The references
;;; we work from come out of the compiler's statically-generated debug
;;; information, such as `code-location''s and `debug-source''s. For
;;; more details, see the "Debugger Programmer's Interface" section of
;;; the CMUCL manual.
;;;
;;; The first step is usually to find the corresponding "source-path"
;;; for the location. Once we have the source-path we can pull up the
;;; source file and `READ' our way through to the right position. The
;;; main source-code groveling work is done in
;;; `swank-source-path-parser.lisp'.

(defvar *debug-definition-finding* nil
  "When true don't handle errors while looking for definitions.
This is useful when debugging the definition-finding code.")

(defvar *source-snippet-size* 256
  "Maximum number of characters in a snippet of source code.
Snippets at the beginning of definitions are used to tell Emacs what
the definitions looks like, so that it can accurately find them by
text search.")

(defmacro safe-definition-finding (&body body)
  "Execute BODY and return the source-location it returns.
If an error occurs and `*debug-definition-finding*' is false, then
return an error pseudo-location.

The second return value is NIL if no error occurs, otherwise it is the
condition object."
  `(flet ((body () ,@body))
    (if *debug-definition-finding*
        (body)
        (handler-case (values (progn ,@body) nil)
          (error (c) (values `(:error ,(trim-whitespace (princ-to-string c)))
                             c))))))

(defun trim-whitespace (string)
  (string-trim #(#\newline #\space #\tab) string))

(defun code-location-source-location (code-location)
  "Safe wrapper around `code-location-from-source-location'."
  (safe-definition-finding
   (source-location-from-code-location code-location)))

(defun source-location-from-code-location (code-location)
  "Return the source location for CODE-LOCATION."
  (let ((debug-fun (di:code-location-debug-function code-location)))
    (when (di::bogus-debug-function-p debug-fun)
      ;; Those lousy cheapskates! They've put in a bogus debug source
      ;; because the code was compiled at a low debug setting.
      (error "Bogus debug function: ~A" debug-fun)))
  (let* ((debug-source (di:code-location-debug-source code-location))
         (from (di:debug-source-from debug-source))
         (name (di:debug-source-name debug-source)))
    (ecase from
      (:file 
       (location-in-file name code-location debug-source))
      (:stream
       (location-in-stream code-location debug-source))
      (:lisp
       ;; The location comes from a form passed to `compile'.
       ;; The best we can do is return the form itself for printing.
       (make-location
        (list :source-form (with-output-to-string (*standard-output*)
                             (debug::print-code-location-source-form 
                              code-location 100 t)))
        (list :position 1))))))

(defun location-in-file (filename code-location debug-source)
  "Resolve the source location for CODE-LOCATION in FILENAME."
  (let* ((code-date (di:debug-source-created debug-source))
         (source-code (get-source-code filename code-date)))
    (with-input-from-string (s source-code)
      (make-location (list :file (unix-truename filename))
                     (list :position (1+ (code-location-stream-position
                                          code-location s)))
                     `(:snippet ,(read-snippet s))))))

(defun location-in-stream (code-location debug-source)
  "Resolve the source location for a CODE-LOCATION from a stream.
This only succeeds if the code was compiled from an Emacs buffer."
  (unless (debug-source-info-from-emacs-buffer-p debug-source)
    (error "The code is compiled from a non-SLIME stream."))
  (let* ((info (c::debug-source-info debug-source))
         (string (getf info :emacs-buffer-string))
         (position (code-location-string-offset 
                    code-location
                    string)))
    (make-location
     (list :buffer (getf info :emacs-buffer))
     (list :position (+ (getf info :emacs-buffer-offset) position))
     (list :snippet (with-input-from-string (s string)
                      (file-position s position)
                      (read-snippet s))))))

;;;;; Function-name locations
;;;
(defun debug-info-function-name-location (debug-info)
  "Return a function-name source-location for DEBUG-INFO.
Function-name source-locations are a fallback for when precise
positions aren't available."
  (with-struct (c::debug-info- (fname name) source) debug-info
    (with-struct (c::debug-source- info from name) (car source)
      (ecase from
        (:file 
         (make-location (list :file (namestring (truename name)))
                        (list :function-name (string fname))))
        (:stream
         (assert (debug-source-info-from-emacs-buffer-p (car source)))
         (make-location (list :buffer (getf info :emacs-buffer))
                        (list :function-name (string fname))))
        (:lisp
         (make-location (list :source-form (princ-to-string (aref name 0)))
                        (list :position 1)))))))

(defun debug-source-info-from-emacs-buffer-p (debug-source)
  "Does the `info' slot of DEBUG-SOURCE contain an Emacs buffer location?
This is true for functions that were compiled directly from buffers."
  (info-from-emacs-buffer-p (c::debug-source-info debug-source)))

(defun info-from-emacs-buffer-p (info)
  (and info 
       (consp info)
       (eq :emacs-buffer (car info))))


;;;;; Groveling source-code for positions

(defun code-location-stream-position (code-location stream)
  "Return the byte offset of CODE-LOCATION in STREAM.  Extract the
toplevel-form-number and form-number from CODE-LOCATION and use that
to find the position of the corresponding form.

Finish with STREAM positioned at the start of the code location."
  (let* ((location (debug::maybe-block-start-location code-location))
	 (tlf-offset (di:code-location-top-level-form-offset location))
	 (form-number (di:code-location-form-number location)))
    (let ((pos (form-number-stream-position tlf-offset form-number stream)))
      (file-position stream pos)
      pos)))

(defun form-number-stream-position (tlf-number form-number stream)
  "Return the starting character position of a form in STREAM.
TLF-NUMBER is the top-level-form number.
FORM-NUMBER is an index into a source-path table for the TLF."
  (multiple-value-bind (tlf position-map) (read-source-form tlf-number stream)
    (let* ((path-table (di:form-number-translations tlf 0))
           (source-path
            (if (<= (length path-table) form-number) ; source out of sync?
                (list 0)                ; should probably signal a condition
                (reverse (cdr (aref path-table form-number))))))
      (source-path-source-position source-path tlf position-map))))
  
(defun code-location-string-offset (code-location string)
  "Return the byte offset of CODE-LOCATION in STRING.
See CODE-LOCATION-STREAM-POSITION."
  (with-input-from-string (s string)
    (code-location-stream-position code-location s)))


;;;; Finding definitions

;;; There are a great many different types of definition for us to
;;; find. We search for definitions of every kind and return them in a
;;; list.

(defimplementation find-definitions (name)
  (append (function-definitions name)
          (setf-definitions name)
          (variable-definitions name)
          (class-definitions name)
          (type-definitions name)
          (compiler-macro-definitions name)
          (source-transform-definitions name)
          (function-info-definitions name)
          (ir1-translator-definitions name)))

;;;;; Functions, macros, generic functions, methods
;;;
;;; We make extensive use of the compile-time debug information that
;;; CMUCL records, in particular "debug functions" and "code
;;; locations." Refer to the "Debugger Programmer's Interface" section
;;; of the CMUCL manual for more details.

(defun function-definitions (name)
  "Return definitions for NAME in the \"function namespace\", i.e.,
regular functions, generic functions, methods and macros.
NAME can any valid function name (e.g, (setf car))."
  (let ((macro?    (and (symbolp name) (macro-function name)))
        (special?  (and (symbolp name) (special-operator-p name)))
        (function? (and (ext:valid-function-name-p name)
                        (ext:info :function :definition name)
                        (if (symbolp name) (fboundp name) t))))
    (cond (macro? 
           (list `((defmacro ,name)
                   ,(function-location (macro-function name)))))
          (special?
           (list `((:special-operator ,name) 
                   (:error ,(format nil "Special operator: ~S" name)))))
          (function?
           (let ((function (fdefinition name)))
             (if (genericp function)
                 (generic-function-definitions name function)
                 (list (list `(function ,name)
                             (function-location function)))))))))

;;;;;; Ordinary (non-generic/macro/special) functions
;;;
;;; First we test if FUNCTION is a closure created by defstruct, and
;;; if so extract the defstruct-description (`dd') from the closure
;;; and find the constructor for the struct.  Defstruct creates a
;;; defun for the default constructor and we use that as an
;;; approximation to the source location of the defstruct.
;;;
;;; For an ordinary function we return the source location of the
;;; first code-location we find.
;;;
(defun function-location (function)
  "Return the source location for FUNCTION."
  (cond ((struct-closure-p function)
         (struct-closure-location function))
        ((c::byte-function-or-closure-p function)
         (byte-function-location function))
        (t
         (compiled-function-location function))))

(defun compiled-function-location (function)
  "Return the location of a regular compiled function."
  (multiple-value-bind (code-location error)
      (safe-definition-finding (function-first-code-location function))
    (cond (error (list :error (princ-to-string error)))
          (t (code-location-source-location code-location)))))

(defun function-first-code-location (function)
  "Return the first code-location we can find for FUNCTION."
  (and (function-has-debug-function-p function)
       (di:debug-function-start-location
        (di:function-debug-function function))))

(defun function-has-debug-function-p (function)
  (di:function-debug-function function))

(defun function-code-object= (closure function)
  (and (eq (vm::find-code-object closure)
	   (vm::find-code-object function))
       (not (eq closure function))))

(defun byte-function-location (fun)
  "Return the location of the byte-compiled function FUN."
  (etypecase fun
    ((or c::hairy-byte-function c::simple-byte-function)
     (let* ((di (kernel:%code-debug-info (c::byte-function-component fun))))
       (if di 
           (debug-info-function-name-location di)
           `(:error 
             ,(format nil "Byte-function without debug-info: ~a" fun)))))
    (c::byte-closure
     (byte-function-location (c::byte-closure-function fun)))))

;;; Here we deal with structure accessors. Note that `dd' is a
;;; "defstruct descriptor" structure in CMUCL. A `dd' describes a
;;; `defstruct''d structure.

(defun struct-closure-p (function)
  "Is FUNCTION a closure created by defstruct?"
  (or (function-code-object= function #'kernel::structure-slot-accessor)
      (function-code-object= function #'kernel::structure-slot-setter)
      (function-code-object= function #'kernel::%defstruct)))

(defun struct-closure-location (function)
  "Return the location of the structure that FUNCTION belongs to."
  (assert (struct-closure-p function))
  (safe-definition-finding
    (dd-location (struct-closure-dd function))))

(defun struct-closure-dd (function)
  "Return the defstruct-definition (dd) of FUNCTION."
  (assert (= (kernel:get-type function) vm:closure-header-type))
  (flet ((find-layout (function)
	   (sys:find-if-in-closure 
	    (lambda (x) 
	      (let ((value (if (di::indirect-value-cell-p x)
			       (c:value-cell-ref x) 
			       x)))
		(when (kernel::layout-p value)
		  (return-from find-layout value))))
	    function)))
    (kernel:layout-info (find-layout function))))

(defun dd-location (dd)
  "Return the location of a `defstruct'."
  ;; Find the location in a constructor.
  (function-location (struct-constructor dd)))

(defun struct-constructor (dd)
  "Return a constructor function from a defstruct definition.
Signal an error if no constructor can be found."
  (let ((constructor (or (kernel:dd-default-constructor dd)
                         (car (kernel::dd-constructors dd)))))
    (when (or (null constructor)
              (and (consp constructor) (null (car constructor))))
      (error "Cannot find structure's constructor: ~S"
             (kernel::dd-name dd)))
    (coerce (if (consp constructor) (first constructor) constructor)
            'function)))

;;;;;; Generic functions and methods

(defun generic-function-definitions (name function)
  "Return the definitions of a generic function and its methods."
  (cons (list `(defgeneric ,name) (gf-location function))
        (gf-method-definitions function)))

(defun gf-location (gf)
  "Return the location of the generic function GF."
  (definition-source-location gf (pcl::generic-function-name gf)))

(defun gf-method-definitions (gf)
  "Return the locations of all methods of the generic function GF."
  (mapcar #'method-definition (pcl::generic-function-methods gf)))

(defun method-definition (method)
  (list (method-dspec method)
        (method-location method)))

(defun method-dspec (method)
  "Return a human-readable \"definition specifier\" for METHOD."
  (let* ((gf (pcl:method-generic-function method))
         (name (pcl:generic-function-name gf))
         (specializers (pcl:method-specializers method))
         (qualifiers (pcl:method-qualifiers method)))
    `(method ,name ,@qualifiers ,(pcl::unparse-specializers specializers))))

;; XXX maybe special case setters/getters
(defun method-location (method)
  (function-location (or (pcl::method-fast-function method)
                         (pcl:method-function method))))

(defun genericp (fn)
  (typep fn 'generic-function))

;;;;;; Types and classes

(defun type-definitions (name)
  "Return `deftype' locations for type NAME."
  (maybe-make-definition (ext:info :type :expander name) 'deftype name))

(defun maybe-make-definition (function kind name)
  "If FUNCTION is non-nil then return its definition location."
  (if function
      (list (list `(,kind ,name) (function-location function)))))

(defun class-definitions (name)
  "Return the definition locations for the class called NAME."
  (if (symbolp name)
      (let ((class (kernel::find-class name nil)))
        (etypecase class
          (null '())
          (kernel::structure-class 
           (list (list `(defstruct ,name) (dd-location (find-dd name)))))
          #+(or)
          (conditions::condition-class
           (list (list `(define-condition ,name) 
                       (condition-class-location class))))
          (kernel::standard-class
           (list (list `(defclass ,name) 
                       (class-location (find-class name)))))
          ((or kernel::built-in-class 
               conditions::condition-class
               kernel:funcallable-structure-class)
           (list (list `(kernel::define-type-class ,name)
                       `(:error 
                         ,(format nil "No source info for ~A" name)))))))))

(defun class-location (class)
  "Return the `defclass' location for CLASS."
  (definition-source-location class (pcl:class-name class)))

(defun find-dd (name)
  "Find the defstruct-definition by the name of its structure-class."
  (let ((layout (ext:info :type :compiler-layout name)))
    (if layout 
        (kernel:layout-info layout))))

(defun condition-class-location (class)
  (let ((slots (conditions::condition-class-slots class))
        (name (conditions::condition-class-name class)))
    (cond ((null slots)
           `(:error ,(format nil "No location info for condition: ~A" name)))
          (t
           ;; Find the class via one of its slot-reader methods.
           (let* ((slot (first slots))
                  (gf (fdefinition 
                       (first (conditions::condition-slot-readers slot)))))
             (method-location 
              (first 
               (pcl:compute-applicable-methods-using-classes 
                gf (list (find-class name))))))))))

(defun make-name-in-file-location (file string)
  (multiple-value-bind (filename c)
      (ignore-errors 
        (unix-truename (merge-pathnames (make-pathname :type "lisp")
                                        file)))
    (cond (filename (make-location `(:file ,filename)
                                   `(:function-name ,(string string))))
          (t (list :error (princ-to-string c))))))

(defun source-location-form-numbers (location)
  (c::decode-form-numbers (c::form-numbers-form-numbers location)))

(defun source-location-tlf-number (location)
  (nth-value 0 (source-location-form-numbers location)))

(defun source-location-form-number (location)
  (nth-value 1 (source-location-form-numbers location)))

(defun resolve-file-source-location (location)
  (let ((filename (c::file-source-location-pathname location))
        (tlf-number (source-location-tlf-number location))
        (form-number (source-location-form-number location)))
    (with-open-file (s filename)
      (let ((pos (form-number-stream-position tlf-number form-number s)))
        (make-location `(:file ,(unix-truename filename))
                       `(:position ,(1+ pos)))))))

(defun resolve-stream-source-location (location)
  (let ((info (c::stream-source-location-user-info location))
        (tlf-number (source-location-tlf-number location))
        (form-number (source-location-form-number location)))
    ;; XXX duplication in frame-source-location
    (assert (info-from-emacs-buffer-p info))
    (destructuring-bind (&key emacs-buffer emacs-buffer-string 
                              emacs-buffer-offset) info
      (with-input-from-string (s emacs-buffer-string)
        (let ((pos (form-number-stream-position tlf-number form-number s)))
          (make-location `(:buffer ,emacs-buffer)
                         `(:position ,(+ emacs-buffer-offset pos))))))))

;; XXX predicates for 18e backward compatibilty.  Remove them when
;; we're 19a only.
(defun file-source-location-p (object) 
  (when (fboundp 'c::file-source-location-p)
    (c::file-source-location-p object)))

(defun stream-source-location-p (object)
  (when (fboundp 'c::stream-source-location-p)
    (c::stream-source-location-p object)))

(defun source-location-p (object)
  (or (file-source-location-p object)
      (stream-source-location-p object)))

(defun resolve-source-location (location)
  (etypecase location
    ((satisfies file-source-location-p)
     (resolve-file-source-location location))
    ((satisfies stream-source-location-p)
     (resolve-stream-source-location location))))

(defun definition-source-location (object name)
  (let ((source (pcl::definition-source object)))
    (etypecase source
      (null 
       `(:error ,(format nil "No source info for: ~A" object)))
      ((satisfies source-location-p)
       (resolve-source-location source))
      (pathname 
       (make-name-in-file-location source name))
      (cons
       (destructuring-bind ((dg name) pathname) source
         (declare (ignore dg))
         (etypecase pathname
           (pathname (make-name-in-file-location pathname (string name)))
           (null `(:error ,(format nil "Cannot resolve: ~S" source)))))))))

(defun setf-definitions (name)
  (let ((function (or (ext:info :setf :inverse name)
                      (ext:info :setf :expander name)
                      (and (symbolp name)
                           (fboundp `(setf ,name))
                           (fdefinition `(setf ,name))))))
    (if function
        (list (list `(setf ,name) 
                    (function-location (coerce function 'function)))))))


(defun variable-location (symbol)
  (multiple-value-bind (location foundp)
      ;; XXX for 18e compatibilty. rewrite this when we drop 18e
      ;; support.
      (ignore-errors (eval `(ext:info :source-location :defvar ',symbol)))
    (if (and foundp location)
        (resolve-source-location location)
        `(:error ,(format nil "No source info for variable ~S" symbol)))))

(defun variable-definitions (name)
  (if (symbolp name)
      (multiple-value-bind (kind recorded-p) (ext:info :variable :kind name)
        (if recorded-p
            (list (list `(variable ,kind ,name)
                        (variable-location name)))))))

(defun compiler-macro-definitions (symbol)
  (maybe-make-definition (compiler-macro-function symbol)
                         'define-compiler-macro
                         symbol))

(defun source-transform-definitions (name)
  (maybe-make-definition (ext:info :function :source-transform name)
                         'c:def-source-transform
                         name))

(defun function-info-definitions (name)
  (let ((info (ext:info :function :info name)))
    (if info
        (append (loop for transform in (c::function-info-transforms info)
                      collect (list `(c:deftransform ,name 
                                      ,(c::type-specifier 
                                        (c::transform-type transform)))
                                    (function-location (c::transform-function 
                                                        transform))))
                (maybe-make-definition (c::function-info-derive-type info)
                                       'c::derive-type name)
                (maybe-make-definition (c::function-info-optimizer info)
                                       'c::optimizer name)
                (maybe-make-definition (c::function-info-ltn-annotate info)
                                       'c::ltn-annotate name)
                (maybe-make-definition (c::function-info-ir2-convert info)
                                       'c::ir2-convert name)
                (loop for template in (c::function-info-templates info)
                      collect (list `(c::vop ,(c::template-name template))
                                    (function-location 
                                     (c::vop-info-generator-function 
                                      template))))))))

(defun ir1-translator-definitions (name)
  (maybe-make-definition (ext:info :function :ir1-convert name)
                         'c:def-ir1-translator name))


;;;; Documentation.

(defimplementation describe-symbol-for-emacs (symbol)
  (let ((result '()))
    (flet ((doc (kind)
             (or (documentation symbol kind) :not-documented))
           (maybe-push (property value)
             (when value
               (setf result (list* property value result)))))
      (maybe-push
       :variable (multiple-value-bind (kind recorded-p)
		     (ext:info variable kind symbol)
		   (declare (ignore kind))
		   (if (or (boundp symbol) recorded-p)
		       (doc 'variable))))
      (when (fboundp symbol)
	(maybe-push
	 (cond ((macro-function symbol)     :macro)
	       ((special-operator-p symbol) :special-operator)
	       ((genericp (fdefinition symbol)) :generic-function)
	       (t :function))
	 (doc 'function)))
      (maybe-push
       :setf (if (or (ext:info setf inverse symbol)
		     (ext:info setf expander symbol))
		 (doc 'setf)))
      (maybe-push
       :type (if (ext:info type kind symbol)
		 (doc 'type)))
      (maybe-push
       :class (if (find-class symbol nil) 
		  (doc 'class)))
      (maybe-push
       :alien-type (if (not (eq (ext:info alien-type kind symbol) :unknown))
		       (doc 'alien-type)))
      (maybe-push
       :alien-struct (if (ext:info alien-type struct symbol)
			 (doc nil)))
      (maybe-push
       :alien-union (if (ext:info alien-type union symbol)
			 (doc nil)))
      (maybe-push
       :alien-enum (if (ext:info alien-type enum symbol)
		       (doc nil)))
      result)))

(defimplementation describe-definition (symbol namespace)
  (describe (ecase namespace
              (:variable
               symbol)
              ((:function :generic-function)
               (symbol-function symbol))
              (:setf
               (or (ext:info setf inverse symbol)
                   (ext:info setf expander symbol)))
              (:type
               (kernel:values-specifier-type symbol))
              (:class
               (find-class symbol))
              (:alien-struct
               (ext:info :alien-type :struct symbol))
              (:alien-union
               (ext:info :alien-type :union symbol))
              (:alien-enum
               (ext:info :alien-type :enum symbol))
              (:alien-type
               (ecase (ext:info :alien-type :kind symbol)
                 (:primitive
                  (let ((alien::*values-type-okay* t))
                    (funcall (ext:info :alien-type :translator symbol) 
                             (list symbol))))
                 ((:defined)
                  (ext:info :alien-type :definition symbol))
                 (:unknown :unkown))))))

;;;;; Argument lists

(defimplementation arglist (fun)
  (etypecase fun
    (function (function-arglist fun))
    (symbol (function-arglist (or (macro-function fun)
                                  (symbol-function fun))))))

(defun function-arglist (fun)
  (let ((arglist
         (cond ((eval:interpreted-function-p fun)
                (eval:interpreted-function-arglist fun))
               ((pcl::generic-function-p fun)
                (pcl:generic-function-lambda-list fun))
               ((c::byte-function-or-closure-p fun)
                (byte-code-function-arglist fun))
               ((kernel:%function-arglist (kernel:%function-self fun))
                (handler-case (read-arglist fun)
                  (error () :not-available)))
               ;; this should work both for compiled-debug-function
               ;; and for interpreted-debug-function
               (t 
                (handler-case (debug-function-arglist 
                               (di::function-debug-function fun))
                  (di:unhandled-condition () :not-available))))))
    (check-type arglist (or list (member :not-available)))
    arglist))

(defimplementation function-name (function)
  (cond ((eval:interpreted-function-p function)
         (eval:interpreted-function-name function))
        ((pcl::generic-function-p function)
         (pcl::generic-function-name function))
        ((c::byte-function-or-closure-p function)
         (c::byte-function-name function))
        (t (kernel:%function-name (kernel:%function-self function)))))

;;; A simple case: the arglist is available as a string that we can
;;; `read'.

(defun read-arglist (fn)
  "Parse the arglist-string of the function object FN."
  (let ((string (kernel:%function-arglist 
                 (kernel:%function-self fn)))
        (package (find-package
                  (c::compiled-debug-info-package
                   (kernel:%code-debug-info
                    (vm::find-code-object fn))))))
    (with-standard-io-syntax
      (let ((*package* (or package *package*)))
        (read-from-string string)))))

;;; A harder case: an approximate arglist is derived from available
;;; debugging information.

(defun debug-function-arglist (debug-function)
  "Derive the argument list of DEBUG-FUNCTION from debug info."
  (let ((args (di::debug-function-lambda-list debug-function))
        (required '())
        (optional '())
        (rest '())
        (key '()))
    ;; collect the names of debug-vars
    (dolist (arg args)
      (etypecase arg
        (di::debug-variable 
         (push (di::debug-variable-symbol arg) required))
        ((member :deleted)
         (push ':deleted required))
        (cons
         (ecase (car arg)
           (:keyword 
            (push (second arg) key))
           (:optional
            (push (debug-variable-symbol-or-deleted (second arg)) optional))
           (:rest 
            (push (debug-variable-symbol-or-deleted (second arg)) rest))))))
    ;; intersperse lambda keywords as needed
    (append (nreverse required)
            (if optional (cons '&optional (nreverse optional)))
            (if rest (cons '&rest (nreverse rest)))
            (if key (cons '&key (nreverse key))))))

(defun debug-variable-symbol-or-deleted (var)
  (etypecase var
    (di:debug-variable
     (di::debug-variable-symbol var))
    ((member :deleted)
     '#:deleted)))

(defun symbol-debug-function-arglist (fname)
  "Return FNAME's debug-function-arglist and %function-arglist.
A utility for debugging DEBUG-FUNCTION-ARGLIST."
  (let ((fn (fdefinition fname)))
    (values (debug-function-arglist (di::function-debug-function fn))
            (kernel:%function-arglist (kernel:%function-self fn)))))

;;; Deriving arglists for byte-compiled functions:
;;;
(defun byte-code-function-arglist (fn)
  ;; There doesn't seem to be much arglist information around for
  ;; byte-code functions.  Use the arg-count and return something like
  ;; (arg0 arg1 ...)
  (etypecase fn
    (c::simple-byte-function 
     (loop for i from 0 below (c::simple-byte-function-num-args fn)
           collect (make-arg-symbol i)))
    (c::hairy-byte-function 
     (hairy-byte-function-arglist fn))
    (c::byte-closure
     (byte-code-function-arglist (c::byte-closure-function fn)))))

(defun make-arg-symbol (i)
  (make-symbol (format nil "~A~D" (string 'arg) i)))

;;; A "hairy" byte-function is one that takes a variable number of
;;; arguments. `hairy-byte-function' is a type from the bytecode
;;; interpreter.
;;;
(defun hairy-byte-function-arglist (fn)
  (let ((counter -1))
    (flet ((next-arg () (make-arg-symbol (incf counter))))
      (with-struct (c::hairy-byte-function- min-args max-args rest-arg-p
                                            keywords-p keywords) fn
        (let ((arglist '())
              (optional (- max-args min-args)))
          ;; XXX isn't there a better way to write this?
          ;; (Looks fine to me. -luke)
          (dotimes (i min-args)
            (push (next-arg) arglist))
          (when (plusp optional)
            (push '&optional arglist)
            (dotimes (i optional)
              (push (next-arg) arglist)))
          (when rest-arg-p
            (push '&rest arglist)
            (push (next-arg) arglist))
          (when keywords-p
            (push '&key arglist)
            (loop for (key _ __) in keywords
                  do (push key arglist))
            (when (eq keywords-p :allow-others)
              (push '&allow-other-keys arglist)))
          (nreverse arglist))))))


;;;; Miscellaneous.

(defimplementation macroexpand-all (form)
  (walker:macroexpand-all form))

(defimplementation compiler-macroexpand-1 (form &optional env)
  (ext:compiler-macroexpand-1 form env))

(defimplementation compiler-macroexpand (form &optional env)
  (ext:compiler-macroexpand form env))

(defimplementation set-default-directory (directory)
  (setf (ext:default-directory) (namestring directory))
  ;; Setting *default-pathname-defaults* to an absolute directory
  ;; makes the behavior of MERGE-PATHNAMES a bit more intuitive.
  (setf *default-pathname-defaults* (pathname (ext:default-directory)))
  (default-directory))

(defimplementation default-directory ()
  (namestring (ext:default-directory)))

(defimplementation call-without-interrupts (fn)
  (sys:without-interrupts (funcall fn)))

(defimplementation getpid ()
  (unix:unix-getpid))

(defimplementation lisp-implementation-type-name ()
  "cmucl")

(defimplementation quit-lisp ()
  (ext::quit))

;;; source-path-{stream,file,string,etc}-position moved into 
;;; swank-source-path-parser


;;;; Debugging

(defvar *sldb-stack-top*)

(defimplementation call-with-debugging-environment (debugger-loop-fn)
  (unix:unix-sigsetmask 0)
  (let* ((*sldb-stack-top* (or debug:*stack-top-hint* (di:top-frame)))
	 (debug:*stack-top-hint* nil)
         (kernel:*current-level* 0))
    (handler-bind ((di::unhandled-condition
		    (lambda (condition)
                      (error (make-condition
                              'sldb-condition
                              :original-condition condition)))))
      (unwind-protect
           (progn
             #+(or)(sys:scrub-control-stack)
             (funcall debugger-loop-fn))
        #+(or)(sys:scrub-control-stack)
        ))))

(defun frame-down (frame)
  (handler-case (di:frame-down frame)
    (di:no-debug-info () nil)))

(defun nth-frame (index)
  (do ((frame *sldb-stack-top* (frame-down frame))
       (i index (1- i)))
      ((zerop i) frame)))

(defimplementation compute-backtrace (start end)
  (let ((end (or end most-positive-fixnum)))
    (loop for f = (nth-frame start) then (frame-down f)
	  for i from start below end
	  while f
	  collect f)))

(defimplementation print-frame (frame stream)
  (let ((*standard-output* stream))
    (handler-case 
        (debug::print-frame-call frame :verbosity 1 :number nil)
      (error (e)
        (ignore-errors (princ e stream))))))

(defimplementation frame-source-location-for-emacs (index)
  (code-location-source-location (di:frame-code-location (nth-frame index))))

(defimplementation eval-in-frame (form index)
  (di:eval-in-frame (nth-frame index) form))

(defun frame-debug-vars (frame)
  "Return a vector of debug-variables in frame."
  (di::debug-function-debug-variables (di:frame-debug-function frame)))

(defun debug-var-value (var frame location)
  (let ((validity (di:debug-variable-validity var location)))
    (ecase validity
      (:valid (di:debug-variable-value var frame))
      ((:invalid :unknown) (make-symbol (string validity))))))

(defimplementation frame-locals (index)
  (let* ((frame (nth-frame index))
	 (loc (di:frame-code-location frame))
	 (vars (frame-debug-vars frame)))
    (loop for v across vars collect
          (list :name (di:debug-variable-symbol v)
                :id (di:debug-variable-id v)
                :value (debug-var-value v frame loc)))))

(defimplementation frame-var-value (frame var)
  (let* ((frame (nth-frame frame))
         (dvar (aref (frame-debug-vars frame) var)))
    (debug-var-value dvar frame (di:frame-code-location frame))))

(defimplementation frame-catch-tags (index)
  (mapcar #'car (di:frame-catches (nth-frame index))))

(defimplementation return-from-frame (index form)
  (let ((sym (find-symbol (string 'find-debug-tag-for-frame)
                          :debug-internals)))
    (if sym
        (let* ((frame (nth-frame index))
               (probe (funcall sym frame)))
          (cond (probe (throw (car probe) (eval-in-frame form index)))
                (t (format nil "Cannot return from frame: ~S" frame))))
        "return-from-frame is not implemented in this version of CMUCL.")))

(defimplementation activate-stepping (frame)
  (set-step-breakpoints (nth-frame frame)))

(defimplementation sldb-break-on-return (frame)
  (break-on-return (nth-frame frame)))

;;; We set the breakpoint in the caller which might be a bit confusing.
;;;
(defun break-on-return (frame)
  (let* ((caller (di:frame-down frame))
         (cl (di:frame-code-location caller)))
    (flet ((hook (frame bp)
             (when (frame-pointer= frame caller)
               (di:delete-breakpoint bp)
               (signal-breakpoint bp frame))))
      (let* ((info (ecase (di:code-location-kind cl)
                     ((:single-value-return :unknown-return) nil)
                     (:known-return (debug-function-returns 
                                     (di:frame-debug-function frame)))))
             (bp (di:make-breakpoint #'hook cl :kind :code-location
                                     :info info)))
        (di:activate-breakpoint bp)
        `(:ok ,(format nil "Set breakpoint in ~A" caller))))))

(defun frame-pointer= (frame1 frame2)
  "Return true if the frame pointers of FRAME1 and FRAME2 are the same."
  (sys:sap= (di::frame-pointer frame1) (di::frame-pointer frame2)))

;;; The PC in escaped frames at a single-return-value point is
;;; actually vm:single-value-return-byte-offset bytes after the
;;; position given in the debug info.  Here we try to recognize such
;;; cases.
;;;
(defun next-code-locations (frame code-location)
  "Like `debug::next-code-locations' but be careful in escaped frames."
  (let ((next (debug::next-code-locations code-location)))
    (flet ((adjust-pc ()
             (let ((cl (di::copy-compiled-code-location code-location)))
               (incf (di::compiled-code-location-pc cl) 
                     vm:single-value-return-byte-offset)
               cl)))
      (cond ((and (di::compiled-frame-escaped frame)
                  (eq (di:code-location-kind code-location)
                      :single-value-return)
                  (= (length next) 1)
                  (di:code-location= (car next) (adjust-pc)))
             (debug::next-code-locations (car next)))
            (t
             next)))))

(defun set-step-breakpoints (frame)
  (let ((cl (di:frame-code-location frame)))
    (when (di:debug-block-elsewhere-p (di:code-location-debug-block cl))
      (error "Cannot step in elsewhere code"))
    (let* ((debug::*bad-code-location-types*
            (remove :call-site debug::*bad-code-location-types*))
           (next (next-code-locations frame cl)))
      (cond (next
             (let ((steppoints '()))
               (flet ((hook (bp-frame bp)
                        (signal-breakpoint bp bp-frame)
                        (mapc #'di:delete-breakpoint steppoints)))
                 (dolist (code-location next)
                   (let ((bp (di:make-breakpoint #'hook code-location
                                                 :kind :code-location)))
                     (di:activate-breakpoint bp)
                     (push bp steppoints))))))
            (t
             (break-on-return frame))))))


;; XXX the return values at return breakpoints should be passed to the
;; user hooks. debug-int.lisp should be changed to do this cleanly.

;;; The sigcontext and the PC for a breakpoint invocation are not
;;; passed to user hook functions, but we need them to extract return
;;; values. So we advice di::handle-breakpoint and bind the values to
;;; special variables.  
;;;
(defvar *breakpoint-sigcontext*)
(defvar *breakpoint-pc*)

;; XXX don't break old versions without fwrappers.  Remove this one day.
#+#.(cl:if (cl:find-package :fwrappers) '(and) '(or))
(progn
  (fwrappers:define-fwrapper bind-breakpoint-sigcontext (offset c sigcontext)
    (let ((*breakpoint-sigcontext* sigcontext)
          (*breakpoint-pc* offset))
      (fwrappers:call-next-function)))
  (fwrappers:set-fwrappers 'di::handle-breakpoint '())
  (fwrappers:fwrap 'di::handle-breakpoint #'bind-breakpoint-sigcontext))

(defun sigcontext-object (sc index)
  "Extract the lisp object in sigcontext SC at offset INDEX."
  (kernel:make-lisp-obj (vm:sigcontext-register sc index)))

(defun known-return-point-values (sigcontext sc-offsets)
  (let ((fp (system:int-sap (vm:sigcontext-register sigcontext
                                                    vm::cfp-offset))))
    (system:without-gcing
     (loop for sc-offset across sc-offsets
           collect (di::sub-access-debug-var-slot fp sc-offset sigcontext)))))

;;; CMUCL returns the first few values in registers and the rest on
;;; the stack. In the multiple value case, the number of values is
;;; stored in a dedicated register. The values of the registers can be
;;; accessed in the sigcontext for the breakpoint.  There are 3 kinds
;;; of return conventions: :single-value-return, :unknown-return, and
;;; :known-return.
;;;
;;; The :single-value-return convention returns the value in a
;;; register without setting the nargs registers.  
;;;
;;; The :unknown-return variant is used for multiple values. A
;;; :unknown-return point consists actually of 2 breakpoints: one for
;;; the single value case and one for the general case.  The single
;;; value breakpoint comes vm:single-value-return-byte-offset after
;;; the multiple value breakpoint.
;;;
;;; The :known-return convention is used by local functions.
;;; :known-return is currently not supported because we don't know
;;; where the values are passed.
;;;
(defun breakpoint-values (breakpoint)
  "Return the list of return values for a return point."
  (flet ((1st (sc) (sigcontext-object sc (car vm::register-arg-offsets))))
    (let ((sc (locally (declare (optimize (ext:inhibit-warnings 3)))
                (alien:sap-alien *breakpoint-sigcontext* (* unix:sigcontext))))
          (cl (di:breakpoint-what breakpoint)))
      (ecase (di:code-location-kind cl)
        (:single-value-return
         (list (1st sc)))
        (:known-return
         (let ((info (di:breakpoint-info breakpoint)))
           (if (vectorp info)
               (known-return-point-values sc info)
               (progn 
                 ;;(break)
                 (list "<<known-return convention not supported>>" info)))))
        (:unknown-return
         (let ((mv-return-pc (di::compiled-code-location-pc cl)))
           (if (= mv-return-pc *breakpoint-pc*)
               (mv-function-end-breakpoint-values sc)
               (list (1st sc)))))))))

;; XXX: di::get-function-end-breakpoint-values takes 2 arguments in
;; newer versions of CMUCL (after ~March 2005).
(defun mv-function-end-breakpoint-values (sigcontext)
  (let ((sym (find-symbol "FUNCTION-END-BREAKPOINT-VALUES/STANDARD" :di)))
    (cond (sym (funcall sym sigcontext))
          (t (di::get-function-end-breakpoint-values sigcontext)))))

(defun debug-function-returns (debug-fun)
  "Return the return style of DEBUG-FUN."
  (let* ((cdfun (di::compiled-debug-function-compiler-debug-fun debug-fun)))
    (c::compiled-debug-function-returns cdfun)))

(define-condition breakpoint (simple-condition) 
  ((message :initarg :message :reader breakpoint.message)
   (values  :initarg :values  :reader breakpoint.values))
  (:report (lambda (c stream) (princ (breakpoint.message c) stream))))

(defimplementation condition-extras (condition)
  (typecase condition
    (breakpoint 
     ;; pop up the source buffer
     `((:show-frame-source 0))) 
    (t '())))

(defun signal-breakpoint (breakpoint frame)
  "Signal a breakpoint condition for BREAKPOINT in FRAME.
Try to create a informative message."
  (flet ((brk (values fstring &rest args)
           (let ((msg (apply #'format nil fstring args))
                 (debug:*stack-top-hint* frame))
             (break 'breakpoint :message msg :values values))))
    (with-struct (di::breakpoint- kind what) breakpoint
      (case kind
        (:code-location
         (case (di:code-location-kind what)
           ((:single-value-return :known-return :unknown-return)
            (let ((values (breakpoint-values breakpoint)))
              (brk values "Return value: ~{~S ~}" values)))
           (t
            #+(or)
            (when (eq (di:code-location-kind what) :call-site)
              (call-site-function breakpoint frame))
            (brk nil "Breakpoint: ~S ~S" 
                 (di:code-location-kind what)
                 (di::compiled-code-location-pc what)))))
        (:function-start
         (brk nil "Function start breakpoint"))
        (t (brk nil "Breakpoint: ~A in ~A" breakpoint frame))))))

(defimplementation sldb-break-at-start (fname)
  (let ((debug-fun (di:function-debug-function (coerce fname 'function))))
    (cond ((not debug-fun)
           `(:error ,(format nil "~S has no debug-function" fname)))
          (t
           (flet ((hook (frame bp &optional args cookie)
                    (declare (ignore args cookie))
                    (signal-breakpoint bp frame)))
             (let ((bp (di:make-breakpoint #'hook debug-fun
                                           :kind :function-start)))
               (di:activate-breakpoint bp)
               `(:ok ,(format nil "Set breakpoint in ~S" fname))))))))

(defun frame-cfp (frame)
  "Return the Control-Stack-Frame-Pointer for FRAME."
  (etypecase frame
    (di::compiled-frame (di::frame-pointer frame))
    ((or di::interpreted-frame null) -1)))

(defun frame-ip (frame)
  "Return the (absolute) instruction pointer and the relative pc of FRAME."
  (if (not frame)
      -1
      (let ((debug-fun (di::frame-debug-function frame)))
        (etypecase debug-fun
          (di::compiled-debug-function 
           (let* ((code-loc (di:frame-code-location frame))
                  (component (di::compiled-debug-function-component debug-fun))
                  (pc (di::compiled-code-location-pc code-loc))
                  (ip (sys:without-gcing
                       (sys:sap-int
                        (sys:sap+ (kernel:code-instructions component) pc)))))
             (values ip pc)))
          ((or di::bogus-debug-function di::interpreted-debug-function)
           -1)))))

(defun frame-registers (frame)
  "Return the lisp registers CSP, CFP, IP, OCFP, LRA for FRAME-NUMBER."
  (let* ((cfp (frame-cfp frame))
         (csp (frame-cfp (di::frame-up frame)))
         (ip (frame-ip frame))
         (ocfp (frame-cfp (di::frame-down frame)))
         (lra (frame-ip (di::frame-down frame))))
    (values csp cfp ip ocfp lra)))

(defun print-frame-registers (frame-number)
  (let ((frame (di::frame-real-frame (nth-frame frame-number))))
    (flet ((fixnum (p) (etypecase p
                         (integer p)
                         (sys:system-area-pointer (sys:sap-int p)))))
      (apply #'format t "~
CSP  =  ~X
CFP  =  ~X
IP   =  ~X
OCFP =  ~X
LRA  =  ~X~%" (mapcar #'fixnum 
                      (multiple-value-list (frame-registers frame)))))))


(defimplementation disassemble-frame (frame-number)
  "Return a string with the disassembly of frames code."
  (print-frame-registers frame-number)
  (terpri)
  (let* ((frame (di::frame-real-frame (nth-frame frame-number)))
         (debug-fun (di::frame-debug-function frame)))
    (etypecase debug-fun
      (di::compiled-debug-function
       (let* ((component (di::compiled-debug-function-component debug-fun))
              (fun (di:debug-function-function debug-fun)))
         (if fun
             (disassemble fun)
             (disassem:disassemble-code-component component))))
      (di::bogus-debug-function
       (format t "~%[Disassembling bogus frames not implemented]")))))


;;;; Inspecting

(defconstant +lowtag-symbols+ 
  '(vm:even-fixnum-type
    vm:function-pointer-type
    vm:other-immediate-0-type
    vm:list-pointer-type
    vm:odd-fixnum-type
    vm:instance-pointer-type
    vm:other-immediate-1-type
    vm:other-pointer-type)
  "Names of the constants that specify type tags.
The `symbol-value' of each element is a type tag.")

(defconstant +header-type-symbols+
  (labels ((suffixp (suffix string)
             (and (>= (length string) (length suffix))
                  (string= string suffix :start1 (- (length string) 
                                                    (length suffix)))))
           (header-type-symbol-p (x)
             (and (suffixp "-TYPE" (symbol-name x))
                  (not (member x +lowtag-symbols+))
                  (boundp x)
                  (typep (symbol-value x) 'fixnum))))
    (remove-if-not #'header-type-symbol-p
                   (append (apropos-list "-TYPE" "VM")
                           (apropos-list "-TYPE" "BIGNUM"))))
  "A list of names of the type codes in boxed objects.")

(defimplementation describe-primitive-type (object)
  (with-output-to-string (*standard-output*)
    (let* ((lowtag (kernel:get-lowtag object))
	   (lowtag-symbol (find lowtag +lowtag-symbols+ :key #'symbol-value)))
      (format t "lowtag: ~A" lowtag-symbol)
      (when (member lowtag (list vm:other-pointer-type
                                 vm:function-pointer-type
                                 vm:other-immediate-0-type
                                 vm:other-immediate-1-type
                                 ))
        (let* ((type (kernel:get-type object))
               (type-symbol (find type +header-type-symbols+
                                  :key #'symbol-value)))
          (format t ", type: ~A" type-symbol))))))

(defmethod emacs-inspect ((o t))
  (cond ((di::indirect-value-cell-p o)
         `("Value: " (:value ,(c:value-cell-ref o))))
        ((alien::alien-value-p o)
         (inspect-alien-value o))
	(t
         (cmucl-inspect o))))

(defun cmucl-inspect (o)
  (destructuring-bind (text labeledp . parts) (inspect::describe-parts o)
    (list* (format nil "~A~%" text)
           (if labeledp
               (loop for (label . value) in parts
                     append (label-value-line label value))
               (loop for value in parts  for i from 0 
                     append (label-value-line i value))))))

(defmethod emacs-inspect ((o function))
  (let ((header (kernel:get-type o)))
    (cond ((= header vm:function-header-type)
           (append (label-value-line*
                    ("Self" (kernel:%function-self o))
                    ("Next" (kernel:%function-next o))
                    ("Name" (kernel:%function-name o))
                    ("Arglist" (kernel:%function-arglist o))
                    ("Type" (kernel:%function-type o))
                    ("Code" (kernel:function-code-header o)))
                   (list 
                    (with-output-to-string (s)
                      (disassem:disassemble-function o :stream s)))))
          ((= header vm:closure-header-type)
           (list* (format nil "~A is a closure.~%" o)
                  (append 
                   (label-value-line "Function" (kernel:%closure-function o))
                   `("Environment:" (:newline))
                   (loop for i from 0 below (1- (kernel:get-closure-length o))
                         append (label-value-line 
                                 i (kernel:%closure-index-ref o i))))))
          ((eval::interpreted-function-p o)
           (cmucl-inspect o))
          (t
           (call-next-method)))))

(defmethod emacs-inspect ((o kernel:funcallable-instance))
  (append (label-value-line* 
           (:function (kernel:%funcallable-instance-function o))
           (:lexenv  (kernel:%funcallable-instance-lexenv o))
           (:layout  (kernel:%funcallable-instance-layout o)))
          (cmucl-inspect o)))

(defmethod emacs-inspect ((o kernel:code-component))
  (append 
   (label-value-line* 
    ("code-size" (kernel:%code-code-size o))
    ("entry-points" (kernel:%code-entry-points o))
    ("debug-info" (kernel:%code-debug-info o))
    ("trace-table-offset" (kernel:code-header-ref 
                           o vm:code-trace-table-offset-slot)))
   `("Constants:" (:newline))
   (loop for i from vm:code-constants-offset 
         below (kernel:get-header-data o)
         append (label-value-line i (kernel:code-header-ref o i)))
   `("Code:" (:newline)
             , (with-output-to-string (s)
                 (cond ((kernel:%code-debug-info o)
                        (disassem:disassemble-code-component o :stream s))
                       (t
                        (disassem:disassemble-memory 
                         (disassem::align 
                          (+ (logandc2 (kernel:get-lisp-obj-address o)
                                       vm:lowtag-mask)
                             (* vm:code-constants-offset vm:word-bytes))
                          (ash 1 vm:lowtag-bits))
                         (ash (kernel:%code-code-size o) vm:word-shift)
                         :stream s)))))))

(defmethod emacs-inspect ((o kernel:fdefn))
  (label-value-line*
   ("name" (kernel:fdefn-name o))
   ("function" (kernel:fdefn-function o))
   ("raw-addr" (sys:sap-ref-32
                (sys:int-sap (kernel:get-lisp-obj-address o))
                (* vm:fdefn-raw-addr-slot vm:word-bytes)))))

#+(or)
(defmethod emacs-inspect ((o array))
  (if (typep o 'simple-array)
      (call-next-method)
      (label-value-line*
       (:header (describe-primitive-type o))
       (:rank (array-rank o))
       (:fill-pointer (kernel:%array-fill-pointer o))
       (:fill-pointer-p (kernel:%array-fill-pointer-p o))
       (:elements (kernel:%array-available-elements o))           
       (:data (kernel:%array-data-vector o))
       (:displacement (kernel:%array-displacement o))
       (:displaced-p (kernel:%array-displaced-p o))
       (:dimensions (array-dimensions o)))))

(defmethod emacs-inspect ((o simple-vector))
  (append 
   (label-value-line*
    (:header (describe-primitive-type o))
    (:length (c::vector-length o)))
   (loop for i below (length o)
         append (label-value-line i (aref o i)))))

(defun inspect-alien-record (alien)
  (with-struct (alien::alien-value- sap type) alien
    (with-struct (alien::alien-record-type- kind name fields) type
      (append
       (label-value-line*
        (:sap sap)
        (:kind kind)
        (:name name))
       (loop for field in fields 
             append (let ((slot (alien::alien-record-field-name field)))
                      (label-value-line slot (alien:slot alien slot))))))))

(defun inspect-alien-pointer (alien)
  (with-struct (alien::alien-value- sap type) alien
    (label-value-line* 
     (:sap sap)
     (:type type)
     (:to (alien::deref alien)))))
  
(defun inspect-alien-value (alien)
  (typecase (alien::alien-value-type alien)
    (alien::alien-record-type (inspect-alien-record alien))
    (alien::alien-pointer-type (inspect-alien-pointer alien))
    (t (cmucl-inspect alien))))

;;;; Profiling
(defimplementation profile (fname)
  (eval `(profile:profile ,fname)))

(defimplementation unprofile (fname)
  (eval `(profile:unprofile ,fname)))

(defimplementation unprofile-all ()
  (eval `(profile:unprofile))
  "All functions unprofiled.")

(defimplementation profile-report ()
  (eval `(profile:report-time)))

(defimplementation profile-reset ()
  (eval `(profile:reset-time))
  "Reset profiling counters.")

(defimplementation profiled-functions ()
  profile:*timed-functions*)

(defimplementation profile-package (package callers methods)
  (profile:profile-all :package package
                       :callers-p callers
                       #-cmu18e :methods #-cmu18e methods))


;;;; Multiprocessing

#+mp
(progn
  (defimplementation initialize-multiprocessing (continuation) 
    (mp::init-multi-processing)
    (mp:make-process continuation :name "swank")
    ;; Threads magic: this never returns! But top-level becomes
    ;; available again.
    (unless mp::*idle-process*
      (mp::startup-idle-and-top-level-loops)))
  
  (defimplementation spawn (fn &key name)
    (mp:make-process fn :name (or name "Anonymous")))

  (defvar *thread-id-counter* 0)

  (defimplementation thread-id (thread)
    (or (getf (mp:process-property-list thread) 'id)
        (setf (getf (mp:process-property-list thread) 'id)
              (incf *thread-id-counter*))))

  (defimplementation find-thread (id)
    (find id (all-threads)
          :key (lambda (p) (getf (mp:process-property-list p) 'id))))

  (defimplementation thread-name (thread)
    (mp:process-name thread))

  (defimplementation thread-status (thread)
    (mp:process-whostate thread))

  (defimplementation current-thread ()
    mp:*current-process*)

  (defimplementation all-threads ()
    (copy-list mp:*all-processes*))

  (defimplementation interrupt-thread (thread fn)
    (mp:process-interrupt thread fn))

  (defimplementation kill-thread (thread)
    (mp:destroy-process thread))

  (defvar *mailbox-lock* (mp:make-lock "mailbox lock"))
  
  (defstruct (mailbox (:conc-name mailbox.)) 
    (mutex (mp:make-lock "process mailbox"))
    (queue '() :type list))

  (defun mailbox (thread)
    "Return THREAD's mailbox."
    (mp:with-lock-held (*mailbox-lock*)
      (or (getf (mp:process-property-list thread) 'mailbox)
          (setf (getf (mp:process-property-list thread) 'mailbox)
                (make-mailbox)))))
  
  (defimplementation send (thread message)
    (check-slime-interrupts)
    (let* ((mbox (mailbox thread)))
      (mp:with-lock-held ((mailbox.mutex mbox))
        (setf (mailbox.queue mbox)
              (nconc (mailbox.queue mbox) (list message))))))

  (defimplementation receive-if (test &optional timeout)
    (let ((mbox (mailbox mp:*current-process*)))
      (assert (or (not timeout) (eq timeout t)))
      (loop
       (check-slime-interrupts)
       (mp:with-lock-held ((mailbox.mutex mbox))
         (let* ((q (mailbox.queue mbox))
                (tail (member-if test q)))
           (when tail
             (setf (mailbox.queue mbox) 
                   (nconc (ldiff q tail) (cdr tail)))
             (return (car tail)))))
       (when (eq timeout t) (return (values nil t)))
       (mp:process-wait-with-timeout 
        "receive-if" 0.5 (lambda () (some test (mailbox.queue mbox)))))))
                   

  ) ;; #+mp



;;;; GC hooks 
;;;
;;; Display GC messages in the echo area to avoid cluttering the
;;; normal output.
;;;

;; this should probably not be here, but where else?
(defun background-message (message)
  (funcall (find-symbol (string :background-message) :swank)
           message))

(defun print-bytes (nbytes &optional stream)
  "Print the number NBYTES to STREAM in KB, MB, or GB units."
  (let ((names '((0 bytes) (10 kb) (20 mb) (30 gb) (40 tb) (50 eb))))
    (multiple-value-bind (power name)
	(loop for ((p1 n1) (p2 n2)) on names
	      while n2 do
	      (when (<= (expt 2 p1) nbytes (1- (expt 2 p2)))
		(return (values p1 n1))))
      (cond (name
	     (format stream "~,1F ~A" (/ nbytes (expt 2 power)) name))
	    (t
	     (format stream "~:D bytes" nbytes))))))

(defconstant gc-generations 6)

#+gencgc
(defun generation-stats ()
  "Return a string describing the size distribution among the generations."
  (let* ((alloc (loop for i below gc-generations
                      collect (lisp::gencgc-stats i)))
         (sum (coerce (reduce #'+ alloc) 'float)))
    (format nil "~{~3F~^/~}" 
            (mapcar (lambda (size) (/ size sum))
                    alloc))))

(defvar *gc-start-time* 0)

(defun pre-gc-hook (bytes-in-use)
  (setq *gc-start-time* (get-internal-real-time))
  (let ((msg (format nil "[Commencing GC with ~A in use.]" 
		     (print-bytes bytes-in-use))))
    (background-message msg)))

(defun post-gc-hook (bytes-retained bytes-freed trigger)
  (declare (ignore trigger))
  (let* ((seconds (/ (- (get-internal-real-time) *gc-start-time*)
                     internal-time-units-per-second))
         (msg (format nil "[GC done. ~A freed  ~A retained  ~A  ~4F sec]"
		     (print-bytes bytes-freed)
		     (print-bytes bytes-retained)
                     #+gencgc(generation-stats)
                     #-gencgc""
                     seconds)))
    (background-message msg)))

(defun install-gc-hooks ()
  (setq ext:*gc-notify-before* #'pre-gc-hook)
  (setq ext:*gc-notify-after* #'post-gc-hook))

(defun remove-gc-hooks ()
  (setq ext:*gc-notify-before* #'lisp::default-gc-notify-before)
  (setq ext:*gc-notify-after* #'lisp::default-gc-notify-after))

(defvar *install-gc-hooks* t
  "If non-nil install GC hooks")

(defimplementation emacs-connected ()
  (when *install-gc-hooks*
    (install-gc-hooks)))

;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;;Trace implementations
;;In CMUCL, we have:
;; (trace <name>)
;; (trace (method <name> <qualifier>? (<specializer>+)))
;; (trace :methods t '<name>) ;;to trace all methods of the gf <name>
;; <name> can be a normal name or a (setf name)

(defun tracedp (spec)
  (member spec (eval '(trace)) :test #'equal))

(defun toggle-trace-aux (spec &rest options)
  (cond ((tracedp spec)
         (eval `(untrace ,spec))
         (format nil "~S is now untraced." spec))
        (t
         (eval `(trace ,spec ,@options))
         (format nil "~S is now traced." spec))))

(defimplementation toggle-trace (spec)
  (ecase (car spec)
    ((setf)
     (toggle-trace-aux spec))
    ((:defgeneric)
     (let ((name (second spec)))
       (toggle-trace-aux name :methods name)))
    ((:defmethod)
     (cond ((fboundp `(method ,@(cdr spec)))
            (toggle-trace-aux `(method ,(cdr spec))))
           ;; Man, is this ugly
           ((fboundp `(pcl::fast-method ,@(cdr spec)))
            (toggle-trace-aux `(pcl::fast-method ,@(cdr spec))))
           (t
            (error 'undefined-function :name (cdr spec)))))
    ((:call)
     (destructuring-bind (caller callee) (cdr spec)
       (toggle-trace-aux (process-fspec callee) 
                         :wherein (list (process-fspec caller)))))
    ;; doesn't work properly
    ;; ((:labels :flet) (toggle-trace-aux (process-fspec spec)))
    ))

(defun process-fspec (fspec)
  (cond ((consp fspec)
         (ecase (first fspec)
           ((:defun :defgeneric) (second fspec))
           ((:defmethod) 
            `(method ,(second fspec) ,@(third fspec) ,(fourth fspec)))
           ((:labels) `(labels ,(third fspec) ,(process-fspec (second fspec))))
           ((:flet) `(flet ,(third fspec) ,(process-fspec (second fspec))))))
        (t
         fspec)))

;;; Weak datastructures

(defimplementation make-weak-key-hash-table (&rest args)
  (apply #'make-hash-table :weak-p t args))


;;; Save image

(defimplementation save-image (filename &optional restart-function)
  (multiple-value-bind (pid error) (unix:unix-fork)
    (when (not pid) (error "fork: ~A" (unix:get-unix-error-msg error)))
    (cond ((= pid 0)
           (let ((args `(,filename 
                         ,@(if restart-function
                               `((:init-function ,restart-function))))))
             (apply #'ext:save-lisp args)))
          (t 
           (let ((status (waitpid pid)))
             (destructuring-bind (&key exited? status &allow-other-keys) status
               (assert (and exited? (equal status 0)) ()
                       "Invalid exit status: ~a" status)))))))

(defun waitpid (pid)
  (alien:with-alien ((status c-call:int))
    (let ((code (alien:alien-funcall 
                 (alien:extern-alien 
                  waitpid (alien:function c-call:int c-call:int
                                          (* c-call:int) c-call:int))
                 pid (alien:addr status) 0)))
      (cond ((= code -1) (error "waitpid: ~A" (unix:get-unix-error-msg)))
            (t (assert (= code pid))
               (decode-wait-status status))))))

(defun decode-wait-status (status)
  (let ((output (with-output-to-string (s)
                  (call-program (list (process-status-program)
                                      (format nil "~d" status))
                                :output s))))
    (read-from-string output)))

(defun call-program (args &key output)
  (destructuring-bind (program &rest args) args
    (let ((process (ext:run-program program args :output output)))
      (when (not program) (error "fork failed"))
      (unless (and (eq (ext:process-status process) :exited)
                   (= (ext:process-exit-code process) 0))
        (error "Non-zero exit status")))))

(defvar *process-status-program* nil)
    
(defun process-status-program ()
  (or *process-status-program*
      (setq *process-status-program*
            (compile-process-status-program))))

(defun compile-process-status-program ()
  (let ((infile (system::pick-temporary-file-name
                 "/tmp/process-status~d~c.c")))
    (with-open-file (stream infile :direction :output :if-exists :supersede)
      (format stream "
#include <stdio.h>
#include <stdlib.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <assert.h>

#define FLAG(value) (value ? \"t\" : \"nil\")

int main (int argc, char** argv) {
  assert (argc == 2);
  { 
    char* endptr = NULL;
    char* arg = argv[1];
    long int status = strtol (arg, &endptr, 10);
    assert (endptr != arg && *endptr == '\\0');
    printf (\"(:exited? %s :status %d :signal? %s :signal %d :coredump? %s\"
	    \" :stopped? %s :stopsig %d)\\n\",
	    FLAG(WIFEXITED(status)), WEXITSTATUS(status),
	    FLAG(WIFSIGNALED(status)), WTERMSIG(status),
	    FLAG(WCOREDUMP(status)),
	    FLAG(WIFSTOPPED(status)), WSTOPSIG(status));
    fflush (NULL);
    return 0;
  }
}
")
      (finish-output stream))
    (let* ((outfile (system::pick-temporary-file-name))
           (args (list "cc" "-o" outfile infile)))
      (warn "Running cc: ~{~a ~}~%" args)
      (call-program args :output t)
      (delete-file infile)
      outfile)))

;; (save-image "/tmp/x.core")

;; Local Variables:
;; pbook-heading-regexp:    "^;;;\\(;+\\)"
;; pbook-commentary-regexp: "^;;;\\($\\|[^;]\\)"
;; End:
