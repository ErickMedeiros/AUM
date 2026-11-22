// 02-maintenance-configurations.bicep
// Três Maintenance Configurations (escopo InGuestPatch), uma por Wave.
// Implantação: az deployment group create -g rg-aum-patching -f 02-maintenance-configurations.bicep -p linuxExcl=@linux-exclusions.json
// v1.1: startDateTime e owner parametrizados.

@description('Máscaras de pacotes Linux que não podem ser atualizados (bancos, runtimes, web servers). Validar com os donos.')
param linuxExcl array

@description('Região das Maintenance Configurations')
param location string = 'brazilsouth'

@description('Primeira data/hora possível (yyyy-MM-dd HH:mm, horário de Brasília)')
param startDateTime string = '2027-01-01 22:00'

param owner string = 'Plataforma-Cloud'

var tz = 'E. South America Standard Time'   // Brasília, sem horário de verão
var sev = [
  'Critical'
  'Security'
]
var janela = {
  startDateTime: startDateTime        // a primeira execução é a primeira ocorrência após esta data
  duration: '03:55'                   // 22h00 às 01h55; 3h55 é o máximo do escopo Guest
  timeZone: tz
}
var waves = [
  { name: 'mc-aum-wave1-dev', recur: 'Month Second Tuesday Offset1' }          // quarta, PT+1
  { name: 'mc-aum-wave2-hml-piloto', recur: 'Month Second Tuesday Offset6' }   // segunda, PT+6
  { name: 'mc-aum-wave3-hml', recur: 'Month Third Tuesday Offset1' }           // quarta, PT+8
]

resource mc 'Microsoft.Maintenance/maintenanceConfigurations@2023-04-01' = [for w in waves: {
  name: w.name
  location: location
  tags: {
    Finalidade: 'Azure Update Manager DEV/HML'
    Owner: owner
  }
  properties: {
    maintenanceScope: 'InGuestPatch'
    visibility: 'Custom'
    extensionProperties: {
      InGuestPatchMode: 'User'
    }
    maintenanceWindow: union(janela, { recurEvery: w.recur })
    installPatches: {
      rebootSetting: 'Never'          // nunca reinicia automaticamente
      windowsParameters: {
        classificationsToInclude: sev
        kbNumbersToExclude: []        // preencher com KBs vetados no CAB
      }
      linuxParameters: {
        classificationsToInclude: sev
        packageNameMasksToExclude: linuxExcl
      }
    }
  }
}]

output mcIds array = [for (w, i) in waves: { name: w.name, id: mc[i].id }]

