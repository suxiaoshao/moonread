# Temporary CI cache validation — do not merge

This marker selects the existing complete CI checks without changing application,
Rust, workflow, project, or lock-file inputs in the warm-cache control run.

Follow-up commits intentionally break one existing Swift integration assertion at
a time to verify that restoring the release cache never executes stale Swift or
Rust code. The pull request is closed without merging after the measurements.
