# Exporta o SO das VMs VMware direto do vCenter (VMware PowerCLI), para identificar o SO das VMs VMware que ainda não têm agente Arc.
# Somente leitura. Requer conta com permissão de leitura no vCenter.
Connect-VIServer -Server '<fqdn-do-vcenter>' | Out-Null
Get-VM | Select-Object Name, PowerState,
    @{ N = 'GuestOS';       E = { $_.Guest.OSFullName } },
    @{ N = 'GuestOSConfig'; E = { $_.ExtensionData.Config.GuestFullName } },
    @{ N = 'VMwareTools';   E = { $_.ExtensionData.Guest.ToolsRunningStatus } },
    @{ N = 'Host';          E = { $_.VMHost.Name } },
    @{ N = 'Pasta';         E = { $_.Folder.Name } },
    @{ N = 'Notas';         E = { $_.Notes } } |
  Export-Csv ".\vcenter-guestos-$(Get-Date -Format 'yyyyMMdd').csv" -NoTypeInformation -Encoding UTF8 -Delimiter ';'
Disconnect-VIServer -Confirm:$false

