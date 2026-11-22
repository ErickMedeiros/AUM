# 24-lab-queries.ps1 · roda cada consulta de um arquivo .kql (separadas por "// ----- Qn") no Resource Graph
param([string]$Arquivo = "$PSScriptRoot\..\scripts\kql\11-tags-governanca.kql", [string]$Sub = (az account show --query id -o tsv))
. "$PSScriptRoot\00-lab-config.ps1"
$txt = Get-Content $Arquivo -Raw
$blocos = [regex]::Split($txt, '(?m)^// (?:-{3,}|={3,}) ?(?=Q\d)') | Select-Object -Skip 1
foreach ($b in $blocos) {
    $titulo = ($b -split "`n")[0].Trim(' -=')
    $q = ($b -split "`n" | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    "===== $titulo"
    try { (Search-AzGraph -Query $q -Subscription $Sub -First 100).Data | Format-Table -AutoSize -Wrap | Out-String -Width 220 }
    catch { "  ERRO: $($_.Exception.Message)" }
}

