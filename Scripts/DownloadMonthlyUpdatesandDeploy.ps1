[CmdLetBinding()]
Param(
    [Parameter(Mandatory=$True)]
    $ConfigFilePath
    )

Import-Module "$($PSScriptRoot)\Update-Commands.psm1"
Try {
    $Config = Get-Content -Path $ConfigFilePath -Raw -ErrorAction Stop | ConvertFrom-Json
} Catch {
    Write-Error "Could not open or read json config file" -ErrorAction Stop
}
$Global:logfile = $Config.SiteSettings.LogPath
$Global:reportfile = $Config.SiteSettings.ReportPath

If ((Get-PatchTuesday).AddDays(2) -eq (Today)) {
    Write-Entry "Patch Tuesday today. Lets get to work" -msgType Info
    # Group Name formatting code
    $Month = $((Get-Date).Month.ToString("00"))
    $Year = $(Get-Date -F yyyy)
    $StrMonth = $(Get-Date -F MMMM)
    $Day = $(Get-Date -Format dd)
    $GroupName = "$Month - $StrMonth $Year Windows Clients"
    Write-Entry "Working on $GroupName"
    $Updates = New-UpdateGroup -GroupName $GroupName -Config $Config
    If ($Updates | Where-Object {$_.Applicable -eq $True}) {
        # Succesfully found applicable updates. Lets log information about the updates
        Write-Report "Report:`r`n`r`nList of updates skipped:`r`n" -New
        $Updates | Where-Object {$_.Applicable -eq $False} | ForEach-Object {
            Write-Report "$($_.UpdateObject.LocalizedDisplayName)"
        }
        Write-Output "`r`nList of updates included:`r`n" | Out-File $Config.SiteSettings.ReportPath -Append
        $Updates | Where-Object {$_.Applicable -eq $True} | ForEach-Object {
            Write-Report "$($_.UpdateObject.LocalizedDisplayName)"
        }
        Add-UpdateToPackage -Config $Config -GroupName $GroupName
        Start-UpdatePackageDistribution -Config $Config
        Write-Report "`r`nList of deployments:`r`n"
        New-CfgSoftwareUpdateDeployments -GroupName $GroupName -Config $Config | ForEach-Object {
            If ($_.StartTime) {
                Write-Report "$($_.AssignmentName) StartTime: $($_.StartTime) Deadline: $($_.EnforcementDeadline)"
            } Else {
                Write-Report "$($_.SoftwareName): Collection: $($_.CollectionName) StartTime: $($_.DeploymentTime) Deadline: $($_.EnforcementDeadline)"
            }
        }
        Write-Entry "Finished Deploying Updates."
        If ($Config.SiteSettings.ReportRecipiants) {
            $Body = "Please see the attched report log"
            $MessageParams = @{
                To = $Config.SiteSettings.ReportRecipiants.Recipiant
                From = "$($env:computername)@$($env:userdnsdomain)"
                Subject = "Scheduled Updates Report"
                smtpServer = $Config.SiteSettings.SMTPServer
            }
            Send-MailMessage @MessageParams -Body $Body -Attachments $Global:reportfile
        }
    }
    Write-Entry "Script End."
}