# Changelog

## v1.1 · revisão após teste em laboratório

A v1.0 foi implantada de ponta a ponta numa assinatura de laboratório. Os defeitos abaixo foram reproduzidos no teste e corrigidos; as correções estão marcadas com `[LAB-FIX n]` nos runbooks.

### Críticos (a v1.0 não funcionava)

| # | Arquivo | Defeito | Correção |
|---|---|---|---|
| 1 | runbooks 06 e 07 | `@(Search-AzGraph …)` devolve **um objeto de resposta** e não as linhas: `$m.rid` vira todos os IDs concatenados, toda máquina falha e, com fail-closed, toda Wave seria cancelada. Com resultado vazio, o fallback por tag nunca rodava. | `(Search-AzGraph …).Data` |
| 2 | runbook 06 | `Get-AzVM -Status` não traz `Id`, `Tags` nem `StorageProfile`: o snapshot nunca era criado e a VM passava como protegida; o item de backup não era encontrado; o PatchStartStop nunca ligava a VM. | Ler modelo e status separadamente; VM sem disco identificado é falha |
| 3 | runbook 06 | `Backup-AzRecoveryServicesBackupItem -ExpiryDateUTC` não existe. | `-ExpiryDateTimeUTC` |
| 4 | runbook 06 | Valor de tag `(Get-Date -Format …)` é PSObject: `New-AzSnapshotConfig` falha com *Unable to cast PSObject to String*. | `[string]` em todos os valores |
| 5 | 05-automation | `New-AzRoleDefinition` com `Actions` na raiz é rejeitado no Az.Resources 10 (*Invalid value for Permissions*). | JSON com array `Permissions` |
| 6 | 05-automation | `Import-AzAutomationRunbook -Type PowerShell72` cria runbook 7.2 e conta nova não tem runtime 7.4. | Cria o runtime environment `PowerShell-7.4` (Az 12.3.0) e publica os runbooks nele via REST |
| 7 | 04-policies | `az policy remediation create … --scope` não existe no Azure CLI 2.86. | Assinatura padrão ou `-g` |

### Altos

| # | Arquivo | Defeito | Correção |
|---|---|---|---|
| 8 | papel AUM Pre-Patch Operator | Sem `virtualMachines/start/action`, `virtualMachines/deallocate/action` e `Microsoft.Resources/tags/write`: o PatchStartStop recebeu **403 AuthorizationFailed** no teste. | Ações incluídas (ainda sem nenhuma ação de delete) |
| 9 | 04-policies | Periodic Assessment tem `osType` com padrão Windows: o Linux ficava de fora. | Uma atribuição por SO e por plataforma |
| 10 | 04-policies | Remediações de CMS e Periodic Assessment em paralelo dão `Conflict` numa VM e desfazem a configuração em outra. | Remediação em sequência |
| 11 | runbook 06 | Falha de proteção ou cancelamento recusado (HTTP 409) terminavam o job como Completed. | Job termina **Failed**; erro registra linha e comando |
| 12 | 05-automation | Papel customizado recém-criado não é encontrado pelo nome no `New-AzRoleAssignment`. | Atribuição por ID, com espera da replicação |
| 13 | 01-tags | `-notin` não diferencia maiúsculas, embora a taxonomia diferencie. | `-cnotin` / `-cin` |
| 14 | todos | Assinatura fixa no código. | Parâmetro `-Sub` obrigatório |

### Médios

- 04-policies em PowerShell (a v1.0 exigia bash e jq).
- 01-tags: relatório com segundos no nome (execuções no mesmo minuto se sobrescreviam); `-NoTypeInformation` removido (obsoleto no PowerShell 7).
- 07-runbook-post: limpa a tag `AUM-StartedBy` depois de desalocar a VM.
- 05-automation: URIs dos webhooks gravadas no Key Vault (`-KeyVault`).

## v1.0

Versão inicial: tags, três Maintenance Configurations, Dynamic Scopes, políticas, Automation com pré e pós-evento, consultas do Resource Graph, POP e GMUD.
