<#
Creates a pull request on an Azure DevOps Server / TFS (or Azure DevOps Services) repo.
Repo coordinates are parsed from the git remote URL:
  https://<host>/tfs/<Collection>/<Project>/_git/<Repo>
  https://dev.azure.com/<Org>/<Project>/_git/<Repo>

Auth:
  -AuthMode integrated   Windows integrated auth (-UseDefaultCredentials), no token needed
  -AuthMode pat          Personal Access Token read from the env var named by -PatEnvVar

Modes:
  -ListCandidates            Print reviewer suggestions (you, team members, recent PR reviewers) as TSV
  -FindReviewer <query>      Look up identities by account name (jdoe, DOMAIN\jdoe) or email
  -CheckOnly                 Report an existing active PR for Source -> Target, or NONE
  -AddReviewersToPr <id>     Add -Reviewers (required) to an existing PR
  (default)                  Create the PR with -Reviewers as required reviewers (you are always added
                             unless -NoSelfReviewer)
Reviewers may be identity GUIDs (preferred, from -ListCandidates / -FindReviewer) or account names.
#>
param(
  [string] $Source,
  [string] $Target,
  [string] $Title,
  [string] $DescriptionFile,
  [string[]] $Reviewers = @(),
  [string] $Remote = 'origin',
  [string] $ServerUrl = '',
  [string] $ApiVersion = '5.0',
  [ValidateSet('integrated', 'pat')] [string] $AuthMode = 'integrated',
  [string] $PatEnvVar = 'AZURE_DEVOPS_EXT_PAT',
  [switch] $Draft,
  [switch] $NoSelfReviewer,
  [switch] $CheckOnly,
  [switch] $ListCandidates,
  [string] $FindReviewer,
  [int] $AddReviewersToPr
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$remoteUrl = (git remote get-url $Remote).Trim() -replace '^(https?://)[^/@]+@', '$1'
if ($remoteUrl -notmatch '^(https?://[^/]+(?:/.+?)?)/_git/([^/]+?)/?$') {
  throw "Remote '$Remote' ($remoteUrl) is not an Azure DevOps/TFS https URL ending in /_git/<repo>"
}
$projectUrl = $Matches[1]
$repo = $Matches[2]
if ($ServerUrl) {
  $base = $ServerUrl.Trim().TrimEnd('/')
  if (-not $remoteUrl.StartsWith("$base/", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Remote '$Remote' ($remoteUrl) is not under the configured server URL ($base). Change server_url with /plugin configure azurepr@azurepr"
  }
}
# Short forms omit the project (the repo has the project's name):
#   https://<host>/tfs/<Collection>/_git/<Repo>, https://dev.azure.com/<Org>/_git/<Repo>, https://<org>.visualstudio.com/_git/<Repo>
if ($projectUrl -match '/tfs/[^/]+$' -or $projectUrl -match '^https?://dev\.azure\.com/[^/]+$' -or $projectUrl -match '^https?://[^/]+$') {
  $projectUrl = "$projectUrl/$repo"
}
$collectionUrl = $projectUrl -replace '/[^/]+$', ''
$project = $projectUrl.Split('/')[-1]
$api = "$projectUrl/_apis/git/repositories/$repo"
$v = "api-version=$ApiVersion"

$auth = @{ UseDefaultCredentials = $true }
if ($AuthMode -eq 'pat') {
  $pat = [Environment]::GetEnvironmentVariable($PatEnvVar)
  if (-not $pat) { throw "Auth mode is 'pat' but environment variable '$PatEnvVar' is empty. Set it to a Personal Access Token with Code (Read & Write) scope." }
  $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes(":$pat"))
  $auth = @{ Headers = @{ Authorization = "Basic $b64" } }
}

function Get-Api([string] $uri) { Invoke-RestMethod -Uri $uri @auth }
function Send-Api([string] $method, [string] $uri, $obj) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 5))
  Invoke-RestMethod -Method $method -Uri $uri @auth -ContentType 'application/json; charset=utf-8' -Body $bytes
}
function Get-Me { (Get-Api "$collectionUrl/_apis/connectionData").authenticatedUser }

function Find-Identity([string] $query) {
  $q = $query.Trim()
  $filter = if ($q -match '@') { 'MailAddress' } else { 'AccountName' }
  if ($filter -eq 'AccountName') { $q = $q -replace '^.*\\', '' }
  $r = Get-Api "$collectionUrl/_apis/identities?searchFilter=$filter&filterValue=$([uri]::EscapeDataString($q))&queryMembership=None&$v"
  @($r.value | Where-Object { $_.isActive -and -not $_.isContainer })
}

function Resolve-ReviewerId([string] $r) {
  if ($r -match '^[0-9a-fA-F-]{36}$') { return $r }
  $found = Find-Identity $r
  if ($found.Count -ne 1) { throw "Reviewer '$r' matched $($found.Count) identities; pass the identity GUID instead (use -FindReviewer)" }
  $found[0].id
}

if ($ListCandidates) {
  $me = Get-Me
  $seen = @{}
  $rows = [System.Collections.Generic.List[string]]::new()
  $add = {
    param($id, $name, $unique, $src)
    if ($id -and -not $seen.ContainsKey($id)) { $seen[$id] = 1; $rows.Add("$id`t$name`t$unique`t$src") }
  }
  & $add $me.id $me.providerDisplayName '(you)' 'self'
  try {
    foreach ($t in (Get-Api "$collectionUrl/_apis/projects/$project/teams?$v").value) {
      foreach ($m in (Get-Api "$collectionUrl/_apis/projects/$project/teams/$($t.id)/members?$v").value) {
        & $add $m.identity.id $m.identity.displayName $m.identity.uniqueName "team:$($t.name)"
      }
    }
  } catch { Write-Warning "Could not read team members: $($_.Exception.Message)" }
  $recent = (Get-Api "$api/pullrequests?searchCriteria.status=all&`$top=50&$v").value.reviewers |
    Where-Object { -not $_.isContainer } | Group-Object id | Sort-Object Count -Descending
  foreach ($g in $recent) { $x = $g.Group[0]; & $add $x.id $x.displayName $x.uniqueName "recent:$($g.Count)" }
  Write-Output "id`tdisplayName`tuniqueName`tsource"
  $rows | ForEach-Object { Write-Output $_ }
  exit 0
}

if ($FindReviewer) {
  $found = Find-Identity $FindReviewer
  if ($found.Count -eq 0) { Write-Output 'NOMATCH'; exit 0 }
  Write-Output "id`tdisplayName`taccount`tmail"
  foreach ($i in $found) {
    Write-Output "$($i.id)`t$($i.providerDisplayName)`t$($i.properties.Domain.'$value')\$($i.properties.Account.'$value')`t$($i.properties.Mail.'$value')"
  }
  exit 0
}

$webBase = (Get-Api "$api`?$v").remoteUrl

function Get-ReviewerIds {
  $ids = @($Reviewers | Where-Object { $_ } | ForEach-Object { Resolve-ReviewerId $_ })
  if (-not $NoSelfReviewer) { $ids = @((Get-Me).id) + $ids }
  @($ids | Select-Object -Unique)
}

if ($AddReviewersToPr) {
  foreach ($id in (Get-ReviewerIds)) {
    $r = Send-Api Put "$api/pullrequests/$AddReviewersToPr/reviewers/$id`?$v" @{ vote = 0; isRequired = $true }
    Write-Output "REVIEWER $($r.displayName) required=$($r.isRequired)"
  }
  Write-Output "URL $webBase/pullrequest/$AddReviewersToPr"
  exit 0
}

if (-not $Source -or -not $Target) { throw '-Source and -Target are required' }
$srcRef = "refs/heads/$Source"
$tgtRef = "refs/heads/$Target"
$existing = Get-Api "$api/pullrequests?searchCriteria.sourceRefName=$srcRef&searchCriteria.targetRefName=$tgtRef&searchCriteria.status=active&$v"
if ($existing.count -gt 0) {
  $pr = $existing.value[0]
  Write-Output "EXISTS #$($pr.pullRequestId) $($pr.title)"
  Write-Output "URL $webBase/pullrequest/$($pr.pullRequestId)"
  exit 0
}
if ($CheckOnly) { Write-Output 'NONE'; exit 0 }

if (-not $Title) { throw '-Title is required' }
$description = if ($DescriptionFile) { Get-Content -Raw -Encoding UTF8 $DescriptionFile } else { '' }
if ($description.Length -gt 4000) { throw "Description is $($description.Length) chars; Azure DevOps limit is 4000" }

$reviewerIds = Get-ReviewerIds
$pr = Send-Api Post "$api/pullrequests?$v" @{
  sourceRefName = $srcRef
  targetRefName = $tgtRef
  title         = $Title
  description   = $description
  isDraft       = [bool]$Draft
  reviewers     = @($reviewerIds | ForEach-Object { @{ id = $_; isRequired = $true } })
}
Write-Output "CREATED #$($pr.pullRequestId) $($pr.title)"
foreach ($r in $pr.reviewers) { Write-Output "REVIEWER $($r.displayName) required=$($r.isRequired)" }
Write-Output "URL $webBase/pullrequest/$($pr.pullRequestId)"
