#!/bin/sh
defPath="default.ttf"

HandleError() {
    echo $defPath
    exit 1
}

command -v "fc-match" > /dev/null || HandleError
command -v "fc-list"  > /dev/null || HandleError
fontMatch=`fc-match monospace`
[ $? -eq 0 ] || HandleError
fontFile=${fontMatch%%:*}
fontDesc=`fc-list | grep $fontFile`
[ $? -eq 0 ] || HandleError
fontPath=${fontDesc%%:*}
[ "$fontPath" = "" ] && HandleError
[ ! -f "$fontPath" ] && HandleError
echo $fontPath
