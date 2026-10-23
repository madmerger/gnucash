(setenv "GNC_UNINSTALLED" "1")

(use-modules (srfi srfi-64))
(use-modules (tests srfi64-extras))
(use-modules (gnucash core-utils))

(define (N_-tests)

  (test-assert "N_ defined"
    (module-ref (current-module) 'N_))

  (test-equal "N_ works properly"
    "foobar"
    (N_ "foobar")))

(define (gnc-format-tests)
  (test-equal "null"
    ""
    (gnc:format ""))

  (test-equal "basic"
    "basic"
    (gnc:format "basic"))

  (test-equal "basic with unused symbols"
    "basic"
    (gnc:format "basic" 'task "testing"))

  (test-equal "one substitution"
    "basic test"
    (gnc:format "basic ${job}" 'job "test"))

  (test-equal "one substitution with hyphen"
    "master chief"
    (gnc:format "master ${job-title}" 'job-title "chief"))

  (test-equal "two substitutions out of order"
    "basic test"
    (gnc:format "${difficulty} ${job}" 'job "test" 'difficulty "basic"))

  (test-equal "trying to reference invalid symbol"
    "${symbol} does not exist"
    (gnc:format "${symbol} does not exist" 'existence "none"))

  (test-equal "multibyte text before and between substitutions"
    "会社 損益計算書 期間 2025/01/01 ～ 2025/12/31"
    (gnc:format "${company-name} ${report-title} 期間 ${start} ～ ${end}"
                'company-name "会社" 'report-title "損益計算書"
                'start "2025/01/01" 'end "2025/12/31"))

  (test-equal "multibyte prefix and incomplete tokens"
    "期間 ${ ${} ${a b} x"
    (gnc:format "期間 ${ ${} ${a b} ${v}" 'v "x"))

  (test-error "gnc:format syntax error" #t
    (gnc:format "${symbol} does not exist" 'existence)))

(define (run-test)
  (test-runner-factory gnc:test-runner)
  (test-begin "test-core-utils")
  (N_-tests)
  (gnc-format-tests)
  (test-end "test-core-utils"))
