;;; godot-camera-control.el --- Script Godot's editor camera from Emacs -*- lexical-binding: t; -*-

;; Copyright (C) 2026
;; Author: Codex
;; Version: 0.2.0
;; Package-Requires: ((emacs "27.1"))
;; Keywords: tools, games, godot, camera

;;; Commentary:

;; This library treats a moving Godot character as a LinuxCNC-style work
;; coordinate.  Confirming follow makes the current editor camera G54/work
;; zero.  A program then adds repeatable camera moves in character-local space:
;; X is right, Y is up, and Z is back (negative Z moves forward).
;;
;; Write normal Emacs Lisp, evaluate it with `C-M-x' or `eval-buffer', and run
;; the resulting interactive function.  No .gdpose buffer is required.
;; The same connection also exposes all five FemaleWalkController Editor
;; Transport actions as deterministic, acknowledged Emacs commands.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defgroup godot-camera nil
  "Program the Godot 4 editor camera from Emacs."
  :group 'tools
  :prefix "godot-camera-")

(defcustom godot-camera-host "127.0.0.1"
  "Host used by the Godot editor pose/camera bridge."
  :type 'string
  :group 'godot-camera)

(defcustom godot-camera-port 7007
  "Port used by the Godot editor pose/camera bridge."
  :type 'integer
  :group 'godot-camera)

(defcustom godot-camera-default-target "IK_character"
  "Scene-relative NodePath used as the moving camera work coordinate."
  :type 'string
  :group 'godot-camera)

(defcustom godot-camera-walk-controller "FemaleWalkController"
  "Scene-relative NodePath of the editor walk transport controller."
  :type 'string
  :group 'godot-camera)

(defcustom godot-character-node "IK_character"
  "Scene-relative character node used by the pose-stream commands."
  :type 'string
  :group 'godot-camera)

(defcustom godot-character-skeleton "Skeleton3D"
  "Skeleton path below `godot-character-node'."
  :type 'string
  :group 'godot-camera)

(defcustom godot-character-controls "../PoseControls"
  "IK controls path below the character skeleton."
  :type 'string
  :group 'godot-camera)

(defcustom godot-collapse-python
  "/Users/hotcat/miniconda3/envs/sam_3d_body/bin/python"
  "Python executable used to stream a cached collapse motion."
  :type 'file
  :group 'godot-camera)

(defcustom godot-collapse-stream-script
  "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/tools/video_to_pose_stream.py"
  "Pose-stream Python script used by `godot-character-start-collapse'."
  :type 'file
  :group 'godot-camera)

(defcustom godot-collapse-cache
  "/Users/hotcat/Downloads/Godot-4-Advanced Locomotion Tutorial/ik-demo-4.6/renders/mocap/girl_collapse_lean_wall_6s_final/motion_pose_frames_vertical.json"
  "Default cached collapse motion streamed by Emacs."
  :type 'file
  :group 'godot-camera)

(defvar godot-collapse--process nil
  "The currently running cached collapse stream process.")

(defvar godot-camera--process nil)
(defvar godot-camera--last-response nil)
(defvar godot-camera--program-name "emacs-camera-program")
(defvar godot-camera--program-loop nil)
(defvar godot-camera--program-target nil)
(defvar godot-camera--program-viewport 1)
(defvar godot-camera--commands nil)
(defvar godot-camera--initial-view nil
  "Character-relative initial camera view for the current program.

The canonical orientation representation is a quaternion XYZW.  A
rotation_degrees fallback is retained for hand-authored legacy programs.")

(defun godot-camera--request-id ()
  "Return a readable unique request identifier."
  (format "emacs-camera-%d-%06x"
          (truncate (* 1000 (float-time))) (random #xFFFFFF)))

(defun godot-camera--connected-p ()
  "Return non-nil when the persistent editor connection is usable."
  (and (process-live-p godot-camera--process)
       (equal (process-get godot-camera--process 'godot-camera-host)
              godot-camera-host)
       (equal (process-get godot-camera--process 'godot-camera-port)
              godot-camera-port)))

(defun godot-camera--ensure-connection ()
  "Return the persistent TCP connection, opening it when necessary."
  (unless (godot-camera--connected-p)
    (godot-camera-disconnect)
    (condition-case error-data
        (setq godot-camera--process
              (make-network-process
               :name (format "godot-camera-%s:%s"
                             godot-camera-host godot-camera-port)
               :buffer (get-buffer-create "*Godot Camera Control*")
               :host godot-camera-host
               :service godot-camera-port
               :family 'ipv4
               :coding 'utf-8-unix
               :nowait nil
               :noquery t
               :filter #'godot-camera--filter
               :sentinel #'godot-camera--sentinel))
      (file-error
       (user-error "Cannot connect to the Godot editor at %s:%s (%s)"
                   godot-camera-host godot-camera-port
                   (error-message-string error-data))))
    (process-put godot-camera--process 'godot-camera-host godot-camera-host)
    (process-put godot-camera--process 'godot-camera-port godot-camera-port)
    (process-put godot-camera--process 'godot-camera-pending ""))
  godot-camera--process)

(defun godot-camera--filter (process chunk)
  "Consume newline-delimited JSON CHUNK from PROCESS."
  (let* ((pending (concat (or (process-get process 'godot-camera-pending) "")
                          chunk))
         (lines (split-string pending "\n"))
         (tail (car (last lines))))
    (process-put process 'godot-camera-pending tail)
    (dolist (line (butlast lines))
      (unless (string-empty-p (string-trim line))
        (condition-case nil
            (let* ((reply (json-parse-string line
                                             :object-type 'alist
                                             :array-type 'list))
                   (type (alist-get 'type reply "message")))
              (setq godot-camera--last-response reply)
              (cond
               ((equal type "error")
                (message "Godot director error: %s"
                         (alist-get 'error reply "unknown")))
               ((string-prefix-p "walk." type)
                (message "Godot %s: %s at %.3fs; path %.2fm; recording %s"
                         type
                         (if (eq (alist-get 'playing reply) t)
                             "playing" "paused")
                         (or (alist-get 'preview_time_seconds reply) 0.0)
                         (or (alist-get 'trajectory_length_m reply) 0.0)
                         (if (eq (alist-get 'camera_recording_active reply) t)
                             "active" "idle")))
               (t
                (message "Godot camera: %s" type))))
          (json-parse-error
           (message "Godot camera bridge sent invalid JSON: %s" line)))))))

(defun godot-camera--sentinel (_process event)
  "Report a camera transport EVENT."
  (unless (string-match-p "open" event)
    (message "Godot camera connection: %s" (string-trim event))))

(defun godot-camera--send (type &rest properties)
  "Send message TYPE with JSON PROPERTIES to the Godot editor."
  (let ((message `(("protocol" . "godot-pose-stream")
                   ("version" . 1)
                   ("type" . ,type)
                   ("request_id" . ,(godot-camera--request-id))
                   ,@properties)))
    (process-send-string (godot-camera--ensure-connection)
                         (concat (json-encode message) "\n"))))

(defun godot-camera--vector3 (value label)
  "Convert three-number VALUE to a JSON vector, identifying it as LABEL."
  (unless (and (sequencep value) (= (length value) 3)
               (cl-every #'numberp value))
    (user-error "%s must contain exactly three numbers" label))
  (vconcat value))

(defun godot-camera--vector4 (value label)
  "Convert four-number VALUE to a JSON vector, identifying it as LABEL."
  (unless (and (sequencep value) (= (length value) 4)
               (cl-every #'numberp value))
    (user-error "%s must contain exactly four numbers" label))
  (vconcat value))

(defun godot-camera--vector2 (value label)
  "Convert two-number VALUE to a JSON vector, identifying it as LABEL."
  (unless (and (sequencep value) (= (length value) 2)
               (cl-every #'numberp value))
    (user-error "%s must contain exactly two numbers" label))
  (vconcat value))

(defun godot-camera--easing-name (easing)
  "Convert EASING symbol or string to its protocol name."
  (replace-regexp-in-string "-" "_" (downcase (format "%s" easing))))

(defun godot-camera--append-command (command)
  "Append COMMAND to the current builder and return it."
  (setq godot-camera--commands
        (append godot-camera--commands (list command)))
  command)

;;;###autoload
(cl-defun godot-camera-confirm-follow
    (&key (target-node godot-camera-default-target) (viewport 1))
  "Make the current editor camera work zero relative to TARGET-NODE.

VIEWPORT is the human-facing 1-based editor viewport number.  The character's
translation and heading are inherited until `godot-camera-release-follow'."
  (interactive)
  (unless (and (integerp viewport) (<= 1 viewport 4))
    (user-error "Viewport must be an integer from 1 through 4"))
  (godot-camera--send
   "camera.follow.confirm"
   `("options" . (("target_node" . ,target-node)
                   ("viewport_index" . ,(1- viewport)))))
  (message "Asked Godot to confirm viewport %d camera work zero" viewport))

;;;###autoload
(cl-defun godot-camera-program-begin
    (&key (name "emacs-camera-program") loop
          (target-node godot-camera-default-target) (viewport 1))
  "Begin building a camera program named NAME.

LOOP repeats the timeline.  TARGET-NODE supplies the moving coordinate, and
VIEWPORT is 1-based.  This only edits Emacs state; call
`godot-camera-send-program' to transmit it."
  (interactive)
  (setq godot-camera--program-name name
        godot-camera--program-loop loop
        godot-camera--program-target target-node
        godot-camera--program-viewport viewport
        godot-camera--commands nil
        godot-camera--initial-view nil)
  (message "Started empty Godot camera program %s" name))

(defun godot-camera-program-clear ()
  "Clear the Emacs-side program builder without changing Godot."
  (interactive)
  (setq godot-camera--commands nil
        godot-camera--initial-view nil)
  (message "Cleared the Emacs camera-program builder"))

;;;###autoload
(cl-defun godot-camera-set-initial-view
    (&key position quaternion x y z pitch roll yaw rotation-degrees)
  "Set the reproducible initial camera view for the current program.

POSITION is character-local `(X Y Z)'.  Prefer QUATERNION `(X Y Z W)' for
orientation because it is the exact, gimbal-lock-free representation.  For
readability, X/Y/Z plus PITCH/ROLL/YAW or ROTATION-DEGREES are accepted as a
fallback; Godot converts that legacy form once when it receives the program.
This edits Emacs state only; `godot-camera-send-program' transmits it."
  (interactive)
  (let* ((resolved-position (or position (list (or x 0.0) (or y 0.0) (or z 0.0))))
         (view (list (cons "position"
                           (godot-camera--vector3 resolved-position "position")))))
    (cond
     (quaternion
      (push (cons "quaternion_xyzw"
                  (godot-camera--vector4 quaternion "quaternion")) view))
     ((or rotation-degrees pitch roll yaw)
      (let ((degrees (or rotation-degrees
                         (list (or pitch 0.0) (or yaw 0.0) (or roll 0.0)))))
        (push (cons "rotation_degrees"
                    (godot-camera--vector3 degrees "rotation-degrees")) view)))
     (t
      (user-error "Provide :quaternion or :rotation-degrees (or :pitch/:roll/:yaw)")))
    (setq godot-camera--initial-view (nreverse view))
    (message "Set quaternion-safe initial camera view for %s" godot-camera--program-name)
    godot-camera--initial-view))

;;;###autoload
(defun godot-camera-restore-initial-view ()
  "Immediately restore the last initial view stored by Emacs or Godot."
  (interactive)
  (godot-camera--send "camera.view.restore")
  (message "Asked Godot to restore the initial camera view"))

(cl-defun godot-camera-g0 (&key (x 0.0) (y 0.0) (z 0.0)
                                 rotation-degrees)
  "Append an instantaneous move to absolute work offset X Y Z."
  (godot-camera--append-command
   (append `(("kind" . "g0") ("to" . [,x ,y ,z]))
           (when rotation-degrees
             `(("rotation_degrees" .
                ,(godot-camera--vector3 rotation-degrees
                                        "rotation-degrees")))))))

(cl-defun godot-camera-g1
    (&key (x 0.0) (y 0.0) (z 0.0) duration feed-mps
          (easing 'smooth) rotation-degrees)
  "Append a linear move to absolute work offset X Y Z.

Specify DURATION in seconds or omit it to derive time from FEED-MPS."
  (godot-camera--append-command
   (append `(("kind" . "g1")
             ("to" . [,x ,y ,z])
             ("easing" . ,(godot-camera--easing-name easing)))
           (when duration `(("duration" . ,duration)))
           (when feed-mps `(("feed_mps" . ,feed-mps)))
           (when rotation-degrees
             `(("rotation_degrees" .
                ,(godot-camera--vector3 rotation-degrees
                                        "rotation-degrees")))))))

(cl-defun godot-camera-g5
    (&key (x 0.0) (y 0.0) (z 0.0) control1 control2 duration feed-mps
          (easing 'smooth) rotation-degrees)
  "Append a cubic Bezier move to absolute work offset X Y Z.

CONTROL1 and CONTROL2 are absolute character-local work coordinates, not
relative handle deltas."
  (godot-camera--append-command
   (append `(("kind" . "g5")
             ("to" . [,x ,y ,z])
             ("easing" . ,(godot-camera--easing-name easing)))
           (when control1
             `(("control1" . ,(godot-camera--vector3 control1 "control1"))))
           (when control2
             `(("control2" . ,(godot-camera--vector3 control2 "control2"))))
           (when duration `(("duration" . ,duration)))
           (when feed-mps `(("feed_mps" . ,feed-mps)))
           (when rotation-degrees
             `(("rotation_degrees" .
                ,(godot-camera--vector3 rotation-degrees
                                        "rotation-degrees")))))))

(cl-defun godot-camera--orbit
    (kind &key degrees (pitch 0.0) (radius-delta 0.0) (height-delta 0.0)
          (pivot '(0.0 1.2 0.0)) (duration 1.0) (easing 'smooth))
  "Append orbit KIND using the supplied camera and pivot parameters."
  (unless (numberp degrees)
    (user-error "Orbit :degrees is required and must be a number"))
  (godot-camera--append-command
   `(("kind" . ,kind)
     ("yaw_degrees" . ,degrees)
     ("pitch_degrees" . ,pitch)
     ("radius_delta" . ,radius-delta)
     ("height_delta" . ,height-delta)
     ("pivot" . ,(godot-camera--vector3 pivot "pivot"))
     ("duration" . ,duration)
     ("easing" . ,(godot-camera--easing-name easing)))))

(cl-defun godot-camera-g2-orbit
    (&key degrees (pitch 0.0) (radius-delta 0.0) (height-delta 0.0)
          (pivot '(0.0 1.2 0.0)) (duration 1.0) (easing 'smooth))
  "Append a clockwise orbit around a character-local PIVOT."
  (godot-camera--orbit "g2" :degrees degrees :pitch pitch
                       :radius-delta radius-delta :height-delta height-delta
                       :pivot pivot :duration duration :easing easing))

(cl-defun godot-camera-g3-orbit
    (&key degrees (pitch 0.0) (radius-delta 0.0) (height-delta 0.0)
          (pivot '(0.0 1.2 0.0)) (duration 1.0) (easing 'smooth))
  "Append a counter-clockwise orbit around a character-local PIVOT."
  (godot-camera--orbit "g3" :degrees degrees :pitch pitch
                       :radius-delta radius-delta :height-delta height-delta
                       :pivot pivot :duration duration :easing easing))

(cl-defun godot-camera-g4 (&key (seconds 1.0))
  "Append a dwell of SECONDS while still inheriting character motion."
  (godot-camera--append-command
   `(("kind" . "g4") ("duration" . ,seconds))))

(defun godot-camera-current-program ()
  "Return the currently built program as a JSON-ready alist."
  `(("name" . ,godot-camera--program-name)
    ("loop" . ,(if godot-camera--program-loop t :json-false))
    ("target_node" . ,(or godot-camera--program-target
                           godot-camera-default-target))
    ("viewport_index" . ,(1- godot-camera--program-viewport))
    ,@(when godot-camera--initial-view
        `(("initial_view" . ,godot-camera--initial-view)))
    ("commands" . ,(vconcat godot-camera--commands))))

;;;###autoload
(cl-defun godot-camera-send-program (&key (play t))
  "Send the current builder to Godot; PLAY starts it immediately."
  (interactive)
  (unless godot-camera--commands
    (user-error "The camera program is empty"))
  (godot-camera--send
   "camera.program.load"
   `("auto_play" . ,(if play t :json-false))
   `("program" . ,(godot-camera-current-program)))
  (message "Sent %s with %d camera commands%s"
           godot-camera--program-name (length godot-camera--commands)
           (if play " and started playback" "")))

(defun godot-camera-play (&optional restart)
  "Play the loaded Godot program; with prefix RESTART, start at zero."
  (interactive "P")
  (godot-camera--send "camera.program.play"
                      `("restart" . ,(if restart t :json-false))))

(defun godot-camera-pause ()
  "Pause the camera timeline, retaining its current offset."
  (interactive)
  (godot-camera--send "camera.program.pause"))

(defun godot-camera-reset ()
  "Pause and reset the loaded camera program to work zero."
  (interactive)
  (godot-camera--send "camera.program.reset"))

(defun godot-camera-clear-remote-program ()
  "Clear Godot's program while leaving fixed character follow active."
  (interactive)
  (godot-camera--send "camera.program.clear"))

(defun godot-camera-status ()
  "Request current follow/program state from Godot."
  (interactive)
  (godot-camera--send "camera.program.status"))

(defun godot-camera-release-follow ()
  "Release character follow, leaving the camera at its current transform."
  (interactive)
  (godot-camera--send "camera.follow.stop"))

(defun godot-walk--send (type &rest properties)
  "Send walk transport message TYPE to `godot-camera-walk-controller'."
  (apply #'godot-camera--send
         type
         (cons `("controller_node" . ,godot-camera-walk-controller)
               properties)))

(defun godot-character--spec ()
  "Return the pose-stream character specification for this scene."
  `(("node_path" . ,godot-character-node)
    ("skeleton_path" . ,godot-character-skeleton)
    ("controls_path" . ,godot-character-controls)))

;;;###autoload
(cl-defun godot-character-set-initial-position
    (&key (x -0.59765434) (y 0.0549866) (z 3.245457)
          (pitch 0.0) (yaw 0.0) (roll 0.0) rotation-degrees)
  "Place the character and reset its pose in the Godot editor.

X, Y, and Z are scene-parent coordinates.  PITCH, YAW, and ROLL are degrees
in Godot's X/Y/Z order.  ROTATION-DEGREES, when supplied, must be a three
number list and overrides the individual angle keywords.  This command only
sets the initial transform; motion-stream root offsets are applied later
relative to this position."
  (interactive
   (list :x (read-number "Initial X: " -0.59765434)
         :y (read-number "Initial Y: " 0.0549866)
         :z (read-number "Initial Z: " 3.245457)
         :yaw (read-number "Initial yaw degrees: " 0.0)))
  (let* ((rotation (or rotation-degrees (vector pitch yaw roll)))
         (pose `(("mode" . "fk")
                 ("reset_to_rest" . t)
                 ("character_transform"
                  ("position" . ,(vector x y z))
                  ("rotation_degrees" . ,(vconcat rotation))))))
    (unless (and (sequencep rotation) (= (length rotation) 3)
                 (cl-every #'numberp rotation))
      (user-error "rotation-degrees must contain exactly three numbers"))
    ;; Keep this as one request so the server resets its root-motion base
    ;; before the next external stream starts.
    (godot-camera--send "pose.apply"
                        `("character" . ,(godot-character--spec))
                        `("pose" . ,pose))
    (message "Godot character initial transform set to (%s, %s, %s)"
             x y z)))

;;;###autoload
(cl-defun godot-character-start-collapse
    (&key cache (position nil) (rotation-degrees nil) (reset t))
  "Set the character start transform and stream a cached collapse.

CACHE defaults to `godot-collapse-cache'.  POSITION is an optional
`(X Y Z)' scene-parent location.  ROTATION-DEGREES is an optional `(X Y Z)'
Euler rotation.  When RESET is non-nil, the initial transform is sent before
the cache begins.  The cache owns the subsequent vertical root motion, so do
not bake the starting world position into every frame."
  (interactive
   (list :cache (read-file-name "Collapse cache: " nil godot-collapse-cache t)
         :position (when current-prefix-arg
                     (list (read-number "Initial X: " -0.59765434)
                           (read-number "Initial Y: " 0.0549866)
                           (read-number "Initial Z: " 3.245457)))))
  (let* ((cache-path (expand-file-name (or cache godot-collapse-cache)))
         (location (or position '(-0.59765434 0.0549866 3.245457)))
         (rotation (or rotation-degrees '(0.0 0.0 0.0))))
    (unless (file-readable-p cache-path)
      (user-error "Collapse cache is not readable: %s" cache-path))
    (unless (and (sequencep location) (= (length location) 3)
                 (cl-every #'numberp location))
      (user-error "position must contain exactly three numbers"))
    (unless (and (sequencep rotation) (= (length rotation) 3)
                 (cl-every #'numberp rotation))
      (user-error "rotation-degrees must contain exactly three numbers"))
    (godot-female-walk-set-motion-source 'external-pose)
    (when reset
      (godot-character-set-initial-position
       :x (nth 0 location) :y (nth 1 location) :z (nth 2 location)
       :rotation-degrees rotation))
    (when (process-live-p godot-collapse--process)
      (delete-process godot-collapse--process))
    (setq godot-collapse--process
          (apply #'start-process
                 "godot-collapse-stream"
                 (get-buffer-create "*Godot Collapse Stream*")
                 godot-collapse-python
                 (list godot-collapse-stream-script
                       "--stream-cache" cache-path
                       "--host" godot-camera-host
                       "--port" (number-to-string godot-camera-port)
                       "--character-path" godot-character-node
                       "--skeleton-path" godot-character-skeleton
                       "--controls-path" godot-character-controls)))
    (set-process-query-on-exit-flag godot-collapse--process nil)
    (message "Started collapse stream: %s" (file-name-nondirectory cache-path))))

;;;###autoload
(defun godot-character-stop-collapse ()
  "Stop the Emacs-launched collapse stream, if one is running."
  (interactive)
  (if (process-live-p godot-collapse--process)
      (progn
        (delete-process godot-collapse--process)
        (setq godot-collapse--process nil)
        (message "Stopped collapse stream"))
    (message "No collapse stream is running")))

;; Short names are convenient in shot files while the long names remain
;; discoverable through M-x and describe-function.
(defalias 'godot-set-character-initial-position
  #'godot-character-set-initial-position)
(defalias 'godot-start-collapse #'godot-character-start-collapse)
(defalias 'godot-stop-collapse #'godot-character-stop-collapse)

;;;###autoload
(defun godot-female-walk-play ()
  "Play FemaleWalkController's editor preview from its current time."
  (interactive)
  (godot-walk--send "walk.play"))

;;;###autoload
(defun godot-female-walk-pause ()
  "Pause FemaleWalkController's editor preview at its current time."
  (interactive)
  (godot-walk--send "walk.pause"))

;;;###autoload
(defun godot-female-walk-restart ()
  "Return the female to time zero and immediately play the walk preview."
  (interactive)
  (godot-walk--send "walk.restart"))

;;;###autoload
(defun godot-female-walk-refresh-trajectory ()
  "Re-read the scene trajectory markers and re-evaluate the current frame."
  (interactive)
  (godot-walk--send "walk.refresh_trajectory"))

(defun godot-walk--motion-source-name (source)
  "Normalize SOURCE to the Godot motion-source protocol name."
  (let ((name (cond ((symbolp source) (symbol-name source))
                    ((stringp source) source)
                    (t nil))))
    (unless name
      (user-error ":motion-source must be walk-cycle, stationary, or external-pose"))
    (setq name (replace-regexp-in-string "-" "_" (downcase name)))
    (pcase name
      ((or "walk" "walk_cycle" "gait") "walk_cycle")
      ((or "stationary" "still" "static") "stationary")
      ((or "external" "external_pose" "pose" "retargeted") "external_pose")
      (_ (user-error "Unknown :motion-source %s" source)))))

;;;###autoload
(defun godot-female-walk-set-motion-source (source)
  "Set the controller's pose owner to SOURCE."
  (interactive (list (intern (completing-read "Motion source: "
                                               '("walk-cycle" "stationary" "external-pose")
                                               nil t))))
  (godot-walk--send "walk.motion_source.set"
                    `("source" . ,(godot-walk--motion-source-name source))))

;;;###autoload
(cl-defun godot-female-walk-record-camera-motion
    (&key duration fps resolution start-delay (keep-frames :unspecified)
          viewport (auto-clip-to-camera-program :unspecified)
          (program-end-padding 0.0) motion-source)
  "Start or stop OTS editor-camera recording with optional capture settings.

DURATION is seconds, FPS is one of 12/24/30, RESOLUTION is `(WIDTH HEIGHT)',
START-DELAY is seconds, KEEP-FRAMES retains source JPEGs, and VIEWPORT is the
human-facing 1-based editor viewport number.  AUTO-CLIP-TO-CAMERA-PROGRAM uses
the loaded camera program's duration.  PROGRAM-END-PADDING adds a final hold;
use zero to stop exactly at the program end, or a negative value to clip early.
MOTION-SOURCE selects the motion owner for this take: `walk-cycle' keeps the
legacy gait evaluator active, `stationary' freezes the current character pose
and root transform, and `external-pose' yields pose ownership to pose.apply or
pose.frame retargeting.  The source is sent with the recording request so a
shot function does not depend on stale editor state.
The symbol `camera-program' is also accepted as DURATION shorthand.  Omitting
all options preserves the dock's current values.  Calling the function while
recording still stops the active take."
  (interactive)
  (let* ((program-duration-p (eq duration 'camera-program))
         (auto-option-specified (not (eq auto-clip-to-camera-program :unspecified)))
         (auto-clip (or program-duration-p
                        (and auto-option-specified auto-clip-to-camera-program)))
         (options nil))
    (when (and duration (not program-duration-p))
      (unless (numberp duration)
        (user-error ":duration must be a number or the symbol camera-program"))
      (push `("duration" . ,duration) options))
    (when (or duration auto-option-specified)
      (push `("auto_clip_to_camera_program" . ,(if auto-clip t :json-false)) options))
    (when auto-clip
      (push `("program_end_padding" . ,program-end-padding) options))
    (when fps (push `("fps" . ,fps) options))
    (when resolution
      (push `("resolution" . ,(godot-camera--vector2 resolution "resolution")) options))
    (when start-delay (push `("start_delay" . ,start-delay) options))
    (unless (eq keep-frames :unspecified)
      (push `("keep_frames" . ,(if keep-frames t :json-false)) options))
    (when viewport (push `("viewport" . ,viewport) options))
    (when motion-source
      (push `("motion_source" . ,(godot-walk--motion-source-name motion-source)) options))
    (if options
        (godot-walk--send "walk.record_camera_motion"
                          `("options" . ,options))
      (godot-walk--send "walk.record_camera_motion"))))

(defun godot-female-walk-status ()
  "Request the observed FemaleWalkController transport state from Godot."
  (interactive)
  (godot-walk--send "walk.status"))

;; Concise aliases are convenient in shot functions while the longer names
;; remain easy to discover with M-x completion.
(defalias 'godot-walk-play #'godot-female-walk-play)
(defalias 'godot-walk-pause #'godot-female-walk-pause)
(defalias 'godot-walk-restart #'godot-female-walk-restart)
(defalias 'godot-walk-refresh-trajectory
  #'godot-female-walk-refresh-trajectory)
(defalias 'godot-walk-set-motion-source
  #'godot-female-walk-set-motion-source)
(defalias 'godot-walk-record-camera-motion
  #'godot-female-walk-record-camera-motion)
(defalias 'godot-walk-status #'godot-female-walk-status)

(defun godot-camera-disconnect ()
  "Close the persistent Emacs-to-Godot camera connection."
  (interactive)
  (when (process-live-p godot-camera--process)
    (delete-process godot-camera--process))
  (setq godot-camera--process nil))

(provide 'godot-camera-control)

;;; godot-camera-control.el ends here
