#!/bin/sh
# Make a release image

if [ "x$1" = "x" ]; then
  echo "usage: $0 RoboTank_X.Y.Z"
  echo "Run this in the parent directory of the RoboTank directory."
  exit 2
fi

directory_name="$1"
if echo "$directory_name" | grep '/'; then
  echo "Directory name must not contain a slash character."
  exit 2
fi
if [ ! -d "$directory_name" ]; then
  echo "Directory $directory_name not found."
  exit 2
fi

zipfile="$directory_name.zip"
if [ -f "$zipfile" ]; then
  echo "rm $zipfile"
  rm "$zipfile" || exit
fi

echo zip -r "$zipfile" "$directory_name" -x '*/.git*' '*/rel/*' '*.xcf' '*.sh' '*/stubs.lua'
exec zip -r "$zipfile" "$directory_name" -x '*/.git*' '*/rel/*' '*.xcf' '*.sh' '*/stubs.lua'

# EOF
