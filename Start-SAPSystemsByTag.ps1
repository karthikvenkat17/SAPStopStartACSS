param(
[string]$tagNameforSnooze = "SnoozeSAPSystem",
# Tag Value to identify the VMs to start
[Parameter(Mandatory=$false)]
[string]$tagValueforSnooze = "True",
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
    Disable-AzContextAutosave -Scope Process
    # Connect to Azure with system-assigned managed identity
    $AzureContext = (Connect-AzAccount -Identity).context
    # set and store context
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    Write-Output "Working on subscription $($AzureContext.Subscription) and tenant $($AzureContext.Tenant)"

    # Get the list of SAP Systems to be started
    $sapSystemsToSnooze = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Workloads/sapVirtualInstances"

    if ($sapSystemsToSnooze) {
        Write-Output "$(Get-TimeStamp) Found $($sapSystemsToSnooze.count) SAP systems to be started"
        $sapSystemsToSnooze | Format-Table -AutoSize -Property Name,ResourceGroupName,Location
    }
    else {
        Write-Output "$(Get-TimeStamp) No SAP systems found with tag $tagNameforSnooze with value $tagValueforSnooze"
        exit 0
    }
    $jobList = [System.Collections.ArrayList]@()
    foreach ($sapSystem in $sapSystemsToSnooze) {
        Write-Output "$(Get-TimeStamp) Scheduling job to start SAP system $($sapSystem.Name) in resource group $($sapSystem.ResourceGroupName)"
        $jobParams = @{virtualInstanceName = $($sapSystem.Name)}
        $startJob = Start-AzAutomationRunbook -AutomationAccountName $automationAccountName `
                                              -Name "Start-SAPSystemUsingACSS" `
                                              -ResourceGroupName $automationAccountRG `
                                              -Parameter $jobParams
        $jobList.Add([PSCustomObject]@{jobID=$($startJob.JobID); SAPSystemID=$($sapSystem.Name); jobStatus="Initiated"})                                
                                              
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
    foreach ($sapSystem in $sapSystemsToSnooze) {
    $status =  Get-AzWorkloadsSapVirtualInstance -SubscriptionId $($AzureContext.Subscription) | Where-Object {$_.Name -eq $($sapSystem.Name)}
    $status | Format-Table -AutoSize -Property Name, ResourceGroupName, Health, Status
    }
}
    catch {
        Write-Output "Error while starting the VMs. See error message for further details"
        Write-Output  $_.Exception
        exit 1
}
    