param(
    # Stop SAP application where applicable 
    [Parameter(Mandatory = $false)]
    [boolean]$stopSAPApplication = $true,
    # Tag name to identify the VMs to stop
    [Parameter(Mandatory = $false)]
    [string]$tagNameforSnooze = "Snooze",
    # Tag Value to identify the VMs to stop
    [Parameter(Mandatory = $false)]
    [string]$tagValueforSnooze = "True",
    # Resource group of the VMs to Stop
    [Parameter(Mandatory = $false)]
    [string]$resourceGroup,
    # SAP System ID to Start
    [Parameter(Mandatory=$false)]
    [string]$sapSystemId,
    [Parameter(Mandatory = $true)]
    [String]$automationAccountName,
    [Parameter(Mandatory = $true)]
    [String]$automationAccountRG,
    [Parameter(Mandatory = $false)]
    [Int32]$jobMaxRuntimeInSeconds = 7200
)


function Get-TimeStamp {    
    return "[{0:dd/MM/yy} {0:HH:mm:ss}]" -f (Get-Date)
}

function Get-SAPAutomationJobStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSCustomObject[]]$jobList,
        [Parameter(Mandatory = $true)]
        [String]$automationRG,
        [Parameter(Mandatory = $true)]
        [String]$automationAccount,
        [Parameter(Mandatory = $true)]
        [Int32]$jobMaxRuntimeInSeconds
    )
    BEGIN {}
    PROCESS {
        try {
            $PollingSeconds = 5
            $WaitTime = 0
            foreach ($job in $jobList) {
                $jobDetail = Get-AzAutomationJob -Id $job.JobID -ResourceGroupName $automationRG -AutomationAccountName $automationAccount
                while(-NOT (IsJobTerminalState $jobDetail.Status) -and $WaitTime -lt $jobMaxRuntimeInSeconds) {
                    Write-Information "Waiting for job $($jobDetail.JobID) to complete"
                    Start-Sleep -Seconds $PollingSeconds
                    $WaitTime += $PollingSeconds
                    $jobDetail = $jobDetail | Get-AzAutomationJob
                 }
                if ($jobDetail.Status -eq "Completed") {
                    $job.JobStatus = "Success"
                    Write-Information "Job $($jobDetail.JobID) successfully completed"
                    }
                    else{
                    $job.JobStatus = "NotSuccess"
                    Write-Information "Job $($jobDetail.JobID) didnt finish successfully. Check child runbook for errors"
                    }          
                }
                return $jobList
                }
        catch {
            Write-Output  $_.Exception.Message
            Write-Output "$(Get-TimeStamp) Job status could not be found" 
            exit 1
        }
    }
    END{}

}

function IsJobTerminalState([string]$Status) {
    $TerminalStates = @("Completed", "Failed", "Stopped", "Suspended")
    return $Status -in $TerminalStates
  }

try {
    # Disable-AzContextAutosave -Scope Process
    # # Connect to Azure with system-assigned managed identity
    # $AzureContext = (Connect-AzAccount -Identity).context
    $AzureContext = Set-AzContext -Subscription "27e7563e-f63e-42c5-85d9-1c9de296c82f"
    # # set and store context
    # $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    Write-Output "Working on subscription $($AzureContext.Subscription) and tenant $($AzureContext.Tenant)"
    
    # Get list of VMs to be stopped
    if ($resourceGroup)
    {   
        $vms = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Compute/virtualMachines"  -ResourceGroupName $resourceGroup
    }
    elseif ($sapSystemId)
    {
        $vms = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Compute/virtualMachines" |  Where-Object {$_.Tags.SAPSystemSID -eq $sapSystemId}
    }
    else {
        $vms = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Compute/virtualMachines"
    }
    
    $sapVISArray = [System.Collections.ArrayList]@()
    if ($stopSAPApplication) 
    {   $sapSIDs = $vms.Tags.SAPSystemSID | Select-Object -Unique
        foreach ($sapSID in $sapSIDs) { 
            $sapVISRG = $vms | Where-Object { $_.Tags.SAPSystemSID -eq $sapSID } | Select-Object @{Name = "VISRG"; Expression = { $_.Tags.SAPVISRG } } -First 1
            $sapVISArray.Add([PSCustomObject]@{SAPSystemID=$sapSID; SAPVISResourceGroup=$sapVISRG.VISRG; SAPVISSubscription=$($AzureContext.Subscription)})
        }
    
        Write-Output "Below SAP systems will be stopped"
        $sapVISArray | Format-Table -AutoSize
        $jobList = [System.Collections.ArrayList]@()
        foreach ($sapVIS in $sapVISArray) 
        {
        Write-Output "Triggering jobs to stop SAP applications"
        $jobParams = @{virtualInstanceName = $($sapVIS.SAPSystemID); virtualInstanceRG = $($sapVIS.SAPVISResourceGroup)}
        $startJob = Start-AzAutomationRunbook -AutomationAccountName $automationAccountName `
                                              -Name "Stop-SAPSystemUsingACSS" `
                                              -ResourceGroupName $automationAccountRG `
                                              -Parameters $jobParams

        $jobList.Add([PSCustomObject]@{jobID=$($startJob.jobID); SAPSystemID=$($sapVIS.SAPSystemID); jobStatus="Initiated"})
        }
        Write-Output "$(Get-TimeStamp) Jobs initiated to stop SAP systems"
        $jobList | Format-Table -AutoSize
        Write-Output "Checking status of SAP system stop jobs"
        $updatedJobList = Get-SAPAutomationJobStatus -jobList $jobList `
                                               -automationAccount $automationAccountName `
                                               -automationRG $automationAccountRG `
                                               -jobMaxRuntimeInSeconds $jobMaxRuntimeInSeconds
        $failedJobs = $updatedJobList | Where-Object {$_.jobStatus -eq "NotSuccess"}
        if ($failedJobs) {
            Write-Output "Failed to stop some SAP systems. See child jobs for further details"
            $failedJobs | Format-Table -AutoSize
        }
        Write-Output "$(Get-TimeStamp) Final output of jobs"
        Write-Output $updatedJobList
        Write-Output ""
        Write-Output "Checking status of SAP systems and stopping corresponding VMs"

        foreach ($sapVIS in $sapVISArray) {
        $status = Get-AzWorkloadsSapVirtualInstance -Name $($sapVIS.SAPSystemID) -ResourceGroupName $($sapVIS.SAPVISResourceGroup) -SubscriptionId $($sapVIS.SAPVISSubscription)
        $status | Format-Table -AutoSize -Property Name, ResourceGroupName, Health, Status
        if ($status.Status -ne "Running" -or $status.Status -ne "PartiallyRunning") 
        {
                Write-Output "SAP application $($status.Name) is in Stopped state. Stopping corresponding VMs"
                $sapVMs = $vms | Where-Object { $_.Tags.SAPSystemSID -eq $sapVIS.SAPSystemID }
                $sapVMs | Format-Table -AutoSize -Property Name,ResourceGroupName
                
                $sapVMs | ForEach-Object -ThrottleLimit 10 -Parallel {
                    $rc = Stop-AzVM -ResourceGroupName $($_.ResourceGroupName) -Name $($_.Name) -Force -ErrorAction Continue                   
                    }
        }
        else {
                Write-Error "Error while stopping SAP application $sapSID. See error message for further details" -ErrorAction Continue
            }
        }
        #Getting list of VMs without SAP System ID tag
        Write-Output "Stopping VMs without SAP System ID tag"
        $nonSAPVMs = $vms | Where-Object { $_.Tags.SAPSystemSID -eq $null }
        if ($nonSAPVMs) {
        $nonsapVMs | Format-Table -AutoSize -Property Name,ResourceGroupName
        $nonsapVMs | ForEach-Object -ThrottleLimit 10 -Parallel {
            $rc = Stop-AzVM -ResourceGroupName $($_.ResourceGroupName) -Name $($_.Name) -Force -ErrorAction Continue                   
            }
        }
    }
    else {
        Write-Output "Stop SAP flag set to false. Proceeding with VM shutdown"
        $vms | ForEach-Object -ThrottleLimit 10 -Parallel {
            $rc = Stop-AzVM -ResourceGroupName $($_.ResourceGroupName) -Name $($_.Name) -Force -ErrorAction Continue
                                
            }
    }
    #Displaying final status of VMS
    Write-Output "Final status of VMs are as below"
    foreach ($vm in $vms) {
        $status = Get-AzVM -ResourceGroupName $($vm.ResourceGroupName) -Name $($vm.Name) -Status
        $status | Format-Table -AutoSize -Property Name, ResourceGroupName, Statuses
        }
}
catch {
    Write-Output "Error while Stopping the VMs. See error message for further details"
        Write-Output  $_.Exception
        exit 1
}   
    