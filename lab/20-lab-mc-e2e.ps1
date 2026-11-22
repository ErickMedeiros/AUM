# 20-lab-mc-e2e.ps1 · MCs temporárias para teste real (cancelamento por calendário e ciclo completo)
# Reaproveita os mesmos webhooks; escopo dinâmico = PatchWave Wave2-HML-Piloto (VM-HyperV-Host).
param([int]$MinCancel = 50, [int]$MinE2E = 95)
. "$PSScriptRoot\00-lab-config.ps1"
$Sub = $Lab.Sub; $RG = $Lab.RG; $aaId = "/subscriptions/$Sub/resourceGroups/$RG/providers/Microsoft.Automation/automationAccounts/$($Lab.AA)"
$wh = Get-Content "$PSScriptRoot\webhooks.local.json" -Raw | ConvertFrom-Json
$tz = [TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time')
$agoraBrt = [TimeZoneInfo]::ConvertTimeFromUtc((Get-Date).ToUniversalTime(), $tz)
$excl = Get-Content "$PSScriptRoot\..\scripts\bicep\linux-exclusions.json" -Raw | ConvertFrom-Json

foreach ($t in @(@{ n = 'mc-aum-lab-cancel'; m = $MinCancel }, @{ n = 'mc-aum-lab-e2e'; m = $MinE2E })) {
    $ini = $agoraBrt.AddMinutes($t.m); $ini = $ini.AddSeconds(-$ini.Second)
    $body = @{ location = $Lab.Loc; tags = @{ Finalidade = 'AUM Lab temporario' }
      properties = @{ maintenanceScope = 'InGuestPatch'; visibility = 'Custom'; extensionProperties = @{ InGuestPatchMode = 'User' }
        maintenanceWindow = @{ startDateTime = $ini.ToString('yyyy-MM-dd HH:mm'); expirationDateTime = $ini.AddHours(3).ToString('yyyy-MM-dd HH:mm')
                               duration = '01:30'; timeZone = 'E. South America Standard Time'; recurEvery = '1Day' }
        installPatches = @{ rebootSetting = 'Never'
          windowsParameters = @{ classificationsToInclude = @('Critical', 'Security'); kbNumbersToExclude = @() }
          linuxParameters   = @{ classificationsToInclude = @('Critical', 'Security'); packageNameMasksToExclude = @($excl) } } } } | ConvertTo-Json -Depth 8
    $mcId = "/subscriptions/$Sub/resourceGroups/$RG/providers/Microsoft.Maintenance/maintenanceConfigurations/$($t.n)"
    $r = Invoke-AzRestMethod -Method PUT -Path "$($mcId)?api-version=2023-04-01" -Payload $body
    Write-Output "$($t.n): HTTP $($r.StatusCode) · início $($ini.ToString('dd/MM HH:mm')) BRT"
    $ds = @{ properties = @{ maintenanceConfigurationId = $mcId; filter = @{ resourceTypes = @('Microsoft.Compute/virtualMachines'); osTypes = @('Windows', 'Linux')
              tagSettings = @{ filterOperator = 'All'; tags = @{ PatchWave = @('Wave2-HML-Piloto') } } } } } | ConvertTo-Json -Depth 8
    $r = Invoke-AzRestMethod -Method PUT -Path "/subscriptions/$Sub/providers/Microsoft.Maintenance/configurationAssignments/ds-$($t.n)?api-version=2023-04-01" -Payload $ds
    Write-Output "  dynamic scope ds-$($t.n): HTTP $($r.StatusCode)"
    az eventgrid system-topic create -g $RG -n "evgt-$($t.n)" --location $Lab.Loc --topic-type Microsoft.Maintenance.MaintenanceConfigurations --source $mcId -o none
    az eventgrid system-topic event-subscription create -g $RG --system-topic-name "evgt-$($t.n)" -n "pre-$($t.n)" --endpoint-type webhook --endpoint $wh.pre --included-event-types Microsoft.Maintenance.PreMaintenanceEvent -o none
    az eventgrid system-topic event-subscription create -g $RG --system-topic-name "evgt-$($t.n)" -n "post-$($t.n)" --endpoint-type webhook --endpoint $wh.post --included-event-types Microsoft.Maintenance.PostMaintenanceEvent -o none
    Write-Output "  event grid: $((az eventgrid system-topic event-subscription list -g $RG --system-topic-name "evgt-$($t.n)" --query '[].provisioningState' -o tsv) -join ',')"
}

# Republica o AUM-PreEvent com o mapa das MCs de laboratório
$api = '2023-05-15-preview'
$r2 = Invoke-AzRestMethod -Method PUT -Path "$aaId/runbooks/AUM-PreEvent/draft/content?api-version=$api" -Payload (Get-Content "$PSScriptRoot\06-runbook-pre.ps1" -Raw)
$r3 = Invoke-AzRestMethod -Method POST -Path "$aaId/runbooks/AUM-PreEvent/publish?api-version=$api"
Write-Output "AUM-PreEvent republicado: content $($r2.StatusCode) · publish $($r3.StatusCode)"

