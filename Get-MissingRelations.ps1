function Get-HuduIdFromItglueObject {
  param(
    $ITGObjectId,
    $AssetType
  )
  switch ($AssetType) {
    'configuration' {
      $FoundHuduAsset = $MatchedConfigurations | Where-Object {$_.ITGID -eq $ITGObjectId}
      $FoundHuduAssetType = $FoundHuduAsset.HuduObject.object_type
    }

    'document' {
      $FoundHuduAsset = $MatchedArticles | Where-Object {$_.ITGID -eq $ITGobjectId}
      $FoundHuduAssetType = 'Article'
    }

    'flexible_asset' {
      $FoundHuduAsset = $MatchedAssets | Where-Object {$_.ITGID -eq $ITGObjectId}
      $FoundHuduAssetType = $FoundHuduAsset.HuduObject.object_type
    }

    'location' {
      $FoundHuduAsset = $MatchedLocations | Where-Object {$_.ITGID -eq $ITGObjectId}
      $FoundHuduAssetType = $FoundHuduAsset.HuduObject.object_type
    }

    'password' {
      $FoundHuduAsset = $MatchedPasswords | Where-Object {$_.ITGID -eq $ITGObjectId}
      $FoundHuduAssetType = 'AssetPassword'
    }
  }
  
  if ($FoundHuduAsset) {
    return [pscustomobject]@{huduobject=$FoundHuduAsset.HuduObject; type = $FoundHuduAssetType}
  }
  else { Write-Warning "Unable to match ITGlue $AssetType to Hudu object to $($ITGobjectId)"}

}

function Get-HuduRelationObject {
  param(
    $ITGlueSourceObjects
  )

  $NewHuduRelations = foreach ($ITGlueSourceObject in $ITGlueSourceObjects) {
    switch ($ITGlueSourceObject.data.type) {
      'flexible-assets' {
        $AssetType = 'flexible_asset'
      }
      'configurations' {
        $AssetType = 'configuration'
      }
      'passwords' {
        $AssetType = 'password'
      }
    }

    $FromableHudu = Get-HuduIdFromItglueObject -AssetType $AssetType -ITGObjectId $ITGlueSourceObject.data.id
    if ($FromableHudu) {
      Write-Host "Determining Hudu objects for source $AssetType / ITGID: $($ITGlueSourceObject.data.id)" -foregroundColor Cyan
      foreach ($LinkedITGlueObject in $ITGlueSourceObject.included) {
        $LinkedHuduItem = Get-HuduIdFromItglueObject -AssetType $LinkedITGlueObject.attributes.'asset-type' -ITGObjectId $LinkedITGlueObject.attributes.'resource-id'
        if ($LinkedHuduItem){
          [pscustomobject]@{
            FromableType = $FromableHudu.type
            FromableID = $FromableHudu.HuduObject.id
            ToableType = $LinkedHuduItem.type
            ToableID = $LinkedHuduItem.HuduObject.id
          }
        }
      }
    }

  }

  return $NewHuduRelations

}


$AssetRelationsToCreate = @()
$ConfigurationRelationsToCreate = @()
$PasswordRelationsToCreate = @()
$FreshITGAssets = @()
$FreshConfigurations = @()
$FreshPasswords = @()
$RelatedAssets = @()
$RelatedConfigurations = @()
$RelatedPasswords = @()

$MatchedAssetsWithIds = @($MatchedAssets | Where-Object {$_.ITGObject -and $_.ITGObject.id})
if ($MatchedAssetsWithIds.Count -gt 0) {
  $FreshITGAssets = @($MatchedAssetsWithIds | ForEach-Object { Get-ITGlueFlexibleAssets -id $_.ITGObject.id -include related_items })
  $RelatedAssets = @($FreshITGAssets | Where-Object {$_.data.relationships.'related-items'.data})
}

$MatchedConfigurationsWithIds = @($MatchedConfigurations | Where-Object {$_.ITGObject -and $_.ITGObject.id})
if ($MatchedConfigurationsWithIds.Count -gt 0) {
  $FreshConfigurations = @($MatchedConfigurationsWithIds | ForEach-Object { Get-ITGlueConfigurations -id $_.ITGObject.id -include related_items })
  $RelatedConfigurations = @($FreshConfigurations | Where-Object {$_.data.relationships.'related-items'.data})
}

$MatchedPasswordsWithIds = @($MatchedPasswords | Where-Object {$_.ITGObject -and $_.ITGObject.id})
if ($MatchedPasswordsWithIds.Count -gt 0) {
  $FreshPasswords = @($MatchedPasswordsWithIds | ForEach-Object { Get-ITGluePasswords -id $_.ITGObject.id -include related_items })
  $RelatedPasswords = @($FreshPasswords | Where-Object {$_.data.relationships.'related-items'.data})
}

if ($RelatedConfigurations.Count -gt 0) {
  $ConfigurationRelationsToCreate = @(Get-HuduRelationObject -ITGlueSourceObjects $RelatedConfigurations)
}
if ($RelatedAssets.Count -gt 0) {
  $AssetRelationsToCreate = @(Get-HuduRelationObject -ITGlueSourceObjects $RelatedAssets)
}
if ($RelatedPasswords.Count -gt 0) {
  $PasswordRelationsToCreate = @(Get-HuduRelationObject -ITGlueSourceObjects $RelatedPasswords)
}

<# Uncomment and run the block below
$createdConfigurationRelations =  $ConfigurationRelationsToCreate | % {New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableID $_.ToableID -ToableType $_.ToableType}
$createdAssetRelations =  $AssetRelationsToCreate | % {New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableID $_.ToableID -ToableType $_.ToableType}
$createdPasswordRelations =  $PasswordRelationsToCreate | % {New-HuduRelation -FromableType $_.FromableType -FromableID $_.FromableID -ToableID $_.ToableID -ToableType $_.ToableType}
#>
