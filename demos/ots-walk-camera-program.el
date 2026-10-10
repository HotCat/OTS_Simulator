
(require 'godot-camera-control)

(godot-camera-release-follow)

(godot-character-play-collapse)


(godot-walk-restart-carrier-trajectory)

(godot-ots-carry-play-walk-cycle)


(godot-camera-confirm-follow
   :target-node "CarrierTrajectory"
   :viewport 1
   :smoothing-seconds 0.12)




(defun ots-walk-camera-shot ()
  (interactive)

  (godot-walk-restart-carrier-at-trajectory-start)
  (godot-walk-restart-carrier-trajectory)

  ;; (godot-camera-confirm-follow
  ;;  :target-node "CarrierTrajectory"
  ;;  :viewport 1
  ;;  :smoothing-seconds 0.12)

  (godot-camera-confirm-carrier-trajectory-follow
   :viewport 1
   :smoothing-seconds 0.12)


  ;; (godot-camera-program-begin
  ;;  :name "ots-carry-girl-coffeebar-01"
  ;;  :target-node "CarrierTrajectory"
  ;;  :viewport 1
  ;;  :loop nil)

  (godot-camera-program-begin
   :name "ots-carry-shot"
   :target-node "CarrierTrajectory"
   :viewport 1
   :loop nil)


  (godot-camera-g4 :seconds 0.1)

  (godot-camera-g2-orbit
   :degrees 34.88
   :pivot '(0.0 1.2 0.0)
   :duration 6.0
   :easing 'smooth)

  ;; (godot-camera-g1 :x 1.2166 :y -1.5764 :z -3.3327
  ;; 		   :duration 6.0
  ;; 		   :easing 'smooth)


  (godot-camera-g4 :seconds 0.75)

  ;; Load the camera program without starting it yet.
  (godot-camera-send-program :play nil)

  ;; Start the OTS carrier animation.
  ;; (godot-ots-carry-play-walk-cycle)
  ;; (godot-ots-carry-play-h3-heavy-load-hybrid)
  (godot-ots-carry-play-mixamo-walking-male-godot-direct)

  ;; Record exactly 9 seconds and match the selected viewport resolution.
  ;; The camera program itself is 7.85 seconds (0.1 + 7.0 + 0.75), so the
  ;; recorder holds the final camera pose for the remaining 1.15 seconds.
  ;; Do not provide :resolution: auto-resolution follows the chosen viewport.

  (godot-walk-record-camera-motion
   ;; :motion-source 'stationary
   :duration 9.0
   :fps 24
   :start-delay 0.1
   ;; Release trajectory/camera follow at 6 s and hold that camera transform
   ;; while the character and recording continue to the 9 s endpoint.
   :camera-follow-stop-at 9.0
   :auto-resolution t
	:viewport 1)
  ;; Start the camera program after recording has been prepared.
  (godot-camera-play t))


(godot-camera-release-follow)


(godot-camera-confirm-carrier-trajectory-follow
 :viewport 1
 :smoothing-seconds 0.12)


(defun restart-ots-carrier ()
  (interactive)
  (godot-walk-restart-carrier-at-trajectory-start))




  (godot-ots-carry-play-walk-cycle)

  (godot-walk-record-camera-motion
   :duration 9.0
   :fps 24
   :start-delay 0.1
   ;; Release trajectory/camera follow at 6 s and hold that camera transform
   ;; while the character and recording continue to the 9 s endpoint.
   :camera-follow-stop-at 6.0
   :auto-resolution t
   :viewport 1)

(godot-ots-carry-play-mixamo-walking-root-motion)

(godot-ots-carry-play-mixamo-walking-male-godot-direct)

  (godot-ots-carry-play-h3-heavy-load-hybrid)

  ;; Record exactly 9 seconds and match the selected viewport resolution.
  ;; The camera program itself is 7.85 seconds (0.1 + 7.0 + 0.75), so the
  ;; recorder holds the final camera pose for the remaining 1.15 seconds.
  ;; Do not provide :resolution: auto-resolution follows the chosen viewport.


(godot-camera-confirm-carrier-trajectory-follow
 :viewport 1
 :smoothing-seconds 0.12)

  (godot-ots-carry-play-mixamo-walking-male-godot-direct)

  (godot-walk-record-camera-motion
   ;; :motion-source 'stationary
   :duration 9.0
   :fps 24
   :start-delay 0.1
   ;; Release trajectory/camera follow at 6 s and hold that camera transform
   ;; while the character and recording continue to the 9 s endpoint.
   :camera-follow-stop-at 0.1
   :auto-resolution t
   :viewport 1)







(defun female-comparison-180-orbit ()
  (interactive)
  (godot-camera-release-follow)

  (godot-camera-program-begin
   :name "two-female-180-orbit"
   :target-node "."
   :viewport 1
   :loop nil)

  ;; ;; Front view, centred between both characters.
  ;; (godot-camera-set-initial-view
  ;;  :position '(0.0 1.05 5.7)
  ;;  :quaternion '(0.0 0.0 0.0 1.0))

  (godot-camera-g4 :seconds 0.25)
  (godot-camera-g2-orbit
   :degrees 180.0
   :pivot '(0.0 1.2 0.0)
   :duration 8.5
   :easing 'smooth)
  (godot-camera-g4 :seconds 0.25)

  (godot-camera-send-program :play nil)

  (godot-walk-record-camera-motion
   :duration 9.0
   :fps 24
   :start-delay 0.1
   :auto-resolution t
   :viewport 1)

  (godot-camera-play t))






(godot-ikea-cpr-servo-play)

(godot-ikea-cpr-servo-capture-male-hand-pose)

(godot-ikea-cpr-servo-capture-hand-markers)









(defun ikea-cpr-camera-shot ()
  (interactive)

  ;; Enter CPR mode at time zero, then pause while preparing the shot.
  (godot-ikea-cpr-servo-restart)
  (godot-ikea-cpr-servo-pause)

  (godot-camera-confirm-follow
   :target-node "OrbitPivot"
   :viewport 1)

  (godot-camera-program-begin
   :name "ikea-cpr-9s"
   :target-node "OrbitPivot"
   :viewport 1
   :loop nil)

  (godot-camera-g4 :seconds 0.1)
  (godot-camera-g3-orbit
   :degrees 30.88
   :pivot '(0.0 1.2 0.0) ; OrbitPivot is already at chest height.
   :duration 7.0
   :easing 'smooth)
  (godot-camera-g4 :seconds 1.1) ; Total camera program: 9.0 s.

  (godot-camera-send-program :play nil)

  ;; Request fixed-step capture while CPR is paused.
  (godot-walk-record-camera-motion
   :duration 9.0
   :fps 24
   :start-delay 0.1
   :auto-resolution t
   :viewport 1)

  ;; Start both timelines after the recorder has been prepared.
  (godot-ikea-cpr-servo-restart)
  (godot-camera-play t))


(godot-camera-release-follow)


