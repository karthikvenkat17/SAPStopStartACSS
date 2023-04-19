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
[string]$sapSystemId
)

function Get-TimeStamp {    
    return "[{0:dd/MM/yy} {0:HH:mm:ss}]" -f (Get-Date)
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
        $vms = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Compute/virtualMachines"
        $vms = $vms | Where-Object {$_.Tags.SAPSystemID -eq $sapSystemId}
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
    #Disable-AzContextAutosave -Scope Process
    # Connect to Azure with system-assigned managed identity
    # $AzureContext = (Connect-AzAccount -Identity).context
    # set and store context
    # $AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext
    $AzureContext = Set-AzContext -Subscription "27e7563e-f63e-42c5-85d9-1c9de296c82f"
    Write-Output "Working on subscription $($AzureContext.Subscription) and tenant $($AzureContext.Tenant)"

    $failedVMs, $startedVMs = Start-SnoozedVms -tagNameforSnooze $tagNameforSnooze -tagValueforSnooze $tagValueforSnooze -resourceGroup $resourceGroup
    
    if ($failedVMs.count -gt 0) {
        Write-Error "$(Get-TimeStamp) Failed to start $($failedVMs.count) VMs. See previous errors for details"
        $failedVMs | Format-Table -Property Name,ResourceGroupName
        exit 1
    }
    
    Write-Output "$(Get-TimeStamp) Below VMs are started"
    $startedVMs | Format-Table -Property Name,ResourceGroupName
    
    $sapSIDs = [System.Collections.ArrayList]@()
    if ($startSAPApplication) {
            $sapSIDs = $startedVMs.Tags.SAPSystemSID | Select-Object -Unique 
    }
    $sapVIS = [System.Collections.ArrayList]@()
    foreach ($sapSID in $sapSIDs)
    {
        $sapVISRG = $startedVMs | Where-Object {$_.Tags.SAPSystemSID -eq $sapSID} | Select-Object @{Name="VISRG";Expression={$_.Tags.SAPVISRG}} -First 1
        $sapVIS = ([PSCustomObject]@{SAPSystemID=$sapSID; SAPVISResourceGroup=$sapVISRG.VISRG; SAPVISSubscription=$($AzureContext.Subscription)})
    }
    Write-Output "$(Get-TimeStamp) Starting SAP applications for SAP System SIDs"
    $sapVIS | Format-Table -AutoSize



    $sapVIS | ForEach-Object -ThrottleLimit 10 -Parallel {
        Write-Output "Starting SAP application for SAP System ID $($_.SAPSystemID)"
        Start-SAPSystemUsingACSS -virtualInstanceName $_.SAPSystemID -virtualInstanceRG $_.SAPVISResourceGroup -virtualInstanceSubscription $_.SAPVISSubscription
    }
    
    Write-Output "Final status of SAP systems are as below"
    foreach ($sapInstance in $sapVIS) {
        $status = Get-AzWorkloadsSapVirtualInstance -Name $sapInstance.SAPSystemID -ResourceGroupName $sapInstance.SAPVISResourceGroup -virtualInstanceSubscription $sapInstance.SAPVISSubscription
        $status | Format-Table -AutoSize
        
    }
    }
    catch {
        Write-Output "Error while starting the VMs. See error message for further details"
        Write-Output  $_.Exception
        exit 1
    }
    