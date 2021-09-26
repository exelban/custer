#!/bin/bash

APP_NAME="Custer"
DMG_PATH="$HOME/Download/$APP_NAME.dmg"
MOUNT_PATH="/tmp/$APP_NAME"
APPLICATION_PATH="/Applications/"

while [[ "$#" > 0 ]]; do case $1 in
  -d|--dmg) DMG_PATH="$2"; shift;;
  -a|--app) APPLICATION_PATH="$2"; shift;;
  -m|--mount) MOUNT_PATH="$2"; shift;;
  -n|--name) APP_NAME="$2"; shift;;
  *) echo "Unknown parameter passed: $1"; exit 1;;
esac; shift; done

rm -rf $APPLICATION_PATH/$APP_NAME.app
cp -rf $MOUNT_PATH/$APP_NAME.app $APPLICATION_PATH/$APP_NAME.app

$APPLICATION_PATH/$APP_NAME.app/Contents/MacOS/$APP_NAME --dmg-path "$DMG_PATH" --mount-path "$MOUNT_PATH"

echo "New version started"
