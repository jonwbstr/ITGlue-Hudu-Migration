
write-host "wrapup 1/10... setting asset layouts as active, enabling advanced website monitoring features" -ForegroundColor DarkCyan
foreach ($layout in Get-HuduAssetLayouts) {write-host "setting $($(Set-HuduAssetLayout -id $layout.id -Active $true).asset_layout.name) as active" }
if ($true -eq $DisableWebsiteMonitoring) {write-host "leaving websites unmonitored per user-config"} else {$MatchedWebsites.HuduObject | Where-Object {$_.id -and $_.id -gt 0} | Foreach-Object {write-host "Enabling advanced monitoring features for $($(Set-HuduWebsite -id $_.id -EnableDMARC 'true' -EnableDKIM 'true' -EnableSPF 'true' -DisableDNS 'false' -DisableSSL 'false' -DisableWhois 'false' -Paused 'false').name)" -ForegroundColor DarkCyan}}

write-host "wrapup 2/10... adding attachments (this can take a while)"
. .\Add-HuduAttachmentsViaAPI.ps1

write-host "wrapup 3/10... Creating IPAM/Networks and Addresses if user-configured to do so... $($importChecklists)"
if ($true -eq $ImportConfigInterfaces){
    write-host "Calculations for addresses can take a while. Please be patient. If it looks like it's stuck, it's just crunching numbers from your $($MatchedConfigurations.count) possible configurations"
    $MatchedInterfaces = Invoke-HuduConfigurationIPAMSync -MatchedConfigurations $MatchedConfigurations
}

write-host "wrapup 4/10... $(if ($true -eq $allowSettingFlagsAndTypes) {"Setting"} else {"Skipping"}) optional flags and flag types..."
if ($true -eq $allowSettingFlagsAndTypes){
    . .\public\Add-HuduFlagsFlagtypes.ps1
}

write-host "wrapup 5/10... Setting Standalone articles with attachments to filename..."
foreach ($a in $(Get-HuduArticles | where-object {$_.content -eq "Empty Document in IT Glue Export - Please Check IT Glue" -and $_.name -ilike "*.*"})){Set-HuduArticle -id $a.id -content "Please see attached file, $($a.name)"}
if (get-command -name Set-HapiErrorsDirectory -ErrorAction SilentlyContinue){try {Set-HapiErrorsDirectory -skipRetry $false} catch {}}

write-host "wrapup 6/10... Placing password folders if user-configured to do so... $($importPasswordFolders)"
if ($true -eq $importPasswordFolders){
    . .\public\Process-PasswordFolders.ps1
}
write-host "wrapup 7/10... Placing checklists / checklist templates if user-configured to do so... $($importChecklists)"
if ($true -eq $importChecklists){
    . .\public\Process-Checklists.ps1
}

write-host "wrapup 8/10... adding missing relations (this can take a long while). Some errors may appear but can be safely ignored."  -ForegroundColor DarkCyan
# set retry to off/false in HuduAPI module, this will save time during adding potentially existent relations.
if (get-command -name Set-HapiErrorsDirectory -ErrorAction SilentlyContinue){try {Set-HapiErrorsDirectory -skipRetry $true} catch {}}
. .\Get-MissingRelations.ps1

write-host "wrapup 9/10... archiving items..."  -ForegroundColor DarkCyan
$DocsCsv = import-csv "$ITGLueExportPath\documents.csv"
$ArchivedPasswords = $MatchedPasswords | Where-Object {$_.itgobject.attributes.archived -eq $true}
$ArchivedConfigurations = $MatchedConfigurations | Where-Object {$_.ITGObject.attributes.archived -eq $true}    
$ArchivedAssets = $MatchedAssets | Where-Object {$_.ITGObject.attributes.archived -eq $true}

$ptaresults = $ArchivedPasswords | ForEach-Object {if ($_.huduid -and $_.huduid -gt 0) {Set-HuduPasswordArchive -id $_.huduid -Archive $true}}
$ctaresults = $ArchivedConfigurations |ForEach-Object {if ($_.huduid -and $_.huduid -gt 0) {Set-HuduAssetArchive -Id $_.huduid -CompanyId $_.huduobject.company_id -Archive $true}}
$ataresults = $ArchivedAssets |ForEach-Object {if ($_.huduid -and $_.huduid -gt 0) {Set-HuduAssetArchive -Id $_.huduid -CompanyId $_.huduobject.company_id -Archive $true}}
$documentsForArchive =  $($matchedarticles | Where-Object {@($($($DocsCsv) | Where-Object {$_.archived -ne "No"}) | ForEach-Object {"$($_.id)"}) -contains [string]($_.ITGID)})
$documentArchiveResults = foreach ($doc in $documentsForArchive) {if ($doc.huduid -and $doc.huduid -gt 0) {Set-HuduArticleArchive -id $doc.huduid -Archive $true -confirm:$false}};
foreach ($obj in @(
    @{Name = "passwords";       Archived = $ptaresults ?? @() },
    @{Name = "configs";         Archived = $ctaresults ?? @() },
    @{Name = "assets";          Archived = $ataresults ?? @() },
    @{Name = "docs";            Archived = $documentArchiveResults ?? @() })) {
    $obj.Archived | ConvertTo-Json -depth 75 | Out-File $(join-path $settings.MigrationLogs "archived-$($obj.Name).json")
}

write-host "wrapup 10/10... $(if ($true -eq ($shouldRunVaultJob ?? $false)) {"Running"} else {"Skipping"}) vault job to update vaulted passwords with real values..."
if ($true -eq ($shouldRunVaultJob ?? $false)){
    . .\Un-Vault-Passwords.ps1
}