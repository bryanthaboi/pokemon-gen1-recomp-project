# $1 = source.properties
# $2 = NDK version to be checked

if [ $# -ne 2 ]; then
    echo "unknown"
    exit 1
fi

ndkVersion=$(grep -Po 'Pkg.Revision = (\d+)' "$1" | grep -Po '\d+')

if [ "$ndkVersion" -ge "$2" ]; then
    echo "yes"
else
    echo "no"
fi
