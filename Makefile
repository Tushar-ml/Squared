.PHONY: ios test

ios:           ## regenerate the Xcode project
	cd ios && xcodegen generate

test:          ## run the iOS unit tests on a simulator
	cd ios && xcodebuild test -project Squared.xcodeproj -scheme Squared \
	  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build -quiet
