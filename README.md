# azurepr — Azure DevOps PR plugin for Claude Code

A [Claude Code](https://code.claude.com) plugin that interactively creates pull requests, with
required reviewers, on **Azure DevOps Server / TFS** (on-prem) and **Azure DevOps Services** repos.

Claude walks you through each step and asks before it acts:

1. Pick the source and target branches. It offers to push first if needed.
2. It checks for an existing PR and summarizes the changes.
3. Choose reviewers. Suggestions come from your teams and recent PR reviewers, and you are added as a required reviewer by default.
4. Choose a title and whether to publish or open a draft.
5. It writes a templated description (types of changes, checklist, deployment notes).
6. Confirm, and the PR is created.

Nothing is pushed or created until you confirm.

## Install

Inside Claude Code:

```
/plugin marketplace add rosdyana/azurepr
/plugin install azurepr@azurepr
```

The install opens a **configuration dialog**:

| Setting | Default | Description |
|---|---|---|
| `server_url` | *(empty)* | Base URL of your server, e.g. `https://devops.example.com/tfs` or `https://dev.azure.com/your-org`. Remotes outside this URL are refused. Leave it empty to accept any `/_git/` remote. |
| `default_target_branch` | `main` | The branch suggested first as the PR target. |
| `api_version` | `5.0` | REST api-version. `5.0` works on Azure DevOps Server 2019 and newer. Use `6.0`/`7.0` for newer servers or for Services. |
| `styleguide_url` | *(empty)* | If set, the PR checklist links to your style guide. |
| `auth_mode` | `integrated` | `integrated` uses Windows integrated auth or Kerberos. `pat` uses a Personal Access Token. |
| `pat_env_var` | `AZURE_DEVOPS_EXT_PAT` | The environment variable that holds your PAT. It is only used when `auth_mode` is `pat`. |

To change settings later, run `/plugin configure azurepr@azurepr`, or use **Configure options** in `/plugin`.

To install non-interactively from a shell, run:

```bash
claude plugin marketplace add rosdyana/azurepr
claude plugin install azurepr@azurepr \
  --config server_url=https://devops.example.com/tfs \
  --config default_target_branch=develop
```

## Authentication

- **`integrated`** (default) needs no token.
  - On domain-joined Windows on the corporate network/VPN, this just works.
  - On macOS or Linux it uses Kerberos (`kinit you@REALM` first) through `curl --negotiate`.
- **`pat`** is for machines that aren't domain-joined, and for Azure DevOps Services.
  1. Create a PAT with the **Code (Read & Write)** scope.
  2. Put it in the environment variable named by `pat_env_var`.
  3. Restart Claude Code.

  ```powershell
  # Windows (persists for your user)
  [Environment]::SetEnvironmentVariable('AZURE_DEVOPS_EXT_PAT', '<token>', 'User')
  ```
  ```bash
  # macOS / Linux: add to ~/.zshrc or ~/.bashrc
  export AZURE_DEVOPS_EXT_PAT='<token>'
  ```

The plugin never stores your token. Its settings only hold the *name* of the environment variable.

## Requirements

- Claude Code **v2.1.271 or newer**.
- A git repo whose remote is an https Azure DevOps / TFS URL containing `/_git/`.
- One of the following:
  - **Windows:** PowerShell 5.1+ or PowerShell 7 (`scripts/create-pr.ps1`).
  - **macOS / Linux / Git Bash:** `bash`, `curl` 7.76+ and [`jq`](https://jqlang.github.io/jq/download/) (`scripts/create-pr.sh`).

## Usage

In a repo with an Azure DevOps remote, ask in plain language:

```
create a PR to main
merge feat-123 to develop
add reviewers to my PR
```

You can also invoke the skill directly with `/azurepr:azure-pr feat-123 to main`.

## Updating

Third-party marketplaces don't auto-update by default. To update, run:

```
claude plugin update azurepr@azurepr
```

## License

MIT
