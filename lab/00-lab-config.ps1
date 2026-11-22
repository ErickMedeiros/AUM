# 00-lab-config.ps1 · parâmetros do laboratório e conexão do Az PowerShell reaproveitando o login do Azure CLI
# Uso: . .\00-lab-config.ps1   (dot-source). Antes: az login --tenant <tenant-id>; az account set --subscription <subscription-id>
$ctx = az account show -o json | ConvertFrom-Json
if (-not $ctx) { throw 'Azure CLI sem login. Rode az login e az account set --subscription <id-da-assinatura-de-laboratório>.' }
$Lab = @{
    Sub    = $ctx.id
    Tenant = $ctx.tenantId
    RG     = 'rg-aum-patching'
    Loc    = 'brazilsouth'
    AA     = 'aa-aum-patching-lab'
    Vault  = 'rsv-aum-lab'
    Dir    = $PSScriptRoot
    Upn    = $ctx.user.name
}
$tok = az account get-access-token --subscription $Lab.Sub --query accessToken -o tsv
Connect-AzAccount -AccessToken $tok -AccountId $Lab.Upn -TenantId $Lab.Tenant -SubscriptionId $Lab.Sub -WarningAction SilentlyContinue | Out-Null
Write-Verbose "Laboratório: assinatura $($ctx.name)"
