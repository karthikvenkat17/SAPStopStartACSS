<#
.SYNOPSIS
   Used to stop SAP Virtual Instance

.DESCRIPTION
    Runbook checks the status of SAP VIS registration and stops it using VIS commands. Requires Az.Workloads PS module. 

.PARAMETER $virtualInstanceName
    Name of the VIS to stop. This is the SAP System SID

.PARAMETER $virtualInstanceSubscription
    Subscription ID for the VIS to stop. Defaults to automation account subscription

.NOTES
    Author: Karthik Venkatraman
#>

    
    
param(
    # Name of the SAP Virtual Instance i.e. SAP System SID
    [Parameter(Mandatory = $true)]
    [String]$virtualInstanceName,
    # Subscription for SAP Virtual Instance
    [Parameter(Mandatory = $false)]
    [String]$virtualInstanceSubscription
)
try {

    Disable-AzContextAutosave -Scope Process
    # Connect to Azure with system-assigned managed identity
    $AzureContext = (Connect-AzAccount -Identity).context
    # set and store context
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    Write-Output "Working on subscription $($AzureContext.Subscription) and tenant $($AzureContext.Tenant)"

    if (!$virtualInstanceSubscription) {
        $virtualInstanceSubscription = $($AzureContext.Subscription)
    }

    # Get VIS Status for the SID
    $sapVIS = Get-AzWorkloadsSapVirtualInstance -SubscriptionId $virtualInstanceSubscription | Where-Object { $_.Name -eq $virtualInstanceName }
    if ($sapVIS.State -eq "RegistrationComplete") {
        ##-and ##$sapVIS.Environment -ne "Production" )  
        Write-Output "SAP Virtual Instance $($virtualInstanceName) is registerd and environment is not Production. Proceeding to stop SAP System"
    }
    else {
        Write-Error "SAP System $($virtualInstanceName) is not registered or environment is Production. Please check if the environment is correct or register the system and try again" -ErrorAction Stop
    }

    # Check if SAP System is already stopped
    if ($sapVIS.Status -eq "Running" -or $sapVIS.SapSystem.Status -eq "PartiallyRunning") {
        Write-Output "SAP System $($virtualInstanceName) is running. Proceeding to stop SAP System"
        # Stop SAP VIS       
        Write-Output "Stopping SAP Virtual Instance for SID $virtualInstanceName" 
        $appstoprc = Stop-AzWorkloadsSapVirtualInstance -InputObject $sapVIS.Id
        if ($appstoprc.Status -ne 'Succeeded') {
            Write-Error "Failed to Stop Virtual Instance for SID $virtualInstanceName" -ErrorAction Stop
        }
        else {
            Write-Output "Successfully stopped SAP System $virtualInstanceName"
        }
    
        # Stop DB instance
        Write-Output "Checking DB Type for $($virtualInstanceName)"
        $dbVIS = Get-AzWorkloadsSapDatabaseInstance -SapVirtualInstanceName $($sapVIS.Name) -ResourceGroupName $($sapVIS.ResourceGroupName)
        if ($dbVIS.DatabaseType -ne "hdb") {
            Write-Output "DB Type is not HANA. Cannot be stopped by ACSS"
            Write-Output "Add additonal script to Stop DB instance for DB Type $($dbVIS.DatabaseType)"
        }
        else {
            Write-Output "Stopping SAP HANA DB for SID $virtualInstanceName"
            $dbstoprc = Stop-AzWorkloadsSapDatabaseInstance -InputObject $dbVIS.Id
            if ($dbstoprc.Status -ne 'Succeeded') {
                Write-Error "Failed to Stop DB Instance for SID $virtualInstanceName" -ErrorAction Stop
            }
            else {
                Write-Output "Successfully stopped Database instance for System $virtualInstanceName"
            }
        }
    
        # Final display of VIS status
        $updatedVIS = Get-AzWorkloadsSapVirtualInstance -SubscriptionId $virtualInstanceSubscription | Where-Object { $_.Name -eq $virtualInstanceName }
        $updatedVIS | Format-Table -AutoSize -Property Name, ResourceGroupName, Health, Environment, ProvisioningState, Location, Status 
    }
    else {
        Write-Output "SAP System $virtualInstanceName is already Stopped. Proceeding with VM shutdown"
    }

    # Stop VMs associated with SAP System
    Write-Output "Stop VMs associated with SAP System $($virtualInstanceName)"
    $vmList = [System.Collections.ArrayList]@()
    foreach ($dbVM in $dbVIS.VMDetail) {
        $vmList.Add($dbVM)
    }
    $scsVIS = Get-AzWorkloadsSapCentralInstance -SapVirtualInstanceName $($sapVIS.Name) -ResourceGroupName $($sapVIS.ResourceGroupName)
    foreach ($scsVM in $scsVIS.VMDetail) {
        $vmList.Add($scsVM)
    }
    $appVIS = Get-AzWorkloadsSapApplicationInstance -SapVirtualInstanceName $($sapVIS.Name) -ResourceGroupName $($sapVIS.ResourceGroupName)
    foreach ($appVM in $appVIS.VMDetail) {
        $vmList.Add($appVM)
    }
    Write-Output "Stopping below VMs for SAP System $($virtualInstanceName)"
    $vmList | Format-Table -AutoSize -Property virtualMachineId
    $vmList | ForEach-Object -ThrottleLimit 10 -Parallel {
        $rc = Stop-AzVM -Id $_.virtualMachineId -Force
        Write-Verbose $rc -Verbose
    }

    #Check status of VMs before Stopping SAP System
    $failedVMs = [System.Collections.ArrayList]@()
    $successVMs = [System.Collections.ArrayList]@()
    Write-Output "Getting Final Status of VMs for SAP System $($virtualInstanceName)"
    foreach ($vm in $vmList) {
        $status = Get-AzVM -ResourceId $($vm.virtualMachineId) -Status
        if ($($status.Statuses[1].DisplayStatus) -contains 'VM Running') {
            [void]$failedVMs.Add($status)
        }
        else {
            [void]$successVMs.Add($status)
        }
    }
    if ($failedVMs.Count -gt 0) {
        Write-Error "Failed to stop VMs for SAP System $($virtualInstanceName). See list below" -ErrorAction Stop
        $failedVMs | Format-Table -AutoSize -Property Name, ResourceGroupName, @{label = 'VMStatus'; Expression = { $_.Statuses[1].DisplayStatus } }
    }
    else {
        Write-Output "Successfully stopped VMs for SAP System $($virtualInstanceName)"
        $successVMs | Format-Table -AutoSize -Property Name, ResourceGroupName, @{label = 'VMStatus'; Expression = { $_.Statuses[1].DisplayStatus } }
    }
}
catch {
    Write-Error  $_.Exception.Message
    "SAP System $virtualInstanceName stop failed. See previous error messages for details"
}