function Write-Report {
    [CmdLetBinding()]
    Param(
        [Parameter(ValueFromPipeline)]$Message,
        [Switch]$New
    )
    Begin{}
    Process {
        If ($New) {
            Write-Output $Message | Out-File -FilePath $Global:reportfile
        } else {
            Write-Output $Message | Out-File -FilePath $Global:reportfile -Append
        }
    }
}
function Write-Entry {
    <#
        .DESCRIPTION
            Write a line to a log file (in format that is best viewed with Trace32.exe)
                
        .PARAMETER logMsg (Mandatory)
            String;	Text to write to log
            
        .PARAMETER msgType
            Int;	Info=1, Warning=2, Error=3, Verbose=4, Deprecated=5
                    [Utilise global variables LogTypeInfo (default), LogTypeWarning, LogTypeError, LogTypeVerbose or LogTypeDeprecated]
            
        .OUTPUT/RETURN
            Output = Debuggin message
            
        .EXAMPLE
            Write-Entry "Action was successful"
            Write-Entry "Error: $_" $global:LogTypeError
            
        .NOTES
            Author:		Jacob Hodges
            Created:	2010/11/30
    #>
        
    [CmdletBinding()]
    PARAM
    (
        [Parameter(Position=1, Mandatory=$true)] $logMsg,
        [Parameter(Position=2)][ValidateSet(
            'Info',
            'Warn',
            'Error',
            'Verbose'
        )] $msgType = 'Info'
    )
    $Type = Switch ($msgType){
        'Info' {1}
        'Warn' {2}
        'Error'{3}
        'Verbose'{4}
    }
     
    #Populate the variables to log
    $time = [DateTime]::Now.ToString("HH:mm:ss.fff+000");
    $date = [DateTime]::Now.ToString("MM-dd-yyyy");
    $component = $myInvocation.ScriptName | Split-Path -leaf
    $file = $myInvocation.ScriptName
        
    $tempMsg = [String]::Format("<![LOG[{0}]LOG]!><time=`"{1}`" date=`"{2}`" component=`"{3}`" context=`"`" type=`"{4}`" thread=`"`" file=`"{5}`">",$logMsg, $time, $date, $component, $Type, $file)
        
    if(-Not ($global:logFile)) 
    {
        Write-Verbose $logMsg
    } else {
    $tempMsg | Out-File -encoding ASCII -Append -FilePath $global:logFile 
    }
}

function Get-PatchTuesday { 
    <#  
    .SYNOPSIS   
        Get the Patch Tuesday of a month 
    .PARAMETER month 
    The month to check
    .PARAMETER year 
    The year to check
    .EXAMPLE  
    Get-PatchTue -month 6 -year 2015
    .EXAMPLE  
    Get-PatchTue June 2015
    #> 
    [CmdLetBinding()]    
    param( 
        [string]$month = (get-date).month, 
        [string]$year = (get-date).year
    ) 

    $firstdayofmonth = [datetime] ([string]$month + "/1/" + [string]$year)
    (0..30 | ForEach-Object {$firstdayofmonth.adddays($_) } | Where-Object {$_.dayofweek -like "Tue*"})[1]
 
}

function Get-DaysSinceLastUpdateGroupCreation {
    [CmdLetBinding()]
    Param($Config)

    Import-ConfigManagerModule -SiteCode $Config.SiteSettings.SiteCode -SiteServer $Config.SiteSettings.SiteServer
    Push-Location
    Set-Location "$($Config.SiteSettings.SiteCode):\"
    $LatestUpdateGroup = Get-CMSoftwareUpdateGroup | Where-Object {
        ($_.CreatedBy -ne 'AutoUpdateRuleEngine') -and 
        ($_.LocalizedDisplayName -match $Config.SiteSettings.GroupName.NamePattern)} |
        Sort-Object -Descending DateCreated | Select-Object -First 1
    Pop-Location
    If ($LatestUpdateGroup) {
        $Days = ((Get-Date) - $LatestUpdateGroup.DateCreated).Days
        Write-Entry "$Days days since last update group creation."
    } else {
        $Days = 30
        Write-Entry "Unable to find update group created. Returning sane amount of 30"
    }
    $Days
}

function Import-ConfigManagerModule {
    [CmdLetBinding()]
    Param(
        [Parameter(Mandatory=$True)]$SiteCode,
        [Parameter(Mandatory=$True)]$SiteServer
        )

    If (-Not (Get-Module -Name ConfigurationManager)) {
        $PossiblePaths ='Program Files','Program Files (x86)'
        ForEach ($Volume in (Get-Volume | Where-Object {$_.DriveType -eq 'Fixed'})) {
            $PossiblePaths | ForEach-Object {
                $PossiblePath = "$($Volume.DriveLetter):\$_\Microsoft Configuration Manager\AdminConsole\bin\ConfigurationManager.psd1"
                Write-Verbose "Testing $PossiblePath for Config manager module"
                If (Test-Path -Path $PossiblePath) {
                    $ModulePath = $PossiblePath
                }
            }
        }
        If ($ModulePath) {
            Import-Module $ModulePath
        } Else {
            Write-Error "Unable to find Config manager module"
            break
        }
    } else {
        Write-Verbose "Module already loaded"
    }
    If (-Not (Get-PSDrive -Name $SiteCode -ErrorAction SilentlyContinue)) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $SiteServer
    }
}

function Get-CfgApplicableUpdates {
    [CmdletBinding()]
    Param(
        $ReleasedOrRevised=30,$Products='Windows 10',$TitleSearchers='.*',$BannedCategories,
        [Parameter(Mandatory=$True)]$SiteCode,
        [Parameter(Mandatory=$True)]$SiteServer
        )
    Import-ConfigManagerModule -SiteCode $SiteCode -SiteServer $SiteServer
    Push-Location
    Set-Location "$($SiteCode):\"
    Write-Entry "Getting updates for $Products" -msgType Info
    Get-CMSoftwareUpdate -DateRevisedMin (Get-Date).AddDays([int]-$ReleasedOrRevised) -Fast -CategoryName $Products| ForEach-Object {
        $AllowedUpdate = $True
        ForEach ($Category in $_.LocalizedCategoryInstanceNames) {
            If ($Category -in $BannedCategories) {
                $AllowedUpdate = $False
            }
        }
        $MatchesTitle = $False
        ForEach ($TitleSearcher in $TitleSearchers) {
            If ($_.LocalizedDisplayName -match $TitleSearcher) {
                $MatchesTitle = $True
            }
        }
        If ($AllowedUpdate -and $MatchesTitle) {
            Write-Entry "Update:$($_.LocalizedDisplayName) was marked as applicable" -msgType Info
            $Applicable = $True
        } Else {
            Write-Entry "Update:$($_.LocalizedDisplayName) was marked as not applicable" -msgType Warn
            $Applicable = $False
        }
        [PSCustomObject]@{
            'DisplayName' = $_.LocalizedDisplayName
            'Applicable' = $Applicable
            'UpdateObject' = $_
        }
    }
    Pop-Location
}

function New-UpdateGroup {
    [CmdletBinding()]
    Param($GroupName,$Config)
    Begin {
        $Products = $Config.SiteSettings.Products
        if ($Config.SiteSettings.ReleasedOrRevised -eq "SinceLastUpdateGroup") {
            $ReleasedOrRevised = (Get-DaysSinceLastUpdateGroupCreation -Config $Config)    
        } else {
            $ReleasedOrRevised = $Config.SiteSettings.ReleasedOrRevised
        }
        $SiteCode = $Config.SiteSettings.SiteCode
    }
    Process {
        Push-Location
        Import-ConfigManagerModule -SiteCode $Config.SiteSettings.SiteCode -SiteServer $Config.SiteSettings.SiteServer
        Set-Location -Path "$($SiteCode):\"
        $Updates = @()
        ForEach ($Product in $Products) {
            $Updates+=Get-CfgApplicableUpdates -ReleasedOrRevised $ReleasedOrRevised `
                -Products $Product.Product `
                -TitleSearchers $Product.TitleSearchers.Searcher `
                -BannedCategories $Product.BannedCategories.BannedCategory `
                -SiteCode $SiteCode -SiteServer $Config.SiteSettings.SiteServer
        }
        If ($Updates | Where-Object {$_.Applicable -eq $True}) {
            Write-Entry "Adding $(($Updates | Where-Object {$_.Applicable -eq $True}).Count) updates to $GroupName" -msgType Info
            If (-Not (Get-CMSoftwareUpdateGroup -Name $GroupName)) {
                Write-Verbose "Software Update Group $GroupName does not exist"
                Write-Entry "Software Update Group $GroupName does not exist" -msgType Warn
                $UpdateGroup = New-CMSoftwareUpdateGroup -Name $GroupName -Description "Updates for USC Computers $(Get-Date -F MMMM) $(Get-Date -F yyyy)"
            } Else {
                Write-Verbose "Software Update Group $GroupName found"
                Write-Entry "Software Update Group $GroupName found" -msgType Info
                $UpdateGroup = Get-CMSoftwareUpdateGroup -Name $GroupName
            }

            $Updates | Where-Object {$_.Applicable -eq $True} | ForEach-Object {
                Write-Entry "Adding $($_.UpdateObject.LocalizedDisplayName) to $GroupName"
                Add-CMSoftwareUpdateToGroup -SoftwareUpdate $_.UpdateObject -SoftwareUpdateGroup $UpdateGroup
            }
        } Else {
            Write-Entry "No updates detected since the last $ReleasedOrRevised days" -msgType Info
        }
        $Updates  # Return all updates to show that we found some
        Pop-Location    
    }
}

function Add-UpdateToPackage {
    [CmdLetBinding()]
    param (
        $Config,
        $GroupName
    )
    $DeploymentPackageName = $Config.SiteSettings.UpdatePackage.PackageName
    $DeploymentPackagePath = $Config.SiteSettings.UpdatePackage.PackagePath
    $SiteCode = $Config.SiteSettings.SiteCode
    $Languages = $Config.SiteSettings.Languages
    If ($Languages) {
        ForEach ($Lang in $Languages) {
            Write-Entry "Selected $Lang language to download"
        }
    }

    Import-ConfigManagerModule -SiteCode $Config.SiteSettings.SiteCode -SiteServer $Config.SiteSettings.SiteServer
    Push-Location
    Set-Location "$($SiteCode):\"
    $DeploymentPackage = Get-CMSoftwareUpdateDeploymentPackage -Name $DeploymentPackageName
    If (-Not $DeploymentPackage) {
        Write-Entry "Deployment package doesn't exist. Attempting to create."
        Pop-Location
        If (-Not (Test-Path -Path $DeploymentPackagePath -ErrorAction SilentlyContinue)) {
            New-Item -Path $DeploymentPackagePath -ItemType Directory -Force
        }
        Set-Location "$($SiteCode):\"
        $DeploymentPackage = New-CMSoftwareUpdateDeploymentPackage -Name $DeploymentPackageName -Description 'Created by Jesse Harris Script' -Path $DeploymentPackagePath
    }
    Write-Entry "Downloading Updates from update group $GroupName to package $DeploymentPackageName"
    Get-CMSoftwareUpdate -UpdateGroupName $GroupName -Fast | ForEach-Object {
        #  Set max amount of times to attempt download
        $MAXTRIES = 3
        #  We start at 1 due to using le
        $Tries = 1
        #  While the update is not download it, try and do so 3 times.
        While (((Get-CMSoftwareUpdate -Id $_.CI_ID -Fast).IsContentProvisioned -ne $True) -and ($Tries -le $MAXTRIES) ) {
            Write-Entry "Attempt $Tries of $MAXTRIES to download $($_.LocalizedDisplayName)"
            $Tries++
            if ($Languages) {
                #  Specific languages have been specified. Limit download to those.
                $_ | Save-CMSoftwareUpdate -DeploymentPackageName $DeploymentPackageName -SoftwareUpdateLanguage $Languages
            } Else {
                #  Download all types by not specifying the language
                $_ | Save-CMSoftwareUpdate -DeploymentPackageName $DeploymentPackageName
            }
        }
    }
    Pop-Location
}

function Start-UpdatePackageDistribution {
    [CmdLetBinding()]
    Param($Config)
    Import-ConfigManagerModule -SiteCode $Config.SiteSettings.SiteCode -SiteServer $Config.SiteSettings.SiteServer
    Push-Location
    Set-Location "$($Config.SiteSettings.SiteCode):\"
    Write-Entry "Distributing content for $($Config.SiteSettings.UpdatePackage.PackageName) to DP Group: $($Config.SiteSettings.UpdatePackage.DistributionPointGroupName)"
    Get-CMSoftwareUpdateDeploymentPackage `
        -Name $Config.SiteSettings.UpdatePackage.PackageName | `
        Start-CMContentDistribution `
        -DistributionPointGroupName $Config.SiteSettings.UpdatePackage.DistributionPointGroupName -ErrorAction SilentlyContinue
    Pop-Location
}

function Today {
    Get-Date -Hour 0 -Minute 0 -Second 0 -Millisecond 0
}
function New-CfgSoftwareUpdateDeployments {
    [CmdLetBinding()]
    Param(
        $GroupName,
        $Config,
        [switch]$LogOnly
    )
    Begin{
        #Init common functions
        Import-ConfigManagerModule -SiteCode $Config.SiteSettings.SiteCode -SiteServer $Config.SiteSettings.SiteServer
        function Find-MaintWindow {
            Param($StartingFrom=7,[switch]$ReturnInt)
            $i = $StartingFrom
            Do { 
                $PotentialMaintWindow = (Get-Date).AddDays($i)
                If ((get-date $PotentialMaintWindow -Format dddd) -in 'Tuesday','Friday') { $MaintWindow = $PotentialMaintWindow } Else {
                    $i++
                }
            } Until ($MaintWindow -ne $null) 
            If ($ReturnInt) {
                return $i
            } else {
                return Get-Date (Get-Date $MaintWindow) -Format yyyy/MM/dd
            }
        }
            
        function Get-MaintDaySchedule {
            [CmdLetBinding()]
            Param($MaintString,$Time)

            $CurrentInt = 0
            $MaintString.Split('+') | ForEach-Object {
                #Write-Verbose "Current Value: $_"
                If ($_ -eq 'Maint') {
                    $CurrentInt = Find-MaintWindow -StartingFrom $CurrentInt -ReturnInt
                } elseif ($_ -eq 'Now') {
                    $CurrentInt = 0
                    $Time = (Get-Date -Format HH:mm)
                } else {
                    $CurrentInt = $CurrentInt + $_
                } 
            } 
            #Write-Verbose "Final value of Int: $CurrentInt"
            [PSCustomObject]@{
                'Day' = Get-Date (Get-Date).AddDays($CurrentInt) -Format yyyy/MM/dd
                'Time' = $Time
                'DateTime' = Get-Date (Today).AddDays($CurrentInt) -Hour $Time.Split(':')[0]
            }
        }
    }

    Process {
        ForEach ($Deployment in $Config.Deployments) {
            $Available = Get-MaintDaySchedule -MaintString $Deployment.Available -Time $Deployment.TimeAvailable
            If ($Deployment.Deadline) {
                $Deadline = Get-MaintDaySchedule -MaintString $Deployment.Deadline -Time $Deployment.TimeDeadline
            } else {
                $Deadline = $Available
            }
            Write-Entry "Deployment: $($Deployment.DeploymentName) available on: $($Available.Day) at $($Available.Time) and deadline on: $($Deadline.Day) at $($Deadline.Time)"
            If ($LogOnly) {
                Write-Verbose "Deployment: $($Deployment.DeploymentName) available on: $($Available.Day) at $($Available.Time)"
                Write-Verbose "Deployment: $($Deployment.DeploymentName) deadline on: $($Deadline.Day) at $($Deadline.Time)"
            } else {
                Push-Location
                Set-Location "$($Config.SiteSettings.SiteCode):\"
                # Check if deployment already exists:
                $DeploymentCheck = Get-CMDeployment -SoftwareName $GroupName -CollectionName $Deployment.Collection
                If ($DeploymentCheck) {
                    Write-Verbose "Deployment already exists"
                    Write-Entry "Deployment for $GroupName to collection $($Deployment.Collection) already exists. Doing nothing"
                    $DeploymentCheck
                } else {
                    if (Get-Command New-CMSoftwareUpdateDeployment -ErrorAction SilentlyContinue) {
                        Write-Entry "Detected SCCM 1702 or greater. Using new cmdlets"
                        Write-Entry "Creating update deployment for $GroupName to $($Deployment.Collection)"
                        New-CMSoftwareUpdateDeployment `
                            -SoftwareUpdateGroupName $GroupName `
                            -CollectionName $Deployment.Collection `
                            -DeploymentName "$GroupName - $($Deployment.DeploymentName)" `
                            -Description "Windows Updates for $(Get-Date -F MMMM) $(Get-Date -F yy)" `
                            -DeploymentType $Deployment.DeploymentType `
                            -SendWakeupPacket $Deployment.WakeOnLAN `
                            -VerbosityLevel AllMessages `
                            -TimeBasedOn $Deployment.TimeBasedOn `
                            -AvailableDateTime $Available.DateTime `
                            -DeadlineDateTime $Deadline.DateTime `
                            -UserNotification $Deployment.UserNotification `
                            -SoftwareInstallation $Deployment.SoftwareInstallation `
                            -AllowRestart $Deployment.AllowRestart `
                            -RestartServer $Deployment.RestartServer `
                            -RestartWorkstation $Deployment.RestartWorkstation `
                            -ProtectedType RemoteDistributionPoint `
                            -UnprotectedType $Deployment.UnprotectedType `
                            -DownloadFromMicrosoftUpdate $Deployment.DownloadFromMicrosoftUpdate `
                            -UseMeteredNetwork $Deployment.UseMeteredNetwork `
                            -UseBranchCache $Deployment.UseBranchCache `
                            -AcceptEula:$Deployment.AcceptEULA
                    } Else {
                        Write-Entry "Detected SCCM 1610 or lower. Using legacy cmdlets"
                        Write-Entry "Creating update deployment for $GroupName to $($Deployment.Collection)"
                        Start-CMSoftwareUpdateDeployment `
                            -SoftwareUpdateGroupName $GroupName `
                            -CollectionName $Deployment.Collection `
                            -DeploymentName $Deployment.DeploymentName `
                            -Description "Windows Updates for $(Get-Date -F MMMM) $(Get-Date -F yy)" `
                            -DeploymentType $Deployment.DeploymentType `
                            -SendWakeUpPacket $Deployment.WakeOnLAN `
                            -VerbosityLevel AllMessages `
                            -TimeBasedOn $Deployment.TimeBasedOn `
                            -DeploymentAvailableDay $Available.Day `
                            -DeploymentAvailableTime $Available.Time `
                            -DeploymentExpireDay $Deadline.Day `
                            -DeploymentExpireTime $Deadline.Time `
                            -UserNotification $Deployment.UserNotification `
                            -SoftwareInstallation $Deployment.SoftwareInstallation `
                            -AllowRestart $Deployment.AllowRestart `
                            -RestartServer $Deployment.RestartServer `
                            -RestartWorkstation $Deployment.RestartWorkstation `
                            -DisableOperationsManagerAlert $True `
                            -GenerateOperationsManagerAlert $True `
                            -ProtectedType RemoteDistributionPoint `
                            -UnprotectedType $Deployment.UnprotectedType `
                            -UseBranchCache $Deployment.UseBranchCache `
                            -DownloadFromMicrosoftUpdate $Deployment.DownloadFromMicrosoftUpdate `
                            -AllowUseMeteredNetwork $Deployment.UseMeteredNetwork `
                            -AcceptEula:$Deployment.AcceptEULA
                        $ReturnObject = $True #Older cmdlets don't automatically return the deployment object, so we flag it here to manually do it later
                    }
                    if ($Deployment.Enabled -eq $False) {
                        Write-Entry "Disabling $($Deployment.DeploymentName)"
                        Set-CMSoftwareUpdateDeployment -DeploymentName $Deployment.DeploymentName -SoftwareUpdateGroupName $GroupName -Enable $False
                    }
                    If ($ReturnObject) {
                        Get-CMDeployment -CollectionName $Deployment.Collection -SoftwareName $GroupName
                    }
                }
                Pop-Location
            }
        }
    }
}
