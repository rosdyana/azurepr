---
name: azure-pr
description: Interactively create a pull request (with required reviewers) on an Azure DevOps Server / TFS or Azure DevOps Services repo. Use when the user asks to "create a PR", "open a PR to main", "merge <branch> to <branch>", or add reviewers to a PR, in a repo whose git remote is an https URL containing /_git/ (e.g. /tfs/<collection>/<project>/_git/<repo> or dev.azure.com/<org>/<project>/_git/<repo>). Args: optional "<source> to <target>".
---

# Create Azure DevOps / TFS Pull Request — interactive

## Configuration (set at plugin install; change with `/plugin configure azurepr@azurepr`)

| Setting | Value |
|---|---|
| Server URL | `${user_config.server_url}` (empty = any `/_git/` remote) |
| Default target branch | `${user_config.default_target_branch}` |
| REST api-version | `${user_config.api_version}` |
| Style guide URL | `${user_config.styleguide_url}` (empty = omit checklist line) |
| Auth mode | `${user_config.auth_mode}` |
| PAT env var (auth mode `pat`) | `${user_config.pat_env_var}` |

Repo/project/collection are parsed from the git remote URL. With auth mode `integrated` no token is
needed (Windows integrated auth / Kerberos). With `pat`, the script reads the token from the env var
above — never ask the user to paste a token into the chat, and never print it.

## Script

Two equivalent helpers live in `${CLAUDE_SKILL_DIR}/scripts/`. Pick one per session:

- **Windows (PowerShell tool available)** — preferred there; integrated auth works natively:
  ```powershell
  $S = "${CLAUDE_SKILL_DIR}/scripts/create-pr.ps1"
  $C = @{ ServerUrl = '${user_config.server_url}'; ApiVersion = '${user_config.api_version}'; AuthMode = '${user_config.auth_mode}'; PatEnvVar = '${user_config.pat_env_var}' }
  & $S @C -ListCandidates                          # TSV: id, displayName, uniqueName, source (self / team / recent)
  & $S @C -FindReviewer <account|DOMAIN\acct|email> # TSV of matching identities, or NOMATCH
  & $S @C -Source <src> -Target <tgt> -CheckOnly   # EXISTS #id + URL, or NONE
  & $S @C -Source <src> -Target <tgt> -Title "<t>" -DescriptionFile <f> -Reviewers <id1>,<id2> [-Draft] [-NoSelfReviewer]
  & $S @C -AddReviewersToPr <id> -Reviewers <id1>,<id2> [-NoSelfReviewer]
  ```
  (Each PowerShell tool call is a fresh shell — define `$S`/`$C` in the same command that uses them.)

- **macOS / Linux / Git Bash** — needs `bash`, `curl`, `jq`:
  ```bash
  S="${CLAUDE_SKILL_DIR}/scripts/create-pr.sh"
  C=(--server-url '${user_config.server_url}' --api-version '${user_config.api_version}' --auth-mode '${user_config.auth_mode}' --pat-env-var '${user_config.pat_env_var}')
  bash "$S" "${C[@]}" --list-candidates
  bash "$S" "${C[@]}" --find-reviewer <account|DOMAIN\\acct|email>
  bash "$S" "${C[@]}" --source <src> --target <tgt> --check-only
  bash "$S" "${C[@]}" --source <src> --target <tgt> --title "<t>" --description-file <f> --reviewers <id1>,<id2> [--draft] [--no-self-reviewer]
  bash "$S" "${C[@]}" --add-reviewers-to-pr <id> --reviewers <id1>,<id2> [--no-self-reviewer]
  ```

All reviewers are added as **required**. The current user is always added as a required reviewer
unless `-NoSelfReviewer` / `--no-self-reviewer`. Pass reviewer identity GUIDs (from the candidate /
find modes).

**This flow is interactive.** Each decision below is a checkpoint: ask with `AskUserQuestion`
(put the recommended option first, labelled "(Recommended)"; the user can always pick "Other" to
type a custom value). Do the read-only work between checkpoints without asking. Never push, and
never create or modify a PR, without the user's explicit OK at the final checkpoint.

## Flow

### 1. Branches — checkpoint
- Read-only: `git fetch origin`, current branch, `git branch -r` for candidate targets.
- If the user already gave source and target in the args/message, skip the question. Otherwise ask
  **"Which branches?"** with options like `<current> → ${user_config.default_target_branch} (Recommended)`
  and up to three other plausible targets that exist on the remote (e.g. `main`, `develop`, `stage`,
  `master`, or a promotion like `stage → main`). Only list targets that exist on the remote; if the
  default target doesn't exist there, recommend the closest match instead.
- Check `git status -sb`. If the source is ahead of `origin/<src>` or has no upstream, ask
  **"Push <src> to origin first?"** (Push / Cancel). Never push without a yes.
- Run the check-only mode. If `EXISTS`, show the URL and ask **"A PR already exists — what now?"**
  (Add reviewers to it → jump to step 3 then use the add-reviewers mode / Stop).

### 2. Gather changes (no question)
```bash
git log --oneline --no-merges origin/<tgt>..origin/<src>
git diff --stat origin/<tgt>...origin/<src> | tail -1
git diff --stat origin/<tgt>...origin/<src> -- <deploy-relevant paths>
```
Deploy-relevant paths: whatever exists in the repo among DB schema/migration folders (e.g. `prisma`,
`migrations`, `db`), `.env.example` / config templates, package manifests (`package.json`,
`requirements.txt`, `pyproject.toml`, `go.mod`, `*.csproj`, …), CI/pipeline files, Dockerfiles.
For small PRs also skim the full diff. If there are 0 commits, tell the user and stop.

### 3. Reviewers — checkpoint
- Run the list-candidates mode. The user (`self`) is a required reviewer by default.
- Ask (multiSelect) **"You're added as a required reviewer. Add anyone else?"** — one option per
  other candidate (label = display name, description = account + why suggested, e.g. "team member",
  "reviewed 13 recent PRs"), max 4 options; tell the user they can type more account names/emails via
  "Other". If there are no other candidates, offer "No one else" plus "Other".
- For any typed names, run the find-reviewer mode. If exactly one match, use it. If several, ask which
  one (show display name + account + mail). If `NOMATCH`, say so and ask again or skip.
- If the user says they should *not* be a reviewer themselves, use the no-self-reviewer flag.

### 4. Title and type — checkpoint
- Ask **"PR title?"** with options: `Merge <src> into <tgt> (Recommended)` and, if the branch has
  one clear theme, a short imperative summary. "Other" = custom title.
- Ask **"Publish or draft?"** (Publish (Recommended) / Draft).
- These two may be asked together in one `AskUserQuestion` call.

### 5. Description (no question — reviewed at step 6)
Write to a scratchpad file (UTF-8, **≤ 4000 chars** — Azure DevOps limit) using this template:
```markdown
## Proposed changes

Merge <src> to <Tgt> (<N> commits; <files changed>, +<ins> / -<del>)

- **<Feature area>:** <grouped, deduplicated summary — not a raw commit dump>

## Types of changes

What types of changes?
_Put an `x` in the boxes that apply_

- [ ] Bugfix (non-breaking change which fixes an issue)
- [ ] New feature (non-breaking change which adds functionality)
- [ ] Breaking change (fix or feature that would cause existing functionality to not work as expected)
- [ ] Other (please describe): <e.g. Merge Stage to Main>

## Checklist

- [x] I have read the [StyleGuide](<style guide URL>) and applied the coding style guideline.
- [x] I have tested for the changes to make sure everything is OK.

## Further comments
<deployment notes: schema migrations, new env vars, new workers, breaking changes — or "None">
## Screenshot
None
```
Style guide URL is `${user_config.styleguide_url}` — if that is empty, **drop the StyleGuide line**
from the checklist. Tick "Types of changes" from the actual commits. For a plain promotion PR (e.g.
stage → main) keep it short: "Merge Stage to Main" and tick only "Other". Call out deploy-relevant
items found in step 2: new schemas/migrations, env/config template changes, dependency changes, new
worker processes.

### 6. Final confirmation — checkpoint (required)
Show a summary in chat: source → target, title, draft/publish, required reviewers (names), and the
full description. Then ask **"Create this PR?"** with options:
- `Create PR (Recommended)`
- `Edit description` → ask what to change, update the file, show it again, re-ask
- `Change reviewers` → back to step 3
- `Cancel`

### 7. Create and report
Run the create command with the chosen reviewer GUIDs. Report the PR number, the `REVIEWER` lines,
and the URL the script prints.

## Troubleshooting

- `401 Unauthorized` with auth mode `integrated` → Windows/Kerberos auth didn't pass through (off VPN,
  not domain-joined, or no `kinit` ticket on macOS/Linux). Ask the user to connect to the corporate
  network, or switch to a PAT: `/plugin configure azurepr@azurepr` → auth mode `pat`, then set the env
  var (`${user_config.pat_env_var}`) in their shell profile and restart Claude Code. As a last resort,
  open `<repo web url>/pullrequestcreate?sourceRef=<src>&targetRef=<tgt>` in the browser.
- `401` with auth mode `pat` → token expired or missing the **Code (Read & Write)** scope.
- "not under the configured server URL" → the repo's remote is on another server; fix `server_url`
  via `/plugin configure azurepr@azurepr` (or leave it empty).
- `TF401179` → an active PR for the same source/target already exists.
- A reviewer matched several identities (e.g. an email shared by two accounts) → ask the user which
  account; prefer the one that appears in the candidate list.
- API version errors (`VS800071` / "version not supported") → change `api_version` (5.0 for Azure
  DevOps Server 2019, 6.0+ for 2020+, 7.x for Services).
