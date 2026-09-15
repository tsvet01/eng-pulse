# Running agents in the cloud (no laptop needed)

Both platforms clone `tsvet01/eng-pulse`, run `scripts/cloud-setup.sh`, read the root `AGENTS.md`, and hand back a branch you turn into a PR. CI on the PR is the verification; agents never deploy.

What cloud agents can do here: Rust and Python changes with tests, docs, Terraform edits (plan runs on the PR), pulse-api work against a local Postgres. What they cannot: build the Swift app (macOS only), deploy, apply infra, or read production secrets. Keep it that way.

## Claude Code on the web

Docs: https://code.claude.com/docs/en/claude-code-on-the-web.md · https://code.claude.com/docs/en/cloud-environments.md

1. Sign in at https://claude.ai/code and authorize the Claude GitHub App for `tsvet01/eng-pulse` (private repos need the app installed on the account). From a terminal, `/web-setup` does the same.
2. Cloud icon above the message box → environment for this repo:
   - **Setup script**: `bash scripts/cloud-setup.sh` (runs before the session; ~5 min budget; cached afterwards)
   - **Network access**: `Trusted` (default; covers crates.io, PyPI, GitHub). `None` also works after the cache is warm, since tests need no network.
   - **Environment variables**: leave empty. Anything here is readable by every session; never put keys in it.
3. Sandbox facts: 4 vCPU / 16 GB / 30 GB; Rust, Python 3, Node, Docker and Postgres 16 preinstalled. `rustup` is not, which is why the setup script installs the pinned toolchain only if `cargo` is missing.
4. Results: the session pushes a branch; open the PR from the web UI or ask Claude to. `claude --teleport <session-id>` pulls a cloud session into a local terminal. The "auto-fix" toggle lets the session watch its PR for CI failures and review comments.
5. Repo files that apply in cloud sessions: `CLAUDE.md` (imports `AGENTS.md`), `.claude/settings.json`, `.claude/skills`, `.mcp.json`. User-level settings do not.

## Codex cloud

Docs: https://learn.chatgpt.com/docs/environments/cloud-environment.md · https://learn.chatgpt.com/docs/cloud/internet-access.md · image: https://github.com/openai/codex-universal

1. https://chatgpt.com/codex → connect GitHub → grant access to `tsvet01/eng-pulse`.
2. https://chatgpt.com/codex/settings/environments → create an environment for the repo:
   - **Image**: universal. **Package versions**: `CODEX_ENV_RUST_VERSION=1.94.0`, `CODEX_ENV_PYTHON_VERSION=3.12`.
   - **Setup script**: `bash scripts/cloud-setup.sh`
   - **Maintenance script** (runs when a cached container is resumed, up to 12 h): `cargo fetch --locked`
   - **Internet access (agent phase)**: On → preset `Common dependencies` (includes crates.io, github.com, pypi.org). Setup always has internet.
   - **Environment variables / secrets**: none. Secrets are stripped before the agent phase anyway.
3. Codex reads the root `AGENTS.md` (and its `## Code Review Rules` section for GitHub reviews).
4. Results: Codex shows a diff; "Open PR" creates the PR. Cloud tasks draw on the plan's usage allowance (Plus/Pro/Business).

## First-session smoke test (both)

Prompt: `Run ./scripts/validate.sh --quick and the python function tests; report the output. Do not change anything.` Expect four green checks and passing pytest runs. If `cargo` is missing, the setup script did not run: check the environment's setup script field.

## Handing work to a cloud agent

- Point at a plan or issue and name the verification (`cargo test --workspace`, the fixtures drift guard, a pytest file).
- Ask for one PR per task. CI decides; you merge; deploys happen on `main`.
- Infra changes: the PR's `terraform-plan` comment is the review artifact; `terraform-apply` still needs your approval in the `production` environment.
