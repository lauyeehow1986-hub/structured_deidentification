# tools/audit_pathlen.ps1 — worst-case MAX_PATH audit for a bundle tree.
# Computes len(assumedRoot) + 1 + len(relativePath) for every file and flags any
# over budget. Default root models extraction into a user's Downloads as 'sds'
# with a conservative ~20-char username, so the audit holds for most operators.
# Windows classic MAX_PATH is 260 for an absolute path; the locked-down target
# cannot enable long-path support, so the bundle must fit by construction.
param(
  [string]$Path = ".",
  [string]$Root = "C:\Users\a_twenty_char_userxx\Downloads\sds",  # conservative
  [int]$Warn = 240,
  [int]$Max  = 255,
  [int]$Top  = 15
)
$ErrorActionPreference = "Stop"
$base = (Resolve-Path -LiteralPath $Path).Path
$rootLen = $Root.TrimEnd('\').Length + 1   # +1 for the separator before the rel path
$items = Get-ChildItem -LiteralPath $base -Recurse -File -Force | ForEach-Object {
  $rel = $_.FullName.Substring($base.Length).TrimStart('\')
  [pscustomobject]@{ Abs = $rootLen + $rel.Length; Rel = $rel }
}
if (-not $items) { Write-Host "No files under $base."; exit 0 }
$sorted = $items | Sort-Object Abs -Descending
$maxAbs = ($sorted | Select-Object -First 1).Abs
Write-Host ("Assumed root: {0}  (len {1})" -f $Root, $rootLen)
Write-Host ("Files: {0}   Longest absolute: {1}   Budget: warn>{2} fail>{3}" -f $items.Count, $maxAbs, $Warn, $Max)
Write-Host "`nTop $Top longest (worst-case absolute):"
$sorted | Select-Object -First $Top | ForEach-Object { "{0,4}  {1}" -f $_.Abs, $_.Rel }
$overItems = @($sorted | Where-Object { $_.Abs -gt $Max })
$warnItems = @($sorted | Where-Object { $_.Abs -gt $Warn -and $_.Abs -le $Max })
if ($warnItems.Count) { Write-Host ("`nWARN: {0} file(s) between {1} and {2}." -f $warnItems.Count, $Warn, $Max) -ForegroundColor Yellow }
if ($overItems.Count) { Write-Host ("`nFAIL: {0} file(s) exceed {1}." -f $overItems.Count, $Max) -ForegroundColor Red; exit 1 }
Write-Host "`nPASS: all paths within budget." -ForegroundColor Green; exit 0
