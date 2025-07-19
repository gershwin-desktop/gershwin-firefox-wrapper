include $(GNUSTEP_MAKEFILES)/common.make

APP_NAME = Firefox

Firefox_OBJC_FILES = \
	main.m \
	FirefoxLauncher.m

# Additional frameworks and libraries needed for enhanced functionality (FreeBSD)
# Add libdispatch support if available
Firefox_LDFLAGS += -L/usr/local/lib -ldispatch
Firefox_CPPFLAGS += -I/usr/local/include

# Compiler flags for optimization and warnings
Firefox_OBJCFLAGS += -Wall -Wextra -O2 -fno-strict-aliasing

# Define version and build information
FIREFOX_WRAPPER_VERSION = 2.0.0
Firefox_OBJCFLAGS += -DFIREFOX_WRAPPER_VERSION=\"$(FIREFOX_WRAPPER_VERSION)\"

include $(GNUSTEP_MAKEFILES)/application.make

after-all::
	@echo "Creating enhanced Info-gnustep.plist..."
	@echo '{' > Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationName = "Firefox";' >> Firefox.app/Resources/Info-gnustep.plist
	@echo '    ApplicationDescription = "Enhanced Firefox Web Browser Wrapper";' >> Firefox.app/Resources/Info-gnustep.plist
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
	@echo "Enhanced Info-gnustep.plist created successfully"
	@if [ -f Firefox.png ]; then \
		echo "Copying Firefox.png to app bundle..."; \
		cp Firefox.png Firefox.app/Resources/; \
	else \
		echo "Warning: Firefox.png not found. Creating placeholder..."; \
		echo "Please place your Firefox.png icon (at least 512x512) in the build directory"; \
		touch Firefox.app/Resources/Firefox.png; \
	fi
	@echo "Setting executable permissions..."
	@chmod +x Firefox.app/Firefox
	@echo ""
	@echo "=========================================="
	@echo "Enhanced Firefox Wrapper Build Complete!"
	@echo "=========================================="
	@echo "Version: $(FIREFOX_WRAPPER_VERSION)"
	@echo "Features:"
	@echo "  ✓ Dynamic dock management"
	@echo "  ✓ Robust connection handling" 
	@echo "  ✓ Enhanced process monitoring"
	@echo "  ✓ System event handling"
	@echo "  ✓ Performance optimizations"
	@echo "  ✓ Crash detection and recovery"
	@echo ""
	@echo "To install: cp -r Firefox.app /Applications/"
	@echo "To debug: ./Firefox.app/Firefox"
	@echo "=========================================="

clean::
	@echo "Cleaning Firefox wrapper build artifacts..."
	@rm -rf Firefox.app
	@rm -f firefox-wrapper.lock
	@echo "Clean complete."

install::
	@echo "Installing Firefox wrapper to /Applications..."
	@if [ -d "/Applications" ]; then \
		cp -r Firefox.app /Applications/; \
		echo "Firefox wrapper installed successfully!"; \
		echo "You can now launch it from /Applications/Firefox.app"; \
	else \
		echo "Error: /Applications directory not found"; \
		exit 1; \
	fi

uninstall::
	@echo "Removing Firefox wrapper from /Applications..."
	@if [ -d "/Applications/Firefox.app" ]; then \
		rm -rf "/Applications/Firefox.app"; \
		echo "Firefox wrapper uninstalled successfully!"; \
	else \
		echo "Firefox wrapper not found in /Applications"; \
	fi

debug: all
	@echo "Running Firefox wrapper in debug mode..."
	@echo "Press Ctrl+C to stop"
	@./Firefox.app/Firefox

help:
	@echo "Firefox Wrapper Enhanced Build System"
	@echo "====================================="
	@echo ""
	@echo "Available targets:"
	@echo "  all        - Build the Firefox wrapper (default)"
	@echo "  clean      - Remove all build artifacts"
	@echo "  install    - Install to /Applications"
	@echo "  uninstall  - Remove from /Applications"
	@echo "  debug      - Build and run in foreground for debugging"
	@echo "  help       - Show this help message"
	@echo ""
	@echo "Configuration:"
	@echo "  FIREFOX_WRAPPER_VERSION = $(FIREFOX_WRAPPER_VERSION)"
	@echo "  LSUIElement = YES (starts hidden, dynamic dock control)"
	@echo "  NSUseRunningCopy = NO (single instance via distributed objects)"
	@echo ""
	@echo "Requirements:"
	@echo "  - GNUstep development environment"
	@echo "  - Firefox installed at /usr/local/bin/firefox"
	@echo "  - wmctrl installed at /usr/local/bin/wmctrl"
	@echo "  - Firefox.png icon file (optional, 512x512 recommended)"

.PHONY: install uninstall debug help
