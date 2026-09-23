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
  (interactive)

  (godot-camera-confirm-follow
   :target-node "IK_character"
   :viewport 1)

  (godot-camera-program-begin
   :name "female-walk-exhibition-hall-01"
   :target-node "IK_character"
   :viewport 1
   :loop nil)

  (godot-camera-g4 :seconds 0.5)

  (godot-camera-g1
   :x -0.3561 :y -0.0377 :z 1.2961
   :duration 1.0
   :easing 'smooth)

  (godot-camera-g2-orbit
   :degrees 180.0
   :pivot '(0.0 1.2 0.0)
   :duration 7.0
   :easing 'smooth)

  (godot-camera-g4 :seconds 0.75)

  ;; Auto-duration needs the program loaded before recording starts.
  (godot-camera-send-program :play nil)

  (godot-walk-record-camera-motion
   :auto-clip-to-camera-program t
   :program-end-padding 0.0
   :fps 24
   :start-delay 0.1
   :viewport 1)

  ;; (godot-walk-restart)
  (godot-camera-play t))



(defun ots-female-walk-camera-shot3 ()
  (interactive)

  (godot-camera-confirm-follow
   :target-node "IK_character"
   :viewport 1)

  (godot-camera-program-begin
   :name "female-walk-exhibition-hall-01"
   :target-node "IK_character"
   :viewport 1
   :loop nil)

  (godot-camera-g4 :seconds 0.5)

  (godot-camera-g1 :x 5.6132 :y -1.6447 :z 0.9884
		   :duration 4.0
		   :easing 'smooth)

  (godot-camera-g2-orbit
   :degrees 90.0
   :pivot '(0.0 1.2 0.0)
   :duration 5.0
   :easing 'smooth)

  (godot-camera-g4 :seconds 0.75)

  ;; Auto-duration needs the program loaded before recording starts.
  (godot-camera-send-program :play nil)


  (godot-walk-record-camera-motion
   :motion-source 'stationary
   :auto-clip-to-camera-program t
   :program-end-padding 0.0
   :fps 24
   :start-delay 0.1
   :viewport 1)

  ;; (godot-walk-restart)
  (godot-camera-play t))



(provide 'female-walk-camera-program)

;;; female-walk-camera-program.el ends here




(defun reset-female-character ()
  (godot-camera-release-follow)
  (godot-walk-restart)
  (godot-walk-pause)
  (godot-camera-restore-initial-view)
  )


(defun reset-female-character2 ()
  (godot-camera-release-follow)
  (godot-camera-restore-initial-view)
  )


(reset-female-character)
(reset-female-character2)
(ots-female-walk-camera-shot2)
(ots-female-walk-camera-shot3)


(godot-walk-status)


(godot-walk-play)

(godot-walk-pause)
(godot-walk-restart)

(godot-walk-refresh-trajectory)
(godot-walk-record-camera-motion)

(godot-camera-release-follow)



(godot-camera-set-initial-view :position '(-1.587332 4.953933 8.858178) :quaternion '(-0.248334482 -0.013592960 -0.001011713 0.968578458))


(godot-character-set-initial-position :position '(-1.587332 4.953933 8.858178) :quaternion '(-0.248334482 -0.013592960 -0.001011713 0.968578458))

I need a button to copy the :position and :quaternion of the current posed IK_character



(godot-character-stop-collapse-animation)

(godot-character-play-collapse
 :animation "collapse/female_collapse_motion")


(godot-character-play-collapse)





I also notice that the character rotate to the collapse initial position, that is means that the character does not collapse at current postion and orientation




(defun female-collapse-camera-shot ()
  (interactive)

  (godot-camera-confirm-follow
   :target-node "IK_character"
   :viewport 1)

  (godot-camera-program-begin
   :name "female-walk-exhibition-hall-01"
   :target-node "IK_character"
   :viewport 1
   :loop nil)

  (godot-camera-g4 :seconds 5.0)

  ;; (godot-camera-g1 :x 0.1831 :y -1.5150 :z 0.4186
  ;; 		   :duration 4.0
  ;; 		   :easing 'smooth)

  ;; (godot-camera-g3-orbit :degrees 15.88 :pivot '(-2.6143 0.0000 2.4228)
  ;; 			 :duration 5.0
  ;; 			 :easing 'smooth)

  (godot-camera-g4 :seconds 0.75)

  ;; Auto-duration needs the program loaded before recording starts.
  (godot-camera-send-program :play nil)

  (godot-character-play-collapse)


  ;; Record the complete camera program.  The native collapse clock is
  ;; advanced by the same fixed-step capture path, while `stationary' keeps
  ;; the legacy walk evaluator from taking ownership of IK_character.
  (godot-walk-record-camera-motion
   :motion-source 'stationary
   :auto-clip-to-camera-program t
   :program-end-padding 0.0
   :fps 24
   :start-delay 0.1
   :viewport 1)



  (godot-camera-play t))


(godot-camera-release-follow)

(godot-character-play-collapse)
