
(require 'godot-camera-control)

(godot-camera-release-follow)

(godot-character-play-collapse)


(godot-walk-restart-carrier-trajectory)

(godot-ots-carry-play-walk-cycle)


(godot-camera-confirm-follow
   :target-node "MaleCarrier"
   :viewport 1)




(defun ots-walk-camera-shot ()
  (interactive)

  (godot-walk-restart-carrier-trajectory)

  (godot-camera-confirm-follow
   :target-node "MaleCarrier"
   :viewport 1)

  (godot-camera-program-begin
   :name "ots-carry-girl-coffeebar-01"
   :target-node "MaleCarrier"
   :viewport 1
   :loop nil)

  (godot-camera-g4 :seconds 0.1)

  (godot-camera-g3-orbit
   :degrees 20.88
   :pivot '(0.0 1.2 0.0)
   :duration 7.0
   :easing 'smooth)

  (godot-camera-g4 :seconds 0.75)

  ;; Load the camera program without starting it yet.
  (godot-camera-send-program :play nil)

  ;; Start the OTS carrier animation.
  (godot-ots-carry-play-walk-cycle)

  ;; Record exactly 9 seconds and match the selected viewport resolution.
  ;; The camera program itself is 7.85 seconds (0.1 + 7.0 + 0.75), so the
  ;; recorder holds the final camera pose for the remaining 1.15 seconds.
  ;; Do not provide :resolution: auto-resolution follows the chosen viewport.
  (godot-walk-record-camera-motion
   :duration 9.0
   :fps 24
   :start-delay 0.1
   :auto-resolution t
   :viewport 1)

  ;; Start the camera program after recording has been prepared.
  (godot-camera-play t))


(godot-camera-release-follow)

