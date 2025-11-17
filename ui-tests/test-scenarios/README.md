# CodeTracer — Tests as Code (Manual QA)

This directory holds **manual test cases** (Markdown with YAML front matter), **suite definitions** (YAML), an **environment matrix**, and a workflow to generate **Manual Test Run** issues.

## Philosophy
- Organize tests **by functionality** (component-first). Use `program` metadata when a case requires a specific program: `noir_space_ship`, `ruby_space_ship`, or `agnostic`.
- Keep test steps and assertions in Markdown checklists for clarity and PR review.
- Use the `Generate Manual Test Run` workflow to open a run issue per suite and matrix slice.

## Structure
- `test-scenarios/testcases/<component>/TC-*.md` — individual cases with front matter + checklists
- `test-scenarios/suites/**/*.yml` — which cases to run for a given component/variant/matrix
- `test-scenarios/support/env-matrix.md` — OS/Browser targets
- `test-scenarios/runbooks` — run templates and optional archives

## Running a Manual Suite
1. Push the branch and trigger **Actions → Generate Manual Test Run**.
2. Choose `suite_path` (for example `test-scenarios/suites/components/event_log.electron.yml`) and matrix inputs.
3. The workflow opens a **Manual Test Run** issue with a checklist of cases.
4. Tick ✅ / ❌ while testing; use the Bug issue form when a step fails.
