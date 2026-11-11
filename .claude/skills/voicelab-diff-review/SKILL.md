---
name: voicelab-diff-review
description: Review a non-trivial code or configuration diff for actionable correctness, security, compatibility, and regression issues.
---

Review the requested diff or file scope against the intended behavior and nearby
code. Prioritize defects with concrete impact: incorrect behavior, data exposure,
unsafe input handling, compatibility breaks, concurrency errors, and missing
failure handling. Check tests or other evidence only where they clarify an
identified risk.

Report only actionable findings. For each, give severity, file and line, the
failure scenario, and why it matters. Do not list speculative concerns or style
preferences. If no findings remain, say so and mention any material validation
limits. This skill supplements the lead's integration review; it does not replace
it.
