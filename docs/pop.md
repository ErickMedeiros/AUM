# POP · Aplicação mensal de patches em DEV e HML

Procedimento operacional padrão para preparar, executar, validar e, se preciso, reverter a aplicação mensal de patches críticos e de segurança pelo Azure Update Manager.

## 1. Campo de aplicação

Azure VMs e servidores Azure Arc conectados, com `Ambiente = DEV` ou `HML` e `PatchWave` diferente de `Hold`. Não se aplica a produção, nós de cluster, appliances e imagens base.

## 2. Definições

| Termo | Definição |
|---|---|
| Patch Tuesday (PT) | Segunda terça-feira do mês |
| Wave | Grupo de máquinas atualizado na mesma janela |
| Janela | 22:00 às 01:55 (horário local) em dia útil |
| Change freeze | Últimos 7 dias corridos do mês |
| Pré e pós-evento | Runbooks acionados pelo Event Grid antes e depois da instalação |
| Fail-closed | Cancela a execução se a proteção pré-patch falhar |
| Go / No-Go | Decisão de liberar ou segurar a Wave seguinte |

## 3. Responsabilidades

| Atividade | Time de nuvem | Change Manager | Donos | NOC |
|---|---|---|---|---|
| Manter tags e calendário de feriados | R | A | C | I |
| Comunicar a Wave (D−5 e D−1) | R | A | I | I |
| Monitorar a janela | C | I | I | R |
| Smoke tests (D+1) | C | I | R | I |
| Decidir Go / No-Go | C | R/A | C | I |
| Executar rollback | R | A | C | I |
| Agendar reboot pendente | R | A | C | I |

R = executa · A = aprova · C = consultado · I = informado

## 4. Pré-requisitos

- GMUD aprovada para o ciclo (mudança padrão recorrente depois da primeira aprovação).
- Máquinas com `Ambiente`, `PatchWave`, `PreBackup` e `SystemOwner` preenchidas e sem apontamento na Q11.
- Azure VMs com Customer Managed Schedules e avaliação periódica ativa (Q6).
- Servidores Arc Connected e extensão de OS Update com status Succeeded.
- Variáveis da Automation revisadas: `AUM-Feriados`, `AUM-FailClosed`, `AUM-HoldWaves`, `AUM-LigarDesalocadas`.
- **Webhooks com mais de 30 dias de validade.** A URI não pode ser relida: a renovação cria um novo webhook (URI no Key Vault) e atualiza as assinaturas pre e post do Event Grid de cada Maintenance Configuration.
- Runbooks `AUM-PreEvent` e `AUM-PostEvent` publicados no runtime **PowerShell-7.4**.
- Máquinas com `PreBackup = AzureBackup` com o **backup inicial concluído** (Q10). O primeiro backup é completo e pode não terminar na janela do pré-evento.
- Papel AUM Pre-Patch Operator com `start/action`, `deallocate/action` e `tags/write` quando houver máquinas com `PatchStartStop = true`.
- **Nenhuma alteração** em Maintenance Configuration, Dynamic Scope ou tag `PatchWave` nos 40 minutos anteriores à janela.

## 5. Procedimento

### D−5 · Comunicação
1. Gerar a lista de máquinas da Wave pela Q8 e conferir que todas estão `Pronta`.
2. Avisar os donos com data, janela, lista de máquinas e prazo para pedir exclusão.
3. Pedidos de exclusão: `PatchWave = Hold` na máquina, com justificativa na GMUD.

### D−1 · Preparação
1. Rodar a Q6: patch mode, avaliação periódica com menos de 24 horas e estado das VMs.
2. Confirmar máquinas ligadas ao menos 15 minutos antes da janela, ou marcadas com `PatchStartStop = true` se o CAB aprovou.
3. Confirmar o calendário: feriado ou freeze precisam constar em `AUM-Feriados`.
4. Lembrete aos donos e ao NOC.

### D0 · Janela (21:30 às 01:55)
1. **21:30:** conferir no job `AUM-PreEvent` se o guard de calendário passou e se todas as máquinas foram protegidas.
2. **Job `AUM-PreEvent` com status Failed** significa falha de proteção ou cancelamento recusado pela API. Confirmar em AUM › History › By maintenance run ID se a execução ficou Cancelled; se não ficou, cancelar pelo portal até T−10.
3. **22:00 a 01:55:** o NOC acompanha o Workbook. Não intervir nas máquinas durante a instalação.
4. Após o término: conferir o job `AUM-PostEvent` e a lista de reboot pendente.

### D+1 · Validação e decisão
1. Até 09:00: publicar o relatório da execução (Q1 a Q5).
2. Até 12:00: donos executam os smoke tests.
3. Tarde: o Change Manager aplica os critérios da seção 7. Em No-Go, incluir a próxima Wave em `AUM-HoldWaves`.
4. Agendar a janela de reboot das máquinas com reboot pendente.

## 6. Validação

| Momento | Verificação | Evidência |
|---|---|---|
| Pré | Avaliação periódica recente; patch mode; tags | Q6, Q7 |
| Pré | Proteção registrada para 100% das máquinas | Job AUM-PreEvent, Q4, Q5 |
| Pós | Status por máquina | Q1 |
| Pós | KBs e pacotes instalados e falhas | Q2 |
| Pós | Reboot pendente | Q3 |
| Pós | Serviços, logs, portas e APIs | Registro do smoke test |

## 7. Critérios entre Waves

| Critério | Limite para avançar |
|---|---|
| Sucesso de instalação | 95% ou mais das máquinas da Wave |
| Incidentes P1/P2 atribuídos ao patch | Nenhum |
| Proteção pré-patch | 100% das máquinas com backup ou snapshot |
| Smoke tests | Aprovados até D+1, 12:00 |
| Falhas restantes | Causa conhecida ou KB/pacote excluído da Wave seguinte |
| Reboot pendente | Janela de reboot agendada |

Qualquer critério não atendido = No-Go.

## 8. Tratamento de falhas

| Situação | Ação |
|---|---|
| Status Failed e "Maintenance window exceeded" | Verificar volume de updates; avaliar execução avulsa na noite útil seguinte |
| Extensão de OS Update com falha | Remover só a extensão com falha e disparar avaliação sob demanda |
| Máquina desligada durante a janela | Registrar como não conforme; próxima Wave ou execução avulsa |
| Pré-evento não executou | Verificar entrega no Event Grid e validade do webhook; a plataforma cancela se não conseguir entregar |
| Hotpatch caiu para cold patch | Verificar baseline e a extensão `Microsoft.CPlat.Core.WindowsHotpatch` |
| Pré-evento com 403 AuthorizationFailed | Conferir as ações do papel AUM Pre-Patch Operator e aguardar a propagação do RBAC |
| Cancelamento recusado (HTTP 409 *Cancellation requested outside window*) | Cancelar pelo portal até T−10; depois do corte, acompanhar e avaliar rollback |
| Execução cancelada pelo sistema logo após mudança de agenda ou tag | Mudança feita a menos de 40 minutos da janela: execução avulsa na noite útil seguinte, sob a mesma GMUD |

## 9. Rollback

Acionado quando um smoke test reprova ou um incidente é atribuído ao patch. Tentar primeiro a opção de menor impacto.

- **A · Remover a atualização.** Windows: `wusa /uninstall /kb:<número> /quiet /norestart`. RHEL: `dnf history undo <id>`. Ubuntu: `apt install <pacote>=<versão anterior>`. Incluir o KB ou pacote nas exclusões das Waves seguintes.
- **B · Restaurar pelo Azure Backup.** Selecionar o ponto criado pelo pré-evento; restaurar os discos e trocá-los na VM, ou criar uma VM nova. Os discos atuais são mantidos.
- **C · Disco a partir do snapshot.** Localizar os snapshots da execução (Q4, tag `MaintenanceRunId`); `New-AzDiskConfig -CreateOption Copy -SourceResourceId <snapshot>`; `New-AzDisk`; parar a VM e `Set-AzVMOSDisk` + `Update-AzVM`. O disco anterior é mantido.
- **D · Servidores Arc.** VMware: reverter para o snapshot `AUM-<execução>` no vCenter. Físicos: restaurar pelo MABS/MARS.

Nenhuma opção apaga disco, snapshot ou backup original. A limpeza é feita pelo dono depois da estabilização; no vCenter, em até 72 horas.

## 10. Registros

- GMUD com `MaintenanceRunId`, relatório do Workbook, smoke tests e decisão Go/No-Go.
- Saída dos jobs `AUM-PreEvent` e `AUM-PostEvent` (retenção de 30 dias na Automation; exportar para a GMUD).
