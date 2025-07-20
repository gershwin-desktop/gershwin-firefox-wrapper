include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Firefox

Firefox_OBJC_FILES = \
	main.m \
	FirefoxLauncher.m

Firefox_LDFLAGS += -L/usr/local/lib
Firefox_CPPFLAGS += -I/usr/local/include
Firefox_LDFLAGS += -ldispatch
Firefox_OBJCFLAGS += -Wall -Wextra -O2 -fno-strict-aliasing

FIREFOX_WRAPPER_VERSION = 3.0.0
Firefox_OBJCFLAGS += -DFIREFOX_WRAPPER_VERSION=\"$(FIREFOX_WRAPPER_VERSION)\"

include $(GNUSTEP_MAKEFILES)/application.make

after-all::
	@echo '{' > Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationName = "Firefox";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationDescription = "Event-Driven Firefox Web Browser Wrapper";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationRelease = "$(FIREFOX_WRAPPER_VERSION)";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSExecutable = "Firefox";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    CFBundleIconFile = "Firefox.png";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSPrincipalClass = "NSApplication";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    LSUIElement = "NO";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSUseRunningCopy = "NO";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSHighResolutionCapable = "YES";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    LSMinimumSystemVersion = "FreeBSD 12.0";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    CFBundleVersion = "$(FIREFOX_WRAPPER_VERSION)";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    CFBundleShortVersionString = "$(FIREFOX_WRAPPER_VERSION)";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    CFBundleIdentifier = "org.gnustep.firefox-wrapper";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    NSServices = (' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '        {' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '            NSMenuItem = { default = "Open in Firefox"; };' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '            NSMessage = "openFile";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '            NSSendTypes = ("NSFilenamesPboardType");' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '        }' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    );' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '}' >> Firefox.app/Resources/Info-gnustep.plist
	@if [ -f Firefox.png ]; then \
		cp Firefox.png Firefox.app/Resources/; \
	else \
		touch Firefox.app/Resources/Firefox.png; \
	fi
	@chmod +x Firefox.app/Firefox

clean::
	@rm -rf Firefox.app

install::
	@if [ -d "/Applications" ]; then \
		cp -r Firefox.app /Applications/; \
	else \
		exit 1; \
	fi

uninstall::
	@if [ -d "/Applications/Firefox.app" ]; then \
		rm -rf "/Applications/Firefox.app"; \
	fi

.PHONY: install uninstall
