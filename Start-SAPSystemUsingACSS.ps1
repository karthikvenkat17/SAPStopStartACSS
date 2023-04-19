    param(
    # Name of the SAP Virtual Instance i.e. SAP System SID
    [Parameter(Mandatory=$true)]
    [String]$virtualInstanceName,
    # Resource group of SAP VIS
    [Parameter(Mandatory=$false)]
    [String]$virtualInstanceRG
    )
    try {

    Disable-AzContextAutosave -Scope Process
    # Connect to Azure with system-assigned managed identity
    $AzureContext = (Connect-AzAccount -Identity).context
    # set and store context
    $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    Write-Output "Working on subscription $($AzureContext.Subscription) and tenant $($AzureContext.Tenant)"

    # Get VIS Status for the SID
    $sapVIS = Get-AzWorkloadsSapVirtualInstance -SubscriptionId $($AzureContext.Subscription) | Where-Object {$_.Name -eq $virtualInstanceName}
    if($sapVIS.State -eq "RegistrationComplete") ##-and ##$sapVIS.Environment -ne "Production" )
    {  
    Write-Output "SAP System $($virtualInstanceName) is in RegistrationComplete state" 
    }
    else {
        Write-Error "SAP System $($virtualInstanceName) is not in RegistrationComplete state. Skipping SAP Application start via ACSS" -ErrorAction Stop
    }
    # Get SAP System Status
    if ($sapVIS.Status -eq "Running")
    {
        Write-Output "SAP System $($virtualInstanceName) is already running. Skipping SAP Application start via ACSS" 
        exit 0
    }
    else {
        Write-Output "SAP System $($virtualInstanceName) is not running. Starting SAP Application via ACSS" 
    }

    #Start VMs for VIS
    Write-Output "Start VMs associated with SAP System $($virtualInstanceName)"
    $vmList = [System.Collections.ArrayList]@()
    $dbVIS = Get-AzWorkloadsSapDatabaseInstance -SapVirtualInstanceName $($sapVIS.Name) -ResourceGroupName $($sapVIS.ResourceGroupName)
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
    Write-Output "Starting below VMs for SAP System $($virtualInstanceName)"
    $vmList | Format-Table -AutoSize -Property virtualMachineId
    $vmList | ForEach-Object -ThrottleLimit 10 -Parallel {
       $rc = Start-AzVM -Id $_.virtualMachineId
       Write-Verbose $rc -Verbose
    }

    #Check status of VMs before starting SAP System
    $failedVMs = [System.Collections.ArrayList]@()
    $startedVMs = [System.Collections.ArrayList]@()
    Write-Output "Getting Final Status of VMs for SAP System $($virtualInstanceName)"
    foreach ($vm in $vmList) {
        $status = Get-AzVM -ResourceId $($vm.virtualMachineId) -Status
        if ($($status.Statuses[1].DisplayStatus) -contains 'VM Running') {
            [void]$startedVMs.Add($status)
        }
        else {
            [void]$failedVMs.Add($status)
        }
    }
    if ($failedVMs.Count -gt 0) {
        Write-Error "Failed to start VMs for SAP System $($virtualInstanceName). See list below" -ErrorAction Stop
        $failedVMs | Format-Table -AutoSize -Property Name,ResourceGroupName,@{label='VMStatus'; Expression = {$_.Statuses[1].DisplayStatus}}
    }
    else {
        Write-Output "Successfully started VMs for SAP System $($virtualInstanceName)"
        $startedVMs | Format-Table -AutoSize -Property Name,ResourceGroupName,@{label='VMStatus'; Expression = {$_.Statuses[1].DisplayStatus}}
    }

    # Sleep for 1 minute to allow VMs to start
    Start-Sleep 60

    # Start DB instance
    Write-Output "Checking DB Type for $($virtualInstanceName)"
    if ($dbVIS.DatabaseType -ne "hdb"){
        Write-Output "DB Type is not HANA. Cannot be started by ACSS"
        Write-Output "Add additonal script to start DB instance for DB Type $($dbVIS.DatabaseType)"
    }
    else {
        Write-Output "DB Type is HANA. Starting DB instance for SAP System $($virtualInstanceName)"
        $dbstartrc = Start-AzWorkloadsSapDatabaseInstance -InputObject $dbVIS.Id
        if ($dbstartrc.Status -ne 'Succeeded') {
            Write-Error "Failed to Start DB Instance for SID $virtualInstanceName" -ErrorAction Stop
        }
        else {
            Write-Output "Successfully started DB Instance for SID $virtualInstanceName"
        }
    }
     
    # Start SAP VIS       
    Write-Output "Staring Central Services and app servers Instances for SID $virtualInstanceName" 
    $appstartrc = Start-AzWorkloadsSapVirtualInstance -InputObject $sapVIS.Id
    if ($appstartrc.Status -ne 'Succeeded') {
                Write-Error "Failed to Start App Services Instance for SID $virtualInstanceName" -ErrorAction Stop
    }
    else {
           Write-Output "Successfully started SAP System $virtualInstanceName"
        }
    
    # Final display of VIS status
    $updatedVIS = Get-AzWorkloadsSapVirtualInstance -SubscriptionId $($AzureContext.Subscription) | Where-Object {$_.Name -eq $virtualInstanceName}
    $updatedVIS | Format-Table -AutoSize -Property Name,ResourceGroupName,Health,Environment,ProvisioningState,Location,Status 
}
catch {
    Write-Error  $_.Exception.Message
    "SAP System $virtualInstanceName start failed. See previous error messages for details"
}
