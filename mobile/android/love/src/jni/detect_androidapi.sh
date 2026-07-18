#!/bin/bash

if [ $# -gt 1 ]; then
    # $1 = android-%d
    # $2 = %d
    version=$(echo $1 | grep -o 'android-[0-9]*' | grep -o '[0-9]*')

    if [ $version -ge $2 ]; then
        echo "yes"
    else
        echo "no"
    fi
else
    echo "unknown"
fi
