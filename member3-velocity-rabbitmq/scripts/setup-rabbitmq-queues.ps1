# Idempotent, NON-destructive queue setup via the RabbitMQ management HTTP API (Windows PowerShell).
# Never deletes or recreates a queue.
$ErrorActionPreference = "Stop"
$Mgmt = if ($env:RABBIT_MGMT) { $env:RABBIT_MGMT } else { "http://localhost:15672" }
$User = if ($env:RABBIT_USER) { $env:RABBIT_USER } else { "guest" }
$Pass = if ($env:RABBIT_PASS) { $env:RABBIT_PASS } else { "guest" }
$Auth = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Pass}")) }

function Ensure-Queue([string]$Name, [hashtable]$Arguments, [bool]$CheckPriority) {
  $url = "$Mgmt/api/queues/%2F/$Name"
  $existing = $null
  try { $existing = Invoke-RestMethod -Uri $url -Headers $Auth -Method Get }
  catch { if ($_.Exception.Response.StatusCode.value__ -ne 404) { throw } }
  if ($existing) {
    Write-Host "[exists] $Name"
    if ($CheckPriority -and $existing.arguments.'x-max-priority' -ne 10) {
      Write-Warning "$Name exists WITHOUT x-max-priority=10. Queue arguments cannot be changed in place; priority 10 will NOT be honoured. See README 'Queue priority'."
    }
  } else {
    $body = @{ durable = $true; auto_delete = $false; arguments = $Arguments } | ConvertTo-Json -Depth 5
    Invoke-RestMethod -Uri $url -Headers $Auth -Method Put -ContentType "application/json" -Body $body | Out-Null
    Write-Host "[create] $Name"
  }
}

Ensure-Queue "fraud-high-priority" @{ "x-max-priority" = 10 } $true
Ensure-Queue "fraud-standard" @{} $false
Ensure-Queue "fraud-dlq" @{} $false
