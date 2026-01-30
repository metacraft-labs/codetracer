;; copied and adapted from Pavel's emacs
(setq package-selected-packages
  '(cargo dap-mode dap-lldb direnv))

(require 'package)
(require 'use-package)

(add-to-list 'package-archives
             '("melpa" . "http://melpa.org/packages/") t)

(add-to-list 'package-archives
             '("org" . "http://orgmode.org/elpa/") t)

(set-language-environment "UTF-8")
(use-package dap-mode)

;; optionally if you want to use debugger
;; (setq dap-auto-configure-features '(sessions locals controls tooltip))
(require 'dap-lldb)

(setq dap-lldb-debug-program '("/nix/store/mp11vrfvp3v2k1lvc7d0n4nnfm00831d-lldb-18.1.7/bin/lldb-dap"))


;; (use-package dap-gdb-lldb)


;; Pavel recommends installing like that:
;; M-x package-install-selected-packages

(dap-register-debug-provider
 "rust"
 (lambda (conf)
   (plist-put conf :dap-server-path "/home/alexander92/codetracer/src/build-debug/bin/db-backend")
   conf))

(dap-register-debug-template "CodeTracer db-backend rust"
                             (list :type "rust"
                                   :request "launch"
                                   :args "--stdio"
                                   :traceFolder "/home/alexander92/.local/share/codetracer/trace-414/"
                                   :name "CodeTracer db-backend rust"))

(toggle-debug-on-error)
