APP = Custer
BUNDLE_ID = eu.exelban.$(APP)

BUILD_PATH = $(PWD)/build
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"

.SILENT: archive notarize sign prepare-dmg prepare-dSYM clean next-version check history
.PHONY: build archive notarize sign prepare-dmg prepare-dSYM clean next-version check history dep deploy-web

build: clean next-version archive notarize sign prepare-dmg prepare-dSYM open

# --- MAIN WORKFLOW FUNCTIONS --- #

archive: next-version clean
	echo "Starting archiving the project..."

	xcodebuild \
  		-scheme $(APP) \
  		-destination 'generic/platform=macOS' \
  		-configuration Release archive \
  		ONLY_ACTIVE_ARCH=NO \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
  		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
  		-archivePath $(BUILD_PATH)/$(APP).xcarchive \
  		-exportPath $(BUILD_PATH)

	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	echo "Starting notarizing the project..."

	xcrun notarytool submit --keychain-profile "AC_PASSWORD" --wait $(ZIP_PATH)

	echo "Stats successfully notarized"

sign:
	echo "Going to staple an application..."

	xcrun stapler staple $(APP_PATH)
	spctl -a -t exec -vvv $(APP_PATH)

	echo "Application successfully stapled"

prepare-dmg:
	if [ ! -d $(PWD)/create-dmg ]; then \
	    git clone https://github.com/andreyvit/create-dmg; \
	fi

	./create-dmg/create-dmg \
	    --volname $(APP) \
	    --background "./Custer/Supporting Files/background.png" \
	    --window-pos 200 120 \
	    --window-size 500 320 \
	    --icon-size 80 \
	    --icon "Custer.app" 125 175 \
	    --hide-extension "Custer.app" \
	    --app-drop-link 375 175 \
	    $(PWD)/$(APP).dmg \
	    $(APP_PATH)

	rm -rf ./create-dmg

prepare-dSYM:
	echo "Zipping dSYMs..."
	cd $(BUILD_PATH)/Custer.xcarchive/dSYMs && zip -r $(PWD)/dSYMs.zip .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

clean:
	rm -rf $(BUILD_PATH)
	if [ -a $(PWD)/dSYMs.zip ]; then rm $(PWD)/dSYMs.zip; fi;
	if [ -a $(PWD)/Custer.dmg ]; then rm $(PWD)/Custer.dmg; fi;

next-version:
	versionNumber=$$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$(PWD)/Custer/Supporting Files/Info.plist") ;\
	echo "Actual version is: $$versionNumber" ;\
	versionNumber=$$((versionNumber + 1)) ;\
	echo "Next version is: $$versionNumber" ;\
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $$versionNumber" "$(PWD)/Custer/Supporting Files/Info.plist" ;\

check:
	xcrun notarytool log $(ID) --keychain-profile "AC_PASSWORD"

history:
	xcrun notarytool history --keychain-profile "AC_PASSWORD"

open:
	echo "Opening working folder..."
	open $(PWD)

# --- WEB --- #

deploy-web:
	npx wrangler pages deploy ./web --project-name custer --branch master --commit-dirty=true
