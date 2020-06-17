<#

.SYNOPSIS
                This script automates the FI Download of UCS firmware and update of Infra and Server FW
                
.DESCRIPTION
                This script performs FI downloads of bundles to the target UCS domain from the local filesystem.
                Once the FI download is complete, an Infrastructure (A bundle) update is performed followed by Host Firmware Policy (HFP) updates.
                Infra updates are always performed, HFP updates can be skipped with the -infraOnly option

.PARAMETERSET
                hfp: Host Firmware Policy Name (org-root)
                infraOnly: update only infra components

.EXAMPLE
                Download-Bundles-Update-FW.ps1 -ucs xx.xx.xx.xx -version 'x.x(xx)' -imagedir c:\work\images -hfp org-root/fw-host-pack-default
                Download-Bundles-Update-FW.ps1 -ucs xx.xx.xx.xx -version 'x.x(xx)' -imagedir c:\work\images -infraOnly 
                -ucs -- UCS Manager IP -- Example: "1.2.3.4"
                -version -- UCS Manager version to upgrade -- Example: "4.1(1c)"
                -imagedir -- Path to download firmware bundle
                -hfp -- Host Firmware Policy Name (org-root), not required if -infraOnly specified -- Example: 4.1.1c
                -infraOnly -- Only perform infra update (A bundle)
                The prompts that will always be presented to the user will be for Username and Password for UCS


.NOTES
                Author: Eric Williams, David Soper
                Company: Cisco Systems, Inc.
                Version: v1.1
                Date: 06/15/2020
                Disclaimer: Code provided as-is.  No warranty implied or included.  This code is for example use only and not for production

.INPUTS
                UCSM IP Address
                UCS Manager version to upgrade
                Directory path to download firmware image bundles
                HFP parameter with HFP name

.OUTPUTS
                None
                
.LINK
                https://github.com/movinalot/ucs-code

#>

param(
    [parameter(Mandatory=${true})][string]${ucs},
    [parameter(Mandatory=${true})][string]${version},
    [parameter(Mandatory=${true})][string]${imageDir},
    [parameter(ParameterSetName='hfp', Mandatory=${true})][string]${hfp},
    [parameter(ParameterSetName='infraOnly', Mandatory=${true})][Switch]${infraOnly}
)

function Set-LogFilePath($LogFile)
{
    Write-Host "Creating log file under directory ${LogFile}\Logs\"
    $Global:LogFile = "$LogFile\Logs\Script.$(Get-Date -Format yyyy-MM-dd.hh-mm-ss).log"
    if([System.IO.File]::Exists($Global:LogFile) -eq $false)
    {
        $null = New-Item -Path $Global:LogFile -ItemType File -Force
    }
}

function Write-Log
{
    [CmdletBinding()]
    param 
    ( 
        [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [String] $Message
    )
    
    $lineNum = (Get-PSCallStack).ScriptLineNumber[1]
    $Message = "Line: $lineNum - $Message"

    $ErrorActionPreference = 'Stop'

    "Info: $(Get-Date -Format g): $Message" | Out-File $Global:LogFile -Append
    Write-Host $Message
}

function Write-ErrorLog
{
    [CmdletBinding()] 
    param ( 
        [Parameter(ValueFromPipeline=$true,ValueFromPipelineByPropertyName=$true)]
        [object] $Message
    )
    
    $lineNum = (Get-PSCallStack).ScriptLineNumber[1]
    $Message = "Line: $lineNum - $Message"

    "Error: $(Get-Date -Format g):" | Out-File $Global:LogFile -Append
    $Message | Out-File $LogFile -Append
    Write-Error $Message
    $trash = Disconnect-Ucs -ErrorAction Ignore
    exit   
}

function Connect-UcsManager
{
    # IP address and credentials to access the management server software that manages 
    # firmware updates for the nodes of the solution.
	
    $ucsConnection = Connect-Ucs -Name ${ucs} -Credential ${ucsCred} -ErrorVariable errVar -ErrorAction SilentlyContinue
    if ($errVar)
    {
        Write-Log "Error attempting to connect to UCS Manager at $managementServerAddress. Details: $errVar"
        return $null
    }
    else
    {
        Write-Log "Connected to Cisco UCS Manager $managementServerAddress"
        return $ucsConnection
    }
}

function Wait-UcsManagerActivation
{
    $count = 0
    $ucsConnection = $null
    while ($ucsConnection -eq $null)
    {
        if ($count -eq 20)
        {
            Write-Log "Error creating a session to UCS Manager even after 20 attempts"
            return $null
        }
        Write-Log "Checking if UCS Manager $($Parameters.ManagementServerAddress) is reachable.."
        if ((Test-Connection -ComputerName ${ucs} -Quiet) -ne $true)
        {
            $count++
            Write-Log "UCS Manager is still not reachable.."
            Write-Log "Sleeping for 30 seconds.. "
            Start-Sleep -Seconds 30
            continue
        }
        $count++
        Write-Log "Attempt # $count - Trying to login to UCS Manager..."
        $ucsConnection = Connect-UcsManager
        if ($ucsConnection -eq $null)
        {
            Write-Log "Error creating a session to UCS Manager "
            Write-Log "Sleeping for 30 seconds..."
            Start-Sleep -Seconds 30
        }
        else
        {
            Write-Log "Successfully logged back into UCS Manager"
            return $ucsConnection
        }
    }
}

function Wait-UcsFabricInterconnectActivation($fiDetails)
{
    $count = 0
    $isComplete = $false
    do
    {
        if ($count -eq 20)
        {
            Write-Log "Error FI activation is still not completed even after 20 minutes. Exiting with error now"
            return $false
        }
        $count++
        Write-Log "Getting the status of FI $($fiDetails.Id)..."
        try 
        {		
            $fwStatus = $fiDetails | Get-UcsFirmwareStatus -ErrorAction Stop| Select OperState
            switch ($fwStatus.OperState)
            {
                { @("bad-image", "failed", "faulty-state") -contains $_ } { Write-Log "Firmware activation of the Fabric Interconnect $($fiDetails.Id) has failed. Status is $fwStatus"; $isComplete = $true; return $false }
                "ready" { Write-Log "Firmware activation of the Fabric Interconnect $($fiDetails.Id) is complete"; $isComplete = $true; return $true }
                { @("activating", "auto-activating", "auto-updating", "rebooting", "rebuilding", "scheduled", "set-startup", "throttled", "upgrading", "updating", "") -contains $_ }
                {
                    Write-Log "Firmware activation is in progress $fwStatus";
                    Write-Log "Sleeping for 1 minute...";
                    Start-Sleep -Seconds 60;
                    break
                }
            }			
        }
        catch
        {
            Write-Log "Failed to get the status of the firmware update process. $_.Exception"
            throw $_.Exception			
        }
    }
    while ($isComplete -eq $false)
}

function Ack-UcsFIRebootEvent
{
    $count = 0
    while ($fwAck -eq $null)
    {		
        $count++
	Write-Log "Checking if there is a Pending activity generated for the activation of the Primary FI"
	$fwAck = Get-UcsFirmwareAck -Filter 'OperState -ilike waiting-for-*'
	if ($fwAck -eq $null)
	{
	    Write-Log "Pending activity is not generated yet sleeping for 1 minute and then retrying the operation.."
	    Start-Sleep -Seconds 60
	}           
	if ($count -ge 40)			
	{
	    Write-ErrorLog "Pending activity is not generated. This is an error case. Terminating firmware update"
	}   
    }
    Write-Log "UCS Manager has generated a pending activity for primary FI reboot."
    Write-Log "Acknowledging the reboot of the primary FI now"
    $trash = Get-UcsFirmwareAck -Filter 'OperState -ilike waiting-for-*' | Set-UcsFirmwareAck -AdminState "trigger-immediate" -Force
    Write-Log "Activation of the primary FI has started"
    Write-Log "This will take few minutes. Sleeping for 5 minutes.."
    Start-Sleep -Seconds 300
}

function Activate-UcsPrimaryFI
{
    $count = 0
    $isCompleted = $false
    $primaryFI = ""
    while (!$isCompleted)
    {
        $fwStatus = $null
        $count++
        if ($count -ge 20)
        {
	    Write-ErrorLog "FI activation is still not completed even after 20 minutes. Exiting with error now"
	}
        if (Get-UcsStatus -ErrorAction SilentlyContinue -ErrorVariable errVar | ? { $_.HaConfiguration -eq "cluster" })
        {
            $primary = Get-UcsMgmtEntity -LeaderShip primary -ErrorAction SilentlyContinue -ErrorVariable errVar
	    if($primary -ne $null)
	    {
		$fwStatus = Get-UcsNetworkElement -Id $primary.Id -ErrorAction SilentlyContinue -ErrorVariable errVar | Get-UcsFirmwareStatus | Select OperState
	    }
        }
        else
        {
            $primary = Get-UcsNetworkElement -ErrorAction SilentlyContinue -ErrorVariable errVar
	    if($primary -ne $null)
	    {
		$fwStatus = Get-UcsNetworkElement -ErrorAction SilentlyContinue -ErrorVariable errVar | Get-UcsFirmwareStatus | Select OperState
	    }
        }
		
	if ( ($fwStatus -eq $null) -or ($primary -eq $null))
	{
	    Write-Log "UCS Manager is not reachable.. Details: $errVar"
	    Write-Log "UCS Manager connection is reset. Reconnecting.."
	    $trash = Disconnect-Ucs -ErrorAction Ignore
	    $ucsConnection = Wait-UcsManagerActivation
	    if ($ucsConnection -eq $null)
	    {
	        Write-Log "ERROR: Unable to login back to the UCS Manager even after multiple retries."
		Write-Log "Terminating firmware update"
		Write-ErrorLog "Firmware Activation has failed"
	    }
	    else
	    {
		# Setting the DefaultUcs so that we don't need to specify the handle for every method call
		$ExecutionContext.SessionState.PSVariable.Set("DefaultUcs", $ucsConnection)
		if (Get-UcsStatus | ? { $_.HaConfiguration -eq "cluster" })
                {
                    $primaryFI = Get-UcsNetworkElement -Id (Get-UcsMgmtEntity -Leadership primary).Id
                }
                else
                {
                    $primaryFI = Get-UcsNetworkElement
                }
		$primaryActivated = Wait-UcsFabricInterconnectActivation $primaryFI
		if (!$primaryActivated)
		{
		    Write-Log "ERROR: Activation of firmware faled on the $($subordFI.Id)"
		    Write-ErrorLog "Firmware Activation has failed"
		}
		else
		{
		    $updatedVersion = $primaryFI | Get-UcsMgmtController | Get-UcsFirmwareRunning -Deployment system | Select PackageVersion
		    Write-Log "Activation of firmware on $($primaryFI.Id) is successful. Updated version is $($updatedVersion.PackageVersion)"
		    break;
		}
	    }
	}
	else
	{
	    Write-Log "Activation of the primary FI is still in progress $($fwStatus.OperState)"
	    Write-Log "Sleeping for a minute.."
	    Start-Sleep -Seconds 60
	}
    }
    $trash = Disconnect-Ucs -ErrorAction Ignore
}

Set-LogFilePath $imageDir

if ((Get-Module | where {$_.Name -ilike "Cisco.UcsManager"}).Name -ine "Cisco.UcsManager")
{
	Write-Log "Loading Module: Cisco UCS PowerTool Module"
	Write-Log ""
	Import-Module Cisco.UcsManager
}  

if ((Get-Module | where {$_.Name -ilike "Cisco.Ucs.Core"}).Name -ine "Cisco.Ucs.Core")
{
	Write-Log "Loading Module: Cisco UCS PowerTool Module"
	Write-Log ""
	Import-Module Cisco.Ucs.Core
}  	

# Script only supports one UCS Domain update at a time
$output = Set-UcsPowerToolConfiguration -SupportMultipleDefaultUcs $false

Try
{
    ${Error}.Clear()
	
    # Login into UCS
    Write-Log "Enter Credentials of UCS Manager to be upgraded to version: '$($version)'"
    ${ucsCred} = Get-Credential -Message "Enter Credentials of UCS Manager to be upgraded"
    Write-Log ""
	
    Write-Log "Logging into UCS Domain: '$($ucs)'"
    Write-Log ""
    $ucsConnection = Connect-UcsManager
    # Setting the DefaultUcs so that we don't need to specify the handle for every method call
    $ExecutionContext.SessionState.PSVariable.Set("DefaultUcs", $ucsConnection)
    
    if (${Error}) 
    {
        Write-Log "Error creating a session to UCS Manager Domain: '$($ucs)'"
        Write-Log "     Error equals: ${Error}"
        Write-Log "     Exiting"
        exit
    }

    # Set bundle names based on provided version
    ${versionSplit} = ${version}.Split([char[]] "()")
    ${versionBundle} = ${versionSplit}[0] + "." + ${versionSplit}[1]
    ${fiModel} = (Get-UcsNetworkElement).Model | Select-Object -First 1
    if ($fiModel -cmatch "^UCS-FI-(?<modelNum>633\d).*$")
    {
        ${aSeriesBundle} = "ucs-6300-k9-bundle-infra." + ${versionBundle} + ".A.bin"
    }
    elseif ($fiModel -cmatch "^UCS-FI-(?<modelNum>632d).*$")
    {
        ${aSeriesBundle} = "ucs-mini-k9-bundle-infra." + ${versionBundle} + ".A.bin"
    }
    elseif ($fiModel -cmatch "^UCS-FI-(?<modelNum>64\d\d).*$")
    {
        ${aSeriesBundle} = "ucs-6400-k9-bundle-infra." + ${versionBundle} + ".A.bin"
    }
    else
    {
        ${aSeriesBundle} = "ucs-k9-bundle-infra." + ${versionBundle} + ".A.bin"
    }

    ${infraVersionA} = ${version} + 'A'
    ${infraVersionB} = ${version} + 'B'
    ${infraVersionC} = ${version} + 'C'

    if (${infraOnly} -eq $false)
    {
        ${bSeriesBundle} = "ucs-k9-bundle-b-series." + ${versionBundle} + ".B.bin"
        ${cSeriesBundle} = "ucs-k9-bundle-c-series." + ${versionBundle} + ".C.bin"
        ${bundle} = @(${aSeriesBundle},${bSeriesBundle},${cSeriesBundle})
    }
    else
    {
        ${bundle} = @(${aSeriesBundle})
    }
        
    foreach (${image} in ${bundle})
    {
        Write-Log "Checking if image file: '$($image)' is already uploaded to UCS Domain: '$($ucs)'"
	${firmwarePackage} = Get-UcsFirmwarePackage -Name ${image}
        ${deleted} = $false
        if (${firmwarePackage})
        {
            # Check if all the images within the package are present by looking at presence
            ${deleted} = ${firmwarePackage} | Get-UcsFirmwareDistImage | ? { $_.ImageDeleted -ne ""}
        }
    
	if (${deleted} -or !${firmwarePackage})
        {
            $Error.Clear()
            # If Image does not exist on FI, uplaod
            $fileName = Join-Path -Path ${imageDir} -ChildPath ${image}
            if((Get-UcsFirmwareDownloader -FileName ${image} -TransferState failed).count -ne 0)
            {
                Write-ErrorLog "Image: '$($image)' already exists under Download Tasks in failed state. Exiting..."
            }
	    Write-Log "Uploading image file: '$($image)' to UCS Domain: '$($ucs)'"
            $trash = Send-UcsFirmware -LiteralPath $fileName | Watch-Ucs -Property TransferState -SuccessValue downloaded -FailureValue failed -PollSec 30 -TimeoutSec 600 -ErrorAction SilentlyContinue
            if ($Error -ne "")
            {
                Write-ErrorLog "Error uploading image: '$($image)' to UCS Domain: '$($ucs)'. Please check Download Tasks for details."
            }
            Write-Log "Upload of image file: '$($image)' to UCS Domain: '$($ucs)' completed"
	    Write-Log ""  
	}
	else
	{
	    Write-Log "Image file: '$($image)' is already uploaded to UCS Domain: '$($ucs)'"
	    Write-Log ""  
	}
    }

    # Check if the status of the firmware boot unit is ready before proceeding with the firmware update
    if (!(Get-UcsNetworkElement | Get-UcsMgmtController | Get-UcsFirmwareBootDefinition  | Get-UcsFirmwareBootUnit | Where-Object { $_.OperState -eq 'ready'}))
    {
	Write-ErrorLog "Fabric Interconnect is not in ready state. Can't proceed with Firmware update."
    }

    # Start the Firmware Auto Install for the Infrastructure update. This will take care of updating the UCS Manager
    # both the Fabric Interconnects. 
    $activatedVersion = Get-UcsMgmtController -Subject system | Get-UcsFirmwareRunning -Type system | Select Version

    if ($activatedVersion.Version -ne $version)
    {
        Write-Log "Triggering the auto install of the infrastructure firmware  to $aSeriesBundle"
        try 
        {
	    $trash = Start-UcsTransaction
	    $trash = Get-UcsOrg -Level root | Get-UcsFirmwareInfraPack -Name "default" -LimitScope | Set-UcsFirmwareInfraPack -ForceDeploy "yes" -InfraBundleVersion ${infraVersionA} -Force
	    $trash = Get-UcsSchedule -Name "infra-fw" | Get-UcsOnetimeOccurrence -Name "infra-fw" | Set-UcsOnetimeOccurrence -Date (Get-UcsTopSystem).CurrentTime -Force
	    $trash = Complete-UcsTransaction -ErrorAction Stop | Out-Null
        }
        catch 
        {
	    Write-ErrorLog "Failed to start firmware auto install process. Details: $_.Exception"		
        }
        
        Write-Log "Waiting until UCS Manager restarts"
        $trash = Disconnect-Ucs -ErrorAction Ignore
        Write-Log "Sleeping for 5 minutes ..."
        Start-Sleep -Seconds 300
        $ucsConnection = Wait-UcsManagerActivation
        # Setting the DefaultUcs so that we don't need to specify the handle for every method call
        $ExecutionContext.SessionState.PSVariable.Set("DefaultUcs", $ucsConnection)
        #Check if UCSM got activated to the new version. 
        Write-Log "Checking the status of the firmware installation"
        #---->
        $activatedVersion = Get-UcsMgmtController -Subject system | Get-UcsFirmwareRunning -Type system | Select Version

        if ($activatedVersion.Version -eq $version)
        {
	    Write-Log "UCS Manager is activated to the $activatedVersion successfully"
        }
        else
        {
    	    Write-Log "Activation has failed so terminating the update process"
	    Write-ErrorLog "UCS Manager is at $activatedVersion version"
        }
	
        Start-Sleep -Seconds 60
        Write-Log "Checking the status of the FI activation"
        # Now check for the status of the FI activation. As part of the auto install first the secondary FI will be activated.
	while ($subordFIActivated -eq $null) 
	{			
            try
	    {
		$subordFI = Get-UcsNetworkElement -Id (Get-UcsMgmtEntity -Leadership subordinate -ErrorAction Stop).Id	-ErrorAction Stop
		$subordFIActivated = Wait-UcsFabricInterconnectActivation $subordFI                  
	    }
	    catch
	    {
		Write-Log "Failed to get the status $_.Exception"
		$trash = Disconnect-Ucs -ErrorAction Ignore
		$ucsConnection = Wait-UcsManagerActivation
		if ($ucsConnection -eq $null)
		{
		    Write-ErrorLog "Unable to connect to the UCS Manager. Terminating the process.."
                }
		# Setting the DefaultUcs so that we don't need to specify the handle for every method call
		$ExecutionContext.SessionState.PSVariable.Set("DefaultUcs", $ucsConnection)		
	    }
	}
	if (!$subordFIActivated)
	{
	    Write-ErrorLog "Activation of firmware failed on the $($subordFI.Id)"
	}
	else
	{
	    $updatedVersion = $subordFI | Get-UcsMgmtController | Get-UcsFirmwareRunning -Deployment system | Select PackageVersion
	    Write-Log "Activation of firmware on $($subordFI.Id) is successful."
	    Start-Sleep -Seconds 30
			    
            Ack-UcsFIRebootEvent
            Activate-UcsPrimaryFI
	}
    }
    else
    {
        Write-Log "UCS Manager is already at $activatedVersion version. Skipping FI upgrade..."
    }

    #=====================>>>>>>>>>>>Server Firmware Upgrade<<<<<<<<<<================================
    if (${infraOnly} -eq $false)
    {
        $Error.Clear()
        $trash = Disconnect-Ucs -ErrorAction Ignore
        $ucsConnection = Connect-UcsManager
	# Setting the DefaultUcs so that we don't need to specify the handle for every method call
        $ExecutionContext.SessionState.PSVariable.Set("DefaultUcs", $ucsConnection)

        try
	{
            $trash = Get-UcsOrg -Level root | Add-UcsFirmwareComputeHostPack -ModifyPresent -BladeBundleVersion ${infraVersionB} -Name ${hfp} -RackBundleVersion ${infraVersionC} -ErrorAction Stop
            Write-Log "Modified Host Firmware Package in root Organization, Name=${hfp}, Version=${version}"

        }
	catch
	{
	    Write-Error "Failed modifying Host Firmware Package Version=${version}"
            Write-Log ${Error}
            $trash = Disconnect-Ucs -ErrorAction Ignore
            exit
	}
    }
    #=====================>>>>>>>>>>>Server Firmware Upgrade<<<<<<<<<<================================

    $trash = Disconnect-Ucs -ErrorAction Ignore
    Write-Log "Firmware FI Download process completed."
    return $true
}
Catch
{
    Write-Log "Error occurred in script:"
    Write-Log ${Error}
    $trash = Disconnect-Ucs -ErrorAction Ignore
    exit
}
