
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

  ;; (godot-camera-g1 :x 5.7428 :y 0.2211 :z 3.4742
  ;; 		   :duration 2.0
  ;; 		   :easing 'smooth)

  (godot-camera-g3-orbit :degrees 30.88 :pivot '(0.0 1.2 0.0)
			 :duration 6.0
			 :easing 'smooth)

  (godot-camera-g4 :seconds 0.75)

  ;; Auto-duration needs the program loaded before recording starts.
  (godot-camera-send-program :play nil)

  (godot-ots-carry-play-walk-cycle)

  ;; The camera program above is 6.85 seconds (0.1 + 6.0 + 0.75).  Use a
  ;; manual duration for a nine-second proxy take; the camera holds its final
  ;; program pose for the remaining 2.15 seconds.  Omit :resolution so the
  ;; recorder matches the selected editor viewport's pixel size automatically.
  (godot-walk-record-camera-motion
   :duration 9.0
   :fps 24
   :start-delay 0.1
   :auto-resolution t
   :viewport 1)


  (godot-camera-play t))


(godot-camera-release-follow)


