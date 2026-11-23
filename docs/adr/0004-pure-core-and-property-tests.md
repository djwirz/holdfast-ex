# 4. A pure core with a thin process shell, proven by property tests

Date: 2026-11-23
Status: Accepted

## Context
The rules (bid minimums, close, holds that should exist) and the invariants must be right under every interleaving of bids, authorization results and crashes. Interleavings are exactly what example-based tests miss.

## Options considered
1. **Pure core plus property tests.** `decide(state, command, now)` returns events, and `apply(state, event)` folds them. The invariants are functions over an event list. StreamData generates random command sequences, authorization orders and outcomes, times around `ends_at`, and crash points (truncate the log, replay, continue).
2. **Logic inside the GenServer, tested through processes.** Less indirection, but every test pays for processes and timing, and interleavings stay hard to generate.
3. **Example tests plus a big load test.** Concrete and readable, but the load test finds bugs late and can't shrink a failure to its cause.

## Decision
Option 1. The core has no processes, database or clock. The server and store are a thin shell. Property tests over the core are the main correctness evidence. Integration tests prove the shell keeps the core's promises (log first, kill at every step). Holdfast's k6 storm with our checker is the black-box layer on top.

## Why
Failing cases shrink to the smallest sequence that breaks an invariant. The same invariant functions run in the property tests, the integration tests and the storm's checker, so "correct" means one thing everywhere.

## Consequences
- The shell must not add behavior the core doesn't model. Review checks that every branch in the server maps to a core command.
- Generators need care to reach interesting states, such as ties, the last second, and replays of the same key. Coverage of those states is reported, not assumed.
- Verify StreamData's current API and its integration with ExUnit at slice 1.
