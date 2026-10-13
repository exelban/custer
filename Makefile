APP = Custer
BUNDLE_ID = eu.exelban.$(APP)

BUILD_PATH = $(PWD)/build/github
APPSTORE_PATH = $(PWD)/build/appstore
APP_PATH = "$(BUILD_PATH)/$(APP).app"
ZIP_PATH = "$(BUILD_PATH)/$(APP).zip"

.SILENT: archive notarize sign prepare-dmg prepare-dSYM clean check history
.PHONY: release-github release-appstore verify-builds test build archive notarize sign prepare-dmg prepare-dSYM clean check history dep deploy-site

# Set Version and Build in each target’s General > Identity settings in Xcode.
release-github: build

build:
	$(MAKE) archive
	$(MAKE) notarize
	$(MAKE) sign
	$(MAKE) prepare-dmg
	$(MAKE) prepare-dSYM

# --- MAIN WORKFLOW FUNCTIONS --- #

archive:
	echo "Starting archiving the project..."

	xcodebuild \
		-allowProvisioningUpdates \
		-scheme $(APP) \
		-destination 'generic/platform=macOS' \
		-configuration Release archive \
		ONLY_ACTIVE_ARCH=NO \
		-archivePath "$(BUILD_PATH)/$(APP).xcarchive"

	echo "Application built, starting the export archive..."

	xcodebuild -exportArchive \
		-allowProvisioningUpdates \
		-exportOptionsPlist "$(PWD)/exportOptions.plist" \
		-archivePath "$(BUILD_PATH)/$(APP).xcarchive" \
		-exportPath "$(BUILD_PATH)"

	python3 scripts/verify-distribution.py github $(APP_PATH) --signed
	ditto -c -k --keepParent $(APP_PATH) $(ZIP_PATH)

	echo "Project archived successfully"

notarize:
	echo "Starting notarizing the project..."

	xcrun notarytool submit --keychain-profile "AC_PASSWORD" --wait $(ZIP_PATH)

	echo "Custer successfully notarized"

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
	cd "$(BUILD_PATH)/Custer.xcarchive/dSYMs" && zip -r "$(PWD)/dSYMs.zip" .
	echo "Created zip with dSYMs"

# --- HELPERS --- #

clean:
	rm -rf "$(BUILD_PATH)"
	if [ -a $(PWD)/dSYMs.zip ]; then rm $(PWD)/dSYMs.zip; fi;
	if [ -a $(PWD)/Custer.dmg ]; then rm $(PWD)/Custer.dmg; fi;

# Archive, verify, and upload the build to App Store Connect.
release-appstore:
	xcodebuild -project Custer.xcodeproj -scheme "Custer App Store" \
		-allowProvisioningUpdates \
		-destination 'generic/platform=macOS' -configuration Release archive \
		ONLY_ACTIVE_ARCH=NO -archivePath "$(APPSTORE_PATH)/Custer.xcarchive"
	python3 scripts/verify-distribution.py appstore \
		"$(APPSTORE_PATH)/Custer.xcarchive/Products/Applications/Custer App Store.app" --signed
	xcodebuild -exportArchive -exportOptionsPlist exportOptions-appstore.plist \
		-allowProvisioningUpdates \
		-archivePath "$(APPSTORE_PATH)/Custer.xcarchive" -exportPath "$(APPSTORE_PATH)/export"

verify-builds:
	xcodebuild -project Custer.xcodeproj -scheme Custer -configuration Release \
		-derivedDataPath build/check-github CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
	xcodebuild -project Custer.xcodeproj -scheme "Custer App Store" -configuration Release \
		-derivedDataPath build/check-store CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO build
	python3 scripts/verify-distribution.py github build/check-github/Build/Products/Release/Custer.app
	python3 scripts/verify-distribution.py appstore "build/check-store/Build/Products/Release/Custer App Store.app"

test:
	mkdir -p build/tests
	xcrun swiftc -parse-as-library -module-cache-path build/tests/module-cache \
		Custer/helpers/StreamResolver.swift Custer/helpers/libs.swift tests/StreamResolverTests.swift -o build/tests/StreamResolverTests
	xcrun swiftc -parse-as-library -D APP_STORE -module-cache-path build/tests/module-cache \
		Custer/helpers/StreamResolver.swift Custer/helpers/libs.swift tests/StreamResolverTests.swift -o build/tests/StreamResolverStoreTests
	python3 tests/run.py build/tests/StreamResolverTests build/tests/StreamResolverStoreTests

check:
	xcrun notarytool log $(ID) --keychain-profile "AC_PASSWORD"

history:
	xcrun notarytool history --keychain-profile "AC_PASSWORD"

open:
	echo "Opening working folder..."
	open $(PWD)

# --- WEB --- #

deploy-site:
	npx wrangler pages deploy ./site --project-name custer --branch master --commit-dirty=true
