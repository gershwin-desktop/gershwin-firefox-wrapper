include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Firefox

Firefox_OBJC_FILES = \
	main.m \
	FirefoxLauncher.m

include $(GNUSTEP_MAKEFILES)/application.make

# Create the Info.plist file
after-all::
	@echo "Creating Info-gnustep.plist..."
	@echo '{' > Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationName = "Firefox";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationDescription = "Firefox Web Browser";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationRelease = "1.0";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSExecutable = "Firefox";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    CFBundleIconFile = "Firefox.png";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSPrincipalClass = "NSApplication";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    LSUIElement = "NO";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '}' >> Firefox.app/Resources/Info-gnustep.plist
	@echo "Info-gnustep.plist created successfully"
	@if [ -f Firefox.png ]; then \
		echo "Copying Firefox.png to app bundle..."; \
		cp Firefox.png Firefox.app/Resources/; \
	else \
		echo "Creating placeholder Firefox.png..."; \
		echo "Place your Firefox.png icon in the Resources directory"; \
		touch Firefox.app/Resources/Firefox.png; \
	fi