;;; godot-pose-mode.el --- Live Godot 4 IK/FK pose documents -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: Codex
;; Version: 0.4.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, games, godot, animation

;;; Commentary:

;; `godot-pose-mode' makes a versioned .gdpose JSON document the source of
;; truth for runtime character poses.  It follows the usual Emacs model: the
;; pose is plain text in a buffer, commands operate on that text, the minibuffer
;; selects named poses, and ordinary saving keeps revisions friendly to Git.
;;
;; Main commands:
;;
;;   C-c C-r   Start the document's Godot preview scene.
;;   C-c C-a   Select the active named pose.
;;   C-c C-e   Evaluate/send the active pose to the running Godot process.
;;   C-c C-d   Dump the current editor pose into this document.
;;   C-c C-x   Delete a pose profile through minibuffer completion.
;;   C-c C-t   Send the active pose to the optional game runtime.
;;   C-c C-s   Save the document inside its Godot project.
;;   C-c C-v   Validate the document without sending it.
;;   C-c C-k   Close this buffer's streaming connection.
;;
;; The transport is a persistent localhost TCP connection containing one JSON
;; object per line.  The exact same protocol can be used by ComfyUI, mocap, or
;; any other process; Emacs is a first-class client, not a required relay.
;; A .gdshot document composes named poses from separate actor .gdpose files;
;; C-c C-e resolves and sends every actor without duplicating skeleton data.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'js)
(require 'subr-x)

(defgroup godot-pose nil
  "Edit and stream Godot 4 IK/FK pose documents."
  :group 'tools
  :prefix "godot-pose-")

(defcustom godot-pose-godot-executable
  (if (eq system-type 'darwin)
      "/Applications/Godot.app/Contents/MacOS/Godot"
    "godot")
  "Godot executable used by `godot-pose-run-preview'."
  :type 'file
  :group 'godot-pose)

(defcustom godot-pose-default-host "127.0.0.1"
  "Fallback stream host when a document does not provide one."
  :type 'string
  :group 'godot-pose)

(defcustom godot-pose-default-port 7007
  "Fallback stream port when a document does not provide one."
  :type 'integer
  :group 'godot-pose)

(defcustom godot-pose-save-directory "poses"
  "Project-relative directory used by `godot-pose-save-to-project'."
  :type 'string
  :group 'godot-pose)

(defvar godot-pose--preview-process nil
  "The Godot preview process most recently started from Emacs.")

(defvar-local godot-pose--stream-process nil)
(defvar-local godot-pose--last-response nil)

(defvar godot-pose-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'godot-pose-run-preview)
    (define-key map (kbd "C-c C-a") #'godot-pose-select-active)
    (define-key map (kbd "C-c C-e") #'godot-pose-send-active)
    (define-key map (kbd "C-c C-d") #'godot-pose-dump-editor-pose)
    (define-key map (kbd "C-c C-x") #'godot-pose-delete-profile)
    (define-key map (kbd "C-c C-t") #'godot-pose-send-active-to-runtime)
    (define-key map (kbd "C-c C-s") #'godot-pose-save-to-project)
    (define-key map (kbd "C-c C-v") #'godot-pose-validate)
    (define-key map (kbd "C-c C-k") #'godot-pose-disconnect)
    map)
  "Keymap for `godot-pose-mode'.")

(defvar godot-shot-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-r") #'godot-shot-run-preview)
    (define-key map (kbd "C-c C-e") #'godot-shot-send)
    (define-key map (kbd "C-c C-t") #'godot-shot-send-to-runtime)
    (define-key map (kbd "C-c C-s") #'godot-shot-save-to-project)
    (define-key map (kbd "C-c C-v") #'godot-shot-validate)
    (define-key map (kbd "C-c C-k") #'godot-pose-disconnect)
    map)
  "Keymap for `godot-shot-mode'.")

;;;###autoload
(define-derived-mode godot-pose-mode js-json-mode "Godot-Pose"
  "Major mode for Git-friendly Godot IK/FK pose documents.

The active pose named by `active_pose' is sent with `C-c C-e'.
Use `C-c C-a' to switch that name through the minibuffer."
  (setq-local indent-tabs-mode nil)
  (setq-local js-indent-level 2)
  (add-hook 'kill-buffer-hook #'godot-pose-disconnect nil t))

;;;###autoload
(define-derived-mode godot-shot-mode js-json-mode "Godot-Shot"
  "Major mode for composing multiple actor .gdpose documents.

Each entry in `actors' selects a document and named pose. `C-c C-e' sends all
selected actor poses to the Godot editor; `C-c C-t' targets the runtime."
  (setq-local indent-tabs-mode nil)
  (setq-local js-indent-level 2)
  (add-hook 'kill-buffer-hook #'godot-pose-disconnect nil t))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.gdpose\\'" . godot-pose-mode))
(add-to-list 'auto-mode-alist '("\\.gdshot\\'" . godot-shot-mode))

(defun godot-pose--parse-document ()
  "Parse and return the current .gdpose buffer as an alist."
  (condition-case error-data
      (save-excursion
        (goto-char (point-min))
        (json-parse-buffer
         :object-type 'alist
         :array-type 'list
         :null-object nil
         :false-object :json-false))
    (json-parse-error
     (user-error "Invalid .gdpose JSON: %s" (error-message-string error-data)))))

(defun godot-pose--get (key alist &optional default)
  "Return string KEY from ALIST, or DEFAULT."
  (if (listp alist)
      (let ((entry (assoc-string key alist)))
        (if entry (cdr entry) default))
    default))

(defun godot-pose--validate-document (document)
  "Validate DOCUMENT and return its active pose entry.
Signal `user-error' when required fields are missing."
  (unless (equal (godot-pose--get "schema" document) "godot-pose-document")
    (user-error "Expected schema \"godot-pose-document\""))
  (unless (= (or (godot-pose--get "version" document) 0) 1)
    (user-error "Only .gdpose document version 1 is supported"))
  (let* ((active-name (godot-pose--get "active_pose" document))
         (poses (godot-pose--get "poses" document))
         (active-entry (and active-name (assoc-string active-name poses))))
    (unless (and (stringp active-name) (not (string-empty-p active-name)))
      (user-error "The document needs a non-empty active_pose"))
    (unless (listp poses)
      (user-error "The document needs a poses object"))
    (unless active-entry
      (user-error "active_pose %S is not present in poses" active-name))
    active-entry))

(defun godot-pose-validate ()
  "Validate the current .gdpose document and report its active pose."
  (interactive)
  (let* ((document (godot-pose--parse-document))
         (active-entry (godot-pose--validate-document document)))
    (message "Valid Godot pose document v1; active pose: %s"
             (car active-entry))))

(defun godot-shot--parse-document ()
  "Parse and return the current .gdshot buffer as an alist."
  (condition-case error-data
      (save-excursion
        (goto-char (point-min))
        (json-parse-buffer
         :object-type 'alist
         :array-type 'list
         :null-object nil
         :false-object :json-false))
    (json-parse-error
     (user-error "Invalid .gdshot JSON: %s" (error-message-string error-data)))))

(defun godot-shot--validate-document (document)
  "Validate shot DOCUMENT and return its actors object."
  (unless (equal (godot-pose--get "schema" document) "godot-shot-document")
    (user-error "Expected schema \"godot-shot-document\""))
  (unless (= (or (godot-pose--get "version" document) 0) 1)
    (user-error "Only .gdshot document version 1 is supported"))
  (let ((actors (godot-pose--get "actors" document)))
    (unless (and (listp actors) actors)
      (user-error "The shot needs a non-empty actors object"))
    (dolist (actor actors)
      (let* ((actor-name (format "%s" (car actor)))
             (selection (cdr actor))
             (document-path (godot-pose--get "document" selection))
             (pose-name (godot-pose--get "pose" selection)))
        (unless (and (stringp document-path) (not (string-empty-p document-path)))
          (user-error "Shot actor %s needs a document path" actor-name))
        (unless (and (stringp pose-name) (not (string-empty-p pose-name)))
          (user-error "Shot actor %s needs a pose name" actor-name))))
    actors))

(defun godot-shot--read-pose-document (path)
  "Read a pose document from absolute PATH, preferring an open buffer."
  (unless (file-readable-p path)
    (user-error "Shot pose document is not readable: %s" path))
  (let ((open-buffer (find-buffer-visiting path)))
    (if open-buffer
        (with-current-buffer open-buffer
          (godot-pose--parse-document))
      (with-temp-buffer
        (insert-file-contents path)
        (condition-case error-data
            (json-parse-buffer
             :object-type 'alist
             :array-type 'list
             :null-object nil
             :false-object :json-false)
          (json-parse-error
           (user-error "Invalid pose document %s: %s"
                       path (error-message-string error-data))))))))

(defun godot-shot--actor-specs (shot-document)
  "Resolve SHOT-DOCUMENT into actor pose specifications."
  (unless buffer-file-name
    (user-error "Save the .gdshot buffer before resolving relative documents"))
  (let ((base-directory (file-name-directory buffer-file-name))
        (actors (godot-shot--validate-document shot-document))
        resolved)
    (dolist (actor actors (nreverse resolved))
      (let* ((actor-name (format "%s" (car actor)))
             (selection (cdr actor))
             (relative-path (godot-pose--get "document" selection))
             (document-path (expand-file-name relative-path base-directory))
             (pose-name (godot-pose--get "pose" selection))
             (pose-document (godot-shot--read-pose-document document-path))
             (_ (godot-pose--validate-document pose-document))
             (poses (godot-pose--get "poses" pose-document))
             (pose-entry (assoc-string pose-name poses))
             (character (godot-pose--get "character" pose-document)))
        (unless pose-entry
          (user-error "Shot actor %s selects missing pose %S in %s"
                      actor-name pose-name relative-path))
        (unless (listp character)
          (user-error "Shot actor %s document has no character object" actor-name))
        (push `(("actor_name" . ,actor-name)
                ("document_path" . ,document-path)
                ("pose_name" . ,pose-name)
                ("character" . ,character)
                ("pose" . ,(cdr pose-entry)))
              resolved)))))

(defun godot-shot-validate ()
  "Validate this shot and every referenced actor pose."
  (interactive)
  (let* ((document (godot-shot--parse-document))
         (specs (godot-shot--actor-specs document)))
    (message "Valid Godot shot document v1; %d actors: %s"
             (length specs)
             (mapconcat (lambda (spec) (godot-pose--get "actor_name" spec))
                        specs ", "))))

(defun godot-pose--endpoint (document &optional endpoint-key)
  "Return (HOST . PORT) from ENDPOINT-KEY in DOCUMENT.
ENDPOINT-KEY defaults to `endpoint', the Godot editor endpoint."
  (let ((endpoint (godot-pose--get (or endpoint-key "endpoint") document)))
    (cons (or (godot-pose--get "host" endpoint) godot-pose-default-host)
          (or (godot-pose--get "port" endpoint) godot-pose-default-port))))

(defun godot-pose--process-live-for-p (process host port)
  "Return non-nil when PROCESS is live and connected to HOST PORT."
  (and (process-live-p process)
       (equal (process-get process 'godot-pose-host) host)
       (equal (process-get process 'godot-pose-port) port)))

(defun godot-pose--ensure-stream (document &optional endpoint-key)
  "Return a persistent stream for ENDPOINT-KEY in DOCUMENT."
  (pcase-let* ((`(,host . ,port) (godot-pose--endpoint document endpoint-key)))
    (unless (godot-pose--process-live-for-p godot-pose--stream-process host port)
      (godot-pose-disconnect)
      (let ((source-buffer (current-buffer)))
        (condition-case error-data
            (setq godot-pose--stream-process
                  (make-network-process
                   :name (format "godot-pose-%s:%s" host port)
                   :buffer (get-buffer-create "*Godot Pose Stream*")
                   :host host
                   :service port
                   :family 'ipv4
                   :coding 'utf-8-unix
                   :nowait nil
                   :noquery t
                   :filter (lambda (process chunk)
                             (godot-pose--stream-filter source-buffer process chunk))
                   :sentinel (lambda (process event)
                               (godot-pose--stream-sentinel source-buffer process event))))
          (file-error
           (user-error
            "Cannot connect to Godot at %s:%s; ensure that endpoint is running (%s)"
            host port (error-message-string error-data))))
        (process-put godot-pose--stream-process 'godot-pose-host host)
        (process-put godot-pose--stream-process 'godot-pose-port port)
        (process-put godot-pose--stream-process 'godot-pose-pending "")))
    godot-pose--stream-process))

(defun godot-pose--stream-filter (source-buffer process chunk)
  "Consume newline-delimited JSON CHUNK from PROCESS for SOURCE-BUFFER."
  (let* ((pending (concat (or (process-get process 'godot-pose-pending) "") chunk))
         (lines (split-string pending "\n"))
         (tail (car (last lines))))
    (process-put process 'godot-pose-pending tail)
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (condition-case nil
            (let* ((reply (json-parse-string line :object-type 'alist :array-type 'list))
                   (type (godot-pose--get "type" reply "message"))
                   (pose-name (godot-pose--get "pose_name" reply)))
              (when (buffer-live-p source-buffer)
                (with-current-buffer source-buffer
                  (setq godot-pose--last-response reply)
                  (when (equal type "pose.captured")
                    (godot-pose--receive-capture process reply))))
              (if pose-name
                  (message "Godot: %s %s" type pose-name)
                (message "Godot pose stream: %s" type)))
          (json-parse-error
           (message "Godot pose stream sent invalid JSON: %s" line)))))))

(defun godot-pose--stream-sentinel (source-buffer process event)
  "Update SOURCE-BUFFER when PROCESS reports EVENT."
  (when (and (buffer-live-p source-buffer)
             (not (process-live-p process)))
    (with-current-buffer source-buffer
      (when (eq godot-pose--stream-process process)
        (setq godot-pose--stream-process nil))))
  (unless (string-match-p "open" event)
    (message "Godot pose stream: %s" (string-trim event))))

(defun godot-pose--request-id ()
  "Create a readable request identifier."
  (format "emacs-%d-%06x" (truncate (* 1000 (float-time))) (random #xFFFFFF)))

(defun godot-pose-dump-editor-pose (pose-name)
  "Capture the current Godot editor pose as POSE-NAME in this document.

The response appends a complete 56-bone FK base, all IK controls, and modifier
states to `poses', makes POSE-NAME active, and leaves the buffer modified for
`C-c C-s'.  It does not save or alter the .tscn scene on disk."
  (interactive
   (list (read-string "Name for current editor pose: "
                      (format-time-string "editor_capture_%Y%m%d_%H%M%S"))))
  (when (string-empty-p (string-trim pose-name))
    (user-error "The captured pose needs a name"))
  (let* ((document (godot-pose--parse-document))
         (_ (godot-pose--validate-document document))
         (poses (godot-pose--get "poses" document))
         (request-id (godot-pose--request-id))
         (character (or (godot-pose--get "character" document) '()))
         (process (godot-pose--ensure-stream document "endpoint")))
    (when (assoc-string pose-name poses)
      (user-error "Pose %S already exists; choose a new capture name" pose-name))
    (process-put process 'godot-pose-capture-request (cons request-id pose-name))
    (process-send-string
     process
     (concat
      (json-encode
       `(("protocol" . "godot-pose-stream")
         ("version" . 1)
         ("type" . "pose.capture")
         ("request_id" . ,request-id)
         ("pose_name" . ,pose-name)
         ("source" . (("application" . "Emacs")
                      ("buffer" . ,(buffer-name))))
         ("character" . ,character)))
      "\n"))
    (message "Requested editor pose %s from Godot…" pose-name)))

(defun godot-pose--receive-capture (process reply)
  "Insert a pose.capture REPLY associated with PROCESS."
  (let* ((pending (process-get process 'godot-pose-capture-request))
         (request-id (godot-pose--get "request_id" reply))
         (pose-name (and pending (cdr pending)))
         (pose (godot-pose--get "pose" reply)))
    (when (and pending
               (equal request-id (car pending))
               (stringp pose-name)
               (listp pose))
      (atomic-change-group
        (godot-pose--append-pose pose-name pose)
        (godot-pose-select-active pose-name))
      (process-put process 'godot-pose-capture-request nil)
      (message "Dumped %s: %s bones, %s IK controls; C-c C-s to save"
               pose-name
               (godot-pose--get "bones_captured" reply "?")
               (godot-pose--get "controls_captured" reply "?")))))

(defun godot-pose--pretty-json (value)
  "Return VALUE as consistently indented JSON."
  (with-temp-buffer
    (insert (json-encode value))
    (json-pretty-print-buffer)
    (buffer-substring-no-properties (point-min) (point-max))))

(defun godot-pose--append-pose (pose-name pose)
  "Append POSE under POSE-NAME to the document's poses object."
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward "\"poses\"[[:space:]]*:[[:space:]]*" nil t)
      (user-error "Cannot find the poses object"))
    (skip-chars-forward " \t\r\n")
    (unless (eq (char-after) ?{)
      (user-error "The poses value is not a JSON object"))
    (let* ((open-position (point))
           (object-end (scan-sexps open-position 1))
           (close-position (and object-end (1- object-end))))
      (unless close-position
        (user-error "Cannot find the end of the poses object"))
      (let* ((existing (string-trim
                        (buffer-substring-no-properties
                         (1+ open-position) close-position)))
             (pose-json (godot-pose--pretty-json pose))
             (indented-pose (replace-regexp-in-string "\n" "\n    " pose-json))
             (entry (concat "    " (json-encode-string pose-name) ": " indented-pose)))
        (if (string-empty-p existing)
            (progn
              (goto-char (1+ open-position))
              (insert "\n" entry "\n  "))
          (goto-char close-position)
          (skip-chars-backward " \t\r\n")
          ;; Insert before the closing brace; inserting after it creates a
          ;; valid root-level property that validation cannot select.
          (insert ",\n" entry))))))

(defun godot-pose-delete-profile (pose-name &optional skip-confirmation)
  "Delete POSE-NAME from the current pose document.

Interactively, select POSE-NAME with the same completing-read idiom used by
`godot-pose-select-active'.  The edit is buffer-local, unsaved, and one-step
undoable.  The last remaining pose cannot be deleted.  If POSE-NAME is active,
the first remaining profile becomes active.

SKIP-CONFIRMATION is intended for automated tests."
  (interactive
   (let* ((document (godot-pose--parse-document))
          (_ (godot-pose--validate-document document))
          (poses (mapcar #'car (godot-pose--get "poses" document)))
          (current (godot-pose--get "active_pose" document)))
     (list (completing-read "Delete Godot pose profile: "
                            poses nil t nil nil current)
           nil)))
  (barf-if-buffer-read-only)
  (let* ((document (godot-pose--parse-document))
         (_ (godot-pose--validate-document document))
         (poses (godot-pose--get "poses" document))
         (pose-names (mapcar #'car poses))
         (active-name (godot-pose--get "active_pose" document))
         (remaining (cl-remove pose-name pose-names :test #'string=)))
    (unless (assoc-string pose-name poses)
      (user-error "Pose profile %S does not exist" pose-name))
    (when (null remaining)
      (user-error "Cannot delete the last pose profile"))
    (when (or skip-confirmation
              (y-or-n-p (format "Delete pose profile %s? " pose-name)))
      (undo-boundary)
      (atomic-change-group
        (godot-pose--delete-pose-entry pose-name)
        (when (string= pose-name active-name)
          (godot-pose-select-active (car remaining))))
      (undo-boundary)
      (message "Deleted pose profile %s; C-/ to undo, C-c C-s to save"
               pose-name))))

(defun godot-pose--poses-object-bounds ()
  "Return the open and close brace positions of the poses object."
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward "\"poses\"[[:space:]]*:[[:space:]]*" nil t)
      (user-error "Cannot find the poses object"))
    (skip-chars-forward " \t\r\n")
    (unless (eq (char-after) ?{)
      (user-error "The poses value is not a JSON object"))
    (let* ((open-position (point))
           (object-end (scan-sexps open-position 1)))
      (unless object-end
        (user-error "Cannot find the end of the poses object"))
      (cons open-position (1- object-end)))))

(defun godot-pose--delete-pose-entry (pose-name)
  "Delete only POSE-NAME's property from the poses JSON object."
  (pcase-let* ((`(,open-position . ,close-position)
                 (godot-pose--poses-object-bounds))
                (property-pattern
                 (concat (regexp-quote (json-encode-string pose-name))
                         "[[:space:]]*:"))
                (expected-depth (1+ (car (syntax-ppss open-position))))
                (property-start nil))
    (goto-char (1+ open-position))
    (while (and (not property-start)
                (re-search-forward property-pattern close-position t))
      (when (= (car (syntax-ppss (match-beginning 0))) expected-depth)
        (setq property-start (match-beginning 0))))
    (unless property-start
      (user-error "Cannot locate pose profile %S in the poses object" pose-name))
    (goto-char (match-end 0))
    (skip-chars-forward " \t\r\n")
    (let* ((value-start (point))
           (value-end (scan-sexps value-start 1))
           (entry-start
            (save-excursion
              (goto-char property-start)
              (let ((line-start (line-beginning-position)))
                (if (string-match-p
                     "\\`[[:space:]]*\\'"
                     (buffer-substring-no-properties line-start property-start))
                    line-start
                  property-start)))))
      (unless value-end
        (user-error "Cannot find the end of pose profile %S" pose-name))
      (goto-char value-end)
      (skip-chars-forward " \t\r\n" close-position)
      (if (eq (char-after) ?,)
          ;; First or middle property: remove its following comma and newline.
          (progn
            (forward-char 1)
            (skip-chars-forward " \t")
            (when (eq (char-after) ?\n)
              (forward-char 1))
            (delete-region entry-start (point)))
        ;; Last property: remove the previous comma with this whole entry.
        (goto-char entry-start)
        (skip-chars-backward " \t\r\n" (1+ open-position))
        (unless (eq (char-before) ?,)
          (user-error "Cannot find a separator before pose profile %S" pose-name))
        (delete-region (1- (point)) value-end)))))

(defun godot-pose-send-active (&optional choose-pose)
  "Send the active pose directly to the currently edited Godot scene.
With prefix argument CHOOSE-POSE, choose the active pose first."
  (interactive "P")
  (godot-pose--send-active-to-endpoint "endpoint" "Godot editor" choose-pose))

(defun godot-pose-send-active-to-runtime (&optional choose-pose)
  "Send the active pose to the optional running game preview.
With prefix argument CHOOSE-POSE, choose the active pose first."
  (interactive "P")
  (godot-pose--send-active-to-endpoint "runtime_endpoint" "Godot runtime" choose-pose))

(defun godot-pose--send-active-to-endpoint (endpoint-key endpoint-label choose-pose)
  "Send the active pose through ENDPOINT-KEY named ENDPOINT-LABEL.
When CHOOSE-POSE is non-nil, choose the active pose first."
  (when choose-pose
    (call-interactively #'godot-pose-select-active))
  (let* ((document (godot-pose--parse-document))
         (active-entry (godot-pose--validate-document document))
         (pose-name (car active-entry))
         (pose (cdr active-entry))
         (character (or (godot-pose--get "character" document) '()))
         (message-object
          `(("protocol" . "godot-pose-stream")
            ("version" . 1)
            ("type" . "pose.apply")
            ("request_id" . ,(godot-pose--request-id))
            ("source" . (("application" . "Emacs")
                         ("buffer" . ,(buffer-name))))
            ("character" . ,character)
            ("pose_name" . ,pose-name)
            ("pose" . ,pose)))
         (process (godot-pose--ensure-stream document endpoint-key)))
    (process-send-string process (concat (json-encode message-object) "\n"))
    (message "Sent pose %s to %s at %s:%s"
             pose-name
             endpoint-label
             (process-get process 'godot-pose-host)
             (process-get process 'godot-pose-port))))

(defun godot-shot-send ()
  "Apply every actor selected by the current shot to the Godot editor."
  (interactive)
  (godot-shot--send-to-endpoint "endpoint" "Godot editor"))

(defun godot-shot-send-to-runtime ()
  "Apply every actor selected by the current shot to the Godot runtime."
  (interactive)
  (godot-shot--send-to-endpoint "runtime_endpoint" "Godot runtime"))

(defun godot-shot--send-to-endpoint (endpoint-key endpoint-label)
  "Send this shot through ENDPOINT-KEY named ENDPOINT-LABEL."
  (let* ((shot-document (godot-shot--parse-document))
         (specs (godot-shot--actor-specs shot-document))
         (process (godot-pose--ensure-stream shot-document endpoint-key)))
    (dolist (spec specs)
      (let ((message-object
             `(("protocol" . "godot-pose-stream")
               ("version" . 1)
               ("type" . "pose.apply")
               ("request_id" . ,(godot-pose--request-id))
               ("source" . (("application" . "Emacs")
                            ("buffer" . ,(buffer-name))
                            ("shot_actor" . ,(godot-pose--get "actor_name" spec))))
               ("character" . ,(godot-pose--get "character" spec))
               ("pose_name" . ,(godot-pose--get "pose_name" spec))
               ("pose" . ,(godot-pose--get "pose" spec)))))
        (process-send-string process (concat (json-encode message-object) "\n"))))
    (message "Sent %d shot actors to %s at %s:%s"
             (length specs)
             endpoint-label
             (process-get process 'godot-pose-host)
             (process-get process 'godot-pose-port))))

(defun godot-pose-select-active (pose-name)
  "Set POSE-NAME as this document's active_pose."
  (interactive
   (let* ((document (godot-pose--parse-document))
          (_ (godot-pose--validate-document document))
          (poses (mapcar #'car (godot-pose--get "poses" document)))
          (current (godot-pose--get "active_pose" document)))
     (list (completing-read "Active Godot pose: " poses nil t nil nil current))))
  (save-excursion
    (goto-char (point-min))
    (unless (re-search-forward
             "\\(\"active_pose\"[[:space:]]*:[[:space:]]*\\)\"[^\"]*\"" nil t)
      (user-error "Cannot find active_pose in this buffer"))
    (replace-match (concat (match-string 1) (json-encode-string pose-name)) t t))
  (message "Active Godot pose: %s (C-c C-e to evaluate)" pose-name))

(defun godot-pose--project-root (document)
  "Resolve DOCUMENT's Godot project root."
  (let* ((base (file-name-directory (or buffer-file-name default-directory)))
         (declared (godot-pose--get "project_root" document))
         (candidate (and declared (expand-file-name declared base))))
    (cond
     ((and candidate (file-exists-p (expand-file-name "project.godot" candidate)))
      (file-name-as-directory candidate))
     ((locate-dominating-file base "project.godot"))
     (t (user-error "Cannot locate project.godot; set project_root in the document")))))

(defun godot-pose-save-to-project ()
  "Save this pose document under its Godot project for Git tracking.
If it is already inside the project, this is a normal `save-buffer'."
  (interactive)
  (let* ((document (godot-pose--parse-document))
         (_ (godot-pose--validate-document document))
         (project-root (file-truename (godot-pose--project-root document)))
         (current (and buffer-file-name (file-truename buffer-file-name))))
    (if (and current (file-in-directory-p current project-root))
        (progn
          (save-buffer)
          (message "Saved Git-trackable pose document: %s" current))
      (let* ((pose-directory (expand-file-name godot-pose-save-directory project-root))
             (default-name (or (and buffer-file-name (file-name-nondirectory buffer-file-name))
                               "character-poses.gdpose"))
             (destination (read-file-name "Save pose document in project: "
                                          pose-directory nil nil default-name)))
        (make-directory (file-name-directory destination) t)
        (write-file destination)
        (message "Saved Git-trackable pose document: %s" destination)))))

(defun godot-shot-save-to-project ()
  "Save this shot document inside its declared Godot project."
  (interactive)
  (let* ((document (godot-shot--parse-document))
         (_ (godot-shot--validate-document document))
         (project-root (file-truename (godot-pose--project-root document)))
         (current (and buffer-file-name (file-truename buffer-file-name))))
    (if (and current (file-in-directory-p current project-root))
        (progn
          (save-buffer)
          (message "Saved Git-trackable shot document: %s" current))
      (let* ((shot-directory (expand-file-name "poses/shots" project-root))
             (default-name (or (and buffer-file-name
                                    (file-name-nondirectory buffer-file-name))
                               "shot-01.gdshot"))
             (destination (read-file-name "Save shot document in project: "
                                          shot-directory nil nil default-name)))
        (make-directory (file-name-directory destination) t)
        (write-file destination)
        (message "Saved Git-trackable shot document: %s" destination)))))

(defun godot-pose-run-preview ()
  "Start the Godot runtime scene declared by this pose document."
  (interactive)
  (let* ((document (godot-pose--parse-document))
         (_ (godot-pose--validate-document document))
         (project-root (godot-pose--project-root document))
         (scene (or (godot-pose--get "preview_scene" document)
                    "res://demos/my_manual_rig_pose.tscn"))
         (log-buffer (get-buffer-create "*Godot Pose Preview*")))
    (when (process-live-p godot-pose--preview-process)
      (user-error "A Godot pose preview is already running"))
    (setq godot-pose--preview-process
          (start-process "godot-pose-preview" log-buffer
                         godot-pose-godot-executable
                         "--path" project-root
                         "--scene" scene))
    (set-process-query-on-exit-flag godot-pose--preview-process nil)
    (message "Started Godot pose preview: %s" scene)))

(defun godot-shot-run-preview ()
  "Start the Godot runtime scene declared by this shot document."
  (interactive)
  (let* ((document (godot-shot--parse-document))
         (_ (godot-shot--actor-specs document))
         (project-root (godot-pose--project-root document))
         (scene (or (godot-pose--get "preview_scene" document)
                    "res://demos/my_manual_rig_pose.tscn"))
         (log-buffer (get-buffer-create "*Godot Pose Preview*")))
    (when (process-live-p godot-pose--preview-process)
      (user-error "A Godot pose preview is already running"))
    (setq godot-pose--preview-process
          (start-process "godot-pose-preview" log-buffer
                         godot-pose-godot-executable
                         "--path" project-root
                         "--scene" scene))
    (set-process-query-on-exit-flag godot-pose--preview-process nil)
    (message "Started Godot shot preview: %s" scene)))

(defun godot-pose-disconnect ()
  "Close this buffer's persistent Godot pose stream."
  (interactive)
  (when (process-live-p godot-pose--stream-process)
    (delete-process godot-pose--stream-process))
  (setq godot-pose--stream-process nil)
  (when (called-interactively-p 'interactive)
    (message "Godot pose stream disconnected")))

(provide 'godot-pose-mode)

;;; godot-pose-mode.el ends here
