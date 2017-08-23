[CmdLetBinding()]
Param()

. C:\Scripts\UpdateCommands.ps1
$Config = Get-Content -Path 'C:\Scripts\Deployments.json' | ConvertFrom-Json
$Global:logfile = $Config.SiteSettings.LogPath

If ((Get-PatchTuesday).AddDays(15) -eq (Today)) {
    Write-Entry "Patch Tuesday today. Lets get to work" -msgType Info
    # Group Name formatting code
    $Month = $((Get-Date).Month.ToString("00"))
    $Year = $(Get-Date -F yyyy)
    $StrMonth = $(Get-Date -F MMMM)
    $Day = $(Get-Date -Format dd)
    $GroupName = "$Month-$Day - $StrMonth $Year"
    Write-Entry "Working on $GroupName"
    if (New-UpdateGroup -GroupName $GroupName -Config $Config) {
        # Succesfully found updates. Move to other tasks
        Add-UpdateToPackage -Config $Config -GroupName $GroupName
        Start-UpdatePackageDistribution -Config $Config
        New-CfgSoftwareUpdateDeployments -GroupName $GroupName -Config $Config 
        Write-Entry "Finished Deploying Updates."
    }
    Write-Entry "Script End."
}
