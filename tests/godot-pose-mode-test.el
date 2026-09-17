;;; godot-pose-mode-test.el --- Tests for actor pose and shot documents -*- lexical-binding: t; -*-

(require 'ert)
(require 'godot-pose-mode)

(defun godot-pose-test--write (path contents)
  "Write CONTENTS to PATH for an isolated ERT fixture."
  (make-directory (file-name-directory path) t)
  (with-temp-file path
    (insert contents)))

(defconst godot-pose-test--pose-document
  "{\n  \"schema\": \"godot-pose-document\",\n  \"version\": 1,\n  \"active_pose\": \"rest\",\n  \"character\": {\"node_path\": \"Actor\", \"skeleton_path\": \"Skeleton3D\"},\n  \"poses\": {\"rest\": {\"mode\": \"fk\", \"reset_to_rest\": true, \"bones\": {}}}\n}\n")

(ert-deftest godot-shot-resolves-separate-actor-documents ()
  (let* ((root (make-temp-file "godot-shot-test-" t))
         (shot-path (expand-file-name "poses/shots/test.gdshot" root))
         (female-path (expand-file-name "poses/female.gdpose" root))
         (male-path (expand-file-name "poses/male.gdpose" root)))
    (godot-pose-test--write female-path godot-pose-test--pose-document)
    (godot-pose-test--write male-path godot-pose-test--pose-document)
    (with-temp-buffer
      (setq buffer-file-name shot-path)
      (insert "{\"schema\":\"godot-shot-document\",\"version\":1,\"actors\":{\"female\":{\"document\":\"../female.gdpose\",\"pose\":\"rest\"},\"male\":{\"document\":\"../male.gdpose\",\"pose\":\"rest\"}}}")
      (let ((specs (godot-shot--actor-specs (godot-shot--parse-document))))
        (should (= (length specs) 2))
        (should (equal (mapcar (lambda (spec)
                                 (godot-pose--get "actor_name" spec))
                               specs)
                       '("female" "male")))
        (should (equal (godot-pose--get
                        "node_path"
                        (godot-pose--get "character" (car specs)))
                       "Actor"))))))

(ert-deftest godot-shot-rejects-a-missing-selected-pose ()
  (let* ((root (make-temp-file "godot-shot-test-" t))
         (shot-path (expand-file-name "poses/shots/test.gdshot" root))
         (actor-path (expand-file-name "poses/actor.gdpose" root)))
    (godot-pose-test--write actor-path godot-pose-test--pose-document)
    (with-temp-buffer
      (setq buffer-file-name shot-path)
      (insert "{\"schema\":\"godot-shot-document\",\"version\":1,\"actors\":{\"actor\":{\"document\":\"../actor.gdpose\",\"pose\":\"missing\"}}}")
      (should-error
       (godot-shot--actor-specs (godot-shot--parse-document))
       :type 'user-error))))

(ert-deftest godot-shot-extension-selects-shot-mode ()
  (should (eq (cdr (assoc-string "\\.gdshot\\'" auto-mode-alist))
              'godot-shot-mode)))

(provide 'godot-pose-mode-test)

;;; godot-pose-mode-test.el ends here
