if ($MyInvocation.InvocationName -eq '.') {
    Write-Host "Script was dot-sourced" -ForegroundColor Green
} else {
    Write-Host "Script was executed without dot-sourcing, this is the recommended method of running the script to ensure settings are retained in the session" -ForegroundColor Yellow; write-warning "exiting to prevent issues later on, please dot-source the script by running `. .\ITGlue-Hudu-Migration.ps1` from powershell 7 or using the provided ITGlue-Hudu-Migration.exe frontend.";
    exit 1
}
if ((get-host).version.major -ne 7) {
    Write-Host "Powershell 7 Required" -foregroundcolor Red
    exit 1
}

. $PSScriptRoot\Initialize-Module.ps1 -InitType 'Full'
$FirstTimeLoad = 1

############################### Functions ###############################
foreach ($dependency in 
        @("Init-OptionsAndLogs.ps1",
        "Initialize-ImageMagik.ps1",
        "Invoke-ImageTest.ps1",
        "Confirm-Import.ps1",
        "Import-Items.ps1",
        "Get-ImportMode.ps1",
        "Get-ConfigurationsImportMode.ps1",
        "Get-FlexLayoutImportMode.ps1",
        "Import-ITGlueItems.ps1",
        "Find-MigratedItem.ps1",
        "Get-FontAwesomeMap.ps1",
        "ConvertTo-HuduURL.ps1",
        "Add-HuduRelation.ps1",
        "Write-TimedMessage.ps1",
        "Get-CastIfNumeric.ps1",
        "Start-ArticleStubs.ps1",
        "Get-PasswordFolders.ps1",
        "Set-MigrationScope.ps1",
        "Resolve-ArticleFolderPath.ps1",
        "Get-Checklists.ps1",
        "Normalize-String.ps1",
        "Normalize-And-ConvertImage.ps1",
        "Get-ITGFieldPopulated.ps1",
        "JWT-Auth.ps1",
        "NetworkInformation.ps1",
        "PreFlightTests.ps1",
        "Add-OptionalFlags.ps1")){
    write-host "importing $dependency"; . "$($(get-childitem -path "." -Recurse -file "$dependency" | Select-Object -first 1).fullname)";
}
###################### Initial Setup and Confirmations ###############################
Write-Host $InvocationWelcomeText -ForegroundColor Green
write-host $BackupSafetyText -ForegroundColor DarkCyan
Write-Host $LiabilityWarning -ForegroundColor Red

# Prompt for backups, initialize modules, check versions
$FontAwesomeUpgrade = Get-FontAwesomeMap
$ErroredItemsFolder = $errors_folder ?? $(Get-EnsuredPath -path $(join-path $(Resolve-Path .).path "debug"))
$backups=$(if ($true -eq $NonInteractive) {"Y"} else {Read-Host "Y/n"})
$ScriptStartTime = $(Get-Date)

$CurrentVersion =  Set-ExternalModulesInitialized `
        -RequiredHuduVersion ([version]"2.39.6") `
        -DisallowedVersions @([version]"2.37.0") `
        -HuduBaseURL $($hudubaseurl ?? $settings.HuduBaseDomain ?? $null) `
        -HuduAPIKey $($huduapikey ?? $settings.HuduApiKey ?? $null)

write-host "Checking your API keys to make sure they are scoped for password access"
$itglueScopeOk = Test-ITGlueAPIKeyPasswordScope
$huduScopeOk = Test-HuduAPIKeyScope
write-host "Hudu API Key Scope for Password Access: $huduScopeOk"
write-host "IT Glue API Key Scope for Password Access: $itglueScopeOk"

if (-not $true -eq $itglueScopeOk -or -not $true -eq $huduScopeOk) {
    Write-Host "One or both of your API keys do not have the required scope for password access. Please update the key scopes and try again." -ForegroundColor Red
    exit 1
}

if ($backups -notin @("Y", "y")) {
    Write-Host "Please take a backup and run the script again"
    exit 1
}

if (Test-Path -Path "$MigrationLogs") {
    if (-not ([string]::IsNullOrEmpty($guiSettingsDir)) -and (test-path $guiSettingsDir)){
        Write-Host "Settings loaded from frontend, skipping path checks for logs/errors dir. Migration log dir was set to: $MigrationLogs; Gui settings at $guiSettingsDir" -ForegroundColor Green
    } elseif ($ResumePrevious -eq $true) {
        Write-Host "A previous attempt has been found job will be resumed from the last successful section" -ForegroundColor Green
        $ResumeFound = $true
    } else {
        Write-Host "A previous attempt has been found, resume is disabled so this will be lost, if you haven't reverted to a snapshot, a resume is recommended" -ForegroundColor Red
        Write-TimedMessage -Timeout 12 -Message "Press any key to continue or ctrl + c to quit and edit the ResumePrevious setting" -DefaultResponse "proceed with new migration, do not resume"
        $ResumeFound = $false
    }
} else {
    Write-Host "No previous runs found creating log directory"
    $null = New-Item "$MigrationLogs" -ItemType "directory"
    $ResumeFound = $false
}


# Setup some variables
$MatchedInterfaces = [System.Collections.ArrayList]@()
$ManualActions = [System.Collections.ArrayList]@()
$MergedOrganizationSettings = @{Types        = @(); TargetCompany = $null;}
$MatchedPasswordFolders = $MatchedPasswordFolders ?? @(); $preloadedPassFolders = $preloadedPassFolders ?? @{}; $ITGlueSSLCerts = @(); $objectFlagMap = $objectFlagMap ?? @{};
$MatchedChecklists = $MatchedChecklists ?? @(); $ITGlueRawChecklists = $ITGlueRawChecklists ?? @(); $ITglueChecklists = $ITglueChecklists ?? [System.Collections.ArrayList]@(); 
$ErroredItemsFolder = if ($ErroredItemsFolder) {$ErroredItemsFolder} else {(Get-EnsuredPath -path $(join-path $(Resolve-Path .).path "debug"))}
$ConfigMigrationName = $ConfigMigrationName ?? "Configurations"
$ConfigImportAssetLayoutName = $ConfigImportAssetLayoutName ?? "Configurations"
$articlesUpdated = @(); $assetsUpdated = @(); $passwordsUpdated = @(); $companyNotesUpdated = @();

############################### Companies ###############################

$HuduCompanies = Get-HuduCompanies
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Companies.json")) {
    Write-Host "Loading Previous Companies Migration"
    $MatchedCompanies = Get-Content "$MigrationLogs\Companies.json" -raw | Out-String | ConvertFrom-Json
} else {        
    . $PSScriptRoot\public\jobs\Start-Companies.ps1
    $CompaniesToMigrate = $MatchedCompanies | Sort-Object CompanyName | Where-Object { $_.Matched -eq $true }
    $HuduCompanies = Get-HuduCompanies
    $MatchedCompanies | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Companies.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Companies Migrated Continue?"  -DefaultResponse "continue to Locations, please."


# preload JWT-only items if JWT provided and relevant import enabled to avoid token expiration during run
if (-not ([string]::IsNullOrWhiteSpace($ItglueJWT)) -and ($true -eq $importPasswordFolders -or $true -eq $importChecklists)) {
    Write-Host "Since you have provided a JWT token and have checklist or password folder import enabled, we will preload these items from ITGlue before your credential becomes stale." -ForegroundColor Green
    . $PSScriptRoot\Public\Jobs\Preload-JWTOnlyItems.ps1
}

############################### Locations ###############################

if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Locations.json")) {
    Write-Host "Loading Previous Locations Migration"
    $MatchedLocations = Get-Content "$MigrationLogs\Locations.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . $PSScriptRoot\public\jobs\Start-Locations.ps1    
    $($MatchedLocations ?? @()) | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Locations.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Locations Migrated Continue?"  -DefaultResponse "continue to Websites, please."

############################### Websites ###############################


if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Websites.json")) {
    Write-Host "Loading Previous Websites Migration"
    $MatchedWebsites = Get-Content "$MigrationLogs\Websites.json" -raw | Out-String | ConvertFrom-Json
} else {
    . $PSScriptRoot\public\jobs\Start-Websites.ps1    
    $MatchedWebsites | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Websites.json"
}
Write-TimedMessage -Timeout 3 -Message  "Snapshot Point: Websites Migrated Continue?"  -DefaultResponse "continue to Configurations, please."


############################### Configurations ###############################
	
#Check for Configuration Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Configurations.json")) {
    Write-Host "Loading Previous Configurations Migration"
    $MatchedConfigurations = Get-Content "$MigrationLogs\Configurations.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . $PSScriptRoot\public\jobs\Start-Configurations.ps1
    $MatchedConfigurations | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Configurations.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Configurations Migrated Continue?"  -DefaultResponse "continue to Contacts, please."


############################### Contacts ###############################
#Check for Location Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Contacts.json")) {
    Write-Host "Loading Previous Contacts Migration"
    $MatchedContacts = Get-Content "$MigrationLogs\Contacts.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . $PSScriptRoot\public\jobs\Start-Contacts.ps1
    $MatchedContacts | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Contacts.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Contacts Migrated Continue?"  -DefaultResponse "continue to Flexible Asset Layouts, please."

	
############################### Flexible Asset Layouts and Assets ###############################
#Check for Layouts Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\AssetLayouts.json")) {
    Write-Host "Loading Previous Asset Layouts Migration"
    $MatchedLayouts = Get-Content "$MigrationLogs\AssetLayouts.json" -raw | Out-String | ConvertFrom-Json -depth 100
    $AllFields = Get-Content "$MigrationLogs\AssetLayoutsFields.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . $PSScriptRoot\public\jobs\Start-FlexibleAssetLayouts.ps1
    $AllFields | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\AssetLayoutsFields.json"
    $MatchedLayouts | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\AssetLayouts.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Layouts Migrated Continue?"  -DefaultResponse "continue to Flexible Assets, please."

############################### Flexible Assets ###############################
#Check for Assets Resume
$UploadFieldsArePresent = $false
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Assets.json")) {
    Write-Host "Loading Previous Asset Migration"
    $MatchedAssets = Get-Content "$MigrationLogs\Assets.json" -raw | Out-String | ConvertFrom-Json -depth 100
    $MatchedAssetPasswords = Get-Content "$MigrationLogs\AssetPasswords.json" -raw | Out-String | ConvertFrom-Json -depth 100
    $RelationsToCreate = [System.Collections.ArrayList](Get-Content "$MigrationLogs\RelationsToCreate.json" -raw | Out-String | ConvertFrom-Json -depth 100)
    $ManualActions = [System.Collections.ArrayList](Get-Content "$MigrationLogs\ManualActions.json" -raw | Out-String | ConvertFrom-Json -depth 100)
} else {
    . .\Public\Jobs\Start-FlexibleAssets.ps1
    $MatchedAssets | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Assets.json"
    $MatchedAssetPasswords | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\AssetPasswords.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
    $RelationsToCreate | ConvertTo-Json -Depth 20 | Out-File "$MigrationLogs\RelationsToCreate.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Assets Migrated Continue?" -DefaultResponse "continue to Documents/Articles, please."

############################### Documents / Articles ###############################

#Check for Article Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\ArticleBase.json")) {
    Write-Host "Loading Article Migration"
    $MatchedArticles = Get-Content "$MigrationLogs\ArticleBase.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\Public\Jobs\Start-Articles.ps1
    $MatchedArticles | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ArticleBase.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Stub Articles Created Continue?"  -DefaultResponse "continue to Document/Article Bodies, please."

############################### Documents / Articles Bodies ###############################

#Check for Articles Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Articles.json")) {
    Write-Host "Loading Article Content Migration"
    $MatchedArticles = Get-Content "$MigrationLogs\Articles.json" -raw | Out-String | ConvertFrom-Json -depth 100
} else {
    . .\Public\Jobs\Populate-Articles.ps1
    $MatchedArticles | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Articles.json"
    $ArticleErrors | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ArticleErrors.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Articles Created Continue?" -DefaultResponse "continue to Passwords, please."

############################### Passwords ###############################

#Check for Passwords Resume
if ($ResumeFound -eq $true -and (Test-Path "$MigrationLogs\Passwords.json")) {
    Write-Host "Loading Previous Paswords Migration"
    $MatchedPasswords = Get-Content "$MigrationLogs\Passwords.json" -raw | Out-String | ConvertFrom-Json
} else {
    . .\Public\Jobs\Start-Passwords.ps1
    $MatchedPasswords | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\Passwords.json"
    $ManualActions | ConvertTo-Json -depth 100 | Out-File "$MigrationLogs\ManualActions.json"
}
Write-TimedMessage -Timeout 3 -Message "Snapshot Point: Passwords Finished. Continue?"  -DefaultResponse "continue to Document/Article Updates, please."

############################## Update ITGlue URLs on All Areas to Hudu #######################

. .\public\Jobs\LinkReplacement.ps1

############################### Wrap-Up ###############################

. .\Public\Jobs\Wrap-Up.ps1

############################### End ###############################

$VaultedPasswords = $VaultedPasswords ?? @(); $unvaultedMatches = $unvaultedMatches ?? @();
$MatchedUploadFields = $MatchedUploadFields ?? @{}; $UnresolvedUploadFields = $UnresolvedUploadFields ?? @{};
foreach ($auxilliaryObj in @(@{Name="UnvaultedPasswords"; Created = $unvaultedMatches ?? @()}, @{Name = "passwordfolders"; Created = $MatchedPasswordFolders ?? @() }, @{Name="UploadFields"; Created = $MatchedUploadFields ?? @() }, @{Name="UnresolvedUploadFields"; Created = $UnresolvedUploadFields ?? @() }, @{Name = "checklists"; Created = $MatchedChecklists ?? @() }, @{Name="Interfaces-IPAM"; Created = ($MatchedInterfaces ?? @())})) {
    write-host "Writing json dump for $($auxilliaryObj.Name) created during migration for reference in manual actions and for audit purposes"
    $auxilliaryObj.Created | ConvertTo-Json -depth 75 | Out-File $(join-path $settings.MigrationLogs "created-$($auxilliaryObj.Name).json")
}

$CompletedAt = Get-Date
$Duration = New-TimeSpan -Start $ScriptStartTime -End $CompletedAt
$CompletedAt = Get-Date
$Duration = $CompletedAt - $ScriptStartTime

$migratedItems = [ordered]@{
    'Companies Migrated'                         = Get-SafeCount $MatchedCompanies
    'Locations Migrated'                         = Get-SafeCount $MatchedLocations
    'Websites Migrated'                          = Get-SafeCount $MatchedWebsites
    'Configurations Migrated'                    = Get-SafeCount $MatchedConfigurations
    'Contacts Migrated'                          = Get-SafeCount $MatchedContacts
    'Layouts Migrated'                           = Get-SafeCount $MatchedLayouts
    'Assets Migrated'                            = Get-SafeCount $MatchedAssets
    'Articles Migrated'                          = Get-SafeCount $MatchedArticles
    'Passwords Migrated'                         = Get-SafeCount $MatchedPasswords
    'Password Folders Migrated'                  = Get-SafeCount $MatchedPasswordFolders
    'Checklists / Checklist Templates Migrated'  = Get-SafeCount $MatchedChecklists
    'Relations Created'                          = Get-SafeCount $NewRelationsCreated
    'IPAM Interfaces/Networks/Addresses Migrated'= Get-SafeCount $MatchedInterfaces
    'Upload Fields Migrated'                     = $MatchedUploadFields.count ?? 0
    'Upload Fields Unresolved'                   = $UnresolvedUploadFields.count ?? 0
    'Vaulted Passwords'                          = $VaultedPasswords.count ?? 0
    'Unvaulted Matches'                          = $unvaultedMatches.count ?? 0
}

$archivedItems = [ordered]@{
    'Passwords Archived'       = $ptaresults.count ?? 0
    'Configurations Archived'  = $ctaresults.count ?? 0
    'Assets Archived'          = $ataresults.count ?? 0
    'Documents Archived'       = $documentArchiveResults.count ?? 0
}
$MigrationSummary = "$(Format-MigrationSummary -ScriptStartTime $ScriptStartTime -CompletedAt $CompletedAt -Duration $Duration -DebugFolder ($debugFolder ?? "$PSScriptRoot\debug") -MigrationLogs ($MigrationLogs ?? "$PSScriptRoot\debug\logs") -migratedItems $migratedItems -archivedItems $archivedItems)"
$MigrationSummary | Out-File -FilePath "$MigrationLogs\MigrationSummary.txt" -Encoding utf8
Format-ManualActionsReport -ManualActions $ManualActions -OutputPath "$MigrationLogs\ManualActions.html" -summary $MigrationSummary
Write-Host $MigrationSummary -ForegroundColor DarkCyan

Write-TimedMessage -Message "Press any key to view manual actions" -Timeout 5  -DefaultResponse "continue, view generative Manual Actions webpage, please."
Start-Process "$MigrationLogs\ManualActions.html"
