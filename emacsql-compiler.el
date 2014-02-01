;;; emacsql-compile.el --- s-expression SQL compiler -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)

(defmacro emacsql-deferror (symbol parents message)
  "Defines a new error symbol  for Emacsql."
  (declare (indent 2))
  (let ((conditions (cl-remove-duplicates
                     (append parents (list symbol 'emacsql-error 'error)))))
    `(prog1 ',symbol
       (setf (get ',symbol 'error-conditions) ',conditions
             (get ',symbol 'error-message) ,message))))

(emacsql-deferror emacsql-error () ;; parent condition for all others
  "Emacsql had an unhandled condition")

(emacsql-deferror emacsql-syntax () "Invalid SQL statement")
(emacsql-deferror emacsql-internal () "Internal error")
(emacsql-deferror emacsql-lock () "Database locked")
(emacsql-deferror emacsql-fatal () "Fatal error")
(emacsql-deferror emacsql-memory () "Out of memory")
(emacsql-deferror emacsql-corruption () "Database corrupted")
(emacsql-deferror emacsql-access () "Database access error")
(emacsql-deferror emacsql-timeout () "Query timeout error")
(emacsql-deferror emacsql-warning () "Warning message")

(defun emacsql-error (format &rest args)
  "Like `error', but signal an emacsql-syntax condition."
  (signal 'emacsql-syntax (list (apply #'format format args))))

;; Escaping functions:

(defun emacsql-quote-scalar (string)
  "Single-quote (scalar) STRING for use in a SQL expression."
  (format "'%s'" (replace-regexp-in-string "'" "''" string)))

(defun emacsql-quote-identifier (string)
  "Double-quote (identifier) STRING for use in a SQL expression."
  (format "\"%s\"" (replace-regexp-in-string "\"" "\"\"" string)))

(defun emacsql-escape-identifier (identifier)
  "Escape an identifier, if needed, for SQL."
  (when (or (null identifier)
            (keywordp identifier)
            (not (symbolp identifier)))
    (emacsql-error "Invalid identifier: %S" identifier))
  (let ((name (symbol-name identifier)))
    (if (string-match-p ":" name)
        (mapconcat #'emacsql-escape-identifier
                   (mapcar #'intern (split-string name ":")) ".")
      (let ((print (replace-regexp-in-string "-" "_" (format "%S" identifier)))
            (special "[]-\000-\040!\"#%&'()*+,./:;<=>?@[\\^`{|}~\177]"))
        (if (or (string-match-p special print)
                (string-match-p "^[0-9$]" print))
            (emacsql-quote-identifier print)
          name)))))

(defun emacsql-escape-scalar (value)
  "Escape VALUE for sending to SQLite."
  (let ((print-escape-newlines t))
    (cond ((null value) "NULL")
          ((numberp value) (prin1-to-string value))
          ((emacsql-quote-scalar (prin1-to-string value))))))

(defun emacsql-escape-vector (vector)
  "Encode VECTOR into a SQL vector scalar."
  (cl-typecase vector
    (null   (emacsql-error "Empty SQL vector expression."))
    (list   (mapconcat #'emacsql-escape-vector vector ", "))
    (vector (concat "(" (mapconcat #'emacsql-escape-scalar vector ", ") ")"))
    (otherwise (emacsql-error "Invalid vector %S" vector))))

(defun emacsql-escape-format (thing &optional kind)
  "Escape THING for use as a `format' spec, pre-escaping for KIND.
KIND should be :scalar or :identifier."
  (replace-regexp-in-string
   "%" "%%" (cl-case kind
              (:scalar (emacsql-escape-scalar thing))
              (:identifier (emacsql-escape-identifier thing))
              (:vector (emacsql-escape-vector thing))
              (otherwise thing))))

;; Schema compiler:

(defvar emacsql-type-map
  '((integer "&INTEGER")
    (float "&REAL")
    (object "&TEXT")
    (nil "&NONE"))
  "An alist mapping Emacsql types to SQL types.")

(defun emacsql--from-keyword (keyword)
  "Convert KEYWORD into SQL."
  (let ((name (substring (symbol-name keyword) 1)))
    (upcase (replace-regexp-in-string "-" " " name))))

(defun emacsql--prepare-constraints (constraints)
  "Compile CONSTRAINTS into a partial SQL expresson."
  (mapconcat
   #'identity
   (cl-loop for constraint in constraints collect
            (cl-typecase constraint
              (null "NULL")
              (keyword (emacsql--from-keyword constraint))
              (symbol (emacsql-escape-identifier constraint))
              (vector (format "(%s)"
                              (mapconcat
                               #'emacsql-escape-identifier
                               constraint
                               ", ")))
              (list (format "(%s)"
                            (car (emacsql--*expr constraint))))
              (otherwise
               (emacsql-escape-scalar constraint))))
   " "))

(defun emacsql--prepare-column (column)
  "Convert COLUMN into a partial SQL string."
  (mapconcat
   #'identity
   (cl-etypecase column
     (symbol (list (emacsql-escape-identifier column)
                   (cadr (assoc nil emacsql-type-map))))
     (list (cl-destructuring-bind (name . constraints) column
             (delete-if
              (lambda (s) (zerop (length s)))
              (list (emacsql-escape-identifier name)
                    (if (member (car constraints) '(integer float object))
                        (cadr (assoc (pop constraints) emacsql-type-map))
                      (cadr (assoc nil emacsql-type-map)))
                    (emacsql--prepare-constraints constraints))))))
   " "))

(defun emacsql-prepare-schema (schema)
  "Compile SCHEMA into a SQL string."
  (if (vectorp schema)
      (emacsql-prepare-schema (list schema))
    (cl-destructuring-bind (columns . constraints) schema
      (mapconcat
       #'identity
       (nconc
        (mapcar #'emacsql--prepare-column columns)
        (mapcar #'emacsql--prepare-constraints constraints))
       ", "))))

;; Statement compilation:

(defvar emacsql-prepare-cache (make-hash-table :test 'equal :weakness 'key)
  "Cache used to memoize `emacsql-prepare'.")

(defvar emacsql--vars ()
  "For use with `emacsql-with-vars'.")

(defun emacsql-sql-p (thing)
  "Return non-nil if THING looks like a prepared statement."
  (and (vectorp thing) (> (length thing) 0) (keywordp (aref thing 0))))

(defun emacsql-param (thing)
  "Return the index and type of THING, or nil if THING is not a parameter.
A parameter is a symbol that looks like $i1, $s2, $v3, etc. The
letter refers to the type: identifier (i), scalar (s),
vector (v), schema (S)."
  (when (symbolp thing)
    (let ((name (symbol-name thing)))
      (when (string-match-p "^\\$[isvS][0-9]+$" name)
        (cons (1- (read (substring name 2)))
              (cl-ecase (aref name 1)
                (?i :identifier)
                (?s :scalar)
                (?v :vector)
                (?S :schema)))))))

(defmacro emacsql-with-params (prefix &rest body)
  "Evaluate BODY, collecting patameters.
Provided local functions: `param', `identifier', `scalar',
`svector', `expr', `subsql', and `combine'. BODY should return a string,
which will be combined with variable definitions."
  (declare (indent 1))
  `(let ((emacsql--vars ()))
     (cl-flet* ((combine (prepared) (emacsql--*combine prepared))
                (param (thing) (emacsql--!param thing))
                (identifier (thing) (emacsql--!param thing :identifier))
                (scalar (thing) (emacsql--!param thing :scalar))
                (svector (thing) (combine (emacsql--*vector thing)))
                (expr (thing) (combine (emacsql--*expr thing)))
                (subsql (thing)
                        (format "(%s)" (combine (emacsql-prepare thing)))))
       (cons (concat ,prefix (progn ,@body)) emacsql--vars))))

(defun emacsql--!param (thing &optional kind)
  "Only use within `emacsql-with-params'!"
  (cl-flet ((check (param)
                   (when (and kind (not (eq kind (cdr param))))
                     (emacsql-error
                      "Invalid parameter type %s, expecting %s" thing kind))))
    (let ((param (emacsql-param thing)))
      (if (null param)
          (emacsql-escape-format
           (if kind
               (cl-case kind
                 (:identifier (emacsql-escape-identifier thing))
                 (:scalar (emacsql-escape-scalar thing))
                 (:vector (emacsql-escape-vector thing))
                 (:schema (emacsql-prepare-schema thing)))
             (if (symbolp thing)
                 (emacsql-escape-identifier thing)
               (emacsql-escape-scalar thing))))
        (prog1 "%s"
          (check param)
          (setf emacsql--vars (nconc emacsql--vars (list param))))))))

(defun emacsql--*vector (vector)
  "Prepare VECTOR."
  (emacsql-with-params ""
    (cl-typecase vector
      (symbol (param vector :vector))
      (list (mapconcat #'svector vector ", "))
      (vector (format "(%s)" (mapconcat #'scalar vector ", ")))
      (otherwise (emacsql-error "Invalid vector: %S" vector)))))

(defun emacsql--*expr (expr)
  "Expand EXPR recursively."
  (emacsql-with-params ""
    (cond
     ((emacsql-sql-p expr) (subsql expr))
     ((vectorp expr) (svector expr))
     ((atom expr) (param expr))
     ((cl-destructuring-bind (op . args) expr
        (cl-flet ((recur (n) (combine (emacsql--*expr (nth n args))))
                  (nops (op)
                        (emacsql-error "Wrong number of operands for %s" op)))
          (cl-case op
            ;; Special cases <= >=
            ((<= >=)
             (cl-case (length args)
               (2 (format "%s %s %s" (recur 0) op (recur 1)))
               (3 (format "%s BETWEEN %s AND %s"
                          (recur 1)
                          (recur (if (eq op '>=) 2 0))
                          (recur (if (eq op '>=) 0 2))))
               (otherwise (nops op))))
            ;; Special case -
            ((-)
             (cl-case (length args)
               (1 (format "-(%s)" (recur 0)))
               (2 (format "%s - %s" (recur 0) (recur 1)))
               (otherwise (nops op))))
            ;; Special case quote
            ((quote) (scalar (nth 0 args)))
            ;; Guess
            (otherwise
             (mapconcat
              #'recur (cl-loop for i from 0 below (length args) collect i)
              (format " %s " (upcase (symbol-name op))))))))))))

(defun emacsql--*idents (idents)
  "Read in a vector of IDENTS identifiers, or just an single identifier."
  (emacsql-with-params ""
    (mapconcat #'expr idents ", ")))

(defun emacsql--*combine (prepared)
  "Only use within `emacsql-with-vars'!"
  (cl-destructuring-bind (string . vars) prepared
    (setf emacsql--vars (nconc emacsql--vars vars))
    string))

(defun emacsql-prepare (sql)
  "Expand SQL into a SQL-consumable string, with parameters."
  (let* ((cache emacsql-prepare-cache)
         (key (cons emacsql-type-map sql)))
    (or (gethash key cache)
        (setf (gethash key cache)
              (emacsql-with-params ""
                (cl-loop with items = (cl-coerce sql 'list)
                         and last = nil
                         while (not (null items))
                         for item = (pop items)
                         collect
                         (cl-typecase item
                           (keyword (if (eq :values item)
                                        (concat "VALUES " (svector (pop items)))
                                      (emacsql--from-keyword item)))
                           (symbolp (if (eq item '*)
                                        "*"
                                      (identifier item)))
                           (vector (if (emacsql-sql-p item)
                                       (subsql item)
                                     (let ((idents (combine
                                                    (emacsql--*idents item))))
                                       (if (keywordp last)
                                           idents
                                         (format "(%s)" idents)))))
                           (list (if (vectorp (car item))
                                     (emacsql-escape-format
                                      (format "(%s)"
                                              (emacsql-prepare-schema item)))
                                   (combine (emacsql--*expr item)))))
                         into parts
                         do (setf last item)
                         finally (cl-return
                                  (mapconcat #'identity parts " "))))))))

(defun emacsql-format (expansion &rest args)
  "Fill in the variables EXPANSION with ARGS."
  (cl-destructuring-bind (format . vars) expansion
    (unless (= (length args) (length vars))
      (emacsql-error "Wrong number of arguments for SQL template."))
    (apply #'format format
           (cl-loop for (i . kind) in vars collect
                    (let ((thing (nth i args)))
                      (cl-case kind
                        (:identifier (emacsql-escape-identifier thing))
                        (:scalar (emacsql-escape-scalar thing))
                        (:vector (emacsql-escape-vector thing))
                        (:schema (car (emacsql--schema-to-string thing)))
                        (otherwise
                         (emacsql-error "Invalid var type %S" kind))))))))

(provide 'emacsql-compiler)

;;; emacsql-compile.el ends here
