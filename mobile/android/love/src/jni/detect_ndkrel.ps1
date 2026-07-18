# $args[0] = source.properties
# $args[1] = NDK version to be checked

if ($args.Count -ne 2) {
    Write-Output "unknown"
    exit 1
}

$ndkVersion = (Select-String -Pattern "Pkg.Revision = (\d+)" -Path $args[0] | ForEach-Object { $_.Matches[0].Groups[1].Value })

if ($ndkVersion -ge $args[1]) {
    Write-Output "yes"
} else {
    Write-Output "no"
}
