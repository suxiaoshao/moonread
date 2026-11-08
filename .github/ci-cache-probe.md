# Temporary #135 compilation-cache probes — DO NOT MERGE

Base/seed: release/1.6 6ba907dbcb27d335eded83e49b07830cbebf56e0, run 42478588711.

This Draft PR is only for sequential CI measurements: unchanged-source hot run,
Swift implementation negative probe, then an iOS-only Rust implementation probe
with unchanged FFI. Existing assertions must detect both deliberate behavior
changes; their expected failures are evidence, not product fixes to merge.

No workflow or test gate changes. PRs restore the release seed and never save it.
Close this PR and delete the test branch when measurements are complete.
