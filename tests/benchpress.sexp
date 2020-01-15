
(prover
  (name zip-find-expect)
  (cmd "grep ' expect:'")
  (sat "expect: sat")
  (unsat "expect: unsat"))

(prover
  (name tptp-find-expect)
  (cmd "grep '% Status[ ]*:'")
  (sat "Status[ ]*: (CounterSatisfiable|Satisfiable)")
  (unsat "Status[ ]*: (Unsatisfiable|Theorem|CounterTheorem|Lemma)"))

(dir
  (path $cur_dir)
  (pattern ".*\\zf")
  (expect (try (run zip-find-expect) (run tptp-find-status) (const unknown))))

(dir
  (path $cur_dir/../examples/)
  (pattern ".*\\.(zf|p)")
  (expect (try (run zip-find-expect) (run tptp-find-status) (const unknown))))

(dir
  (path $home/workspace/TPTP-v6.1.0//)
  (pattern ".*\\.p")
  (expect (try (run tptp-find-status) (const unknown))))

(prover
  (name zip-dev)
  (binary $cur_dir/../zipperposition.exe)
  (cmd "$cur_dir/../zipperposition.exe $file --timeout $timeout --mem-limit $memory --output none")
  (unsat "SZS status (Theorem|Unsatisfiable)")
  (sat "SZS status (CounterSatisfiable|Satisfiable)")
  (timeout "SZS status ResourceOut")
  (version "git:."))

(prover
  (name zip-dev-check)
  (binary $cur_dir/../zipperposition.exe)
  (cmd "$cur_dir/../zipperposition.exe $file --timeout $timeout --mem-limit $memory --output none --check")
  (unsat "SZS status (Theorem|Unsatisfiable)")
  (sat "SZS status (CounterSatisfiable|Satisfiable)")
  (timeout "SZS status ResourceOut")
  (version "git:."))

(task
  (name zip-local-test)
  (action
    (run_provers
      (provers zip-dev zip-dev-check)
      (timeout 10)
      (memory 2000)
      (dirs))))
