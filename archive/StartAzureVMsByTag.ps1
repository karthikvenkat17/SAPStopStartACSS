param(
# Start SAP application where applicable 
[Parameter(Mandatory=$false)]
[boolean]$startSAPApplication = $true,
# Tag name to identify the VMs to start
[Parameter(Mandatory=$false)]
[string]$tagNameforSnooze = "Snooze",
# Tag Value to identify the VMs to start
[Parameter(Mandatory=$false)]
[string]$tagValueforSnooze = "True",
# Resource group of the VMs to Start
[Parameter(Mandatory=$false)]
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
  

function Start-SnoozedVms {
    param(
        [Parameter(Mandatory=$true)]
        [string]$tagNameforSnooze,
        [Parameter(Mandatory=$true)]
        [string]$tagValueforSnooze,
        [Parameter(Mandatory=$false)]
        [string]$resourceGroup,
        [Parameter(Mandatory=$false)]
        [string]$sapSystemId
    )    
    # Get all VMs to be started 
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

    # Start the VMs
    if ($vms) {
        Write-Verbose "$(Get-TimeStamp) Starting VMs found with the tag" -Verbose
        # Start the VMs
        $vms | Foreach-Object -ThrottleLimit 10 -Parallel {
            Write-Verbose "Starting VM $($_.Name) in resource group $($_.ResourceGroupName) in subscription $($_.SubscriptionId)" -Verbose
            $rc = Start-AzVM -ResourceGroupName $_.ResourceGroupName -Name $_.Name
            Write-Verbose "$($rc.Status)" -Verbose
    }

    #Check status of VMs
    $failedVMs = [System.Collections.ArrayList]@()
    $startedVMs = [System.Collections.ArrayList]@()
    foreach ($vm in $vms) {
    Write-Verbose "$(Get-TimeStamp) Checking status of VM $($vm.Name) in resource group $($vm.ResourceGroupName) in subscription $($vm.SubscriptionId)" -Verbose
    $status = Get-AzVM -ResourceGroupName $($vm.ResourceGroupName) -Name $($vm.Name) -Status
    if ($status.Statuses.DisplayStatus -contains 'VM Running') {
        Write-Verbose "Successfully started VM $($vm.Name) in resource group $($vm.ResourceGroupName) in subscription $($vm.SubscriptionId)" -Verbose 
        [void]$startedVMs.Add($vm)
    }
    else {
    Write-Verbose "Failed to start VM $($vm.Name) in resource group $($vm.ResourceGroupName) in subscription $($vm.SubscriptionId). Current state is $($vm.Statuses.DisplayStatus)" 
        [void]$failedVMs.Add($vm)
    }
    }
    }

    else {
        Write-Error "$(Get-TimeStamp) No VMs found with tag $tagNameforSnooze with value $tagValueforSnooze" -ErrorAction Stop
    }
    return $failedVMs, $startedVMs
}

try {
    Disable-AzContextAutosave -Scope Process
    # Connect to Azure with system-assigned managed identity
    $AzureContext = (Connect-AzAccount -Identity).context
    # set and store context
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    Write-Output "Working on subscription $($AzureContext.Subscription) and tenant $($AzureContext.Tenant)"

    $failedVMs, $startedVMs = Start-SnoozedVms -tagNameforSnooze $tagNameforSnooze -tagValueforSnooze $tagValueforSnooze -resourceGroup $resourceGroup -sapSystemId $sapSystemId
    
    if ($failedVMs.count -gt 0) {
        Write-Error "$(Get-TimeStamp) Failed to start $($failedVMs.count) VMs. See previous errors for details"
        $failedVMs | Format-Table -Property Name,ResourceGroupName
        exit 1
    }
    
    Write-Output "$(Get-TimeStamp) Below VMs are started"
    $startedVMs | Format-Table -AutoSize -Property Name,ResourceGroupName


    $sapVISArray = [System.Collections.ArrayList]@()
    if ($startSAPApplication) 
    {   $sapSIDs = $startedVms.Tags.SAPSystemSID | Select-Object -Unique
        foreach ($sapSID in $sapSIDs) { 
            $sapVISRG = $startedVMs | Where-Object { $_.Tags.SAPSystemSID -eq $sapSID } | Select-Object @{Name = "VISRG"; Expression = { $_.Tags.SAPVISRG } } -First 1
            $sapVISArray.Add([PSCustomObject]@{SAPSystemID=$sapSID; SAPVISResourceGroup=$sapVISRG.VISRG; SAPVISSubscription=$($AzureContext.Subscription)})
        }
        Write-Output "SAP VIS List"
        $sapVISArray | Format-Table -AutoSize
        $jobList = [System.Collections.ArrayList]@()
        foreach ($sapVIS in $sapVISArray)
        {
        $jobParams = @{virtualInstanceName = $($sapVIS.SAPSystemID); virtualInstanceRG = $($sapVIS.SAPVISResourceGroup)}
        $startJob = Start-AzAutomationRunbook -AutomationAccountName $automationAccountName `
                                              -Name 'Start-SAPSystemUsingACSS' `
                                              -ResourceGroupName $automationAccountRG `
                                              -Parameters $jobParams
        $jobList.Add([PSCustomObject]@{jobID=$($startJob.JobID); SAPSystemID=$($sapVIS.SAPSystemID); jobStatus="Initiated"})
        
        }
        Write-Output "$(Get-TimeStamp) Jobs scheduled to start SAP systems"
        $jobList | Format-Table -AutoSize

        Write-Output "Checking status of SAP system start jobs"
        $updatedJobList = Get-SAPAutomationJobStatus -jobList $jobList `
                                               -automationAccount $automationAccountName `
                                               -automationRG $automationAccountRG `
                                               -jobMaxRuntimeInSeconds $jobMaxRuntimeInSeconds


        $failedJobs = $updatedJobList | Where-Object {$_.jobStatus -eq "NotSuccess"}
        if ($failedJobs) {
            Write-Output "Failed to start SAP systems. See error message for further details"
            $failedJobs | Format-Table -AutoSize
        }

        Write-Output "$(Get-TimeStamp) Final output of jobs"
        Write-Output $updatedJobList
        Write-Output ""
        Write-Output "$(Get-TimeStamp) Final status of SAP systems are as below"
        foreach ($sapVIS in $sapVISArray) {
        $status = Get-AzWorkloadsSapVirtualInstance -Name $($sapVIS.SAPSystemID) -ResourceGroupName $($sapVIS.SAPVISResourceGroup) -SubscriptionId $($sapVIS.SAPVISSubscription)
        $status | Format-Table -AutoSize -Property Name, ResourceGroupName, Health, Status
        }
    }
    else {
        Write-Output "$(Get-TimeStamp) Skipping start of SAP application servers"
    }
    }
    catch {
        Write-Output "Error while starting the VMs. See error message for further details"
        Write-Output  $_.Exception
        exit 1
    }
    