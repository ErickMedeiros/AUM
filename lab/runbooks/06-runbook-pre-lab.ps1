<#
.SYNOPSIS
  AUM-PreEvent · Pré-evento das Maintenance Configurations do Azure Update Manager (DEV/HML).
.DESCRIPTION
  1. Aceita somente Microsoft.Maintenance.PreMaintenanceEvent (o Event Grid entrega pelo menos uma vez: o script é idempotente).
  2. Guard de calendário: fim de semana, feriado, change freeze (últimos 7 dias do mês) ou Wave em Hold -> cancela a execução.
  3. Lista as máquinas da execução pelo Azure Resource Graph.
  4. Azure VM com Azure Backup -> backup on-demand; sem Azure Backup -> snapshot incremental de SO e dados.
     Servidor Arc -> job no Hybrid Runbook Worker (snapshot no vCenter) conforme a tag PreBackup.
  5. Falha de proteção com AUM-FailClosed = true -> cancela a execução e registra o motivo.
.NOTES
  PowerShell 7.4 · identidade gerenciada da Automation Account.
  Política não-destrutiva: o script não contém nenhum comando Remove-*, nem altera configurações existentes.
  VARIANTE DE LABORATÓRIO: igual a scripts/runbooks/06-runbook-pre.ps1 + variável AUM-IgnorarCalendario e MCs temporárias (mc-aum-lab-*). Não usar em produção.
    1 Search-AzGraph devolve um objeto de resposta: usar .Data (senão @() tem 1 item com todos os IDs juntos).
    2 Get-AzVM -Status não traz Id, Tags nem StorageProfile: ler o modelo e o status separadamente.
    3 VM sem disco gerenciado identificado agora é falha (antes passava "protegida" sem snapshot).
    4 PreBackup da VM Azure é respeitado (AzureBackup exige cofre; Snapshot força snapshot).
    5 Variável AUM-IgnorarCalendario (opcional, só laboratório) para testar fora de dia útil.
#>
param([Parameter(Mandatory = $false)][object]$WebhookData)
$ErrorActionPreference = 'Stop'

function Write-Log([string]$Msg) { Write-Output ('{0:yyyy-MM-dd HH:mm:ss}Z {1}' -f (Get-Date).ToUniversalTime(), $Msg) }

# ---------- Evento ----------
if (-not $WebhookData) { throw 'Runbook acionado sem WebhookData.' }
$evento = (ConvertFrom-Json -InputObject $WebhookData.RequestBody)[0]
if ($evento.eventType -ne 'Microsoft.Maintenance.PreMaintenanceEvent') { Write-Log "Evento ignorado: $($evento.eventType)"; return }

$runId   = $evento.data.CorrelationId                  # .../maintenanceConfigurations/<mc>/providers/microsoft.maintenance/applyupdates/<yyyyMMddHHmmss>
$mcName  = ($evento.data.MaintenanceConfigurationId -split '/')[-1]
$runTag  = ($runId -split '/')[-1]
$inicio  = ([datetimeoffset]::Parse($evento.data.StartDateTime)).UtcDateTime
$corte   = ([datetimeoffset]::Parse($evento.data.CancellationCutOffDateTime)).UtcDateTime
Write-Log "Execução $runTag da $mcName · início $inicio UTC · corte para cancelamento $corte UTC"

Connect-AzAccount -Identity | Out-Null

# ---------- Configuração ----------
$feriados    = (Get-AutomationVariable -Name 'AUM-Feriados') | ConvertFrom-Json
$failClosed  = [System.Convert]::ToBoolean((Get-AutomationVariable -Name 'AUM-FailClosed'))
$retencao    = [int](Get-AutomationVariable -Name 'AUM-RetencaoBackupDias')
$holdWaves   = (Get-AutomationVariable -Name 'AUM-HoldWaves') | ConvertFrom-Json
$hwGroup     = Get-AutomationVariable -Name 'AUM-HybridWorkerGroup'
$aaName      = Get-AutomationVariable -Name 'AUM-AutomationAccount'
$aaRg        = Get-AutomationVariable -Name 'AUM-AutomationRG'
$ligarDesal  = [System.Convert]::ToBoolean((Get-AutomationVariable -Name 'AUM-LigarDesalocadas'))
$ignorarCal  = $false
try { $ignorarCal = [System.Convert]::ToBoolean((Get-AutomationVariable -Name 'AUM-IgnorarCalendario')) } catch { }   # [LAB-FIX 5]
$tz          = [TimeZoneInfo]::FindSystemTimeZoneById('E. South America Standard Time')

function Stop-MaintenanceRun([string]$Motivo) {
    if ((Get-Date).ToUniversalTime() -gt $corte) { Write-Log "ATENÇÃO: prazo de cancelamento expirado. Motivo não aplicado: $Motivo"; return }
    $r = Invoke-AzRestMethod -Method PUT -Path "$($runId)?api-version=2023-09-01-preview" -Payload '{"properties":{"status":"Cancel"}}'
    Write-Log "Cancelamento solicitado (HTTP $($r.StatusCode)): $Motivo"
    if ($r.StatusCode -ge 300) { $script:cancelFalhou = $true; Write-Log "ERRO: cancelamento recusado pela API: $($r.Content)" }   # [LAB-FIX 7]
}
$script:cancelFalhou = $false

function Get-BloqueioCalendario {
    $local = [TimeZoneInfo]::ConvertTimeFromUtc($inicio, $tz)
    $dias  = @($local.Date, $local.Date.AddDays(1))            # noite de início e madrugada seguinte
    foreach ($d in $dias) {
        if ($d.DayOfWeek -in [DayOfWeek]::Saturday, [DayOfWeek]::Sunday) { return "Fim de semana ($($d.ToString('dd/MM')))" }
        if ($feriados -contains $d.ToString('yyyy-MM-dd'))                  { return "Feriado ($($d.ToString('dd/MM')))" }
    }
    $ultimo = [datetime]::DaysInMonth($local.Year, $local.Month)
    if ($local.Day -gt ($ultimo - 7)) { return 'Change freeze: última semana do mês' }
    if ($holdWaves -contains $mcName) { return 'Wave em Hold (decisão No-Go do Change Manager)' }
    return $null
}

$bloqueio = Get-BloqueioCalendario
if ($bloqueio -and $ignorarCal) { Write-Log "LAB: bloqueio de calendário ignorado por AUM-IgnorarCalendario ($bloqueio)"; $bloqueio = $null }
if ($bloqueio) { Stop-MaintenanceRun $bloqueio; if ($script:cancelFalhou) { throw "Cancelamento por calendário não aceito pela API ($bloqueio)" }; return }

# ---------- Máquinas da execução ----------
$q = @"
maintenanceresources
| where type =~ 'microsoft.maintenance/applyupdates'
| where properties.correlationId =~ '$runId'
| project rid = tolower(tostring(properties.resourceId))
"@
$maquinas = @((Search-AzGraph -Query $q -First 1000).Data)                     # [LAB-FIX 1]
if ($maquinas.Count -eq 0) {
    # Alternativa: avaliar o Dynamic Scope (tag PatchWave) quando a lista ainda não foi materializada
    $wave = @{ 'mc-aum-wave1-dev' = 'Wave1-Dev'; 'mc-aum-wave2-hml-piloto' = 'Wave2-HML-Piloto'; 'mc-aum-wave3-hml' = 'Wave3-HML'
               'mc-aum-lab-cancel' = 'Wave2-HML-Piloto'; 'mc-aum-lab-e2e' = 'Wave2-HML-Piloto' }[$mcName]      # LAB: MCs temporárias
    $maquinas = @((Search-AzGraph -First 1000 -Query @"
resources
| where type in~ ('microsoft.compute/virtualmachines','microsoft.hybridcompute/machines')
| where tags.PatchWave =~ '$wave'
| project rid = tolower(id)
"@).Data)                                                                       # [LAB-FIX 1]
}
Write-Log "Máquinas na execução: $($maquinas.Count)"

$falhas = [System.Collections.Generic.List[string]]::new()
foreach ($m in $maquinas) {
    try {
        $p = $m.rid -split '/'
        if ($m.rid -match '/microsoft.hybridcompute/machines/') {
            $arc = Get-AzResource -ResourceId $m.rid
            switch ($arc.Tags.PreBackup) {
                'Hypervisor' {
                    Start-AzAutomationRunbook -AutomationAccountName $aaName -ResourceGroupName $aaRg `
                        -Name 'AUM-Snapshot-vSphere' -RunOn $hwGroup -Parameters @{ VmName = $p[-1]; RunTag = $runTag } | Out-Null
                    Write-Log "Arc $($p[-1]): snapshot vSphere solicitado ao Hybrid Worker"
                }
                'MABS'      { Write-Log "Arc $($p[-1]): proteção por MABS/MARS; verificar ponto de recuperação nas últimas 24 h" }
                default     { throw "Arc $($p[-1]) sem método de proteção (tag PreBackup)." }
            }
            continue
        }
        $vm    = Get-AzVM -ResourceGroupName $p[4] -Name $p[-1]                 # [LAB-FIX 2] modelo: Id, Tags, StorageProfile
        $vmSt  = Get-AzVM -ResourceGroupName $p[4] -Name $p[-1] -Status         # status: PowerState
        $power = ($vmSt.Statuses | Where-Object Code -like 'PowerState/*').Code
        if ($power -ne 'PowerState/running') {
            if ($ligarDesal -and $vm.Tags.PatchStartStop -eq 'true') {
                Start-AzVM -ResourceGroupName $p[4] -Name $p[-1] -NoWait | Out-Null
                Update-AzTag -ResourceId $vm.Id -Tag @{ 'AUM-StartedBy' = $runTag } -Operation Merge | Out-Null
                Write-Log "$($p[-1]): estava desalocada ($power); ligada para a janela (será desligada no pós-evento)"
            } else { Write-Log "$($p[-1]): desalocada; não será atualizada nesta execução"; continue }
        }
        $metodo = $vm.Tags.PreBackup                                                # [LAB-FIX 4]
        $status = if ($metodo -ne 'Snapshot') { Get-AzRecoveryServicesBackupStatus -Name $p[-1] -ResourceGroupName $p[4] -Type AzureVM } else { $null }
        if ($metodo -eq 'AzureBackup' -and -not $status.BackedUp) { throw "$($p[-1]): PreBackup = AzureBackup, mas a VM não está protegida em nenhum cofre" }
        if ($status.BackedUp) {
            $item = Get-AzRecoveryServicesBackupItem -BackupManagementType AzureVM -WorkloadType AzureVM -VaultId $status.VaultId |
                    Where-Object { $_.SourceResourceId -eq $vm.Id }
            if (-not $item) { throw "$($p[-1]): item de backup não encontrado no cofre $($status.VaultId)" }
            $job  = Backup-AzRecoveryServicesBackupItem -Item $item -VaultId $status.VaultId -ExpiryDateTimeUTC (Get-Date).ToUniversalTime().AddDays($retencao)   # [LAB-FIX 6] nome correto do parâmetro
            Write-Log "$($p[-1]): backup on-demand iniciado (job $($job.JobId))"
            # Aguarda só a fase de snapshot; a transferência para o cofre continua em segundo plano
            do {
                Start-Sleep -Seconds 30
                $det  = Get-AzRecoveryServicesBackupJobDetail -Job $job -VaultId $status.VaultId
                $snap = $det.SubTasks | Where-Object Name -eq 'Take Snapshot'
            } while ($snap.Status -notin 'Completed','Failed' -and (Get-Date).ToUniversalTime() -lt $corte.AddMinutes(-2))
            if ($snap.Status -ne 'Completed') { throw "$($p[-1]): snapshot do Azure Backup não concluído ($($snap.Status))" }
            Write-Log "$($p[-1]): backup on-demand com snapshot concluído (retenção $retencao dias)"
        } else {
            $discos = @($vm.StorageProfile.OsDisk.ManagedDisk.Id) + @($vm.StorageProfile.DataDisks | ForEach-Object { $_.ManagedDisk.Id })
            $discos = @($discos | Where-Object { $_ })
            if ($discos.Count -eq 0) { throw "$($p[-1]): nenhum disco gerenciado identificado para snapshot" }   # [LAB-FIX 3]
            foreach ($dId in $discos) {
                $d = Get-AzDisk -ResourceGroupName ($dId -split '/')[4] -DiskName ($dId -split '/')[-1]
                $nome = "snap-aum-$runTag-$($d.Name)"; if ($nome.Length -gt 80) { $nome = $nome.Substring(0, 80) }
                if (Get-AzSnapshot -ResourceGroupName $d.ResourceGroupName -SnapshotName $nome -ErrorAction SilentlyContinue) {
                    Write-Log "Snapshot já existe (execução repetida): $nome"; continue
                }
                # [LAB-FIX 9] valores de tag como [string]: (Get-Date -Format) devolve PSObject e o SDK rejeita (cast PSObject -> String)
                $cfg = New-AzSnapshotConfig -SourceUri $d.Id -Location $d.Location -CreateOption Copy -Incremental -Tag @{
                    MaintenanceRunId = [string]$runTag; MaintenanceConfig = [string]$mcName; CreatedBy = 'AUM-PreEvent'
                    CreatedOn = [string](Get-Date -Format 'yyyy-MM-dd'); SourceDisk = [string]$d.Name; SourceVm = [string]$p[-1] }
                New-AzSnapshot -ResourceGroupName $d.ResourceGroupName -SnapshotName $nome -Snapshot $cfg | Out-Null
                Write-Log "Snapshot incremental criado: $nome"
            }
        }
    } catch {
        $falhas.Add($m.rid)
        Write-Error ("Falha na proteção de $($m.rid): $($_.Exception.Message) [linha $($_.InvocationInfo.ScriptLineNumber): $($_.InvocationInfo.Line.Trim())]") -ErrorAction Continue   # [LAB-FIX 8]
    }
}

if ($falhas.Count -gt 0) {
    if ($failClosed) { Stop-MaintenanceRun "Proteção pré-patch falhou em $($falhas.Count) máquina(s): $($falhas -join ', ')" }
    else { Write-Log "Fail-open: $($falhas.Count) máquina(s) sem proteção; a execução segue e o fato vai para o relatório." }
    throw "Pré-evento terminou com $($falhas.Count) falha(s) de proteção$(if ($script:cancelFalhou) { ' e o cancelamento NÃO foi aceito' })."   # [LAB-FIX 7] job = Failed
}
Write-Log 'Pré-evento concluído.'

