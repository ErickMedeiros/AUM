# Laboratório · teste de ponta a ponta

A solução foi implantada e testada numa **assinatura de laboratório pay-as-you-go**, antes de qualquer uso em produção. Este documento descreve o ambiente, o roteiro para reproduzir o teste, os resultados obtidos e a limpeza.

## 1. Ambiente

| VM | SO | Ambiente | PatchWave | PreBackup | O que o teste exercita |
|---|---|---|---|---|---|
| VM-SRV-AADDS | Windows Server 2025 Datacenter | DEV | Wave1-Dev | AzureBackup | Backup on-demand num cofre do Recovery Services |
| VM-HyperV-Host | Windows Server 2025 Datacenter (SO + disco de dados) | HML | Wave2-HML-Piloto | Snapshot | Snapshot incremental de vários discos; execução real |
| vm-imersao | Ubuntu 24.04 LTS | HML | Wave3-HML | Snapshot + `PatchStartStop = true` | Ligar VM desalocada no pré e desalocar no pós-evento |
| srv-testedomain001 | — | (teste negativo) | — | — | Linha inválida que o `01-tags.ps1` precisa rejeitar |

Recursos criados em `rg-aum-patching`: as três Maintenance Configurations, duas MCs temporárias de teste (`mc-aum-lab-cancel` e `mc-aum-lab-e2e`), a Automation Account `aa-aum-patching-lab` (runtime PowerShell-7.4, dois runbooks, dois webhooks e variáveis), cinco system topics do Event Grid e o cofre `rsv-aum-lab` (LRS, DefaultPolicy).

## 2. Roteiro

Os scripts de apoio estão em [`lab/`](../lab). Todos leem a assinatura do contexto atual do Azure CLI.

```powershell
az login --tenant <tenant-id>; az account set --subscription <subscription-id-do-laboratório>
cd lab; . .\00-lab-config.ps1          # conecta o Az PowerShell com o token do Azure CLI
```

| Passo | Comando | Valida |
|---|---|---|
| 1 | `..\scripts\powershell\01-tags.ps1 -Sub $Lab.Sub -Csv .\examples\AUM_Tags_Lab.csv` (simulação, depois `-Aplicar -Ambiente DEV` e `HML`) | Validação, teste negativo, gravação em Merge |
| 2 | Bicep 02 e 03 ([implantação](implantacao.md)) | MCs e Dynamic Scopes |
| 3 | `..\scripts\powershell\04-policies.ps1` (ou atribuições por grupo de recursos para limitar às VMs do lab) | CMS, Periodic Assessment, auditoria de tags |
| 4 | `..\scripts\powershell\05-automation.ps1 -Sub $Lab.Sub -AA aa-aum-patching-lab` | RBAC, runtime 7.4, runbooks, webhooks, Event Grid |
| 5 | `.\23-lab-publicar.ps1` | Publica a variante de laboratório do pré-evento ([runbooks/06-runbook-pre-lab.ps1](../lab/runbooks/06-runbook-pre-lab.ps1)) |
| 6 | Cofre e proteção de uma VM: `az backup vault create` + `az backup protection enable-for-vm` | Caminho AzureBackup |
| 7 | `.\20-lab-mc-e2e.ps1 -MinCancel 50 -MinE2E 95` | Duas execuções **reais**: uma cancelada pelo guard e uma completa |
| 8 | `.\21-lab-simular-evento.ps1 -Mc mc-aum-wave1-dev` (e Wave3, e `-Tipo Post`) | Pré e pós-evento com eventos no formato do Event Grid |
| 9 | `.\22-lab-jobs.ps1 -Ultimos 5` | Saída dos jobs da Automation |
| 10 | `.\24-lab-queries.ps1` | Q8, Q9, Q10 e Q11 |
| 11 | `.\99-lab-limpeza.ps1 -Sub $Lab.Sub` (lista) e `-Executar` | Remoção de tudo o que o teste criou |

Cuidados do roteiro:

- **Regra dos 40 minutos:** as MCs de teste precisam começar pelo menos 40 minutos depois de criadas; o pré-evento chega cerca de 30 minutos antes.
- **Guard de calendário:** num fim de semana, a execução real é cancelada (útil para testar o cancelamento). Para a execução completa num fim de semana, a variante de laboratório lê a variável `AUM-IgnorarCalendario = true`. Volte-a para `false` logo depois do pré-evento.
- **Eventos simulados** usam um `CorrelationId` fictício: o caminho de proteção é testado de verdade, mas a API de cancelamento responde HTTP 409 (*outside window*), o que só prova que ela foi chamada.
- **PatchStartStop:** a VM precisa estar desalocada antes do pré-evento, e no teste simulado o pós-evento só deve ser enviado depois que ela estiver `running`.
- Defina `AUM-LigarDesalocadas = true` na Automation para testar o PatchStartStop.

## 3. Resultados

| Etapa | Resultado | Observação |
|---|---|---|
| Tags (Onda 0) | ✅ | 3 aplicadas em Merge; linha de teste negativo rejeitada |
| Customer Managed Schedules | ✅ | 3/3 AutomaticByPlatform + bypass, depois de remediar em sequência |
| Periodic Assessment | ✅ | 3/3; uma remediação em paralelo falhou com Conflict |
| Auditoria de tags | ✅ | VMs do lab Compliant; VMs fora da taxonomia NonCompliant |
| MCs, Dynamic Scopes, Event Grid | ✅ | 6 assinaturas pre/post com handshake do webhook validado |
| **Execução real com cancelamento** | ✅ | Pré-evento 35 min antes; guard "fim de semana"; API Cancel HTTP 200; run **Cancelled**; pós-evento recebido com Status Cancelled |
| **Execução real completa** | ✅ | Snapshot incremental de SO e dados; run **Succeeded** em 10 min; 0 patches pendentes; reboot NotNeeded; atualização *Definition* NotSelected |
| Snapshot Linux (simulado) | ✅ | Snapshot com as tags de rastreio |
| Backup on-demand (simulado) | ✅ | Primeiro backup: *Take Snapshot* em 12 min, job completo em 42 min |
| Fail-closed | ✅ | Falha de proteção chama o cancelamento e o job termina **Failed** |
| PatchStartStop com o papel da v1.0 | ❌ esperado | **403 AuthorizationFailed** em `virtualMachines/start/action` |
| PatchStartStop com o papel da v1.1 | ✅ | VM ligada, tag `AUM-StartedBy`, snapshot; pós-evento desalocou |
| Limpeza da tag `AUM-StartedBy` | ⚠️ | Validada só por revisão de código |
| Consultas Q8–Q11 | ✅ | Q8 com as 3 VMs Pronta; Q9 incompleta (ver plano de tags) |

Os defeitos da v1.0 encontrados neste teste estão no [CHANGELOG](../CHANGELOG.md).

## 4. Lições para produção

1. Não alterar MC, Dynamic Scope ou tag `PatchWave` nos 40 minutos anteriores à janela.
2. Proteger as VMs `AzureBackup` com antecedência: o primeiro backup pode estourar os 20 minutos do pré-evento.
3. Remediar as políticas em sequência e conferir a Q6 depois.
4. Uma atribuição de Periodic Assessment por SO.
5. Tratar job `AUM-PreEvent` **Failed** como falha no D0.
6. Usar a Q11 como verificação obrigatória dos valores das tags.
7. Para auditoria de mudanças de tag, completar a Q9 com o Activity Log.
8. Fixar a versão do runtime da Automation e repetir este roteiro antes de atualizar os módulos Az.

## 5. Custos e limpeza

Itens com custo no laboratório: cofre do Recovery Services (instância protegida e armazenamento), snapshots incrementais (cobrados pelo uso) e a VM ligada pelo PatchStartStop. Automation, Event Grid e Maintenance Configurations têm custo desprezível neste volume.

```powershell
.\99-lab-limpeza.ps1 -Sub $Lab.Sub                          # só lista
.\99-lab-limpeza.ps1 -Sub $Lab.Sub -Executar                # remove tudo, inclusive o cofre
.\99-lab-limpeza.ps1 -Sub $Lab.Sub -Executar -ManterCofre -RestaurarPatchMode
```

A limpeza não toca nas VMs nem nos discos: remove Dynamic Scopes, políticas e o RBAC delas, o papel customizado, os snapshots criados pelo pré-evento, as tags AUM e o grupo `rg-aum-patching`.
