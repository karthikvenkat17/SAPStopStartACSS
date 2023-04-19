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
[string]$resourceGroup
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
        [string]$resourceGroup
    )    
try{
    # Get the VMs with the tag
    if ($resourceGroup)
    {   
        $vms = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Compute/virtualMachines"  -ResourceGroupName $resourceGroup
    }
    else {
        $vms = Get-AzResource -TagName $tagNameforSnooze -TagValue $tagValueforSnooze -ResourceType "Microsoft.Compute/virtualMachines"
    }
    
    # Start the VMs
    #Write-Verbose $vms -Verbose
    $failedVMs = [System.Collections.ArrayList]@()
    $startedVMs = [System.Collections.ArrayList]@()
    if ($vms) {
        # Start the VMs
        foreach ($vm in $vms) {
            Write-Verbose "$(Get-TimeStamp) Starting VM $($vm.Name) in resource group $($vm.ResourceGroupName) in subscription $($vm.SubscriptionId)" -Verbose
            $rc = Start-AzVM -ResourceGroupName $($vm.ResourceGroupName) -Name $($vm.Name)
            if ($rc.Status -ne 'Succeeded') {
                Write-Error "$(Get-TimeStamp) Failed to start VM $($vm.Name) in resource group $($vm.ResourceGroupName) in subscription $($vm.SubscriptionId)" -ErrorAction Continue
                [void]$failedVMs.Add($vm)
            }
            else {
                Write-Verbose "$(Get-TimeStamp) Successfully started VM $($vm.Name) in resource group $($vm.ResourceGroupName) in subscription $($vm.SubscriptionId)" -Verbose
                [void]$startedVMs.Add($vm)
                }
                }
            }

    else {
        Write-Error "$(Get-TimeStamp) No VMs found with tag $tagNameforSnooze with value $tagValueforSnooze" -ErrorAction Stop
    }
    return $failedVMs, $startedVMs
}
catch {
    Write-Output "Error while starting the VMs"
    Write-Output  $_.Exception
    exit 1
}
}


function Start-SAPApplication {
param(
# Name of the SAP Virtual Instance i.e. SAP System SID
[Parameter(Mandatory=$true)]
[String]$virtualInstanceName,
# Resource group of the target SAP VMs which form the VIS
[Parameter(Mandatory=$true)]
[String]$virtualInstanceRG,
# Subscription of the target SAP VMs which form the VIS
[Parameter(Mandatory=$true)]
[String]$virtualInstanceSubscription
)
# Get VIS Status for the SID
$sapVIS = Get-AzWorkloadsSapVirtualInstance -Name $virtualInstanceName -ResourceGroupName $virtualInstanceRG -SubscriptionId $virtualInstanceSubscription
if($sapVIS.State -eq "RegistrationComplete") ##-and ##$sapVIS.Environment -ne "Production" )
{  
Write-Verbose "$(Get-TimeStamp) SAP System $($virtualInstanceName) is in RegistrationComplete state. Starting SAP Application via ACSS" -Verbose
}
else {
    Write-Verbose "$(Get-TimeStamp) SAP System $($virtualInstanceName) is not in RegistrationComplete state. Skipping SAP Application start via ACSS"
    return "SAP System $($virtualInstanceName) is not in RegistrationComplete state. Skipping SAP Application start via ACSS", $false
}
# Get SAP System Status
if ($sapVIS.SapSystem.State -eq "Running")
{
    Write-Verbose "$(Get-TimeStamp) SAP System $($virtualInstanceName) is already running. Skipping SAP Application start via ACSS" -Verbose
    return "SAP System $($virtualInstanceName) is already running. Skipping SAP Application start via ACSS", $false
}
else {
    Write-Verbose "$(Get-TimeStamp) SAP System $($virtualInstanceName) is not running. Starting SAP Application via ACSS" -Verbose
}
# Start DB instance
Write-Verbose "$(Get-TimeStamp) Checking DB Type for $($virtualInstanceName)"
$dbVIS = Get-AzWorkloadsSapDatabaseInstance -SapVirtualInstanceName $virtualInstanceName -ResourceGroupName $virtualInstanceRG -SubscriptionId $virtualInstanceSubscription
if ($dbVIS.DatabaseType -eq "hdb"){
    Write-Verbose "DB Type is HANA. Proceeding with DB start for SAP System $($virtualInstanceName) via ACSS"
    if ($dbVIS.Status -ne "Running") {
        Write-Verbose "$(Get-TimeStamp) Starting HANA DB for SAP System $($virtualInstanceName)" -Verbose
        $dbrc = Start-AzWorkloadsSapDatabaseInstance -Name $dbVIS.Name -SapVirtualInstanceName $virtualInstanceName -ResourceGroupName $virtualInstanceRG -SubscriptionId $virtualInstanceSubscription
        if ($dbrc.Status -ne 'Succeeded') {
        Write-Error "$(Get-TimeStamp) Failed to Start Database Instance for SID $virtualInstanceName" -ErrorAction Continue
        return "Failed to Start Database Instance for SID $virtualInstanceName", $false
        }
        else {
        Write-Verbose "$(Get-TimeStamp) Successfully started Database Instance for SID $virtualInstanceName" -Verbose
        }
    }
    else {
        Write-Verbose "$(Get-TimeStamp) HANA DB for SAP System $($virtualInstanceName) is already running" -Verbose
    }
}
else {
    Write-Verbose "$(Get-TimeStamp) DB Type is not HANA. Skipping DB start for SAP System $($virtualInstanceName) via ACSS"
    Write-Verbose "Add custom script to start DB here"
}
        
# Start Central Services Instance       
Write-Verbose "$(Get-TimeStamp) Staring SAP Central Services Instance for SID $virtualInstanceName" -Verbose
$scsVIS = Get-AzWorkloadsSapCentralInstance -ResourceGroupName $virtualInstanceRG -SapVirtualInstanceName $virtualInstanceName -SubscriptionId $virtualInstanceSubscription
    if ($scsVIS.Status -eq "Running") {
        Write-Verbose "$(Get-TimeStamp) Central Services Instance for SID $virtualInstanceName is already running" -Verbose
    }
    else{
        $scsrc = Start-AzWorkloadsSapCentralInstance -Name $scsVIS.Name -SapVirtualInstanceName $virtualInstanceName -ResourceGroupName $virtualInstanceRG -SubscriptionId $virtualInstanceSubscription
        if ($scsrc.Status -ne 'Succeeded') {
            Write-Error "$(Get-TimeStamp) Failed to Start Central Services Instance for SID $virtualInstanceName" -ErrorAction Continue
            return "Failed to Start Central Services Instance for SID $virtualInstanceName", $false
        }
        else {
        Write-Verbose "$(Get-TimeStamp) Successfully started Central Services Instance for SID $virtualInstanceName" -Verbose
        }
    }


# Start Application Services Instance
Write-Verbose "$(Get-TimeStamp) Staring SAP Application Services Instance for SID $virtualInstanceName" -Verbose
$appVIS = Get-AzWorkloadsSapApplicationInstance -ResourceGroupName $virtualInstanceRG -SapVirtualInstanceName $virtualInstanceName -SubscriptionId $virtualInstanceSubscription
    if ($appVIS.Status -eq "Running") {
        Write-Verbose "$(Get-TimeStamp) Application Services Instance for SID $virtualInstanceName is already running" -Verbose
            return "SAP $virtualInstanceName is already running", $true
    }
    else {        
        $apprc = Start-AzWorkloadsSapApplicationInstance -Name $appVIS.Name -SapVirtualInstanceName $virtualInstanceName -ResourceGroupName $virtualInstanceRG -SubscriptionId $virtualInstanceSubscription
        if ($apprc.Status -ne 'Succeeded') {
            Write-Error "$(Get-TimeStamp) Failed to Start App Services Instance for SID $virtualInstanceName" -ErrorAction Continue
            return "Failed to Start App Services Instance for SID $virtualInstanceName", $false
        }
        else {
            Write-Verbose "$(Get-TimeStamp) Successfully started Application Services Instance for SID $virtualInstanceName" -Verbose
            return "Successfully started SAP System $virtualInstanceName", $true
        }
    }
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
        exit 1
    }
    
    Write-Output "$(Get-TimeStamp) Below VMs are started"
    $startedVMs | Format-Table -Property Name,ResourceGroupName,SubscriptionId
    
    $sapSIDs = [System.Collections.ArrayList]@()
    if ($startSAPApplication) {
            $sapSIDs = $startedVMs.Tags.SAPSystemSID | Select-Object -Unique 
        Write-Output "$(Get-TimeStamp) Starting SAP applications for SAP System SIDs"
        $sapSIDs | ForEach-Object { Write-Output $_}
    }
    foreach ($sapSID in $sapSIDs)
    {
        Write-Output "$(Get-TimeStamp) Starting SAP application for SAP System SID $sapSID"
        $sapVISRG = $startedVMs | Where-Object {$_.Tags.SAPSystemSID -eq $sapSID} | Select-Object @{Name="VISRG";Expression={$_.Tags.SAPVISRG}} -First 1
        $reasonCode,$sapStartStatus = Start-SAPApplication -virtualInstanceName $sapSID -virtualInstanceRG $sapVISRG.VISRG -virtualInstanceSubscription $($AzureContext.Subscription)
        if ($sapStartStatus) {
            Write-Output "$(Get-TimeStamp) Successfully started SAP application for SAP System SID $sapSID"
        }
        else {
            Write-Error "$(Get-TimeStamp) Failed to start SAP application for SAP System SID $sapSID. Reason: $reasonCode"
        }
    }
    Write-Output "Below SAP systems are started"
    $sapSIDs | Format-Table -Property Name
        
    }
    catch {
        Write-Output "Error while starting the VMs. See error message for further details"
        Write-Output  $_.Exception
        exit 1
    }
    