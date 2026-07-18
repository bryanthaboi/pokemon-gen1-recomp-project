$path = $args[0]

if (Test-Path -Path "$path/love/Android.mk") {
    Write-Output "yes"
} else {
    Write-Output "no"
}
