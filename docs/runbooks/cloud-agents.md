# Cloud agents

Both platforms clone the repo, run `scripts/cloud-setup.sh`, read `AGENTS.md`, and return a branch. CI on the PR is the verification. Agents can change Rust, Python, docs and Terraform (plan runs on the PR); they cannot build the Swift app, deploy, apply infra, or see production secrets.

## Claude Code on the web

Docs: https://code.claude.com/docs/en/cloud-environments.md

1. https://claude.ai/code → authorize the Claude GitHub App for `tsvet01/eng-pulse` (or `/web-setup` from a terminal).
2. Environment (cloud icon above the prompt): setup script `bash scripts/cloud-setup.sh`; network `Trusted`; no environment variables (they are visible to every session).
3. Sandbox: 4 vCPU / 16 GB, Rust, Python, Docker and Postgres 16 preinstalled; no `rustup`, hence the script.
4. Results: the session pushes a branch; open the PR from the UI. `claude --teleport <id>` pulls a session locally.

## Codex cloud

Docs: https://learn.chatgpt.com/docs/environments/cloud-environment.md · https://github.com/openai/codex-universal

1. https://chatgpt.com/codex → connect GitHub → grant `tsvet01/eng-pulse`.
2. https://chatgpt.com/codex/settings/environments → new environment: image universal; `CODEX_ENV_RUST_VERSION=1.94.0`, `CODEX_ENV_PYTHON_VERSION=3.12`; setup script `bash scripts/cloud-setup.sh`; maintenance script `cargo fetch --locked`; agent-phase internet `Common dependencies`; no variables or secrets.
3. Results: "Open PR" from the task's diff.

## First session (both)

Prompt: `Run ./scripts/validate.sh --quick and the python function tests; report the output; change nothing.` If `cargo` is missing, the setup script field is wrong.
