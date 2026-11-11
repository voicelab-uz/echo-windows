<!-- voicelab-agent-workflow:start -->
## Efficient agent workflow

- Use the repository skills `voicelab-team-agents` for useful task decomposition
  and `voicelab-diff-review` for review of non-trivial changes when those skills
  are available and relevant.
- Keep the lead responsible for understanding the request, planning, architecture
  and design decisions, integration, and review of the final diff. The lead should
  use a frontier-capable model when the current client offers one, focusing it on
  design and review; otherwise use the strongest suitable model available. Match
  reasoning effort to the work.
- Delegate bounded implementation or research to one cost-effective worker when
  useful, even if it touches one file. For substantial tasks with independent
  slices, use multiple agents when the current client exposes suitable tools and
  the time saved outweighs coordination overhead. Choose the lowest-cost capable
  model for each slice. Bounded inventory, documentation, and isolated edits
  usually need less reasoning than security-sensitive or cross-cutting work. Do
  not spawn agents just to meet a quota; handle trivial answers directly and use
  one suitable worker for tightly coupled implementation. If no agent tool is
  available, continue with available tools.
- Give each agent one clear outcome, explicit file ownership, relevant constraints,
  and a concise request for evidence or focused checks. Keep shared-file edits with
  one owner, or ask agents to return proposals for the lead to integrate. Avoid
  duplicate investigations and oversized prompts; delegate only the context the
  slice needs.
- Review every returned diff and its evidence before integration. A completion
  claim alone is not verification. Run checks that cover changed behavior; use a
  focused check when it gives enough confidence, and avoid unrelated full-suite
  work unless the user or repository requires it. Escalate unclear architecture,
  ownership conflicts, or blocked work to the coordinating lead.
- Never pass secrets, `.env` contents, credentials, customer data, or raw customer
  logs to agents. Prefer source, non-sensitive metadata, and synthetic examples.
  Do not initiate paid services or change global client configuration as part of
  agent setup.
- Respect client rate limits and `Retry-After` guidance. Resume existing work
  where possible, use an available equivalent model when needed, and do not fan
  out calls or retry indefinitely when a shared limit is reached.
<!-- voicelab-agent-workflow:end -->

# Instructions for AI agents and developers

This repository contains Echo for Windows, built with .NET 8 and WinUI 3.
The supported solution is `VoiceLabEcho.sln`; application source is in `VoiceLab.WinUI3/`.

- Follow the user's current requirements and the established Windows UI patterns.
- Read `README.md`, `BUILD_INSTRUCTIONS.md`, and the relevant source before changing behavior.
- Keep authentication, transcription, account separation, encrypted storage, and API contracts intact.
- Reuse the app's bundled styles and assets. Preserve font and lexicon licenses and provenance notices.
- Keep generated binaries, installers, local credentials, session files, and test outputs out of Git.
- Do not reintroduce retired projects, external reference source trees, or old progress reports.
- Keep documentation aligned with the actual application and report unverified behavior accurately.
- Never change Windows security policies as part of ordinary builds or installation.

Build with `dotnet build VoiceLabEcho.sln -c Release -p:Platform=x64`.
Run service checks with `dotnet run --project VoiceLab.WinUI3/VoiceLab.SmokeTests/VoiceLab.SmokeTests.csproj -c Release`.
Follow `VoiceLab.WinUI3/RELEASE_VERIFICATION.md` for interactive acceptance checks.
The single-file installer recipe is `VoiceLab.WinUI3/installer/VoiceLab-Echo.iss`.
