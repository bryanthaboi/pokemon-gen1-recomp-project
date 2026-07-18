if ($args.Length -gt 1) {
    # $args[0] = android-%d
    # $args[1] = %d
    $found = $args[0] -match 'android-(\d+)'

    if ($found -and $matches[1] -ge $args[1]) {
        Write-Output "yes"
    } else {
        Write-Output "no"
    }
} else {
    Write-Output "unknown"
}
