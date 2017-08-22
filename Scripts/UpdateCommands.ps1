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
        [Parameter(Position=2)] $msgType = $global:LogTypeInfo
    )
    
    #Populate the variables to log
    $time = [DateTime]::Now.ToString("HH:mm:ss.fff+000");
    $date = [DateTime]::Now.ToString("MM-dd-yyyy");
    $component = $myInvocation.ScriptName | Split-Path -leaf
    $file = $myInvocation.ScriptName
        
    $tempMsg = [String]::Format("<![LOG[{0}]LOG]!><time=`"{1}`" date=`"{2}`" component=`"{3}`" context=`"`" type=`"{4}`" thread=`"`" file=`"{5}`">",$logMsg, $time, $date, $component, $msgType, $file)
        
    if($debug)
    {
        Write-Host $logMsg
    }
        
    $tempMsg | Out-File -encoding ASCII -Append -FilePath $global:logFile 
}

function Import-ConfigManagerModule {
    [CmdLetBinding()]
    Param()

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
}
function New-UpdateGroup {
    [CmdletBinding()]
    Param($GroupName,$Config)
    Begin {
        $Products = $Config.SiteSettings.Products.Product
        $ReleasedOrRevised = [int]-$Config.SiteSettings.ReleasedOrRevised
        $TitleSearchers= $Config.SiteSettings.TitleSearchers.Searcher
        $SiteCode = $Config.SiteSettings.SiteCode
        function Get-CfgApplicableUpdates {
            [CmdletBinding()]
            Param($ReleasedOrRevised,$Products,$TitleSearchers)
            $BannedCategories = 
                'Finnish',
                'Turkish',
                'Dutch',
                'Hebrew',
                'German',
                'Danish',
                'French',
                'Hungarian',
                'Spanish',
                'Norwegian',
                'Russian',
                'Japanese',
                'Italian',
                'Greek',
                'Korean',
                'Chinese',
                'Polish',
                'Swedish',
                'Portuguese',
                'Serbian',
                'Portuguese (Brazil)',
                'Thai',
                'Slovak',
                'Slovenian',
                'Estonian',
                'Lithuanian',
                'Romanian',
                'Serbian',
                'Bulgarian',
                'Arabic',
                'Czech',
                'Ukrainian',
                'Latvian',
                'Croatian',
                'Chinese (Traditional, Taiwan)',
                'Chinese (Simplified, China)',
                'Upgrades'
            #Write-Host "TitleSearchers are: $TitleSearchers" -ForegroundColor "Yellow"
            #Write-Host "Products are: $Products" -ForegroundColor "Yellow"
            Get-CMSoftwareUpdate -DateRevisedMin (Get-Date).AddDays($ReleasedOrRevised) -Fast -CategoryName $Products| Where-Object {
                $AllowedUpdate = $True
                ForEach ($Category in $_.LocalizedCategoryInstanceNames) {
                    If ($Category -in $BannedCategories) {
                        $AllowedUpdate = $False
                    }
                }
                If ($AllowedUpdate -eq $False) {
                    Write-Entry "Update: $($_.LocalizedDisplayName) was not allowed by category" -msgType $global:LogTypeInfo
                }
                $MatchesTitle = $False
                ForEach ($TitleSearcher in $TitleSearchers) {
                    If ($_.LocalizedDisplayName -match $TitleSearcher) {
                        $MatchesTitle = $True
                    }
                }
                If ($MatchesTitle -eq $False) {
                    Write-Entry "Update: $($_.LocalizedDisplayName) was not allowed by unmatched title search" -msgType $global:LogTypeInfo
                }
                $AllowedUpdate -and $MatchesTitle
            }
        }
    }
    Process {
        Push-Location
        Import-ConfigManagerModule
        Set-Location -Path "$($SiteCode):\"
        $Updates = Get-CfgApplicableUpdates -ReleasedOrRevised $ReleasedOrRevised -Products $Products -TitleSearchers $TitleSearchers

        If (-Not (Get-CMSoftwareUpdateGroup -Name $GroupName)) {
            Write-Verbose "Software Group $GroupName does not exist"
            $UpdateGroup = New-CMSoftwareUpdateGroup -Name $GroupName -Description "Updates for USC Computers $(Get-Date -F MMMM) $(Get-Date -F yyyy)"
        } Else {
            Write-Verbose "Software Group $GroupName found"
            $UpdateGroup = Get-CMSoftwareUpdateGroup -Name $GroupName
        }

        $Updates | ForEach-Object {
            Add-CMSoftwareUpdateToGroup -SoftwareUpdate $_ -SoftwareUpdateGroup $UpdateGroup
        }
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

    Push-Location
    Set-Location "$($SiteCode):\"
    $DeploymentPackage = Get-CMSoftwareUpdateDeploymentPackage -Name $DeploymentPackageName
    If (-Not $DeploymentPackage) {
        Pop-Location
        If (-Not (Test-Path -Path $DeploymentPackagePath -ErrorAction SilentlyContinue)) {
            New-Item -Path $DeploymentPackagePath -Name $DeploymentPackageName -ItemType Directory -Force
        }
        Set-Location "$($SiteCode):\"
        $DeploymentPackage = New-CMSoftwareUpdateDeploymentPackage -Name $DeploymentPackageName -Description 'Created by Jesse Harris Script' -Path $DeploymentPackagePath
    }
    Get-CMSoftwareUpdateGroup -Name $GroupName | Save-CMSoftwareUpdate -DeploymentPackageName $DeploymentPackageName -SoftwareUpdateLanguage "English"
    Pop-Location
}

function Start-UpdatePackageDistribution {
    [CmdLetBinding()]
    Param($Config)
    Import-ConfigManagerModule
    Push-Location
    Set-Location "$($Config.SiteSettings.SiteCode):\"
    Get-CMSoftwareUpdateDeploymentPackage `
        -Name $Config.SiteSettings.UpdatePackage.PackageName | `
        Start-CMContentDistribution `
        -DistributionPointGroupName $Config.SiteSettings.UpdatePackage.DistributionPointGroupName
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
        Import-ConfigManagerModule
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
                    $DeploymentCheck
                } else {
                    if (Get-Command New-CMSoftwareUpdateDeployment) {
                        New-CMSoftwareUpdateDeployment `
                            -SoftwareUpdateGroupName $GroupName `
                            -CollectionName $Deployment.Collection `
                            -DeploymentName "$GroupName - $($Deployment.DeploymentName)" `
                            -Description "Windows Updates for $StrMonth $Year" `
                            -DeploymentType Required `
                            -SendWakeupPacket $Deployment.WakeOnLAN `
                            -VerbosityLevel AllMessages `
                            -TimeBasedOn LocalTime `
                            -AvailableDateTime $Available.DateTime `
                            -DeadlineDateTime $Deadline.DateTime `
                            -UserNotification $Deployment.UserNotification `
                            -SoftwareInstallation $Deployment.SoftwareInstallation `
                            -AllowRestart $Deployment.AllowRestart `
                            -RestartServer $Deployment.RestartServer `
                            -RestartWorkstation $Deployment.RestartWorkstation `
                            -ProtectedType RemoteDistributionPoint `
                            -UnprotectedType $Deployment.UnprotectedType `
                            -DownloadFromMicrosoftUpdate $False `
                            -UseMeteredNetwork $False `
                            -UseBranchCache $False
                    } Else {
                        Start-CMSoftwareUpdateDeployment `
                            -SoftwareUpdateGroupName $GroupName `
                            -CollectionName $Deployment.Collection `
                            -DeploymentName $Deployment.DeploymentName `
                            -Description "Windows Updates for $StrMonth $Year" `
                            -DeploymentType Required `
                            -SendWakeUpPacket $Deployment.WakeOnLAN 
                            -VerbosityLevel AllMessages `
                            -TimeBasedOn Local `
                            -DeploymentAvailableDay $Available.Day `
                            -DeploymentAvailableTime $Available.Time `
                            -UserNotification $Deployment.UserNotification `
                            -SoftwareInstallation $Deployment.SoftwareInstallation `
                            -AllowRestart $Deployment.AllowRestart `
                            -RestartServer $Deployment.RestartServer `
                            -RestartWorkstation $Deployment.RestartWorkstation `
                            <#-PersistOnWriteFilterDevice $False#> `
                            <#-GenerateSuccessAlert $True#> `
                            <#-PercentSuccess 90#> `
                            <#-TimeValue 10#> `
                            <#-TimeUnit Days#> `
                            -DisableOperationsManagerAlert $True `
                            -GenerateOperationsManagerAlert $True `
                            -ProtectedType RemoteDistributionPoint `
                            -UnprotectedType $Deployment.UnprotectedType `
                            -UseBranchCache $True `
                            -DownloadFromMicrosoftUpdate $True `
                            -AllowUseMeteredNetwork $False
                    }
                }
                Pop-Location
            }
        }
    }
}