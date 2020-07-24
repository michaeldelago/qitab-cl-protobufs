;;; Copyright 2012-2020 Google LLC
;;;
;;; Use of this source code is governed by an MIT-style
;;; license that can be found in the LICENSE file or at
;;; https://opensource.org/licenses/MIT.

(in-package "PROTO-IMPL")


;;; Print objects using Protobufs text format

(defun print-text-format (object &key
                                   (indent 0)
                                   (stream *standard-output*)
                                   (name nil)
                                   (print-name t)
                                   (pretty-print t))
  "Prints a protocol buffer message to a stream.
Parameters:
  OBJECT: The protocol buffer message to print.
  INDENT: Indent the output by INDENT spaces.
  STREAM: The stream to print to.
  NAME: A string. If supplied (and PRINT-NAME is T), this string will be
    used as the name in printing. If not supplied, then the PROTO-NAME slot
    of OBJECT's message descriptor will be used.
  PRINT-NAME: Bool for printing the name of the top level proto message.
  PRETTY-PRINT: When true, generate line breaks and other human readable output
    in the text format. When false, replace line breaks with spaces."
  (let* ((type    (type-of object))
         (message (find-message-for-class type)))
    (assert message ()
            "There is no Protobuf message having the type ~S" type)
    (macrolet ((read-slot (object slot reader)
                 `(if ,reader
                      (funcall ,reader ,object)

                      (slot-value ,object ,slot))))
      (let ((name (or name (proto-name message))))
        (if print-name
            (if pretty-print
                (format stream "~&~V,0T~A {~%" indent name)
                (format stream "~A { " name))
            (format stream "{")))
      (dolist (field (proto-fields message))
        ;; If a field doesn't have an offset, then it is an extension.
        ;; Otherwise, we can use the %%IS-SET vector.
        (when (if (slot-value field 'field-offset)
                  (= (bit (slot-value object '%%is-set)
                          (proto-field-offset field))
                     1)
                  (has-extension object (proto-internal-field-name field)))
          (let ((slot   (slot-value field 'internal-field-name))
                (reader (slot-value field 'reader)))
            (if (eq (proto-label field) :repeated)
                (print-repeated-field
                 (if slot
                     (read-slot object slot
                                (and (not (proto-lazy-p field))
                                     reader))
                     (list object))
                 (proto-class field)
                 (proto-name field)
                 :indent indent
                 :stream stream
                 :print-name print-name
                 :pretty-print pretty-print)
                (print-non-repeated-field
                 (if slot (read-slot object slot reader) object)
                 (proto-class field)
                 (proto-name field)
                 :indent indent
                 :stream stream
                 :print-name print-name
                 :pretty-print pretty-print)))))
      (if pretty-print
          (format stream "~&~V,0T}~%" indent)
          (format stream "} "))
      nil)))

(defun print-repeated-field
    (values type name &key (indent 0) (stream *standard-output*) (print-name t) (pretty-print t))
  "Print the text format of a single field which is not repeated.

Parameters:
  VALUES: The list or vector of values in the field to print.
  TYPE: The protobuf type to print. This is obtained from
    the PROTO-CLASS slot in the field-descriptor.
  NAME: The name of the field. This is printed before the value.
  INDENT: If supplied, indent the text by INDENT spaces.
  STREAM: The stream to output to.
  PRINT-NAME: Whether or not to print the name of the field.
  PRETTY-PRINT: When true, print newlines and indentation."
  (unless values
    (return-from print-repeated-field nil)) ; If values is NIL, then there is nothing to do.
  (let ((desc))
    (cond
      ((scalarp type)
       (doseq (v values)
              (print-scalar v type name stream
                            (and pretty-print indent))))
      ((typep (setq desc (or (find-message type)
                             (find-enum type)
                             (find-type-alias type)))
              'message-descriptor)
       (dolist (v values)
         (print-text-format v :indent (+ indent 2)
                              :stream stream
                              :name name
                              :print-name print-name
                              :pretty-print pretty-print)))
      ((typep desc 'enum-descriptor)
       (doseq (v values)
              (print-enum v desc name stream
                          (and pretty-print indent))))
      ((typep desc 'protobuf-type-alias)
       (let ((type (proto-proto-type desc)))
         (doseq (v values)
                (let ((v (funcall (proto-serializer desc) v)))
                  (print-scalar v type name stream
                                (and pretty-print indent))))))
      (t (undefined-type type "While printing ~S to text format," values)))))

(defun print-non-repeated-field
    (value type name &key (indent 0) (stream *standard-output*) (print-name t) (pretty-print t))
  "Print the text format of a single field which is not repeated.

Parameters:
  VALUE: The value in the field to print.
  TYPE: The protobuf type to print. This is obtained from
    the PROTO-CLASS slot in the field-descriptor.
  NAME: The name of the field. This is printed before the value.
  INDENT: If supplied, indent the text by INDENT spaces.
  STREAM: The stream to output to.
  PRINT-NAME: Whether or not to print the name of the field.
  PRETTY-PRINT: When true, print newlines and indentation."
  (let ((desc))
    ;; If VALUE is NIL and the type is not boolean, there is nothing to do.
    (unless (or value (eq type :bool))
      (return-from print-non-repeated-field nil))
    (cond
      ((scalarp type)
       (print-scalar value type name stream
                     (and pretty-print indent)))
      ((typep (setq desc (or (find-message type)
                             (find-enum type)
                             (find-type-alias type)
                             (find-map-descriptor type)))
              'message-descriptor)
       (print-text-format value :indent (+ indent 2)
                                :stream stream
                                :name name
                                :print-name print-name
                                :pretty-print pretty-print))
      ((typep desc 'enum-descriptor)
       (print-enum value desc name stream
                   (and pretty-print indent)))
      ((typep desc 'protobuf-type-alias)
       (when value
         (let ((value (funcall (proto-serializer desc) value))
               (type  (proto-proto-type desc)))
           (print-scalar value type name stream
                         (and pretty-print indent)))))
      ;; todo(benkuehnert): use specified map format
      ((typep desc 'map-descriptor)
       (let ((key-class (map-descriptor-key-class desc))
             (val-class (map-descriptor-val-class desc)))
         (if pretty-print
             (format stream "~&~VT~A: {~%" (+ 2 indent) name)
             (format stream "~A: {" name))
         (flet ((print-entry (k v)
                  (format stream "~&~VT" (+ 4 indent))
                  (print-scalar k key-class nil stream nil)
                  (format stream "-> ")
                  (if (scalarp val-class)
                      (print-scalar v val-class nil stream nil)
                      (print-text-format v :stream stream
                                           :pretty-print nil))
                  (format stream "~%")))
           (maphash #'print-entry value)
           (format stream "~&~VT}" (+ indent 2)))))

      (t (undefined-type type "While printing ~S to text format," value)))))

(defun print-scalar (val type name stream indent)
  "Print scalar value to stream

Parameters:
  VAL: The data for the value to print.
  TYPE: The type of val.
  NAME: The name to print before the value. If nil, then no
        name will be printed.
  STREAM: The stream to print to.
  INDENT: Either a number or nil.
          - If indent is a number, indent this print
            by (+ indent 2) and write a newline at
            the end.
          - If indent is nil, then do not indent and
            do not write a newline."
  (when (or val (eq type :bool))
    (when indent
      (format stream "~&~V,0T" (+ indent 2)))
    (when name
      (format stream "~A: " name))
    (ecase type
      ((:int32 :uint32 :int64 :uint64 :sint32 :sint64
        :fixed32 :sfixed32 :fixed64 :sfixed64)
       (format stream "~D" val))
      ((:string)
       (format stream "\"~A\"" val))
      ((:bytes)
       (format stream "~S" val))
      ((:bool)
       (format stream "~A" (if val "true" "false")))
      ((:float :double)
       (format stream "~D" val))
      ;; A few of our homegrown types
      ((:symbol)
       (let ((val (if (keywordp val)
                    (string val)
                    (format nil "~A:~A" (package-name (symbol-package val)) (symbol-name val)))))
         (format stream "\"~A\"" val)))
      ((:date :time :datetime :timestamp)
       (format stream "~D" val)))
    (if indent
      (format stream "~%")
      (format stream " "))))

(defun print-enum (val enum name stream indent)
  "Print enum to stream

Parameters:
  VAL: The enum value.
  ENUM: The enum descriptor.
  NAME: The name to print before the value. If NIL, no name will be printed.
  STREAM: The stream to print to.
  INDENT: Either a number or nil.
          - If indent is a number, indent this print
            by (+ indent 2) and write a newline at
            the end.
          - If indent is nil, then do not indent and
            do not write a newline."
  (when val
    (if indent
      (format stream "~&~V,0T" (+ indent 2)))
    (if name
        (format stream "~A: " name))
    (let* ((e (find (keywordify val)
                    (enum-descriptor-values enum)
                    :key #'enum-value-descriptor-name))
           (value (and e (enum-value-descriptor-name e)))
           (proto-keyword-value (substitute #\_ #\- (string value))))
      (format stream "~A" proto-keyword-value)
      (if indent
        (format stream "~%")
        (format stream " ")))))

;;; Parse objects that were serialized using the text format

(defgeneric parse-text-format (type &key stream parse-name)
  (:documentation
   "Parses an object of type 'type' from the stream 'stream' using the textual format."))

(defmethod parse-text-format ((type symbol)
                              &key (stream *standard-input*) (parse-name t))
  (let ((message (find-message-for-class type)))
    (assert message ()
            "There is no Protobuf message having the type ~S" type)
    (parse-text-format message :stream stream :parse-name parse-name)))

(defmethod parse-text-format ((msg-desc message-descriptor)
                              &key (stream *standard-input*) (parse-name t))
  "Parse a protobuf message with descriptor MSG-DESC from STREAM. This method
returns the parsed object. PARSE-NAME is a flag used for recursive calls. If true,
attempt to parse the name of the message and match it against MSG-DESC."
  (when parse-name
    (let ((name (parse-token stream)))
      (assert (string= name (proto-name msg-desc)) ()
              "The message is not of the expected type ~A" (proto-name msg-desc))))
  (let ((object (make-instance (or (proto-alias-for msg-desc)
                                   (proto-class msg-desc))))
        (rslots ())) ; repeated slot names, tracks which slots need to be nreversed.
    (expect-char stream #\{)
    (loop
      (skip-whitespace stream)
      (when (eql (peek-char nil stream nil) #\})
        (read-char stream)
        (dolist (slot rslots)
          (setf (proto-slot-value object slot)
                (nreverse (proto-slot-value object slot))))
        (return-from parse-text-format object))
      (let* ((name  (parse-token stream))
             (field (and name (find-field msg-desc name)))
             (type  (and field (if (eq (proto-class field) 'boolean)
                                   :bool (proto-class field))))
             (slot  (and field (proto-external-field-name field))))
        (if (null field)
            (skip-field stream)
            (multiple-value-bind (val error-p)
                (parse-field type :stream stream)
              (cond
                (error-p
                 (undefined-field-type "While parsing ~S from text format,"
                                       msg-desc type field))
                ((eq (proto-label field) :repeated)
                 ;; If slot is NIL, then this field doesn't exist in the message
                 ;; so we skip it.
                 (when slot
                   (pushnew slot rslots)
                   (push val (proto-slot-value object slot))))
                (t
                 (when slot
                   (setf (proto-slot-value object slot) val))))))))))

(defun parse-field (type &key (stream *standard-input*))
  "Parse data of type TYPE from STREAM. This function returns
the object parsed. If the parsing fails, the function will
return T as a second value."
  (let ((desc (or (find-message type)
                 (find-enum type)
                 (find-type-alias type))))
    (cond ((scalarp type)
           (expect-char stream #\:)
           (case type
             ((:float) (parse-float stream))
             ((:double) (parse-double stream))
             ((:string) (parse-string stream))
             ((:bool)   (boolean-true-p (parse-token stream)))
             (otherwise (parse-signed-int stream))))
          ((typep desc 'message-descriptor)
           (when (eql (peek-char nil stream nil) #\:)
             (read-char stream))
           (parse-text-format (find-message type)
                              :stream stream
                              :parse-name nil))
          ((typep desc 'enum-descriptor)
           (expect-char stream #\:)
           (let* ((name (parse-token stream))
                  (enum (find (keywordify name) (enum-descriptor-values desc)
                              :key #'enum-value-descriptor-name)))
             (and enum (enum-value-descriptor-name enum))))
          ((typep desc 'protobuf-type-alias)
           (let ((type (proto-proto-type desc)))
             (expect-char stream #\:)
             (case type
               ((:float) (parse-float stream))
               ((:double) (parse-double stream))
               ((:string) (parse-string stream))
               ((:bool)   (boolean-true-p (parse-token stream)))
               (otherwise (parse-signed-int stream)))))
        (t (values nil t)))))

(defun skip-field (stream)
  "Skip either a token or a balanced {}-pair."
  (ecase (peek-char nil stream nil)
    ((#\:)
     (read-char stream)
     (skip-whitespace stream)
     (parse-token-or-string stream))
    ((#\{)
     (let ((depth 0))
       (loop for ch = (read-char stream)
             do (cond ((eql ch #\")
                       (loop for ch0 = (read-char stream)
                             until (eql ch0 #\")))
                      ((eql ch #\{)
                       (iincf depth))
                      ((eql ch #\})
                       (idecf depth)))
             until (i= depth 0))))))
