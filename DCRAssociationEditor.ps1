# Load assembly for Windows Forms
Add-Type -AssemblyName System.Windows.Forms

# Function to update the status label
function UpdateStatusLabel([string]$text, [string]$color) {
    $labelStatus.Text = $text
    $labelStatus.ForeColor = $color
}

# Function to validate input fields
function ValidateInputs() {
    if ([string]::IsNullOrWhiteSpace($inputSubscriptionId.Text) -or [string]::IsNullOrWhiteSpace($inputDCRName.Text)) {
        UpdateStatusLabel "Subscription ID and DCR Name are required." "DarkRed"
        return $false
    }
    return $true
}

# Function to query DCR associations
function QueryDCRAssociations() {
    if (-not (ValidateInputs)) { return }
    try {
        $listBoxArcAndVms.Items.Clear()
        UpdateStatusLabel "Querying DCR associations..." "Orange"
        $subscriptionId = $inputSubscriptionId.Text
        $dcrName = $inputDCRName.Text

        # Get the Subscription ID and DCR Name from the input fields
        $subscriptionId = $inputSubscriptionId.Text
        $dcrName = $inputDCRName.Text
   

        # Query all DCRs in the subscription
        $DCRsContent = Invoke-AzRestMethod -Path ("/subscriptions/$subscriptionId/providers/Microsoft.Insights/dataCollectionRules?api-version=2022-06-01") -Method GET
        $DCRs = $DCRsContent.Content | ConvertFrom-Json

        # Filter to find the matching DCR by name and extract its resource group
        foreach ($dcr in $DCRs.value) {
            if ($dcr.name -eq $dcrName) {
                $idParts = $dcr.id -split '/'
                $global:dcrResourceGroup = $idParts[-5] # Adjust index if necessary
                break
            }
        }

        # Execute the query with the provided Subscription ID and DCR Name to get associations
        $DCRAsso = Invoke-AzRestMethod -Path ("/subscriptions/$subscriptionId/resourceGroups/$global:dcrResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$dcrName/associations?api-version=2022-06-01") -Method GET
   
        # Extract associations
        $associations = $DCRAsso.Content | ConvertFrom-Json
        

        # Clear existing items in the list box
        $listBoxAssociations.Items.Clear()
   
        # Add associations to the list box with different icons based on machine type Arc/AzureVM
        $associations.value | ForEach-Object {
            $idParts = $_.id -split '/'
            $resourceName = $idParts[-5]
            $resourceType = $idParts[-6]
            $resourceGroup = $idParts[-9] 

            $displayText = "$resourceName ($resourceGroup)"
            switch ($resourceType) {
                # `u{2733} `u{1f4ab}
                'machines' { $displayText = "✳️ $displayText" }
                'virtualmachines' { $displayText = "💫 $displayText" }
            }

            $idMappings[$displayText] = $_.id
            $listBoxAssociations.Items.Add($displayText)

            $buttonQueryAzureResources.Enabled = $true
        }
        
        # After querying and processing, update the status accordingly
        $sucstatus = 'Read ' + $associations.Value.Count.ToString() + ' associations.'
        UpdateStatusLabel $sucstatus "DarkGreen"
    }
    catch {
        UpdateStatusLabel "Failed to query DCR associations: $_" "DarkRed"
    }
}

# Function to query Azure VMs and Arc Machines
function QueryAzureResources {
    if (-not (ValidateInputs)) { return }
    $resourceGroupName = $textBoxResourceGroup.Text
    if ($textBoxMachineSubscriptionId.Text -ne '') {
        $subscriptionId = $textBoxMachineSubscriptionId.Text 
    }
    else { $subscriptionId = $inputSubscriptionId.Text }

    if ([string]::IsNullOrWhiteSpace($resourceGroupName)) {
        UpdateStatusLabel "Resource Group name is required." "DarkRed"
        return
    }

    UpdateStatusLabel "Querying Azure resources..." "Orange"
    try {
        # Initialize $vms and $arc as empty arrays
        $vms = @()
        $arc = @()

        # Querying Azure VMs
        $vmQueryResult = Invoke-AzRestMethod -Path "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.Compute/virtualMachines?api-version=2022-03-01" -Method GET
        $vmsContent = $vmQueryResult.Content | ConvertFrom-Json 
        if ($vmsContent.Value) {
            $vms = foreach ($vm in $vmsContent.value) {
                [PSCustomObject]@{
                    Id          = $vm.id
                    DisplayName = "$($vm.name)"
                    Type        = "AzureVM"
                }
            }
        }
        else { $vms = @() }
        
        # Querying Azure Arc machines
        $arcMachinesQueryResult = Invoke-AzRestMethod -Path "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/Microsoft.HybridCompute/machines?api-version=2020-08-02" -Method GET
        $arcContent = $arcMachinesQueryResult.Content | ConvertFrom-Json 
        if ($arcContent.value) {
            $arc = foreach ($machine in $arcContent.value) {
                [PSCustomObject]@{
                    Id          = $machine.id
                    DisplayName = "$($machine.name)"
                    Type        = "Arc"
                }
            }
        }
        else { $arc = @() }

        # Combine results 
        $combinedResults = @($vms) + @($arc)
            
        if ($combinedResults.Count -gt 0) {
            # Clear the list box before repopulating
            $listBoxArcAndVms.Items.Clear()
        
            # Populate the list box, filtering out already associated machines
            $combinedResults | ForEach-Object {
                $dcrName = $inputDCRName.Text.ToLower()
                $resourceGroupName = $textBoxResourceGroup.Text
                $subscriptionId = $inputSubscriptionId.Text
                $machineName = $_.DisplayName
        
                # Determine the provider namespace based on the type of machine
                $providerNamespace = if ($_.Type -eq "Arc") {
                    "Microsoft.HybridCompute/machines"
                }
                else {
                    "Microsoft.Compute/virtualMachines"
                }
        
                # Original resource ID components, adjusted for provider namespace
                $baseResourcePath = "/subscriptions/$subscriptionId/resourceGroups/$resourceGroupName/providers/$providerNamespace/$machineName".ToLower()
                # Append the DCR association path using the DCR name
                $dcrAssociationPath = "/providers/microsoft.insights/datacollectionruleassociations/$dcrName-association"
                # Combine the paths to form the new resource ID
                $newResourceId = $baseResourcePath + $dcrAssociationPath
        
                if (-not $idMappings.ContainsValue($newResourceId)) {

                    if ($_.Type -eq "Arc") {
                        $dispText = "✳️ $machineName"
                    }
                    else { $dispText = "💫 $machineName" }

                    $listBoxArcAndVms.Items.Add($dispText)
                    $global:machinesMappings[$dispText] = $_.Id
                
                }
            }

            $sucstatus = "Read " + $combinedResults.Count.ToString() + " machines, " + $listBoxArcAndVms.Items.Count + " not associated."
            UpdateStatusLabel $sucstatus "DarkGreen"
        }
        else {
            UpdateStatusLabel "No machines found." "Orange"
        }
               
    }
    catch {
        UpdateStatusLabel "Failed to query Azure resources" "DarkRed"
    }
}

# Function to add associations in bulk
function AddAssociations {
    $selectedMachines = $listBoxArcAndVms.SelectedItems
    if ($selectedMachines.Count -eq 0) {
        UpdateStatusLabel "No machines selected for association." "DarkRed"
        return
    }

    UpdateStatusLabel "Adding associations..." "Orange"

    try {
        foreach ($selectedMachine in $selectedMachines) {
            if ($null -ne $selectedMachine -and $global:machinesMappings.ContainsKey($selectedMachine)) {
                # Get the base machine ID
                $machineId = $global:machinesMappings[$selectedMachine]
    
                # Construct the necessary data for adding an association
                $subscriptionId = $inputSubscriptionId.Text
                $dcrRule = $inputDCRName.Text
    
                # Construct the JSON payload for the association
                $jsonObject = [PSCustomObject]@{
                    properties = [PSCustomObject]@{
                        dataCollectionRuleId = "/subscriptions/$subscriptionId/resourceGroups/$global:dcrResourceGroup/providers/Microsoft.Insights/dataCollectionRules/$dcrRule"
                    }
                }
                $jsonString = $jsonObject | ConvertTo-Json -Depth 5
    
                # Attempt to add the association
                $associationResult = Invoke-AzRestMethod -Path "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrRule-association?api-version=2022-06-01" -Method PUT -Payload $jsonString
    
                if ($associationResult.StatusCode -eq 200) {
                    Write-Host "Association added successfully for $selectedMachine"
                        
                }
                else {
                    Write-Host "Failed to add association for $selectedMachine"
                }
            }
        }

        # Refresh the list of associations 
        # no refresh!
        # QueryDCRAssociations

        # Update status 
        UpdateStatusLabel "Associations added successfully" "DarkGreen"
    }
    catch {
        UpdateStatusLabel "Failed to add associations" "DarkRed"
    }
    
}

# Function to remove an association by ID
function RemoveSelectedAssociation {
    $selectedText = $listBoxAssociations.SelectedItem
    if ($null -ne $selectedText -and $idMappings.ContainsKey($selectedText)) {
        $associationId = $idMappings[$selectedText]
        $res = RemoveAssociation $associationId

        if ($res) {
            # Update the list box and mappings after removal
            $listBoxAssociations.Items.Remove($selectedText)
            $idMappings.Remove($selectedText)
        }
    }
    else {
        UpdateStatusLabel "No association selected for removal." "DarkRed"
    }
}

function RemoveAssociation([string]$associationId) {
    try {
        Write-Host "Removing association with ID: $associationId"
        $path = $associationId + "?api-version=2022-06-01"
        $associationResult = Invoke-AzRestMethod -Path $path -Method DELETE

        if ($associationResult.StatusCode -eq 200) {
            UpdateStatusLabel "Association deleted successfully" "DarkGreen"
            return $true
        }
        else {
            UpdateStatusLabel "Failed to delete association" "DarkRed"
            return $false
        }
    }
    catch {
        UpdateStatusLabel "Error removing association: $_" "DarkRed"
    }
}

#Install Az.Accounts
Install-Module Az.Accounts

# Run Connect-AzAccount manually if needed
Connect-AzAccount

# Initialize hashtables to store mappings
$idMappings = @{}
$global:machinesMappings = @{}
$global:dcrResourceGroup = $null

# Create a new form
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Azure DCR Associations Editor'
$form.Size = New-Object System.Drawing.Size(950, 650)
$form.StartPosition = 'CenterScreen'

# Add status label
$labelStatus = New-Object System.Windows.Forms.Label
$labelStatus.Text = 'Started.'
$labelStatus.ForeColor = "DarkGreen"
$labelStatus.Location = New-Object System.Drawing.Point(620, 5)
$labelStatus.TextAlign = "MiddleRight"
$labelStatus.Size = New-Object System.Drawing.Size(300, 20)


# Label and input field for DCR Subscription ID
$labelSubscriptionId = New-Object System.Windows.Forms.Label
$labelSubscriptionId.Text = 'DCR Subscription ID:'
$labelSubscriptionId.Location = New-Object System.Drawing.Point(10, 10)
$labelSubscriptionId.Size = New-Object System.Drawing.Size(120, 20)
$inputSubscriptionId = New-Object System.Windows.Forms.TextBox
$inputSubscriptionId.Location = New-Object System.Drawing.Point(150, 10)
$inputSubscriptionId.Text = '1de0fe9e-5d0d-41fa-b34d-457f5bd2789e'
$inputSubscriptionId.Width = 300

# Label and input field for Data Collection Rule Name
$labelDCRName = New-Object System.Windows.Forms.Label
$labelDCRName.Text = 'DCR Name:'
$labelDCRName.Location = New-Object System.Drawing.Point(10, 40)
$inputDCRName = New-Object System.Windows.Forms.TextBox
$inputDCRName.Location = New-Object System.Drawing.Point(150, 40)
$inputDCRName.Text = 'CEFDCR'
$inputDCRName.Width = 300


$labelMachineId = New-Object System.Windows.Forms.Label
$labelMachineId.Text = 'Associations:'
$labelMachineId.Location = New-Object System.Drawing.Point(10, 100)



# Add filter controls
$filterTextBox = New-Object System.Windows.Forms.TextBox
$filterTextBox.Location = New-Object System.Drawing.Point(100, 100)
$filterTextBox.Size = New-Object System.Drawing.Size(200, 20)
$filterButton = New-Object System.Windows.Forms.Button
$filterButton.Location = New-Object System.Drawing.Point(320, 100)
$filterButton.Size = New-Object System.Drawing.Size(75, 23)
$filterButton.Text = 'Filter'
# Filter button click event
$filterButton.Add_Click({
        $filterText = $filterTextBox.Text.ToLower()
        $listBoxAssociations.Items.Clear()
        $idMappings.Keys | Where-Object { $_.ToLower().Contains($filterText) } | ForEach-Object {
            $listBoxAssociations.Items.Add($_)
        }
    })


# Create list boxes for associations
$listBoxAssociations = New-Object System.Windows.Forms.ListBox
$listBoxAssociations.Location = New-Object System.Drawing.Point(10, 130)
$listBoxAssociations.Size = New-Object System.Drawing.Size(230, 400)


# Button to execute the query for DCRs and Associations
$buttonQuery = New-Object System.Windows.Forms.Button
$buttonQuery.Text = 'Query DCR Associations'
$buttonQuery.Location = New-Object System.Drawing.Point(10, 70)
$buttonQuery.Size = New-Object System.Drawing.Size(200, 23)
$buttonQuery.Add_Click({ QueryDCRAssociations })
  

# Machine subscription label and textbox
$labelMachineSubscriptionId = New-Object System.Windows.Forms.Label
$labelMachineSubscriptionId.Text = 'Machines Subscription ID:'
$labelMachineSubscriptionId.Location = New-Object System.Drawing.Point(420, 130)
$labelMachineSubscriptionId.AutoSize = $true
$textBoxMachineSubscriptionId = New-Object System.Windows.Forms.TextBox
$textBoxMachineSubscriptionId.Location = New-Object System.Drawing.Point(570, 130)
$textBoxMachineSubscriptionId.Size = New-Object System.Drawing.Size(200, 20)

# Machine Resource Group Name TextBox
$labelResourceGroup = New-Object System.Windows.Forms.Label
$labelResourceGroup.Text = 'Machines Resource Group:'
$labelResourceGroup.Location = New-Object System.Drawing.Point(420, 160)
$labelResourceGroup.AutoSize = $true
$textBoxResourceGroup = New-Object System.Windows.Forms.TextBox
$textBoxResourceGroup.Location = New-Object System.Drawing.Point(570, 160)
$textBoxResourceGroup.Size = New-Object System.Drawing.Size(200, 20)

# Query Azure Machine Resources Button
$buttonQueryAzureResources = New-Object System.Windows.Forms.Button
$buttonQueryAzureResources.Text = 'Query VMs'
$buttonQueryAzureResources.Enabled = $false
$buttonQueryAzureResources.Location = New-Object System.Drawing.Point(780, 130)
$buttonQueryAzureResources.Size = New-Object System.Drawing.Size(130, 50)
$buttonQueryAzureResources.Add_Click({ QueryAzureResources })

# ListBox for Displaying Machines Query Results
$listBoxArcAndVms = New-Object System.Windows.Forms.ListBox
$listBoxArcAndVms.Location = New-Object System.Drawing.Point(570, 200)
$listBoxArcAndVms.Size = New-Object System.Drawing.Size(230, 330)
$listBoxArcAndVms.SelectionMode = [System.Windows.Forms.SelectionMode]::MultiExtended

# Add Association Button
$buttonAddAssociation = New-Object System.Windows.Forms.Button
$buttonAddAssociation.Text = '<- Add Associations'
$buttonAddAssociation.Location = New-Object System.Drawing.Point(300, 280)
$buttonAddAssociation.Size = New-Object System.Drawing.Size(250, 23)
$buttonAddAssociation.Add_Click({ AddAssociations })

# Button to remove machine associations
$buttonRemoveAssociation = New-Object System.Windows.Forms.Button
$buttonRemoveAssociation.Text = 'Remove Machine Association'
$buttonRemoveAssociation.Location = New-Object System.Drawing.Point(10, 540)
$buttonRemoveAssociation.Size = New-Object System.Drawing.Size(200, 23)
$buttonRemoveAssociation.Add_Click({ RemoveSelectedAssociation })

# Add controls to the form
$form.Controls.Add($labelStatus)
$form.Controls.Add($labelSubscriptionId)
$form.Controls.Add($inputSubscriptionId)
$form.Controls.Add($labelDCRName)
$form.Controls.Add($inputDCRName)
$form.Controls.Add($buttonQuery)
$form.Controls.Add($filterTextBox)
$form.Controls.Add($filterButton)
$form.Controls.Add($labelMachineId)
$form.Controls.Add($listBoxAssociations)
$form.Controls.Add($buttonRemoveAssociation)
$form.Controls.Add($labelMachineSubscriptionId)
$form.Controls.Add($textBoxMachineSubscriptionId)
$form.Controls.Add($labelResourceGroup)
$form.Controls.Add($textBoxResourceGroup)
$form.Controls.Add($buttonQueryAzureResources)
$form.Controls.Add($listBoxArcAndVms)
$form.Controls.Add($buttonAddAssociation)

# Show the form
$form.ShowDialog()
