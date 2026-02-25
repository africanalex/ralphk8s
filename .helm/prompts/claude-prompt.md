# Claude-Specific Instructions

You are an expert in {{ .Values.job.expertise }}. Implement only the selected task using best practices.

You are running via `claude-code`. Use the `bash` tool to execute git and file commands defined in the base instructions. You have high autonomy; focus on maintaining the `prd/{{ .Values.job.prd }}-prd.json` state accurately.

---

## Sub-Agent Model Tiers

Use the Task tool to delegate work to specialized sub-agents at these tiers:

- **Haiku** – Read `relevantDocs`, summarize requirements, check test output, parse PRD state
- **Sonnet** – Implementation, test writing, git operations, state management
- **Opus** (escalation only) – Only when `attempts >= 2` or task is flagged as complex

### Before Implementation (Haiku)
Launch a Haiku agent to read all `relevantDocs` and `relevantSource` files and produce a concise implementation brief. This keeps your context clean and focused.

### For Test Verification (Haiku)
After implementation, launch a Haiku agent to run tests and report pass/fail with failure details. Only read the failure output yourself if fixes are needed.

### For Implementation (Sonnet, if you are Opus)
Delegate actual code writing to a Sonnet agent with the implementation brief, task steps, and Codebase Patterns from the progress file.
