param(
  [string]$Action = "spawn_tank",
  [string]$User = "tester"
)

$payload = @{
  action = $Action
  user = $User
} | ConvertTo-Json

Invoke-RestMethod -Uri "http://127.0.0.1:8787/event" -Method Post -ContentType "application/json" -Body $payload
