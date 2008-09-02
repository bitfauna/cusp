;;;; -*- Mode: lisp; indent-tabs-mode: nil -*-
;;;
;;; features.lisp --- CFFI-specific features.
;;;
;;; Copyright (C) 2006-2007, Luis Oliveira  <loliveira@common-lisp.net>
;;;
;;; Permission is hereby granted, free of charge, to any person
;;; obtaining a copy of this software and associated documentation
;;; files (the "Software"), to deal in the Software without
;;; restriction, including without limitation the rights to use, copy,
;;; modify, merge, publish, distribute, sublicense, and/or sell copies
;;; of the Software, and to permit persons to whom the Software is
;;; furnished to do so, subject to the following conditions:
;;;
;;; The above copyright notice and this permission notice shall be
;;; included in all copies or substantial portions of the Software.
;;;
;;; THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
;;; EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
;;; MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
;;; NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
;;; HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
;;; WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
;;; OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
;;; DEALINGS IN THE SOFTWARE.
;;;

(in-package #:cl-user)

(eval-when (:compile-toplevel :load-toplevel :execute)
  (pushnew :cffi *features*))

;;; CFFI-SYS backends take care of pushing the appropriate features to
;;; *features*.  See each cffi-*.lisp file.

(defpackage #:cffi-features
  (:use #:cl)
  (:export
   #:cffi-feature-p

   ;; Features related to the CFFI-SYS backend.  Why no-*?  This
   ;; reflects the hope that these symbols will go away completely
   ;; meaning that at some point all lisps will support long-longs,
   ;; the foreign-funcall primitive, etc...
   #:no-long-long
   #:no-foreign-funcall
   #:no-stdcall
   #:flat-namespace

   ;; Only SCL supports long-double...
   ;;#:no-long-double

   ;; Features related to the operating system.
   ;; More should be added.
   #:darwin
   #:unix
   #:windows

   ;; Features related to the processor.
   ;; More should be added.
   #:ppc32
   #:x86
   #:x86-64
   #:sparc
   #:sparc64
   #:hppa
   #:hppa64
   ))

(in-package #:cffi-features)

(defun cffi-feature-p (feature-expression)
  "Matches a FEATURE-EXPRESSION against those symbols in *FEATURES*
that belong to the CFFI-FEATURES package."
  (when (eql feature-expression t)
    (return-from cffi-feature-p t))
  (let ((features-package (find-package '#:cffi-features)))
    (flet ((cffi-feature-eq (name feature-symbol)
             (and (eq (symbol-package feature-symbol) features-package)
                  (string= name (symbol-name feature-symbol)))))
      (etypecase feature-expression
        (symbol
         (not (null (member (symbol-name feature-expression) *features*
                            :test #'cffi-feature-eq))))
        (cons
         (ecase (first feature-expression)
           (:and (every #'cffi-feature-p (rest feature-expression)))
           (:or  (some #'cffi-feature-p (rest feature-expression)))
           (:not (not (cffi-feature-p (cadr feature-expression))))))))))
