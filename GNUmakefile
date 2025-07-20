-include GNUmakefile.preamble

include $(GNUSTEP_MAKEFILES)/common.make

$(APP_NAME)_OBJC_FILES = \
	main.m \
	ApplicationWrapper.m

$(APP_NAME)_LDFLAGS += -L/usr/local/lib
$(APP_NAME)_CPPFLAGS += -I/usr/local/include
$(APP_NAME)_LDFLAGS += -ldispatch
$(APP_NAME)_OBJCFLAGS += -Wall -Wextra -O2 -fno-strict-aliasing

$(APP_NAME)_OBJCFLAGS += -DAPPLICATION_NAME='"$(APP_NAME)"'
$(APP_NAME)_OBJCFLAGS += -DEXECUTABLE_PATH='"$(EXECUTABLE_PATH)"'
$(APP_NAME)_OBJCFLAGS += -DSERVICE_NAME='"$(SERVICE_NAME)"'
$(APP_NAME)_OBJCFLAGS += -DWINDOW_SEARCH_STRING='"$(WINDOW_SEARCH_STRING)"'
$(APP_NAME)_OBJCFLAGS += -DBUNDLE_IDENTIFIER='"$(BUNDLE_ID)"'

include $(GNUSTEP_MAKEFILES)/application.make

after-all::
	@echo '{' > $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    ApplicationName = "$(APP_NAME)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    ApplicationDescription = "Event-Driven $(APP_NAME) Application Wrapper";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    ApplicationRelease = "$(VERSION)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    NSExecutable = "$(APP_NAME)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    CFBundleIconFile = "$(ICON_FILE)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    NSPrincipalClass = "NSApplication";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    LSUIElement = "NO";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    NSUseRunningCopy = "NO";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    NSHighResolutionCapable = "YES";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    LSMinimumSystemVersion = "FreeBSD 12.0";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    CFBundleVersion = "$(VERSION)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    CFBundleShortVersionString = "$(VERSION)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    CFBundleIdentifier = "$(BUNDLE_ID)";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    NSServices = (' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '        {' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '            NSMenuItem = { default = "Open in $(APP_NAME)"; };' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '            NSMessage = "openFile";' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '            NSSendTypes = ("NSFilenamesPboardType");' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '        }' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '    );' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@echo '}' >> $(APP_NAME).app/Resources/Info-gnustep.plist
	@if [ -f $(ICON_FILE) ]; then \
		cp $(ICON_FILE) $(APP_NAME).app/Resources/; \
	else \
		touch $(APP_NAME).app/Resources/$(ICON_FILE); \
	fi
	@chmod +x $(APP_NAME).app/$(APP_NAME)

clean::
	@rm -rf $(APP_NAME).app

install::
	@if [ -d "/Applications" ]; then \
		cp -r $(APP_NAME).app /Applications/; \
	else \
		exit 1; \
	fi

uninstall::
	@if [ -d "/Applications/$(APP_NAME).app" ]; then \
		rm -rf "/Applications/$(APP_NAME).app"; \
	fi

.PHONY: install uninstall
