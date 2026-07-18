#!/bin/bash

if [ -d "$1/love" ] && [ -f "$1/love/Android.mk" ]; then
    echo "yes"
else
    echo "no"
fi
