# Merge-CSVFiles.ps1
# Merges all CSV files in a folder into a single CSV file with one header line

param(
    [Parameter(Mandatory=$true)]
    [string]$SourceFolder,

    [Parameter(Mandatory=$false)]
    [string]$OutputFile = "$SourceFolder\merged_output.csv"
)

$csvFiles = Get-ChildItem -Path $SourceFolder -Filter "*.csv" | Sort-Object Name

if ($csvFiles.Count -eq 0) {
    Write-Host "No CSV files found in: $SourceFolder"
    exit 1
}

Write-Host "Found $($csvFiles.Count) CSV files. Merging..."

# Write first file including its header
Get-Content $csvFiles[0].FullName | Set-Content $OutputFile

# Append remaining files skipping their header (first line)
for ($i = 1; $i -lt $csvFiles.Count; $i++) {
    Get-Content $csvFiles[$i].FullName | Select-Object -Skip 1 | Add-Content $OutputFile
    Write-Host "Added: $($csvFiles[$i].Name)"
}

Write-Host ""
Write-Host "Done! Merged file saved to: $OutputFile"
