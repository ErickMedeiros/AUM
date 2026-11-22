# 21-lab-simular-evento.ps1 · envia ao webhook um PreMaintenanceEvent/PostMaintenanceEvent no formato do Event Grid
# O CorrelationId é fictício (a API de cancelamento responde 404, o que prova o caminho de cancelamento sem afetar nada).
param(
    [Parameter(Mandatory)][ValidateSet('mc-aum-wave1-dev', 'mc-aum-wave2-hml-piloto', 'mc-aum-wave3-hml')][string]$Mc,
    [ValidateSet('Pre', 'Post')][string]$Tipo = 'Pre',
    [string]$InicioBrt = '2026-11-23 22:00',      # segunda-feira útil, fora do freeze
    [string]$RunTag = (Get-Date -Format 'yyyyMMddHHmmss')
)
$Sub = (az account show --query id -o tsv)
$mcId = "/subscriptions/$Sub/resourcegroups/rg-aum-patching/providers/microsoft.maintenance/maintenanceconfigurations/$Mc"
$tz = [TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time')
$ini = [TimeZoneInfo]::ConvertTimeToUtc([datetime]::ParseExact($InicioBrt, 'yyyy-MM-dd HH:mm', $null), $tz)
$wh = Get-Content "$PSScriptRoot\webhooks.local.json" -Raw | ConvertFrom-Json
$ev = @(@{
    id = [guid]::NewGuid().Guid; topic = $mcId; subject = $Mc
    eventType = "Microsoft.Maintenance.$($Tipo)MaintenanceEvent"; eventTime = (Get-Date).ToUniversalTime().ToString('o'); dataVersion = '1.0'
    data = @{
        CorrelationId = "$mcId/providers/microsoft.maintenance/applyupdates/$RunTag"
        MaintenanceConfigurationId = $mcId; ResourceSubscriptionIds = @($Sub)
        StartDateTime = $ini.ToString('yyyy-MM-ddTHH:mm:ssZ'); EndDateTime = $ini.AddHours(3).AddMinutes(55).ToString('yyyy-MM-ddTHH:mm:ssZ')
        CancellationCutOffDateTime = $ini.AddMinutes(-10).ToString('yyyy-MM-ddTHH:mm:ssZ'); Status = $(if ($Tipo -eq 'Post') { 'Succeeded' } else { 'Pending' })
    } })
$url = if ($Tipo -eq 'Pre') { $wh.pre } else { $wh.post }
$r = Invoke-RestMethod -Method Post -Uri $url -Body (ConvertTo-Json -InputObject $ev -Depth 6) -ContentType 'application/json'
Write-Output "$Tipo $Mc · run $RunTag · início $InicioBrt BRT · job $($r.JobIds -join ',')"

