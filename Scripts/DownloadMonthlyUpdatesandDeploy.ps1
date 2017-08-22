[CmdLetBinding()]
Param()

. C:\Scripts\UpdateCommands.ps1
$Config = Get-Content -Path 'C:\Scripts\Deployments.json' | ConvertFrom-Json
$Global:logfile = $Config.SiteSettings.LogPath

# Group Name formatting code
$Month = $((Get-Date).Month.ToString("00"))
$Year = $(Get-Date -F yyyy)
$StrMonth = $(Get-Date -F MMMM)
$GroupName = "$Month - $StrMonth $Year"

#New-UpdateGroup -GroupName $GroupName -Config $Config
#Add-UpdateToPackage -GroupName $GroupName -Config $Config
#Start-UpdatePackageDistribution -Config $Config
New-CfgSoftwareUpdateDeployments -GroupName $GroupName -Config $Config 