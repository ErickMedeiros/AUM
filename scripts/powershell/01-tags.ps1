<#
.SYNOPSIS  Aplica as tags Ambiente, PatchWave, PreBackup, SystemOwner, Sistema e PatchStartStop a partir do CSV aprovado.
.DESCRIPTION
  Lê AUM_Tags_Proposta.csv (separador ;) e processa só as linhas com Aprovado = S.
  Valida valores e coerência Ambiente × PatchWave antes de gravar.
  Sem -Aplicar: só simula e gera o relatório. Com -Aplicar: grava em modo Merge (preserva as demais tags; nada é removido).
.EXAMPLE  .\01-tags.ps1 -Sub <subscription-id> -Csv .\AUM_Tags_Proposta.csv                 # simulação
.EXAMPLE  .\01-tags.ps1 -Sub <subscription-id> -Csv .\AUM_Tags_Proposta.csv -Aplicar -Ambiente DEV   # grava só as linhas DEV
.NOTES    v1.1: -Sub parametrizado; valores validados com diferenciação de maiúsculas (-cnotin); relatório com segundos.
#>
param(
    [Parameter(Mandatory)][string]$Sub,
    [string]$Csv = '.\AUM_Tags_Proposta.csv',
    [ValidateSet('DEV', 'HML', 'PROD', 'TODOS')][string]$Ambiente = 'TODOS',
    [switch]$Aplicar
)
$ErrorActionPreference = 'Stop'
Set-AzContext -Subscription $Sub | Out-Null

$ambOk   = 'DEV', 'HML', 'PROD'
$waveOk  = 'Wave1-Dev', 'Wave2-HML-Piloto', 'Wave3-HML', 'Hold', 'Nao-Aplicavel'
$backOk  = 'AzureBackup', 'Snapshot', 'Hypervisor', 'MABS', ''
$coerente = @{ DEV = 'Wave1-Dev', 'Hold', 'Nao-Aplicavel'; HML = 'Wave2-HML-Piloto', 'Wave3-HML', 'Hold', 'Nao-Aplicavel'; PROD = 'Hold', 'Nao-Aplicavel' }

$linhas = Import-Csv $Csv -Delimiter ';' | Where-Object { $_.Aprovado -eq 'S' -and ($Ambiente -eq 'TODOS' -or $_.Ambiente -eq $Ambiente) }
$relatorio = foreach ($l in $linhas) {
    $erro = @()
    if ($l.Ambiente -cnotin $ambOk)  { $erro += "Ambiente inválido '$($l.Ambiente)'" }
    if ($l.PatchWave -cnotin $waveOk) { $erro += "PatchWave inválida '$($l.PatchWave)'" }
    if ($l.PreBackup -cnotin $backOk) { $erro += "PreBackup inválido '$($l.PreBackup)'" }
    if ($l.Ambiente -cin $ambOk -and $l.PatchWave -cnotin $coerente[$l.Ambiente]) { $erro += "PatchWave $($l.PatchWave) não é permitida para $($l.Ambiente)" }
    if ($l.PatchWave -like 'Wave*' -and -not $l.SystemOwner) { $erro += 'SystemOwner obrigatório para máquina em Wave' }
    if ($l.PatchWave -like 'Wave*' -and -not $l.PreBackup)   { $erro += 'PreBackup obrigatório para máquina em Wave' }

    $tags = @{ Ambiente = $l.Ambiente; PatchWave = $l.PatchWave }
    foreach ($k in 'PreBackup', 'SystemOwner', 'Sistema', 'PatchStartStop') { if ($l.$k) { $tags[$k] = $l.$k } }

    $acao = if ($erro) { 'Rejeitada' } elseif ($Aplicar) { 'Aplicada' } else { 'Simulada' }
    if (-not $erro -and $Aplicar) {
        try { Update-AzTag -ResourceId $l.ResourceId -Tag $tags -Operation Merge | Out-Null }
        catch { $acao = 'Falhou'; $erro += $_.Exception.Message }
    }
    [pscustomobject]@{ Nome = $l.Nome; Ambiente = $l.Ambiente; PatchWave = $l.PatchWave; Acao = $acao; Detalhe = ($erro -join '; ') }
}
$relatorio | Format-Table -AutoSize
$arq = ".\tags-relatorio-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
$relatorio | Export-Csv $arq -Encoding UTF8 -Delimiter ';'
Write-Output "Relatório: $arq · Aplicadas: $(@($relatorio | ? Acao -eq 'Aplicada').Count) · Simuladas: $(@($relatorio | ? Acao -eq 'Simulada').Count) · Rejeitadas: $(@($relatorio | ? Acao -eq 'Rejeitada').Count)"

