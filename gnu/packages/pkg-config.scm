;;; GNU Guix --- Functional package management for GNU
;;; Copyright © 2012, 2013, 2014, 2016 Ludovic Courtès <ludo@gnu.org>
;;; Copyright © 2019 Mathieu Othacehe <m.othacehe@gmail.com>
;;; Copyright © 2021 Maxime Devos <maximedevos@telenet.be>
;;; Copyright © 2022, 2024 Maxim Cournoyer <maxim.cournoyer@gmail.com>
;;; Copyright © 2023 Zheng Junjie <873216071@qq.com>
;;;
;;; This file is part of GNU Guix.
;;;
;;; GNU Guix is free software; you can redistribute it and/or modify it
;;; under the terms of the GNU General Public License as published by
;;; the Free Software Foundation; either version 3 of the License, or (at
;;; your option) any later version.
;;;
;;; GNU Guix is distributed in the hope that it will be useful, but
;;; WITHOUT ANY WARRANTY; without even the implied warranty of
;;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;;; GNU General Public License for more details.
;;;
;;; You should have received a copy of the GNU General Public License
;;; along with GNU Guix.  If not, see <http://www.gnu.org/licenses/>.

(define-module (gnu packages pkg-config)
  #:use-module (guix licenses)
  #:use-module (guix packages)
  #:use-module (guix download)
  #:use-module (guix gexp)
  #:use-module (guix search-paths)
  #:use-module (guix build-system gnu)
  #:use-module (guix build-system trivial)
  #:use-module (gnu packages bash)
  #:use-module (gnu packages check)
  #:use-module (guix memoization)
  #:export (pkg-config
            pkgconf
            pkgconf-as-pkg-config))


;;;
;;; "Primitive" pkg-config packages.
;;;

;; The %-less variants defined below should be used instead; the %-prefixed
;; "primitive" packages are exported so that `fold-packages' can find them,
;; making them available for use via the Guix CLI.
(define-public %pkg-config
  (package
   (name "pkg-config")
   (version "0.29.2")
   (source (origin
            (method url-fetch)
            (uri (list
                  (string-append
                   "http://fossies.org/linux/misc/pkg-config-" version
                   ".tar.gz")

                  ;; FIXME: The following URL redirects to HTTPS, which
                  ;; creates bootstrapping problems:
                  ;; <http://bugs.gnu.org/22774>.
                  (string-append
                   "http://pkgconfig.freedesktop.org/releases/pkg-config-"
                   version ".tar.gz")))
            (sha256
             (base32
              "14fmwzki1rlz8bs2p810lk6jqdxsk966d8drgsjmi54cd00rrikg"))))
   (build-system gnu-build-system)
   (arguments
    `(#:configure-flags
      '("--with-internal-glib"
        ;; Those variables are guessed incorrectly when cross-compiling.
        ;; See: https://developer.gimp.org/api/2.0/glib/glib-cross-compiling.html.
        ,@(if (%current-target-system)
              '("glib_cv_stack_grows=no"
                "glib_cv_uscore=no"
                "ac_cv_func_posix_getpwuid_r=yes"
                "ac_cv_func_posix_getgrgid_r=yes")
              '()))))
   (native-search-paths
    (list $PKG_CONFIG_PATH))
   (home-page "https://www.freedesktop.org/wiki/Software/pkg-config")
   (license gpl2+)
   (synopsis "Helper tool used when compiling applications and libraries")
   (description
    "pkg-config is a helper tool used when compiling applications and
libraries.  It helps you insert the correct compiler options on the
command line so an application can use gcc -o test test.c `pkg-config
--libs --cflags glib-2.0` for instance, rather than hard-coding values
on where to find glib (or other libraries).  It is language-agnostic, so
it can be used for defining the location of documentation tools, for
instance.")))

(define-public %pkgconf
  (package
    (name "pkgconf")
    (version "2.1.0")
    (source (origin
              (method url-fetch)
              (uri (string-append  "https://distfiles.dereferenced.org/"
                                   name "/" name "-" version ".tar.xz"))
              (sha256
               (base32
                "0qbpczwrrsq2981mdv3iil26vq9ac8v1sfi9233jpiaixrhmhv96"))))
    (build-system gnu-build-system)
    (arguments
     (list #:phases #~(modify-phases %standard-phases
                        (add-after 'unpack 'set-HOME
                          (lambda _
                            ;; Kyua requires a writable HOME.
                            (setenv "HOME" "/tmp"))))))
    (native-inputs (list atf kyua))
    (native-search-paths (list $PKG_CONFIG_PATH))
    (home-page "http://pkgconf.org/")
    (synopsis "Package compiler and linker metadata toolkit")
    (description "@command{pkgconf} is a program which helps to configure
compiler and linker flags for development libraries.  It is similar to
pkg-config from freedesktop.org.  @code{libpkgconf} is a library which
provides access to most of pkgconf's functionality, to allow other tooling
such as compilers and IDEs to discover and use libraries configured by
pkgconf.")
    (license isc)))

(define-public %pkgconf-as-pkg-config
  (package/inherit %pkgconf
    (name "pkgconf-as-pkg-config")
    (build-system gnu-build-system)
    (arguments
     (list
      #:tests? #f
      #:phases
      #~(modify-phases %standard-phases
          (delete 'configure)
          (delete 'build)
          (replace 'install
            (lambda* (#:key inputs #:allow-other-keys)
              (let ((pkgconf (search-input-file inputs "bin/pkgconf")))
                (mkdir-p (string-append #$output "/bin"))
                (symlink pkgconf (string-append #$output "/bin/pkg-config"))

                ;; Also make 'pkg.m4' available, some packages might expect it.
                (mkdir-p (string-append #$output "/share"))
                ;; XXX: Using '#$(this-package-input "pkgconf") here would
                ;; create a cycle.
                (symlink (string-append (dirname (dirname pkgconf))
                                        "/share/aclocal")
                         (string-append #$output "/share/aclocal"))))))))
    (native-inputs '())
    (inputs (list %pkgconf))
    (propagated-inputs '())))


;;;
;;; Tooling for generating pkg-config wrappers for cross-compiling.
;;;

(define (make-cross-pkg-config pkg-config)
  (mlambda (target)
    "Return a procedure that evaluates to a PKG-CONFIG package for TARGET,
essentially just a wrapper called `TARGET-pkg-config', as `configure' scripts
like it."
    ;; See <http://www.flameeyes.eu/autotools-mythbuster/pkgconfig/cross-compiling.html>
    ;; for details.
    (package
      (inherit pkg-config)
      (name (string-append (package-name pkg-config) "-" target))
      (build-system trivial-build-system)
      (arguments
       (list
        #:builder (with-imported-modules '((guix build utils))
                    #~(begin
                        (use-modules (guix build utils))

                        (let* ((in     #+pkg-config)
                               (out    #$output)
                               (bin    (string-append out "/bin"))
                               (prog   (string-append #$target "-pkg-config"))
                               (native (string-append in "/bin/pkg-config")))

                          (mkdir-p bin)

                          ;; Create a `TARGET-pkg-config' -> `pkg-config' symlink.
                          ;; This satisfies the pkg.m4 macros, which use
                          ;; AC_PROG_TOOL to determine the `pkg-config' program
                          ;; name.
                          (symlink native (string-append bin "/" prog))

                          ;; Also make 'pkg.m4' available, some packages might
                          ;; expect it.
                          (mkdir-p (string-append out "/share"))
                          (symlink (string-append in "/share/aclocal")
                                   (string-append out "/share/aclocal")))))))

      ;; Ignore native inputs, and set `PKG_CONFIG_PATH' for target inputs.
      (native-search-paths '())
      (search-paths (package-native-search-paths pkg-config)))))

(define (make-pkg-config-for-target pkg-config)
  "Return a procedure that evaluates to a `pkg-config' package for TARGET
built from PKG-CONFIG.  The target may be either #f for a native build, or a
GNU triplet."
  (let ((cross-pkg-config (make-cross-pkg-config pkg-config)))
    (lambda (target)
      (if target
          (cross-pkg-config target)
          pkg-config))))

(define pkg-config-for-target
  (make-pkg-config-for-target %pkg-config))

(define pkgconf-for-target
  (make-pkg-config-for-target %pkgconf))

(define pkgconf-as-pkg-config-for-target
  (make-pkg-config-for-target %pkgconf-as-pkg-config))


;;;
;;; The final pkg-config package variables to use.
;;;

;; These are a hacks for automatically choosing the native or the cross
;; `pkg-config' depending on whether it's being used in a cross-build
;; environment or not.
(define-syntax pkg-config
  (identifier-syntax (pkg-config-for-target (%current-target-system))))

(define-syntax pkgconf
  (identifier-syntax (pkgconf-for-target (%current-target-system))))

(define-syntax pkgconf-as-pkg-config
  (identifier-syntax (pkgconf-as-pkg-config-for-target
                      (%current-target-system))))


;;;
;;; pkg-config packages for native use (build-time only).
;;;
(define (make-pkg-config-for-build pkg-config)
  "Return a `pkg-config' package from PKG-CONFIG for use by the builder when
cross-compiling, that honors a PKG_CONFIG_PATH_FOR_BUILD search path instead
of PKG_CONFIG_PATH, to avoid conflicting with the target `pkg-config'."
  (package
    (inherit (hidden-package pkg-config))
    (name "pkg-config-for-build")
    (version "0")
    (source #f)
    (build-system trivial-build-system)
    (inputs (list bash-minimal pkg-config))
    (arguments
     (list
      #:modules '((guix build utils))
      #:builder
      #~(begin
          (use-modules (guix build utils))
          (define where (string-append #$output "/bin/pkg-config"))
          (mkdir-p (dirname where))
          (call-with-output-file where
            (lambda (port)
              (format port "#!~a
export PKG_CONFIG_PATH=\"$PKG_CONFIG_PATH_FOR_BUILD\"
exec ~a \"$@\""
                      (search-input-file %build-inputs "bin/bash")
                      (search-input-file %build-inputs "bin/pkg-config"))))
          (chmod where #o500))))
    (native-search-paths
     (map (lambda (original)
            (search-path-specification
             (inherit original)
             (variable "PKG_CONFIG_PATH_FOR_BUILD")))
          (package-native-search-paths pkg-config)))))

(define-public pkg-config-for-build
  (make-pkg-config-for-build %pkg-config))

(define-public pkgconf-as-pkg-config-for-build
  (make-pkg-config-for-build %pkgconf-as-pkg-config))
