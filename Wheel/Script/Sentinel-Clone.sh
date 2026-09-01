#!/bin/bash

source ~/.profile

DirScript=$PathSentinel/Script/

cd ${DirScript}

gawk -f Sentinel-Clone.awk

exit 0
