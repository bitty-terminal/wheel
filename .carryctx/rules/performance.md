# Performance rules

1. Performance is a contract expressed through accepted, measurable budgets;
   descriptive goals alone are not acceptance criteria.
2. A claim records workload, input corpus, hardware, OS, build profile,
   toolchain, sample size, variance, baseline, and exact revision.
3. Measure turn latency, context compilation time, Merkle tree root hashing
   duration, DAG wave scheduling throughput, and memory consumption separately.
4. Bound protocol payloads, context window budgets (64 KiB total, 16 KiB Zone 1,
   32 KiB Zone 2, 16 KiB Zone 3), tool auto-spillover thresholds (4 KiB), and
   turn iterations before optimizing them.
5. Invariant prefixes in Zone 1 must maintain byte-for-byte cache key stability
   across turn prompts to maximize LLM prompt-cache hits.
6. A benchmark improvement cannot weaken correctness, security, compatibility,
   fallback, or recovery.
7. Record regressions and residual uncertainty in CarryCtx; update canonical
   performance requirements when an accepted budget changes.
