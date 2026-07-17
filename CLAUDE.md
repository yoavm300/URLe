## Reference Standards (imported from the bootcamp repo)

The maintainer's best-practice reference lives in `.claude/` (copied from the
bootcamp curriculum repo). Work by it:

- **`.claude/standards.md`** — the load-bearing sections for this app repo are
  **§6 Code Standards** (Kubernetes: no `default` namespace, no `latest` tags,
  resource requests/limits, labels; Terraform: typed variables, no hardcoded
  values, outputs, no inline credentials, remote state for production; Docker:
  pinned base images, non-root, multi-stage where relevant; CI/CD: separate
  build/deploy stages, least privilege, no secret exposure) and
  **§7 Security Standards** (never real credentials, secure defaults,
  anti-patterns clearly labeled). "Default to stricter engineering practices
  when uncertain" (§12) applies here too.
- **`.claude/bootcamp-CLAUDE.md`** — the maintainer's operating policies carry
  over: don't generate documentation unless asked; ask before major
  architectural/infra/networking/security changes; answer solution-first, then
  brief why; never run destructive commands (`terraform apply/destroy`,
  `kubectl delete`, `helm install/upgrade`, `rm -rf`, `git push --force`,
  `git reset --hard`) autonomously — show the command and let the user run it.
- **`.claude/context.md`** and **`.claude/prompts/`** — curriculum-authoring
  context, kept for reference. The curriculum-specific rules (README section
  templates, `NN-` directory numbering, teaching progression) do **not** apply
  to this repo; the code and security standards do.

---

This is a production-structured Flask URL shortener, split into 3
independently deployable microservices (the original single-app layout is
retired). Follow this structure strictly:

Project_URLe/
shared/                  # SQLAlchemy models, extensions, config — shared by all services
  config.py
  extensions.py
  models/user.py
  models/url.py
services/
  auth/                  # /register /login /logout — owns the users table
  dashboard/             # / /shorten /urls /url/* + static — owns URL management
  redirect/              # GET /<short_code> — hottest path, scales independently
    (each: app/ package with create_app(), run.py, Dockerfile, requirements.txt)
helm/                    # Helm: one chart per service + postgres/redis + urle-chart umbrella,
                         #   plus git-ops/ (Argo CD AppProject + one Application per environment)
terraform/               # Terraform modules + Terragrunt environments tree (global/dev/prod)
k8s/                     # raw manifests by kind — minikube-local reference only
docs/BOOTSTRAP.md        # one-time AWS/GitHub account setup

Rules:

Use Flask + SQLAlchemy + Flask-Login
SQLite locally; Postgres (in-cluster dev / RDS prod) via DATABASE_URL
Keep code modular and clean
No monolithic files
Use application factory pattern (create_app) — one per service
Each service runs from its own services/<name>/run.py (dev-only entrypoint)
MANIFEST.md is the source of truth for the target infrastructure (§2, §10, §11)
-------
Behavioral guidelines to reduce common LLM coding mistakes. Merge with project-specific instructions as needed.

Tradeoff: These guidelines bias toward caution over speed. For trivial tasks, use judgment.
1. Think Before Coding

Don't assume. Don't hide confusion. Surface tradeoffs.

Before implementing:

    State your assumptions explicitly. If uncertain, ask.
    If multiple interpretations exist, present them - don't pick silently.
    If a simpler approach exists, say so. Push back when warranted.
    If something is unclear, stop. Name what's confusing. Ask.

2. Simplicity First

Minimum code that solves the problem. Nothing speculative.

    No features beyond what was asked.
    No abstractions for single-use code.
    No "flexibility" or "configurability" that wasn't requested.
    No error handling for impossible scenarios.
    If you write 200 lines and it could be 50, rewrite it.

Ask yourself: "Would a senior engineer say this is overcomplicated?" If yes, simplify.
3. Surgical Changes

Touch only what you must. Clean up only your own mess.

When editing existing code:

    Don't "improve" adjacent code, comments, or formatting.
    Don't refactor things that aren't broken.
    Match existing style, even if you'd do it differently.
    If you notice unrelated dead code, mention it - don't delete it.

When your changes create orphans:

    Remove imports/variables/functions that YOUR changes made unused.
    Don't remove pre-existing dead code unless asked.

The test: Every changed line should trace directly to the user's request.
4. Goal-Driven Execution

Define success criteria. Loop until verified.

Transform tasks into verifiable goals:

    "Add validation" → "Write tests for invalid inputs, then make them pass"
    "Fix the bug" → "Write a test that reproduces it, then make it pass"
    "Refactor X" → "Ensure tests pass before and after"

For multi-step tasks, state a brief plan:

1. [Step] → verify: [check]
2. [Step] → verify: [check]
3. [Step] → verify: [check]

Strong success criteria let you loop independently. Weak criteria ("make it work") require constant clarification.

These guidelines are working if: fewer unnecessary changes in d7iffs, fewer rewrites due to overcomplication, and clarifying questions come before implementation rather than after mistakes.


<!-- nx configuration start-->
<!-- Leave the start & end comments to automatically receive updates. -->

# General Guidelines for working with Nx

- For navigating/exploring the workspace, invoke the `nx-workspace` skill first - it has patterns for querying projects, targets, and dependencies
- When running tasks (for example build, lint, test, e2e, etc.), always prefer running the task through `nx` (i.e. `nx run`, `nx run-many`, `nx affected`) instead of using the underlying tooling directly
- Prefix nx commands with the workspace's package manager (e.g., `pnpm nx build`, `npm exec nx test`) - avoids using globally installed CLI
- You have access to the Nx MCP server and its tools, use them to help the user
- For Nx plugin best practices, check `node_modules/@nx/<plugin>/PLUGIN.md`. Not all plugins have this file - proceed without it if unavailable.
- NEVER guess CLI flags - always check nx_docs or `--help` first when unsure

## Scaffolding & Generators

- For scaffolding tasks (creating apps, libs, project structure, setup), ALWAYS invoke the `nx-generate` skill FIRST before exploring or calling MCP tools

## When to use nx_docs

- USE for: advanced config options, unfamiliar flags, migration guides, plugin configuration, edge cases
- DON'T USE for: basic generator syntax (`nx g @nx/react:app`), standard commands, things you already know
- The `nx-generate` skill handles generator discovery internally - don't call nx_docs just to look up generator syntax


<!-- nx configuration end-->