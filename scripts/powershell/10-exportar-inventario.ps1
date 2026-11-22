# Exporta a Q1 (arquivo 10b-inventario-so-suporte-Q1.kql) para CSV (alternativa ao Download do portal)
# Requer: Az.Accounts e Az.ResourceGraph · leitura (Reader) na assinatura alvo
param([Parameter(Mandatory)][string]$Sub)
if (-not (Get-AzContext)) { Connect-AzAccount | Out-Null }
Set-AzContext -Subscription $Sub | Out-Null
 
# Lê a Q1 e remove as linhas de comentário
$texto = Get-Content (Join-Path $PSScriptRoot '..\kql\10b-inventario-so-suporte-Q1.kql') -Raw
$q1 = $texto -replace '(?m)^\s*//.*$', ''
 
$tudo = @(); $skip = $null
do {
    $r = if ($skip) { Search-AzGraph -Query $q1 -Subscription $Sub -First 1000 -SkipToken $skip }
         else       { Search-AzGraph -Query $q1 -Subscription $Sub -First 1000 }
    $tudo += $r; $skip = $r.SkipToken
} while ($skip)
 
$arquivo = ".\inventario-so-suporte-$(Get-Date -Format 'yyyyMMdd').csv"
$tudo | Select-Object * -ExcludeProperty ResourceId | Export-Csv $arquivo -NoTypeInformation -Encoding UTF8 -Delimiter ';'
Write-Output "Exportado: $arquivo ($($tudo.Count) máquinas)"

