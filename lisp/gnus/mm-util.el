;;; mm-util.el --- Utility functions for Mule and low level things

;; Copyright (C) 1998-2016 Free Software Foundation, Inc.

;; Author: Lars Magne Ingebrigtsen <larsi@gnus.org>
;;	MORIOKA Tomohiko <morioka@jaist.ac.jp>
;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:

;;; Code:

(eval-when-compile (require 'cl))
(require 'mail-prsvr)
(require 'timer)

(defvar mm-mime-mule-charset-alist )
;; Note this is not presently used on Emacs >= 23, which is good,
;; since it means standalone message-mode (which requires mml and
;; hence mml-util) does not load gnus-util.
(autoload 'gnus-completing-read "gnus-util")

;; Emulate functions that are not available in every (X)Emacs version.
;; The name of a function is prefixed with mm-, like `mm-char-int' for
;; `char-int' that is a native XEmacs function, not available in Emacs.
;; Gnus programs all should use mm- functions, not the original ones.
(eval-and-compile
  (mapc
   (lambda (elem)
     (let ((nfunc (intern (format "mm-%s" (car elem)))))
       (if (fboundp (car elem))
	   (defalias nfunc (car elem))
	 (defalias nfunc (cdr elem)))))
   `(
     ;; string-as-multibyte often doesn't really do what you think it does.
     ;; Example:
     ;;    (aref (string-as-multibyte "\201") 0) -> 129 (aka ?\201)
     ;;    (aref (string-as-multibyte "\300") 0) -> 192 (aka ?\300)
     ;;    (aref (string-as-multibyte "\300\201") 0) -> 192 (aka ?\300)
     ;;    (aref (string-as-multibyte "\300\201") 1) -> 129 (aka ?\201)
     ;; but
     ;;    (aref (string-as-multibyte "\201\300") 0) -> 2240
     ;;    (aref (string-as-multibyte "\201\300") 1) -> <error>
     ;; Better use string-to-multibyte or encode-coding-string.
     ;; If you really need string-as-multibyte somewhere it's usually
     ;; because you're using the internal emacs-mule representation (maybe
     ;; because you're using string-as-unibyte somewhere), which is
     ;; generally a problem in itself.
     ;; Here is an approximate equivalence table to help think about it:
     ;; (string-as-multibyte s)   ~= (decode-coding-string s 'emacs-mule)
     ;; (string-to-multibyte s)   ~= (decode-coding-string s 'binary)
     ;; (string-make-multibyte s) ~= (decode-coding-string s locale-coding-system)
     ;; `string-as-multibyte' is an Emacs function, not available in XEmacs.
     (string-as-multibyte . identity))))

(defun mm-ucs-to-char (codepoint)
  "Convert Unicode codepoint to character."
  (or (decode-char 'ucs codepoint) ?#))

(defvar mm-coding-system-list nil)
(defun mm-get-coding-system-list ()
  "Get the coding system list."
  (or mm-coding-system-list
      (setq mm-coding-system-list (coding-system-list))))

(defun mm-coding-system-p (cs)
  "Return CS if CS is a coding system."
  (and (coding-system-p cs)
       cs))

(defvar mm-charset-synonym-alist
  `(
    ;; Not in XEmacs, but it's not a proper MIME charset anyhow.
    ,@(unless (mm-coding-system-p 'x-ctext)
	'((x-ctext . ctext)))
    ;; ISO-8859-15 is very similar to ISO-8859-1.  But it's _different_ in 8
    ;; positions!
    ,@(unless (mm-coding-system-p 'iso-8859-15)
	'((iso-8859-15 . iso-8859-1)))
    ;; BIG-5HKSCS is similar to, but different than, BIG-5.
    ,@(unless (mm-coding-system-p 'big5-hkscs)
	'((big5-hkscs . big5)))
    ;; A Microsoft misunderstanding.
    ,@(when (and (not (mm-coding-system-p 'unicode))
		 (mm-coding-system-p 'utf-16-le))
	'((unicode . utf-16-le)))
    ;; A Microsoft misunderstanding.
    ,@(unless (mm-coding-system-p 'ks_c_5601-1987)
	(if (mm-coding-system-p 'cp949)
	    '((ks_c_5601-1987 . cp949))
	  '((ks_c_5601-1987 . euc-kr))))
    ;; Windows-31J is Windows Codepage 932.
    ,@(when (and (not (mm-coding-system-p 'windows-31j))
		 (mm-coding-system-p 'cp932))
	'((windows-31j . cp932)))
    ;; Charset name: GBK, Charset aliases: CP936, MS936, windows-936
    ;; http://www.iana.org/assignments/charset-reg/GBK
    ;; Emacs 22.1 has cp936, but not gbk, so we alias it:
    ,@(when (and (not (mm-coding-system-p 'gbk))
		 (mm-coding-system-p 'cp936))
	'((gbk . cp936)))
    ;; UTF8 is a bogus name for UTF-8
    ,@(when (and (not (mm-coding-system-p 'utf8))
		 (mm-coding-system-p 'utf-8))
	'((utf8 . utf-8)))
    ;; ISO8859-1 is a bogus name for ISO-8859-1
    ,@(when (and (not (mm-coding-system-p 'iso8859-1))
		 (mm-coding-system-p 'iso-8859-1))
	'((iso8859-1 . iso-8859-1)))
    ;; ISO_8859-1 is a bogus name for ISO-8859-1
    ,@(when (and (not (mm-coding-system-p 'iso_8859-1))
		 (mm-coding-system-p 'iso-8859-1))
	'((iso_8859-1 . iso-8859-1)))
    )
  "A mapping from unknown or invalid charset names to the real charset names.

See `mm-codepage-iso-8859-list' and `mm-codepage-ibm-list'.")

(defun mm-codepage-setup (number &optional alias)
  "Create a coding system cpNUMBER.
The coding system is created using `codepage-setup'.  If ALIAS is
non-nil, an alias is created and added to
`mm-charset-synonym-alist'.  If ALIAS is a string, it's used as
the alias.  Else windows-NUMBER is used."
  (interactive
   (let ((completion-ignore-case t)
	 (candidates (if (fboundp 'cp-supported-codepages)
			 (cp-supported-codepages)
		       ;; Removed in Emacs 23 (unicode), so signal an error:
		       (error "`codepage-setup' not present in this Emacs version"))))
     (list (gnus-completing-read "Setup DOS Codepage" candidates
                                 t nil nil "437"))))
  (when alias
    (setq alias (if (stringp alias)
		    (intern alias)
		  (intern (format "windows-%s" number)))))
  (let* ((cp (intern (format "cp%s" number))))
    (unless (mm-coding-system-p cp)
      (if (fboundp 'codepage-setup)	; silence compiler
	  (codepage-setup number)
	(error "`codepage-setup' not present in this Emacs version")))
    (when (and alias
	       ;; Don't add alias if setup of cp failed.
	       (mm-coding-system-p cp))
      (add-to-list 'mm-charset-synonym-alist (cons alias cp)))))

(defcustom mm-codepage-iso-8859-list
  (list 1250 ;; Windows-1250 is a variant of Latin-2 heavily used by Microsoft
	;; Outlook users in Czech republic.  Use this to allow reading of
	;; their e-mails.
	'(1252 . 1) ;; Windows-1252 is a superset of iso-8859-1 (West
	            ;; Europe).  See also `gnus-article-dumbquotes-map'.
	'(1254 . 9) ;; Windows-1254 is a superset of iso-8859-9 (Turkish).
	'(1255 . 8));; Windows-1255 is a superset of iso-8859-8 (Hebrew).
  "A list of Windows codepage numbers and iso-8859 charset numbers.

If an element is a number corresponding to a supported windows
codepage, appropriate entries to `mm-charset-synonym-alist' are
added by `mm-setup-codepage-iso-8859'.  An element may also be a
cons cell where the car is a codepage number and the cdr is the
corresponding number of an iso-8859 charset."
  :type '(list (set :inline t
		    (const 1250 :tag "Central and East European")
		    (const (1252 . 1) :tag "West European")
		    (const (1254 . 9) :tag "Turkish")
		    (const (1255 . 8) :tag "Hebrew"))
	       (repeat :inline t
		       :tag "Other options"
		       (choice
			(integer :tag "Windows codepage number")
			(cons (integer :tag "Windows codepage number")
			      (integer :tag "iso-8859 charset  number")))))
  :version "22.1" ;; Gnus 5.10.9
  :group 'mime)

(defcustom mm-codepage-ibm-list
  (list 437 ;; (US etc.)
	860 ;; (Portugal)
	861 ;; (Iceland)
	862 ;; (Israel)
	863 ;; (Canadian French)
	865 ;; (Nordic)
	852 ;;
	850 ;; (Latin 1)
	855 ;; (Cyrillic)
	866 ;; (Cyrillic - Russian)
	857 ;; (Turkish)
	864 ;; (Arabic)
	869 ;; (Greek)
	874);; (Thai)
  ;; In Emacs 23 (unicode), cp... and ibm... are aliases.
  ;; Cf. http://thread.gmane.org/v9lkng5nwy.fsf@marauder.physik.uni-ulm.de
  "List of IBM codepage numbers.

The codepage mappings slightly differ between IBM and other vendors.
See \"ftp://ftp.unicode.org/Public/MAPPINGS/VENDORS/IBM/README.TXT\".

If an element is a number corresponding to a supported windows
codepage, appropriate entries to `mm-charset-synonym-alist' are
added by `mm-setup-codepage-ibm'."
  :type '(list (set :inline t
		    (const 437 :tag "US etc.")
		    (const 860 :tag "Portugal")
		    (const 861 :tag "Iceland")
		    (const 862 :tag "Israel")
		    (const 863 :tag "Canadian French")
		    (const 865 :tag "Nordic")
		    (const 852)
		    (const 850 :tag "Latin 1")
		    (const 855 :tag "Cyrillic")
		    (const 866 :tag "Cyrillic - Russian")
		    (const 857 :tag "Turkish")
		    (const 864 :tag "Arabic")
		    (const 869 :tag "Greek")
		    (const 874 :tag "Thai"))
	       (repeat :inline t
		       :tag "Other options"
		       (integer :tag "Codepage number")))
  :version "22.1" ;; Gnus 5.10.9
  :group 'mime)

(defun mm-setup-codepage-iso-8859 (&optional list)
  "Add appropriate entries to `mm-charset-synonym-alist'.
Unless LIST is given, `mm-codepage-iso-8859-list' is used."
  (unless list
    (setq list mm-codepage-iso-8859-list))
  (dolist (i list)
    (let (cp windows iso)
      (if (consp i)
	  (setq cp (intern (format "cp%d" (car i)))
		windows (intern (format "windows-%d" (car i)))
		iso (intern (format "iso-8859-%d" (cdr i))))
	(setq cp (intern (format "cp%d" i))
	      windows (intern (format "windows-%d" i))))
      (unless (mm-coding-system-p windows)
	(if (mm-coding-system-p cp)
	    (add-to-list 'mm-charset-synonym-alist (cons windows cp))
	  (add-to-list 'mm-charset-synonym-alist (cons windows iso)))))))

(defun mm-setup-codepage-ibm (&optional list)
  "Add appropriate entries to `mm-charset-synonym-alist'.
Unless LIST is given, `mm-codepage-ibm-list' is used."
  (unless list
    (setq list mm-codepage-ibm-list))
  (dolist (number list)
    (let ((ibm (intern (format "ibm%d" number)))
	  (cp  (intern (format "cp%d" number))))
      (when (and (not (mm-coding-system-p ibm))
		 (mm-coding-system-p cp))
	(add-to-list 'mm-charset-synonym-alist (cons ibm cp))))))

;; Initialize:
(mm-setup-codepage-iso-8859)
(mm-setup-codepage-ibm)

;; Note: this has to be defined before `mm-charset-to-coding-system'.
(defcustom mm-charset-eval-alist
  '(
    ;; Emacs 22 provides autoloads for 1250-1258
    ;; (i.e. `mm-codepage-setup' does nothing).
    (windows-1250 . (mm-codepage-setup 1250 t))
    (windows-1251 . (mm-codepage-setup 1251 t))
    (windows-1253 . (mm-codepage-setup 1253 t))
    (windows-1257 . (mm-codepage-setup 1257 t)))
  "An alist of (CHARSET . FORM) pairs.
If an article is encoded in an unknown CHARSET, FORM is
evaluated.  This allows the loading of additional libraries
providing charsets on demand.  If supported by your Emacs
version, you could use `autoload-coding-system' here."
  :version "22.1" ;; Gnus 5.10.9
  :type '(list (set :inline t
		    (const (windows-1250 . (mm-codepage-setup 1250 t)))
		    (const (windows-1251 . (mm-codepage-setup 1251 t)))
		    (const (windows-1253 . (mm-codepage-setup 1253 t)))
		    (const (windows-1257 . (mm-codepage-setup 1257 t)))
		    (const (cp850 . (mm-codepage-setup 850 nil))))
	       (repeat :inline t
		       :tag "Other options"
		       (cons (symbol :tag "charset")
			     (symbol :tag "form"))))
  :group 'mime)
(put 'mm-charset-eval-alist 'risky-local-variable t)

(defvar mm-charset-override-alist)

;; Note: this function has to be defined before `mm-charset-override-alist'
;; since it will use this function in order to determine its default value
;; when loading mm-util.elc.
(defun mm-charset-to-coding-system (charset &optional lbt
					    allow-override silent)
  "Return coding-system corresponding to CHARSET.
CHARSET is a symbol naming a MIME charset.
If optional argument LBT (`unix', `dos' or `mac') is specified, it is
used as the line break code type of the coding system.

If ALLOW-OVERRIDE is given, use `mm-charset-override-alist' to
map undesired charset names to their replacement.  This should
only be used for decoding, not for encoding.

A non-nil value of SILENT means don't issue a warning even if CHARSET
is not available."
  ;; OVERRIDE is used (only) in `mm-decode-body' and `mm-decode-string'.
  (when (stringp charset)
    (setq charset (intern (downcase charset))))
  (when lbt
    (setq charset (intern (format "%s-%s" charset lbt))))
  (cond
   ((null charset)
    charset)
   ;; Running in a non-MULE environment.
   ((or (null (mm-get-coding-system-list))
	(not (fboundp 'coding-system-get)))
    charset)
   ;; Check override list quite early.  Should only used for decoding, not for
   ;; encoding!
   ((and allow-override
	 (let ((cs (cdr (assq charset mm-charset-override-alist))))
	   (and cs (mm-coding-system-p cs) cs))))
   ;; ascii
   ((or (eq charset 'us-ascii)
	(string-match "ansi.x3.4" (symbol-name charset)))
    'ascii)
   ;; Check to see whether we can handle this charset.  (This depends
   ;; on there being some coding system matching each `mime-charset'
   ;; property defined, as there should be.)
   ((and (mm-coding-system-p charset)
;;; Doing this would potentially weed out incorrect charsets.
;;; 	 charset
;;; 	 (eq charset (coding-system-get charset 'mime-charset))
	 )
    charset)
   ;; Use coding system Emacs knows.
   ((and (fboundp 'coding-system-from-name)
	 (coding-system-from-name charset)))
   ;; Eval expressions from `mm-charset-eval-alist'
   ((let* ((el (assq charset mm-charset-eval-alist))
	   (cs (car el))
	   (form (cdr el)))
      (and cs
	   form
	   (prog2
	       ;; Avoid errors...
	       (condition-case nil (eval form) (error nil))
	       ;; (message "Failed to eval `%s'" form))
	       (mm-coding-system-p cs)
	     (message "Added charset `%s' via `mm-charset-eval-alist'" cs))
	   cs)))
   ;; Translate invalid charsets.
   ((let ((cs (cdr (assq charset mm-charset-synonym-alist))))
      (and cs
	   (mm-coding-system-p cs)
	   ;; (message
	   ;;  "Using synonym `%s' from `mm-charset-synonym-alist' for `%s'"
	   ;;  cs charset)
	   cs)))
   ;; Last resort: search the coding system list for entries which
   ;; have the right mime-charset in case the canonical name isn't
   ;; defined (though it should be).
   ((let (cs)
      ;; mm-get-coding-system-list returns a list of cs without lbt.
      ;; Do we need -lbt?
      (dolist (c (mm-get-coding-system-list))
	(if (and (null cs)
		 (eq charset (or (coding-system-get c :mime-charset)
				 (coding-system-get c 'mime-charset))))
	    (setq cs c)))
      (unless (or silent cs)
	;; Warn the user about unknown charset:
	(if (fboundp 'gnus-message)
	    (gnus-message 7 "Unknown charset: %s" charset)
	  (message "Unknown charset: %s" charset)))
      cs))))

;; Note: `mm-charset-to-coding-system' has to be defined before this.
(defcustom mm-charset-override-alist
  ;; Note: pairs that cannot be used in the Emacs version currently running
  ;; will be removed.
  '((gb2312 . gbk)
    (iso-8859-1 . windows-1252)
    (iso-8859-8 . windows-1255)
    (iso-8859-9 . windows-1254))
  "A mapping from undesired charset names to their replacement.

You may add pairs like (iso-8859-1 . windows-1252) here,
i.e. treat iso-8859-1 as windows-1252.  windows-1252 is a
superset of iso-8859-1."
  :type
  '(list
    :convert-widget
    (lambda (widget)
      (let ((defaults
	      (delq nil
		    (mapcar (lambda (pair)
			      (if (mm-charset-to-coding-system (cdr pair)
							       nil nil t)
				  pair))
			    '((gb2312 . gbk)
			      (iso-8859-1 . windows-1252)
			      (iso-8859-8 . windows-1255)
			      (iso-8859-9 . windows-1254)
			      (undecided  . windows-1252)))))
	    (val (copy-sequence (default-value 'mm-charset-override-alist)))
	    pair rest)
	(while val
	  (push (if (and (prog1
			     (setq pair (assq (caar val) defaults))
			   (setq defaults (delq pair defaults)))
			 (equal (car val) pair))
		    `(const ,pair)
		  `(cons :format "%v"
			 (const :format "(%v" ,(caar val))
			 (symbol :size 3 :format " . %v)\n" ,(cdar val))))
		rest)
	  (setq val (cdr val)))
	(while defaults
	  (push `(const ,(pop defaults)) rest))
	(widget-convert
	 'list
	 `(set :inline t :format "%v" ,@(nreverse rest))
	 `(repeat :inline t :tag "Other options"
		  (cons :format "%v"
			(symbol :size 3 :format "(%v")
			(symbol :size 3 :format " . %v)\n")))))))
  ;; Remove pairs that cannot be used in the Emacs version currently
  ;; running.  Note that this section will be evaluated when loading
  ;; mm-util.elc.
  :set (lambda (symbol value)
	 (custom-set-default
	  symbol (delq nil
		       (mapcar (lambda (pair)
				 (if (mm-charset-to-coding-system (cdr pair)
								  nil nil t)
				     pair))
			       value))))
  :version "22.1" ;; Gnus 5.10.9
  :group 'mime)

(defvar mm-binary-coding-system
  (cond
   ((mm-coding-system-p 'binary) 'binary)
   ((mm-coding-system-p 'no-conversion) 'no-conversion)
   (t nil))
  "100% binary coding system.")

(defvar mm-text-coding-system
  (or (if (memq system-type '(windows-nt ms-dos))
	  (and (mm-coding-system-p 'raw-text-dos) 'raw-text-dos)
	(and (mm-coding-system-p 'raw-text) 'raw-text))
      mm-binary-coding-system)
  "Text-safe coding system (For removing ^M).")

(defvar mm-text-coding-system-for-write nil
  "Text coding system for write.")

(defvar mm-auto-save-coding-system
  (cond
   ((mm-coding-system-p 'utf-8-emacs)	; Mule 7
    (if (memq system-type '(windows-nt ms-dos))
	(if (mm-coding-system-p 'utf-8-emacs-dos)
	    'utf-8-emacs-dos mm-binary-coding-system)
      'utf-8-emacs))
   ((mm-coding-system-p 'emacs-mule)
    (if (memq system-type '(windows-nt ms-dos))
	(if (mm-coding-system-p 'emacs-mule-dos)
	    'emacs-mule-dos mm-binary-coding-system)
      'emacs-mule))
   ((mm-coding-system-p 'escape-quoted) 'escape-quoted)
   (t mm-binary-coding-system))
  "Coding system of auto save file.")

(defvar mm-universal-coding-system mm-auto-save-coding-system
  "The universal coding system.")

;; Fixme: some of the cars here aren't valid MIME charsets.  That
;; should only matter with XEmacs, though.
(defvar mm-mime-mule-charset-alist
  `((us-ascii ascii)
    (iso-8859-1 latin-iso8859-1)
    (iso-8859-2 latin-iso8859-2)
    (iso-8859-3 latin-iso8859-3)
    (iso-8859-4 latin-iso8859-4)
    (iso-8859-5 cyrillic-iso8859-5)
    ;; Non-mule (X)Emacs uses the last mule-charset for 8bit characters.
    ;; The fake mule-charset, gnus-koi8-r, tells Gnus that the default
    ;; charset is koi8-r, not iso-8859-5.
    (koi8-r cyrillic-iso8859-5 gnus-koi8-r)
    (iso-8859-6 arabic-iso8859-6)
    (iso-8859-7 greek-iso8859-7)
    (iso-8859-8 hebrew-iso8859-8)
    (iso-8859-9 latin-iso8859-9)
    (iso-8859-14 latin-iso8859-14)
    (iso-8859-15 latin-iso8859-15)
    (viscii vietnamese-viscii-lower)
    (iso-2022-jp latin-jisx0201 japanese-jisx0208 japanese-jisx0208-1978)
    (euc-kr korean-ksc5601)
    (gb2312 chinese-gb2312)
    (gbk chinese-gbk)
    (gb18030 gb18030-2-byte
	     gb18030-4-byte-bmp gb18030-4-byte-smp
	     gb18030-4-byte-ext-1 gb18030-4-byte-ext-2)
    (big5 chinese-big5-1 chinese-big5-2)
    (tibetan tibetan)
    (thai-tis620 thai-tis620)
    (windows-1251 cyrillic-iso8859-5)
    (iso-2022-7bit ethiopic arabic-1-column arabic-2-column)
    (iso-2022-jp-2 latin-iso8859-1 greek-iso8859-7
		   latin-jisx0201 japanese-jisx0208-1978
		   chinese-gb2312 japanese-jisx0208
		   korean-ksc5601 japanese-jisx0212)
    (iso-2022-int-1 latin-iso8859-1 greek-iso8859-7
		    latin-jisx0201 japanese-jisx0208-1978
		    chinese-gb2312 japanese-jisx0208
		    korean-ksc5601 japanese-jisx0212
		    chinese-cns11643-1 chinese-cns11643-2)
    (iso-2022-int-1 latin-iso8859-1 latin-iso8859-2
		    cyrillic-iso8859-5 greek-iso8859-7
		    latin-jisx0201 japanese-jisx0208-1978
		    chinese-gb2312 japanese-jisx0208
		    korean-ksc5601 japanese-jisx0212
		    chinese-cns11643-1 chinese-cns11643-2
		    chinese-cns11643-3 chinese-cns11643-4
		    chinese-cns11643-5 chinese-cns11643-6
		    chinese-cns11643-7)
    (iso-2022-jp-3 latin-jisx0201 japanese-jisx0208-1978 japanese-jisx0208
		   japanese-jisx0213-1 japanese-jisx0213-2)
    (shift_jis latin-jisx0201 katakana-jisx0201 japanese-jisx0208)
    ,(cond ((fboundp 'unicode-precedence-list)
	    (cons 'utf-8 (delq 'ascii (mapcar 'charset-name
					      (unicode-precedence-list)))))
	   ((or (not (fboundp 'charsetp)) ;; non-Mule case
		(charsetp 'unicode-a)
		(not (mm-coding-system-p 'mule-utf-8)))
	    '(utf-8 unicode-a unicode-b unicode-c unicode-d unicode-e))
	   (t ;; If we have utf-8 we're in Mule 5+.
	    (append '(utf-8)
		    (delete 'ascii
			    (coding-system-get 'mule-utf-8 'safe-charsets))))))
  "Alist of MIME-charset/MULE-charsets.")

;; Correct by construction, but should be unnecessary for Emacs:
(when (and (fboundp 'coding-system-list)
	   (fboundp 'sort-coding-systems))
  (let ((css (sort-coding-systems (coding-system-list 'base-only)))
	cs mime mule alist)
    (while css
      (setq cs (pop css)
	    mime (or (coding-system-get cs :mime-charset) ; Emacs 23 (unicode)
		     (coding-system-get cs 'mime-charset)))
      (when (and mime
		 (not (eq t (setq mule
				  (coding-system-get cs 'safe-charsets))))
		 (not (assq mime alist)))
	(push (cons mime (delq 'ascii mule)) alist)))
    (setq mm-mime-mule-charset-alist (nreverse alist))))

(defvar mm-hack-charsets '(iso-8859-15 iso-2022-jp-2)
  "A list of special charsets.
Valid elements include:
`iso-8859-15'    convert ISO-8859-1, -9 to ISO-8859-15 if ISO-8859-15 exists.
`iso-2022-jp-2'  convert ISO-2022-jp to ISO-2022-jp-2 if ISO-2022-jp-2 exists."
)

(defvar mm-iso-8859-15-compatible
  '((iso-8859-1 "\xA4\xA6\xA8\xB4\xB8\xBC\xBD\xBE")
    (iso-8859-9 "\xA4\xA6\xA8\xB4\xB8\xBC\xBD\xBE\xD0\xDD\xDE\xF0\xFD\xFE"))
  "ISO-8859-15 exchangeable coding systems and inconvertible characters.")

(defvar mm-iso-8859-x-to-15-table
  (and (fboundp 'coding-system-p)
       (mm-coding-system-p 'iso-8859-15)
       (mapcar
	(lambda (cs)
	  (if (mm-coding-system-p (car cs))
	      (let ((c (string-to-char
			(decode-coding-string "\341" (car cs)))))
		(cons (char-charset c)
		      (cons
		       (- (string-to-char
			   (decode-coding-string "\341" 'iso-8859-15)) c)
		       (string-to-list (decode-coding-string (car (cdr cs))
							     (car cs))))))
	    '(gnus-charset 0)))
	mm-iso-8859-15-compatible))
  "A table of the difference character between ISO-8859-X and ISO-8859-15.")

(defcustom mm-coding-system-priorities
  (let ((lang (if (boundp 'current-language-environment)
		  (symbol-value 'current-language-environment))))
    (cond (;; XEmacs without Mule but with `file-coding'.
	   (not lang) nil)
	  ;; In XEmacs 21.5 it may be the one like "Japanese (UTF-8)".
	  ((string-match "\\`Japanese" lang)
	   ;; Japanese users prefer iso-2022-jp to others usually used
	   ;; for `buffer-file-coding-system', however iso-8859-1 should
	   ;; be used when there are only ASCII and Latin-1 characters.
	   '(iso-8859-1 iso-2022-jp utf-8))))
  "Preferred coding systems for encoding outgoing messages.

More than one suitable coding system may be found for some text.
By default, the coding system with the highest priority is used
to encode outgoing messages (see `sort-coding-systems').  If this
variable is set, it overrides the default priority."
  :version "24.4"
  :type '(repeat (symbol :tag "Coding system"))
  :group 'mime)

;; ??
(defvar mm-use-find-coding-systems-region
  (fboundp 'find-coding-systems-region)
  "Use `find-coding-systems-region' to find proper coding systems.

Setting it to nil is useful on Emacsen supporting Unicode if sending
mail with multiple parts is preferred to sending a Unicode one.")

(defvar mm-extra-numeric-entities
  (mapcar
   (lambda (item)
     (cons (car item) (mm-ucs-to-char (cdr item))))
   '((#x80 . #x20AC) (#x82 . #x201A) (#x83 . #x0192) (#x84 . #x201E)
     (#x85 . #x2026) (#x86 . #x2020) (#x87 . #x2021) (#x88 . #x02C6)
     (#x89 . #x2030) (#x8A . #x0160) (#x8B . #x2039) (#x8C . #x0152)
     (#x8E . #x017D) (#x91 . #x2018) (#x92 . #x2019) (#x93 . #x201C)
     (#x94 . #x201D) (#x95 . #x2022) (#x96 . #x2013) (#x97 . #x2014)
     (#x98 . #x02DC) (#x99 . #x2122) (#x9A . #x0161) (#x9B . #x203A)
     (#x9C . #x0153) (#x9E . #x017E) (#x9F . #x0178)))
  "*Alist of extra numeric entities and characters other than ISO 10646.
This table is used for decoding extra numeric entities to characters,
like \"&#128;\" to the euro sign, mainly in html messages.")

;;; Internal variables:

;;; Functions:

(defun mm-mule-charset-to-mime-charset (charset)
  "Return the MIME charset corresponding to the given Mule CHARSET."
  (if (and (fboundp 'find-coding-systems-for-charsets)
	   (fboundp 'sort-coding-systems))
      (let ((css (sort (sort-coding-systems
			(find-coding-systems-for-charsets (list charset)))
		       'mm-sort-coding-systems-predicate))
	    cs mime)
	(while (and (not mime)
		    css)
	  (when (setq cs (pop css))
	    (setq mime (or (coding-system-get cs :mime-charset)
			   (coding-system-get cs 'mime-charset)))))
	mime)
    (let ((alist (mapcar (lambda (cs)
			   (assq cs mm-mime-mule-charset-alist))
			 (sort (mapcar 'car mm-mime-mule-charset-alist)
			       'mm-sort-coding-systems-predicate)))
	  out)
      (while alist
	(when (memq charset (cdar alist))
	  (setq out (caar alist)
		alist nil))
	(pop alist))
      out)))

(defun mm-enable-multibyte ()
  "Set the multibyte flag of the current buffer.
Only do this if the default value of `enable-multibyte-characters' is
non-nil."
  (set-buffer-multibyte 'to))

(defun mm-disable-multibyte ()
  "Unset the multibyte flag of in the current buffer."
  (set-buffer-multibyte nil))

(defun mm-preferred-coding-system (charset)
  ;; A typo in some Emacs versions.
  (or (get-charset-property charset 'preferred-coding-system)
      (get-charset-property charset 'prefered-coding-system)))

;; Mule charsets shouldn't be used.
(defsubst mm-guess-charset ()
  "Guess Mule charset from the language environment."
  (or
   mail-parse-mule-charset ;; cached mule-charset
   (progn
     (setq mail-parse-mule-charset
	   (and (boundp 'current-language-environment)
		(car (last
		      (assq 'charset
			    (assoc current-language-environment
				   language-info-alist))))))
     (if (or (not mail-parse-mule-charset)
	     (eq mail-parse-mule-charset 'ascii))
	 (setq mail-parse-mule-charset
	       (or (car (last (assq mail-parse-charset
				    mm-mime-mule-charset-alist)))
		   ;; default
		   'latin-iso8859-1)))
     mail-parse-mule-charset)))

(defun mm-charset-after (&optional pos)
  "Return charset of a character in current buffer at position POS.
If POS is nil, it defaults to the current point.
If POS is out of range, the value is nil.
If the charset is `composition', return the actual one."
  (let ((char (char-after pos)) charset)
    (if (< char 128)
	(setq charset 'ascii)
      ;; charset-after is fake in some Emacsen.
      (setq charset (and (fboundp 'char-charset) (char-charset char)))
      (if (eq charset 'composition)	; Mule 4
	  (let ((p (or pos (point))))
	    (cadr (find-charset-region p (1+ p))))
	(if (and charset (not (memq charset '(ascii eight-bit-control
						    eight-bit-graphic))))
	    charset
	  (mm-guess-charset))))))

(defun mm-mime-charset (charset)
  "Return the MIME charset corresponding to the given Mule CHARSET."
  (if (eq charset 'unknown)
      (error "The message contains non-printable characters, please use attachment"))
  (if (and (fboundp 'coding-system-get) (fboundp 'get-charset-property))
      (or
       (and (mm-preferred-coding-system charset)
	    (or (coding-system-get
		 (mm-preferred-coding-system charset) :mime-charset)
		(coding-system-get
		 (mm-preferred-coding-system charset) 'mime-charset)))
       (and (eq charset 'ascii)
	    'us-ascii)
       (mm-preferred-coding-system charset)
       (mm-mule-charset-to-mime-charset charset))
    ;; This is for XEmacs.
    (mm-mule-charset-to-mime-charset charset)))

;; Fixme:  This is used in places when it should be testing the
;; default multibyteness.
(defun mm-multibyte-p ()
  "Non-nil if multibyte is enabled in the current buffer."
  enable-multibyte-characters)

(defun mm-iso-8859-x-to-15-region (&optional b e)
  (if (fboundp 'char-charset)
      (let (charset item c inconvertible)
	(save-restriction
	  (if e (narrow-to-region b e))
	  (goto-char (point-min))
	  (skip-chars-forward "\0-\177")
	  (while (not (eobp))
	    (cond
	     ((not (setq item (assq (char-charset (setq c (char-after)))
				    mm-iso-8859-x-to-15-table)))
	      (forward-char))
	     ((memq c (cdr (cdr item)))
	      (setq inconvertible t)
	      (forward-char))
	     (t
	      (insert-before-markers (prog1 (+ c (car (cdr item)))
				       (delete-char 1)))))
	    (skip-chars-forward "\0-\177")))
	(not inconvertible))))

(defun mm-sort-coding-systems-predicate (a b)
  (let ((priorities
	 (mapcar (lambda (cs)
		   ;; Note: invalid entries are dropped silently
		   (and (setq cs (mm-coding-system-p cs))
			(coding-system-base cs)))
		 mm-coding-system-priorities)))
    (and (setq a (mm-coding-system-p a))
	 (if (setq b (mm-coding-system-p b))
	     (> (length (memq (coding-system-base a) priorities))
		(length (memq (coding-system-base b) priorities)))
	   t))))

(defun mm-find-mime-charset-region (b e &optional hack-charsets)
  "Return the MIME charsets needed to encode the region between B and E.
nil means ASCII, a single-element list represents an appropriate MIME
charset, and a longer list means no appropriate charset."
  (let (charsets)
    ;; The return possibilities of this function are a mess...
    (or (and (mm-multibyte-p)
	     mm-use-find-coding-systems-region
	     ;; Find the mime-charset of the most preferred coding
	     ;; system that has one.
	     (let ((systems (find-coding-systems-region b e)))
	       (when mm-coding-system-priorities
		 (setq systems
		       (sort systems 'mm-sort-coding-systems-predicate)))
	       (setq systems (delq 'compound-text systems))
	       (unless (equal systems '(undecided))
		 (while systems
		   (let* ((head (pop systems))
			  (cs (or (coding-system-get head :mime-charset)
				  (coding-system-get head 'mime-charset))))
		     ;; The mime-charset (`x-ctext') of
		     ;; `compound-text' is not in the IANA list.  We
		     ;; shouldn't normally use anything here with a
		     ;; mime-charset having an `x-' prefix.
		     ;; Fixme:  Allow this to be overridden, since
		     ;; there is existing use of x-ctext.
		     ;; Also people apparently need the coding system
		     ;; `iso-2022-jp-3' (which Mule-UCS defines with
		     ;; mime-charset, though it's not valid).
		     (if (and cs
			      (not (string-match "^[Xx]-" (symbol-name cs)))
			      ;; UTF-16 of any variety is invalid for
			      ;; text parts and, unfortunately, has
			      ;; mime-charset defined both in Mule-UCS
			      ;; and versions of Emacs.  (The name
			      ;; might be `mule-utf-16...'  or
			      ;; `utf-16...'.)
			      (not (string-match "utf-16" (symbol-name cs))))
			 (setq systems nil
			       charsets (list cs))))))
	       charsets))
	;; We're not multibyte, or a single coding system won't cover it.
	(setq charsets
	      (delete-dups
	       (mapcar 'mm-mime-charset
		       (delq 'ascii
			     (mm-find-charset-region b e))))))
    (if (and (> (length charsets) 1)
	     (memq 'iso-8859-15 charsets)
	     (memq 'iso-8859-15 hack-charsets)
	     (save-excursion (mm-iso-8859-x-to-15-region b e)))
	(dolist (x mm-iso-8859-15-compatible)
	  (setq charsets (delq (car x) charsets))))
    (if (and (memq 'iso-2022-jp-2 charsets)
	     (memq 'iso-2022-jp-2 hack-charsets))
	(setq charsets (delq 'iso-2022-jp charsets)))
    charsets))

(defmacro mm-with-unibyte-buffer (&rest forms)
  "Create a temporary buffer, and evaluate FORMS there like `progn'.
Use unibyte mode for this."
  `(with-temp-buffer
     (mm-disable-multibyte)
     ,@forms))
(put 'mm-with-unibyte-buffer 'lisp-indent-function 0)
(put 'mm-with-unibyte-buffer 'edebug-form-spec '(body))

(defmacro mm-with-multibyte-buffer (&rest forms)
  "Create a temporary buffer, and evaluate FORMS there like `progn'.
Use multibyte mode for this."
  `(with-temp-buffer
     (mm-enable-multibyte)
     ,@forms))
(put 'mm-with-multibyte-buffer 'lisp-indent-function 0)
(put 'mm-with-multibyte-buffer 'edebug-form-spec '(body))

(defmacro mm-with-unibyte-current-buffer (&rest forms)
  "Evaluate FORMS with current buffer temporarily made unibyte.

Note: We recommend not using this macro any more; there should be
better ways to do a similar thing.  The previous version of this macro
bound the default value of `enable-multibyte-characters' to nil while
evaluating FORMS but it is no longer done.  So, some programs assuming
it if any may malfunction."
  (declare (obsolete nil "25.1") (indent 0) (debug t))
  (let ((multibyte (make-symbol "multibyte")))
    `(let ((,multibyte enable-multibyte-characters))
       (when ,multibyte
	 (set-buffer-multibyte nil))
       (prog1
	   (progn ,@forms)
	 (when ,multibyte
	   (set-buffer-multibyte t))))))

(defun mm-find-charset-region (b e)
  "Return a list of Emacs charsets in the region B to E."
  (cond
   ((and (mm-multibyte-p)
	 (fboundp 'find-charset-region))
    ;; Remove composition since the base charsets have been included.
    ;; Remove eight-bit-*, treat them as ascii.
    (let ((css (find-charset-region b e)))
      (dolist (cs
	       '(composition eight-bit-control eight-bit-graphic control-1)
	       css)
	(setq css (delq cs css)))))
   (t
    ;; We are in a unibyte buffer, so we futz around a bit.
    (save-excursion
      (save-restriction
	(narrow-to-region b e)
	(goto-char (point-min))
	(skip-chars-forward "\0-\177")
	(if (eobp)
	    '(ascii)
	  (let (charset)
	    (setq charset
		  (and (boundp 'current-language-environment)
		       (car (last (assq 'charset
					(assoc current-language-environment
					       language-info-alist))))))
	    (if (eq charset 'ascii) (setq charset nil))
	    (or charset
		(setq charset
		      (car (last (assq mail-parse-charset
				       mm-mime-mule-charset-alist)))))
	    (list 'ascii (or charset 'latin-iso8859-1)))))))))

(defun mm-auto-mode-alist ()
  "Return an `auto-mode-alist' with only the .gz (etc) thingies."
  (let ((alist auto-mode-alist)
	out)
    (while alist
      (when (listp (cdar alist))
	(push (car alist) out))
      (pop alist))
    (nreverse out)))

(defvar mm-inhibit-file-name-handlers
  '(jka-compr-handler image-file-handler epa-file-handler)
  "A list of handlers doing (un)compression (etc) thingies.")

(defun mm-insert-file-contents (filename &optional visit beg end replace
					 inhibit)
  "Like `insert-file-contents', but only reads in the file.
A buffer may be modified in several ways after reading into the buffer due
to advanced Emacs features, such as file-name-handlers, format decoding,
`find-file-hooks', etc.
If INHIBIT is non-nil, inhibit `mm-inhibit-file-name-handlers'.
  This function ensures that none of these modifications will take place."
  (letf* ((format-alist nil)
          (auto-mode-alist (if inhibit nil (mm-auto-mode-alist)))
          ((default-value 'major-mode) 'fundamental-mode)
          (enable-local-variables nil)
          (after-insert-file-functions nil)
          (enable-local-eval nil)
          (inhibit-file-name-operation (if inhibit
                                           'insert-file-contents
                                         inhibit-file-name-operation))
          (inhibit-file-name-handlers
           (if inhibit
               (append mm-inhibit-file-name-handlers
                       inhibit-file-name-handlers)
             inhibit-file-name-handlers))
          (ffh (if (boundp 'find-file-hook)
                   'find-file-hook
                 'find-file-hooks))
          (val (symbol-value ffh)))
    (set ffh nil)
    (unwind-protect
	(insert-file-contents filename visit beg end replace)
      (set ffh val))))

(defun mm-append-to-file (start end filename &optional codesys inhibit)
  "Append the contents of the region to the end of file FILENAME.
When called from a function, expects three arguments,
START, END and FILENAME.  START and END are buffer positions
saying what text to write.
Optional fourth argument specifies the coding system to use when
encoding the file.
If INHIBIT is non-nil, inhibit `mm-inhibit-file-name-handlers'."
  (let ((coding-system-for-write
	 (or codesys mm-text-coding-system-for-write
	     mm-text-coding-system))
	(inhibit-file-name-operation (if inhibit
					 'append-to-file
				       inhibit-file-name-operation))
	(inhibit-file-name-handlers
	 (if inhibit
	     (append mm-inhibit-file-name-handlers
		     inhibit-file-name-handlers)
	   inhibit-file-name-handlers)))
    (write-region start end filename t 'no-message)
    (message "Appended to %s" filename)))

(defun mm-write-region (start end filename &optional append visit lockname
			      coding-system inhibit)

  "Like `write-region'.
If INHIBIT is non-nil, inhibit `mm-inhibit-file-name-handlers'."
  (let ((coding-system-for-write
	 (or coding-system mm-text-coding-system-for-write
	     mm-text-coding-system))
	(inhibit-file-name-operation (if inhibit
					 'write-region
				       inhibit-file-name-operation))
	(inhibit-file-name-handlers
	 (if inhibit
	     (append mm-inhibit-file-name-handlers
		     inhibit-file-name-handlers)
	   inhibit-file-name-handlers)))
    (write-region start end filename append visit lockname)))

(defalias 'mm-make-temp-file 'make-temp-file)
(define-obsolete-function-alias 'mm-make-temp-file 'make-temp-file "25.2")

(defvar mm-image-load-path-cache nil)

(defun mm-image-load-path (&optional package)
  (if (and mm-image-load-path-cache
	   (equal load-path (car mm-image-load-path-cache)))
      (cdr mm-image-load-path-cache)
    (let (dir result)
      (dolist (path load-path)
	(when (and path
		   (file-directory-p
		    (setq dir (concat (file-name-directory
				       (directory-file-name path))
				      "etc/images/" (or package "gnus/")))))
	  (push dir result)))
      (setq result (nreverse result)
	    mm-image-load-path-cache (cons load-path result))
      result)))

;; Fixme: This doesn't look useful where it's used.
(if (fboundp 'detect-coding-region)
    (defun mm-detect-coding-region (start end)
      "Like `detect-coding-region' except returning the best one."
      (let ((coding-systems
	     (detect-coding-region start end)))
	(or (car-safe coding-systems)
	    coding-systems)))
  (defun mm-detect-coding-region (start end)
    (let ((point (point)))
      (goto-char start)
      (skip-chars-forward "\0-\177" end)
      (prog1
	  (if (eq (point) end) 'ascii (mm-guess-charset))
	(goto-char point)))))

(declare-function mm-detect-coding-region "mm-util" (start end))

(if (fboundp 'coding-system-get)
    (defun mm-detect-mime-charset-region (start end)
      "Detect MIME charset of the text in the region between START and END."
      (let ((cs (mm-detect-coding-region start end)))
	(or (coding-system-get cs :mime-charset)
	    (coding-system-get cs 'mime-charset))))
  (defun mm-detect-mime-charset-region (start end)
    "Detect MIME charset of the text in the region between START and END."
    (let ((cs (mm-detect-coding-region start end)))
      cs)))

(defun mm-coding-system-to-mime-charset (coding-system)
  "Return the MIME charset corresponding to CODING-SYSTEM."
  (when coding-system
    (or (coding-system-get coding-system :mime-charset)
	(coding-system-get coding-system 'mime-charset))))

(defvar jka-compr-acceptable-retval-list)
(declare-function jka-compr-make-temp-name "jka-compr" (&optional local))

(defun mm-decompress-buffer (filename &optional inplace force)
  "Decompress buffer's contents, depending on jka-compr.
Only when FORCE is t or `auto-compression-mode' is enabled and FILENAME
agrees with `jka-compr-compression-info-list', decompression is done.
Signal an error if FORCE is neither nil nor t and compressed data are
not decompressed because `auto-compression-mode' is disabled.
If INPLACE is nil, return decompressed data or nil without modifying
the buffer.  Otherwise, replace the buffer's contents with the
decompressed data.  The buffer's multibyteness must be turned off."
  (when (and filename
	     (if force
		 (prog1 t (require 'jka-compr))
	       (and (fboundp 'jka-compr-installed-p)
		    (jka-compr-installed-p))))
    (let ((info (jka-compr-get-compression-info filename)))
      (when info
	(unless (or (memq force (list nil t))
		    (jka-compr-installed-p))
	  (error ""))
	(let ((prog (jka-compr-info-uncompress-program info))
	      (args (jka-compr-info-uncompress-args info))
	      (msg (format "%s %s..."
			   (jka-compr-info-uncompress-message info)
			   filename))
	      (err-file (jka-compr-make-temp-name))
	      (cur (current-buffer))
	      (coding-system-for-read mm-binary-coding-system)
	      (coding-system-for-write mm-binary-coding-system)
	      retval err-msg)
	  (message "%s" msg)
	  (mm-with-unibyte-buffer
	    (insert-buffer-substring cur)
	    (condition-case err
		(progn
		  (unless (memq (apply 'call-process-region
				       (point-min) (point-max)
				       prog t (list t err-file) nil args)
				jka-compr-acceptable-retval-list)
		    (erase-buffer)
		    (insert (mapconcat 'identity
				       (split-string
					(prog2
					    (insert-file-contents err-file)
					    (buffer-string)
					  (erase-buffer)) t)
				       " ")
			    "\n")
		    (setq err-msg
			  (format "Error while executing \"%s %s < %s\""
				  prog (mapconcat 'identity args " ")
				  filename)))
		  (setq retval (buffer-string)))
	      (error
	       (setq err-msg (error-message-string err)))))
	  (when (file-exists-p err-file)
	    (ignore-errors (delete-file err-file)))
	  (when inplace
	    (unless err-msg
	      (delete-region (point-min) (point-max))
	      (insert retval))
	    (setq retval nil))
	  (message "%s" (or err-msg (concat msg "done")))
	  retval)))))

(eval-when-compile
  (unless (fboundp 'coding-system-name)
    (defalias 'coding-system-name 'ignore))
  (unless (fboundp 'find-file-coding-system-for-read-from-filename)
    (defalias 'find-file-coding-system-for-read-from-filename 'ignore))
  (unless (fboundp 'find-operation-coding-system)
    (defalias 'find-operation-coding-system 'ignore)))

(defun mm-find-buffer-file-coding-system (&optional filename)
  "Find coding system used to decode the contents of the current buffer.
This function looks for the coding system magic cookie or examines the
coding system specified by `file-coding-system-alist' being associated
with FILENAME which defaults to `buffer-file-name'.  Data compressed by
gzip, bzip2, etc. are allowed."
  (unless filename
    (setq filename buffer-file-name))
  (save-excursion
    (let ((decomp (unless ;; Not worth it to examine charset of tar files.
		      (and filename
			   (string-match
			    "\\.\\(?:tar\\.[^.]+\\|tbz\\|tgz\\)\\'"
			    filename))
		    (mm-decompress-buffer filename nil t))))
      (when decomp
	(set-buffer (generate-new-buffer " *temp*"))
        (mm-disable-multibyte)
	(insert decomp)
	(setq filename (file-name-sans-extension filename)))
      (goto-char (point-min))
      (unwind-protect
	  (if filename
	      (or (funcall (symbol-value 'set-auto-coding-function)
			   filename (- (point-max) (point-min)))
		  (car (find-operation-coding-system 'insert-file-contents
						     filename)))
	    (let (auto-coding-alist)
	      (condition-case nil
		  (funcall (symbol-value 'set-auto-coding-function)
			   nil (- (point-max) (point-min)))
		(error nil))))
	(when decomp
	  (kill-buffer (current-buffer)))))))

(provide 'mm-util)

;;; mm-util.el ends here
