;;; female-walk-camera-program.el --- Example moving-work-coordinate shot -*- lexical-binding: t; -*-

;; Evaluate this buffer, frame the female in Godot viewport 1, then run:
;;
;;   M-x ots-female-walk-camera-shot
;;
;; The current framing becomes work zero.  Every move below is evaluated in
;; IK_character's moving coordinate, so the walk carries the camera while the
;; authored dolly/curve/orbit remains stable and repeatable.

(require 'godot-camera-control)

(defun ots-female-walk-camera-shot ()
  "Follow the walking female while executing a gentle director-authored move."
  (interactive)
  (godot-camera-confirm-follow :target-node "IK_character" :viewport 1)
  (godot-camera-program-begin
   :name "female-walk-exhibition-hall-01"
   :target-node "IK_character"
   :viewport 1
   :loop nil)
  (godot-walk-restart)
  (godot-camera-g4 :seconds 0.5)
  ;; Absolute offset from the camera framing confirmed above.
  (godot-camera-g1 :x 0.25 :y 0.06 :z -0.18
                   :duration 2.0 :easing 'smooth)
  ;; The two controls are also absolute offsets from work zero.
  (godot-camera-g5 :x 0.55 :y 0.12 :z -0.35
                   :control1 '(0.32 0.07 -0.21)
                   :control2 '(0.48 0.11 -0.31)
                   :duration 2.5 :easing 'smoother)
  ;; Orbit clockwise while retaining the walking character as moving origin.
  (godot-camera-g2-orbit :degrees 360.0
                         :pivot '(0.0 1.2 0.0)
                         :duration 10.0 :easing 'smooth)
  (godot-camera-g4 :seconds 0.75)
  (godot-camera-send-program :play t))




(defun ots-female-walk-camera-shot2 ()
  "Record a synchronized female walking camera take."
  (interactive)

  ;; Establish the camera work coordinate.
  (godot-camera-confirm-follow
   :target-node "IK_character"
   :viewport 1)

  ;; Build and load the camera program without starting it.
  (godot-camera-program-begin
   :name "female-walk-exhibition-hall-01"
   :target-node "IK_character"
   :viewport 1
   :loop nil)

  (godot-camera-g4 :seconds 0.5)

  (godot-camera-g1
   :x -0.3561
   :y -0.0377
   :z 1.2961
   :duration 1.0
   :easing 'smooth)

  (godot-camera-g2-orbit
   :degrees 360.0
   :pivot '(0.0 1.2 0.0)
   :duration 7.0
   :easing 'smooth)

  (godot-camera-g4 :seconds 0.75)

  (godot-camera-send-program :play nil)

  ;; Enter fixed-step capture before either timeline starts.
  (godot-walk-record-camera-motion
   :duration 10.0
   :fps 24
   :resolution '(1280 720)
   :start-delay 0.1
   :keep-frames nil
   :viewport 1)

  ;; These are now adopted by the recorder's fixed-step clock.
  (godot-walk-restart)
  (godot-camera-play t))



(provide 'female-walk-camera-program)

;;; female-walk-camera-program.el ends here




(defun reset-female-character ()
  (godot-camera-release-follow)
  (godot-walk-restart)
  (godot-walk-pause)
  (godot-camera-restore-initial-view)
  )


(reset-female-character)
(ots-female-walk-camera-shot2)


(godot-walk-status)


(godot-walk-play)

(godot-walk-pause)
(godot-walk-restart)

(godot-walk-refresh-trajectory)
(godot-walk-record-camera-motion)

(godot-camera-release-follow)
