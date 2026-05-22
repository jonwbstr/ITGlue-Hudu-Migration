
if ($ImportArticles -eq $true) {
    $Attachfiles = Get-ChildItem (Join-Path -Path $ITGLueExportPath -ChildPath "attachments\documents") -recurse
    $ImageMap = $ImageMap ?? @{}
    # Now do the actual work of populating the content of articles
    $ArticleErrors = foreach ($Article in $MatchedArticles) {

        $page_out = ''
        $imagePath = $null
    
        # Check for attachments
        $attachdir = $Attachfiles | Where-Object { $_.PSIsContainer -eq $true -and $_.Name -match $Article.ITGID }
        if ($Attachdir) {
            $InFile = ''
            $html = ''
            $rawsource = ''
        }


        Write-Host "Starting $($Article.Name) in $($Article.Company.CompanyName)" -ForegroundColor Green
            
        $InFile = $Article.FullPath
            
        $html = New-Object -ComObject "HTMLFile"
        $rawsource = Get-Content -encoding UTF8 -LiteralPath $InFile -Raw
        if ($rawsource.Length -gt 0) {
            $source = [regex]::replace($rawsource , '\xa0+', ' ')
            $src = [System.Text.Encoding]::Unicode.GetBytes($source)
            $html.write($src)
            $images = @($html.Images)

            foreach ($imageObject in $images) {                    
                if (($imageObject.src -notmatch '^http[s]?://') -or ($imageObject.src -match [regex]::Escape($ITGURL))) {
                    $script:HasImages = $true
                    $imgHTML = $imageObject.outerHTML
                    Write-Host "Processing HTML: $imgHTML"
                    if ($imageObject.src -match [regex]::Escape($ITGURL)) {
                        $matchedImage = Update-StringWithCaptureGroups -inputString $imgHTML -type 'img' -pattern $ImgRegexPatternToMatch
                        if ($matchedImage) {
                            $tnImgUrl = $matchedImage.url
                            $tnImgPath = $matchedImage.path
                        } else {
                            $tnImgPath = $imageObject.src
                        }
                    }
                    else {
                        $basepath = Split-Path $InFile
                        
                        if ($fullImgUrl = $imgHTML.split('data-src-original="')[1]) {$fullImgUrl = $fullImgUrl.split('"')[0] }
                        $tnImgUrl = $imgHTML.split('src="')[1].split('"')[0]
                        if ($fullImgUrl) {$fullImgPath = Join-Path -Path $basepath -ChildPath $fullImgUrl.replace('/','\')}
                        $tnImgPath = Join-Path -Path $basepath -ChildPath $tnImgUrl.replace('/','\')
                    }
                    
                    Write-Host "Processing IMG: $tnImgPath"
                    
                    # Some logic to test for the original data source being specified vs the thumbnail. Grab the Thumbnail or final source.
                    if ($fullImgUrl -and ($foundFile = Get-Item -Path "$fullImgPath*" -ErrorAction SilentlyContinue)) {
                        $imagePath = $foundFile.FullName
                    } elseif ($tnImgUrl -and ($foundFile = Get-Item -Path "$tnImgPath*" -ErrorAction SilentlyContinue)) {
                        $imagePath = $foundFile.FullName
                    } else { 
                        Remove-Variable -Name imagePath -ErrorAction SilentlyContinue
                        Remove-Variable -Name foundFile -ErrorAction SilentlyContinue
                        Write-Warning "Unable to validate image file."
                        $ManualLog = [PSCustomObject]@{
                                Document_Name = $Article.Name
                                Company_Name  = $Article.Company.CompanyName
                                HuduID        = $Article.HuduID
                                Type          = "Article - Image"
                                Field_Name    = "Image"
                                Notes         = 'Missing image, file not found'
                                Action        = "Neither $fullImgPath or $tnImgPath were found, validate the images exist in the export, or retrieve them from ITGlue directly"
                                Data          = "$InFile"
                                Hudu_URL      = $Article.HuduObject.url
                                ITG_URL       = "$ITGURL/$($Article.ITGLocator)"
                        }
                        $null = $ManualActions.add($ManualLog)
                        continue
                }
                # Test the path to ensure that a file extension exists, if no file extension we get problems later on. We rename it if there's no ext.
                if ($imagePath -and (Test-Path $imagePath -ErrorAction SilentlyContinue)) {
                    write-verbose "File present at purported image path: $imagePath... checking for image..."

                        $imageType = Invoke-ImageTest $imagePath
                        if ($imageType) {
                            write-verbose "$imagePath appears to contain image... normalizing..."
                            $imageInfo = Normalize-And-ConvertImage -InputPath $imagePath
                            write-verbose "$imagePath => $($imageInfo.FinalPath)"

                            $imagePath = $imageInfo.FinalPath ?? $imagePath
                            $OriginalFullImagePath = $imageInfo.Original

                            write-verbose "Uploading new/copied ITGlue image $OriginalFullImagePath => $imagePath"
                            try {
                                $UploadImage = New-HuduPublicPhoto -FilePath $imagePath.ToLower() -record_id $Article.HuduID -record_type 'Article'
                                $ImageMap["$OriginalFullImagePath"] = "$($UploadImage.public_photo.url)"
                            } catch {
                # issue during Upload
                                $ManualLog = [PSCustomObject]@{
                                    Document_Name = $Article.Name
                                    Type          = "Article - Image"
                                    Company_Name  = $Article.Company.CompanyName
                                    HuduID        = $Article.HuduID
                                    Field_Name    = "Image"
                                    Action        = "Failed to upload image to Hudu, manually upload and update the article with the new image URL"
                                    Notes         = 'Failed to upload image to Hudu'
                                    Data          = $_
                                    Hudu_URL      = $Article.HuduObject.url
                                    ITG_URL       = "$ITGURL/$($Article.ITGLocator)"
                                }
                                Write-ErrorObjectsToFile -ErrorObject $ManualLog -name "image-upload-err-$($imageInfo.basename)"
                                $null = $ManualActions.add($ManualLog)
                                continue
                            }
                            try {                                    
                                $NewImageURL = $UploadImage.public_photo.url.replace($HuduBaseDomain, '')

                                # Update the <img> tag src
                                $imageObject.src = [string]$NewImageURL
                                Write-Host "Setting <img>.src to: $NewImageURL"

                                # Try to find a matching <a> link around the image
                                $ImgLink = ($html.Links | Where-Object { $imageObject.innerHTML -eq $imgHTML }) | Select-Object -First 1
                                
                                if ($ImgLink) {
                                    if ($ImgLink.PSObject.Properties.Match("href")) {
                                        $ImgLink.href = [string]$NewImageURL
                                    } else {
                                        Write-Host "Image link object found but 'href' property is not present on it"
                                    }
                                } else {
                                    write-verbose "Image link object was not found for innerHTML: $imgHTML"
                                }
                            } catch {
                # issue during HTML replace / parse
                                $ManualLog = [PSCustomObject]@{
                                    Document_Name = $Article.Name
                                    Type          = "Article - Image"
                                    Company_Name  = $Article.Company.CompanyName
                                    HuduID        = $Article.HuduID
                                    Field_Name    = "Image"
                                    Notes         = "Issue encountered during HTML image replacement."
                                    Action        = "Manually update the article with the new image URL"
                                    Data          = "New image URL: $NewImageURL; Error: $_"
                                    Hudu_URL      = $Article.HuduObject.url
                                    ITG_URL       = "$ITGURL/$($Article.ITGLocator)"
                                }
                                Write-ErrorObjectsToFile -ErrorObject $ManualLog -name "image-err-$($imageInfo.basename)"
                                $null = $ManualActions.add($ManualLog)
                            }
                        } else {
                # image not detected by imagemagick
                            $ManualLog = [PSCustomObject]@{
                                Document_Name = $Article.Name
                                Company_Name  = $Article.Company.CompanyName
                                HuduID        = $Article.HuduID
                                Type          = "Article - Image"
                                Field_Name    = "Image"
                                Notes         = 'Image Not Detected'
                                Action        = "$imagePath not detected as image, validate the identified file is an image, or imagemagick modules are loaded"        
                                Data          = "$InFile"
                                Hudu_URL      = $Article.HuduObject.url
                                ITG_URL       = "$ITGURL/$($Article.ITGLocator)"
                            }
                            Write-ErrorObjectsToFile -ErrorObject $ManualLog -name "image-nd-$($imagePath)"
                            $null = $ManualActions.add($ManualLog)

                        }
                    }
                }
            }
        
            $page_Source = $html.documentelement.outerhtml
            $page_out = [regex]::replace($page_Source , '\xa0+', ' ')
                    
        }
    
        if ($page_out -eq '') {
            $page_out = 'Empty Document in IT Glue Export - Please Check IT Glue'
        }
        
            
        $articleUsesGlobalKB = if ($null -ne $Article.PSObject.Properties['IsGlobalKBArticle']) {
            [bool]$Article.IsGlobalKBArticle
        } else {
            [bool]($Article.company.InternalCompany -and -not $PlaceInternalDocsInInternalCompany)
        }

        if (-not $articleUsesGlobalKB) {
            $ArticleSplat = @{
                article_id = $Article.HuduID
                name       = $Article.name
                content    = $page_out
                company_id = $Article.company.HuduID                   
            }	
        } else {
            $ArticleSplat = @{
                article_id = $Article.HuduID
                name       = $Article.name
                content    = $page_out
            }	
        }
            
        $null = Set-HuduArticle @ArticleSplat
        Write-Host "$($Article.name) completed" -ForegroundColor Green
    
        $Article.Imported = "Created-By-Script"
        
    } 