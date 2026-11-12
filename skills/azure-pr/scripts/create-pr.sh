#!/usr/bin/env bash
# Creates a pull request on an Azure DevOps Server / TFS (or Azure DevOps Services) repo.
# Bash + curl + jq port of create-pr.ps1 with the same modes and output format.
#
# Repo coordinates are parsed from the git remote URL:
#   https://<host>/tfs/<Collection>/<Project>/_git/<Repo>
#   https://dev.azure.com/<Org>/<Project>/_git/<Repo>
#
# Auth:
#   --auth-mode integrated   SPNEGO/Kerberos via curl --negotiate (SSPI on Windows Git Bash,
#                            a Kerberos ticket from kinit on macOS/Linux)
#   --auth-mode pat          Personal Access Token read from the env var named by --pat-env-var
#
# Modes:
#   --list-candidates            Reviewer suggestions (you, team members, recent PR reviewers) as TSV
#   --find-reviewer <query>      Look up identities by account name (jdoe, DOMAIN\jdoe) or email
#   --check-only                 Report an existing active PR for source -> target, or NONE
#   --add-reviewers-to-pr <id>   Add --reviewers (required) to an existing PR
#   (default)                    Create the PR with --reviewers as required reviewers (you are always
#                                added unless --no-self-reviewer)
# --reviewers takes a comma-separated list of identity GUIDs (preferred) or account names.
set -euo pipefail

die() { echo "ERROR: $*" >&2; exit 1; }

source_branch='' target_branch='' title='' description_file='' reviewers='' remote='origin'
server_url='' api_version='5.0' auth_mode='integrated' pat_env_var='AZURE_DEVOPS_EXT_PAT'
draft=false no_self=false check_only=false list_candidates=false find_reviewer='' add_to_pr=''

while [ $# -gt 0 ]; do
  case "$1" in
    --source) source_branch="$2"; shift 2 ;;
    --target) target_branch="$2"; shift 2 ;;
    --title) title="$2"; shift 2 ;;
    --description-file) description_file="$2"; shift 2 ;;
    --reviewers) reviewers="$2"; shift 2 ;;
    --remote) remote="$2"; shift 2 ;;
    --server-url) server_url="$2"; shift 2 ;;
    --api-version) api_version="$2"; shift 2 ;;
    --auth-mode) auth_mode="$2"; shift 2 ;;
    --pat-env-var) pat_env_var="$2"; shift 2 ;;
    --draft) draft=true; shift ;;
    --no-self-reviewer) no_self=true; shift ;;
    --check-only) check_only=true; shift ;;
    --list-candidates) list_candidates=true; shift ;;
    --find-reviewer) find_reviewer="$2"; shift 2 ;;
    --add-reviewers-to-pr) add_to_pr="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

command -v curl >/dev/null || die "curl is required"
command -v jq >/dev/null || die "jq is required (https://jqlang.github.io/jq/download/)"

# ---- repo coordinates -------------------------------------------------------
remote_url=$(git remote get-url "$remote" | tr -d '\r\n')
remote_url=$(printf '%s' "$remote_url" | sed -E 's#^(https?://)[^/@]+@#\1#')
if [[ ! "$remote_url" =~ ^(https?://[^/]+(/.+)?)/_git/([^/]+)/?$ ]]; then
  die "Remote '$remote' ($remote_url) is not an Azure DevOps/TFS https URL ending in /_git/<repo>"
fi
project_url="${BASH_REMATCH[1]}"
repo="${BASH_REMATCH[3]}"
if [ -n "$server_url" ]; then
  base="${server_url%/}"
  shopt -s nocasematch
  if [[ "$remote_url" != "$base/"* ]]; then
    die "Remote '$remote' ($remote_url) is not under the configured server URL ($base). Change server_url with /plugin configure azurepr@azurepr"
  fi
  shopt -u nocasematch
fi
# Short forms omit the project (the repo has the project's name)
if [[ "$project_url" =~ /tfs/[^/]+$ || "$project_url" =~ ^https?://dev\.azure\.com/[^/]+$ || "$project_url" =~ ^https?://[^/]+$ ]]; then
  project_url="$project_url/$repo"
fi
collection_url="${project_url%/*}"
project="${project_url##*/}"
api="$project_url/_apis/git/repositories/$repo"
v="api-version=$api_version"

# ---- http -------------------------------------------------------------------
case "$auth_mode" in
  integrated) auth_args=(--negotiate -u :) ;;
  pat)
    pat="${!pat_env_var:-}"
    [ -n "$pat" ] || die "Auth mode is 'pat' but environment variable '$pat_env_var' is empty. Set it to a Personal Access Token with Code (Read & Write) scope."
    auth_args=(-u ":$pat") ;;
  *) die "--auth-mode must be 'integrated' or 'pat'" ;;
esac

get_api() { curl -sS --fail-with-body "${auth_args[@]}" "$1"; }
send_api() { # method uri json
  curl -sS --fail-with-body "${auth_args[@]}" -X "$1" -H 'Content-Type: application/json; charset=utf-8' --data-binary @- "$2" <<<"$3"
}
me_id() { get_api "$collection_url/_apis/connectionData" | jq -r '.authenticatedUser.id'; }
urienc() { jq -rn --arg s "$1" '$s|@uri'; }

find_identity() { # prints JSON array of active, non-container identities
  local q filter
  q=$(printf '%s' "$1" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
  if [[ "$q" == *@* ]]; then filter=MailAddress; else filter=AccountName; q="${q##*\\}"; fi
  get_api "$collection_url/_apis/identities?searchFilter=$filter&filterValue=$(urienc "$q")&queryMembership=None&$v" |
    jq '[.value[] | select(.isActive and ((.isContainer // false) | not))]'
}

resolve_reviewer_id() {
  local r="$1" found n
  if [[ "$r" =~ ^[0-9a-fA-F-]{36}$ ]]; then echo "$r"; return; fi
  found=$(find_identity "$r")
  n=$(jq 'length' <<<"$found")
  [ "$n" -eq 1 ] || die "Reviewer '$r' matched $n identities; pass the identity GUID instead (use --find-reviewer)"
  jq -r '.[0].id' <<<"$found"
}

# ---- modes ------------------------------------------------------------------
if $list_candidates; then
  me=$(get_api "$collection_url/_apis/connectionData" | jq -c '.authenticatedUser')
  rows=$(jq -r '[.id, .providerDisplayName, "(you)", "self"] | @tsv' <<<"$me")
  if teams=$(get_api "$collection_url/_apis/projects/$(urienc "$project")/teams?$v" 2>&1); then
    while IFS=$'\t' read -r tid tname; do
      [ -n "$tid" ] || continue
      if members=$(get_api "$collection_url/_apis/projects/$(urienc "$project")/teams/$tid/members?$v" 2>&1); then
        rows+=$'\n'$(jq -r --arg t "team:$tname" '.value[] | [.identity.id, .identity.displayName, .identity.uniqueName, $t] | @tsv' <<<"$members")
      else echo "WARNING: Could not read team members: $members" >&2; fi
    done < <(jq -r '.value[] | [.id, .name] | @tsv' <<<"$teams" | tr -d '\r')
  else
    echo "WARNING: Could not read team members: $teams" >&2
  fi
  rows+=$'\n'$(get_api "$api/pullrequests?searchCriteria.status=all&\$top=50&$v" | jq -r '
    [.value[].reviewers[]? | select((.isContainer // false) | not)]
    | group_by(.id) | map({n: length, r: .[0]}) | sort_by(-.n)[]
    | [.r.id, .r.displayName, .r.uniqueName, "recent:\(.n)"] | @tsv')
  printf 'id\tdisplayName\tuniqueName\tsource\n'
  printf '%s\n' "$rows" | tr -d '\r' | awk -F'\t' 'NF && $1 != "" && !seen[$1]++'
  exit 0
fi

if [ -n "$find_reviewer" ]; then
  found=$(find_identity "$find_reviewer")
  if [ "$(jq 'length' <<<"$found")" -eq 0 ]; then echo NOMATCH; exit 0; fi
  printf 'id\tdisplayName\taccount\tmail\n'
  jq -r '.[] | [.id, .providerDisplayName,
    "\(.properties.Domain["$value"] // "")\\\(.properties.Account["$value"] // "")",
    (.properties.Mail["$value"] // "")] | @tsv' <<<"$found"
  exit 0
fi

web_base=$(get_api "$api?$v" | jq -r '.remoteUrl')

reviewer_ids() { # one GUID per line, self first unless --no-self-reviewer, de-duplicated
  {
    $no_self || me_id
    if [ -n "$reviewers" ]; then
      IFS=',' read -ra list <<<"$reviewers"
      for r in "${list[@]}"; do
        r=$(printf '%s' "$r" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g')
        if [ -n "$r" ]; then resolve_reviewer_id "$r"; fi
      done
    fi
  } | tr -d '\r' | awk 'NF && !seen[tolower($0)]++'
}

if [ -n "$add_to_pr" ]; then
  ids=$(reviewer_ids)
  while read -r id; do
    [ -n "$id" ] || continue
    send_api PUT "$api/pullrequests/$add_to_pr/reviewers/$id?$v" '{"vote":0,"isRequired":true}' |
      jq -r '"REVIEWER \(.displayName) required=\(.isRequired)"'
  done <<<"$ids"
  echo "URL $web_base/pullrequest/$add_to_pr"
  exit 0
fi

[ -n "$source_branch" ] && [ -n "$target_branch" ] || die "--source and --target are required"
src_ref="refs/heads/$source_branch"
tgt_ref="refs/heads/$target_branch"
existing=$(get_api "$api/pullrequests?searchCriteria.sourceRefName=$(urienc "$src_ref")&searchCriteria.targetRefName=$(urienc "$tgt_ref")&searchCriteria.status=active&$v")
if [ "$(jq '.count' <<<"$existing")" -gt 0 ]; then
  jq -r '.value[0] | "EXISTS #\(.pullRequestId) \(.title)"' <<<"$existing"
  echo "URL $web_base/pullrequest/$(jq -r '.value[0].pullRequestId' <<<"$existing")"
  exit 0
fi
if $check_only; then echo NONE; exit 0; fi

[ -n "$title" ] || die "--title is required"
description=''
if [ -n "$description_file" ]; then description=$(cat "$description_file"); fi
desc_len=$(jq -rn --arg d "$description" '$d | length')
[ "$desc_len" -le 4000 ] || die "Description is $desc_len chars; Azure DevOps limit is 4000"

ids_json=$(reviewer_ids | jq -R . | jq -sc 'map({id: ., isRequired: true})')
body=$(jq -n --arg s "$src_ref" --arg t "$tgt_ref" --arg title "$title" --arg d "$description" \
  --argjson draft "$draft" --argjson reviewers "$ids_json" \
  '{sourceRefName: $s, targetRefName: $t, title: $title, description: $d, isDraft: $draft, reviewers: $reviewers}')
pr=$(send_api POST "$api/pullrequests?$v" "$body")
jq -r '"CREATED #\(.pullRequestId) \(.title)", (.reviewers[] | "REVIEWER \(.displayName) required=\(.isRequired)")' <<<"$pr"
echo "URL $web_base/pullrequest/$(jq -r '.pullRequestId' <<<"$pr")"
