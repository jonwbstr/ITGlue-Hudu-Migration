
if ($ImportArticles -eq $true) {

    if (-not $PlaceInternalDocsInInternalCompany -and $GlobalKBFolder -in ('y','yes','ye')) {
        if (-not ($GlobalKBFolder = Get-HuduFolders -name $InternalCompany)) {
            $GlobalKBFolder = (New-HuduFolder -Name $InternalCompany).folder
        }
    } 
else {
    $GlobalKBFolder = $null
}


$ITGDocuments = Import-CSV -Path (Join-Path -path $ITGLueExportPath -ChildPath "documents.csv")
[string]$ITGDocumentsPath = Join-Path -path $ITGLueExportPath -ChildPath "Documents"

$files = Get-ChildItem -Path $ITGDocumentsPath -recurse
$MatchedArticles = foreach ($doc in $ITGDocuments) {
    $article = Start-ArticleStubs `
        -Document $doc -Files $files `
        -ITGDocumentsPath $ITGDocumentsPath -MatchedCompanies $MatchedCompanies `
        -GlobalKBFolder $GlobalKBFolder `
        -IncludeIgnoredFirstArticleDirectory:$($IncludeIgnoredFirstArticleDirectory ?? $false) `
        -PlaceInternalDocsInInternalCompany:$($PlaceInternalDocsInInternalCompany ?? $false)

    if ($article) { $article }
}
