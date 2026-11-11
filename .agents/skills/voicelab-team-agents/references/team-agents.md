# Team agent workflow

Use parallel agents when a task has independent research or implementation slices
and the available client tools support delegation. Keep a trivial, tightly coupled,
or single-file task with one agent.

## Roles and task setup

- The current lead owns task understanding, planning, architecture and design
  choices, integration, and review of the final diff.
- Choose the lowest-cost available model that can handle each bounded slice. Match
  reasoning effort to the slice's uncertainty and risk; use stronger reasoning for
  security-sensitive or architecture work. Use only the model and reasoning
  controls exposed by the current client.
- Give each agent a clear result, explicit owned paths, constraints, relevant
  context, and a small evidence request. Keep delegated context focused and use
  synthetic examples for sensitive areas.
- Assign distinct files when possible. Route shared-file changes through one owner
  or have agents return proposed edits for the lead to integrate.

## Integration

- Ask agents to report changed paths, decisions, and focused checks or evidence.
  Do not treat a completion claim as verification.
- Review every returned diff against the request and repo instructions. Resolve
  conflicts centrally and run checks that cover the changed behavior; avoid a full
  suite when a focused check is enough and the user did not request broader
  validation.
- For user-visible changes, inspect the result in the relevant environment when
  available. Deploy only when the user authorized deployment and the integrated
  change is ready.
- Do not send secrets, `.env` contents, credentials, customer data, or raw customer
  logs to subagents.
