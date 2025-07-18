#import "FirefoxLauncher.h"

@implementation FirefoxLauncher

- (id)init
{
    self = [super init];
    if (self) {
        // Point to the real Firefox we moved
        firefoxExecutablePath = @"/Applications/Firefox-real.app/Contents/MacOS/firefox";
        // Fallback to system Firefox if real one not found
        if (![[NSFileManager defaultManager] fileExistsAtPath:firefoxExecutablePath]) {
            firefoxExecutablePath = @"/usr/local/bin/firefox";
        }
        isFirefoxRunning = NO;
        firefoxTask = nil;
        serviceConnection = nil;
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    NSLog(@"=== DEBUG: Firefox wrapper starting up ===");
    
    // Force the process name to be Firefox
    [[NSProcessInfo processInfo] setProcessName:@"Firefox"];
    
    // Debug bundle information
    NSBundle *bundle = [NSBundle mainBundle];
    NSLog(@"Bundle path: %@", [bundle bundlePath]);
    NSLog(@"Bundle identifier: %@", [bundle bundleIdentifier]);
    NSLog(@"Bundle name: %@", [bundle objectForInfoDictionaryKey:@"CFBundleName"]);
    NSLog(@"Bundle display name: %@", [bundle objectForInfoDictionaryKey:@"CFBundleDisplayName"]);
    NSLog(@"Bundle executable: %@", [bundle objectForInfoDictionaryKey:@"CFBundleExecutable"]);
    NSLog(@"Executable path: %@", [bundle executablePath]);
    NSLog(@"Process name: %@", [[NSProcessInfo processInfo] processName]);
    
    // Check what GWorkspace might find when looking for "Firefox"
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSString *firefoxPath = [ws fullPathForApplication:@"Firefox"];
    NSLog(@"GWorkspace thinks Firefox is at: %@", firefoxPath);
    NSLog(@"Our actual path: %@", [bundle bundlePath]);
    NSLog(@"Paths match: %@", [firefoxPath isEqualToString:[bundle bundlePath]] ? @"YES" : @"NO");
    
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Firefox" ofType:@"png"];
    if (iconPath && [[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (icon) {
            [NSApp setApplicationIconImage:icon];
            [icon release];
        }
    }
    
    serviceConnection = [NSConnection defaultConnection];
    [serviceConnection setRootObject:self];
    
    // Register as "Firefox" so GWorkspace can find us
    NSString *appName = @"Firefox";
    
    NSLog(@"Attempting to register distributed object as '%@'", appName);
    
    if (![serviceConnection registerName:appName]) {
        NSLog(@"Registration failed - checking for existing instance");
        NSConnection *existing = [NSConnection connectionWithRegisteredName:appName host:nil];
        if (existing) {
            NSLog(@"Firefox launcher already running, activating existing instance");
            
            // Try to contact the existing wrapper to activate Firefox
            id proxy = [existing rootProxy];
            NSLog(@"Got proxy: %@", proxy);
            if (proxy && [proxy respondsToSelector:@selector(activateIgnoringOtherApps:)]) {
                NSLog(@"Calling activateIgnoringOtherApps on existing instance");
                [proxy activateIgnoringOtherApps:YES];
            } else {
                NSLog(@"Proxy doesn't respond to activateIgnoringOtherApps, trying direct activation");
                // Fallback to direct activation
                [self activateFirefoxWindows];
            }
            
            // Exit gracefully instead of hard exit
            [NSApp terminate:self];
            return; // Don't continue with initialization
        } else {
            NSLog(@"No existing connection found, but registration still failed");
            // Don't exit here - maybe we can still work without distributed objects
            NSLog(@"Continuing without distributed objects registration");
        }
    } else {
        NSLog(@"Firefox launcher successfully registered as '%@'", appName);
        NSLog(@"Service connection: %@", serviceConnection);
        NSLog(@"Root object: %@", [serviceConnection rootObject]);
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"=== DEBUG: Application finished launching ===");
    
    // Test if GWorkspace can find us
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    NSString *ourPath = [[NSBundle mainBundle] bundlePath];
    NSArray *runningApps = [ws runningApplications];
    
    NSLog(@"Currently running applications:");
    for (NSDictionary *app in runningApps) {
        NSString *name = [app objectForKey:@"NSApplicationName"];
        NSString *path = [app objectForKey:@"NSApplicationPath"];
        NSLog(@"  %@ at %@", name, path);
        
        if ([name isEqualToString:@"Firefox"]) {
            NSLog(@"  *** Found Firefox in running apps! Path: %@", path);
            NSLog(@"  *** Matches our path: %@", [path isEqualToString:ourPath] ? @"YES" : @"NO");
        }
    }
    
    // Test distributed objects registration
    NSConnection *testConnection = [NSConnection connectionWithRegisteredName:@"Firefox" host:nil];
    if (testConnection) {
        id proxy = [testConnection rootProxy];
        NSLog(@"Distributed object 'Firefox' found: %@", proxy);
        NSLog(@"Proxy class: %@", [proxy class]);
        NSLog(@"Responds to activateIgnoringOtherApps: %@", 
              [proxy respondsToSelector:@selector(activateIgnoringOtherApps:)] ? @"YES" : @"NO");
    } else {
        NSLog(@"No distributed object named 'Firefox' found");
    }
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is already running");
        [self activateFirefoxWindows];
    } else {
        NSLog(@"Firefox not running, launching it");
        [self launchFirefox];
    }
    
    NSLog(@"=== DEBUG: Application setup complete ===");
}

#pragma mark - GWorkspace Integration Methods

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    NSLog(@"=== DEBUG: GWorkspace requesting Firefox activation (ignoreOthers: %@) ===", flag ? @"YES" : @"NO");
    NSLog(@"Current Firefox running state: %@", [self isFirefoxCurrentlyRunning] ? @"YES" : @"NO");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is running, activating windows");
        [self activateFirefoxWindows];
        // Notify that we're no longer hidden
        [self notifyGWorkspaceOfStateChange];
    } else {
        NSLog(@"Firefox not running, launching it first");
        [self launchFirefox];
    }
    
    NSLog(@"=== DEBUG: Activation request completed ===");
}

- (void)hide:(id)sender
{
    NSLog(@"=== DEBUG: GWorkspace requesting Firefox hide ===");
    
    // First, get all Firefox window IDs
    NSTask *searchTask = [[NSTask alloc] init];
    [searchTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [searchTask setArguments:@[@"search", @"--class", @"firefox"]];
    
    NSPipe *searchPipe = [NSPipe pipe];
    [searchTask setStandardOutput:searchPipe];
    [searchTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [searchTask launch];
        [searchTask waitUntilExit];
        
        if ([searchTask terminationStatus] == 0) {
            NSData *data = [[searchPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSArray *windowIDs = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"];
            [output release];
            
            NSLog(@"Found %lu Firefox windows to hide", (unsigned long)[windowIDs count]);
            
            // Minimize each window individually
            for (NSString *windowID in windowIDs) {
                if ([windowID length] > 0) {
                    NSLog(@"Minimizing window: %@", windowID);
                    NSTask *minimizeTask = [[NSTask alloc] init];
                    [minimizeTask setLaunchPath:@"/usr/local/bin/xdotool"];
                    [minimizeTask setArguments:@[@"windowminimize", windowID]];
                    [minimizeTask setStandardOutput:[NSPipe pipe]];
                    [minimizeTask setStandardError:[NSPipe pipe]];
                    
                    NS_DURING
                        [minimizeTask launch];
                        [minimizeTask waitUntilExit];
                        NSLog(@"Window %@ minimize result: %d", windowID, [minimizeTask terminationStatus]);
                    NS_HANDLER
                        NSLog(@"Failed to minimize window %@: %@", windowID, localException);
                    NS_ENDHANDLER
                    
                    [minimizeTask release];
                }
            }
            
            NSLog(@"Firefox windows minimized (%lu windows)", (unsigned long)[windowIDs count]);
            [self notifyGWorkspaceOfStateChange];
        } else {
            NSLog(@"No Firefox windows found to hide");
        }
    NS_HANDLER
        NSLog(@"Failed to search for Firefox windows: %@", localException);
    NS_ENDHANDLER
    
    [searchTask release];
    NSLog(@"=== DEBUG: Hide request completed ===");
}

- (void)unhideWithoutActivation
{
    NSLog(@"=== DEBUG: GWorkspace requesting Firefox unhide without activation ===");
    
    // First, get all Firefox window IDs
    NSTask *searchTask = [[NSTask alloc] init];
    [searchTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [searchTask setArguments:@[@"search", @"--class", @"firefox"]];
    
    NSPipe *searchPipe = [NSPipe pipe];
    [searchTask setStandardOutput:searchPipe];
    [searchTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [searchTask launch];
        [searchTask waitUntilExit];
        
        if ([searchTask terminationStatus] == 0) {
            NSData *data = [[searchPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSArray *windowIDs = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"];
            [output release];
            
            NSLog(@"Found %lu Firefox windows to unhide", (unsigned long)[windowIDs count]);
            
            // Unminimize each window individually without activation
            for (NSString *windowID in windowIDs) {
                if ([windowID length] > 0) {
                    NSLog(@"Unmapping window: %@", windowID);
                    NSTask *mapTask = [[NSTask alloc] init];
                    [mapTask setLaunchPath:@"/usr/local/bin/xdotool"];
                    [mapTask setArguments:@[@"windowmap", windowID]];
                    [mapTask setStandardOutput:[NSPipe pipe]];
                    [mapTask setStandardError:[NSPipe pipe]];
                    
                    NS_DURING
                        [mapTask launch];
                        [mapTask waitUntilExit];
                        NSLog(@"Window %@ unmap result: %d", windowID, [mapTask terminationStatus]);
                    NS_HANDLER
                        NSLog(@"Failed to unminimize window %@: %@", windowID, localException);
                    NS_ENDHANDLER
                    
                    [mapTask release];
                }
            }
            
            NSLog(@"Firefox windows unhidden (%lu windows)", (unsigned long)[windowIDs count]);
            [self notifyGWorkspaceOfStateChange];
        } else {
            NSLog(@"No Firefox windows found to unhide");
        }
    NS_HANDLER
        NSLog(@"Failed to search for Firefox windows: %@", localException);
    NS_ENDHANDLER
    
    [searchTask release];
    NSLog(@"=== DEBUG: Unhide request completed ===");
}

- (BOOL)isHidden
{
    NSLog(@"=== DEBUG: GWorkspace asking if Firefox is hidden ===");
    
    // Check if Firefox windows are minimized
    NSTask *checkTask = [[NSTask alloc] init];
    [checkTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [checkTask setArguments:@[@"search", @"--onlyvisible", @"--class", @"firefox"]];
    [checkTask setStandardOutput:[NSPipe pipe]];
    [checkTask setStandardError:[NSPipe pipe]];
    
    BOOL hasVisibleWindows = NO;
    NS_DURING
        [checkTask launch];
        [checkTask waitUntilExit];
        hasVisibleWindows = ([checkTask terminationStatus] == 0);
        NSLog(@"Visible windows check result: %@", hasVisibleWindows ? @"YES" : @"NO");
    NS_HANDLER
        NSLog(@"Failed to check Firefox window visibility: %@", localException);
    NS_ENDHANDLER
    
    [checkTask release];
    BOOL hidden = !hasVisibleWindows;
    NSLog(@"Firefox is hidden: %@", hidden ? @"YES" : @"NO");
    return hidden; // Hidden if no visible windows
}

- (void)notifyGWorkspaceOfStateChange
{
    NSLog(@"=== DEBUG: Notifying GWorkspace of state change ===");
    
    // Post notifications that GWorkspace/Dock can observe
    NSDictionary *userInfo = @{
        @"NSApplicationName": @"Firefox",
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    if ([self isHidden]) {
        NSLog(@"Posting NSApplicationDidHideNotification");
        [nc postNotificationName:NSApplicationDidHideNotification 
                          object:NSApp 
                        userInfo:userInfo];
    } else {
        NSLog(@"Posting NSApplicationDidUnhideNotification");
        [nc postNotificationName:NSApplicationDidUnhideNotification 
                          object:NSApp 
                        userInfo:userInfo];
    }
    
    NSLog(@"=== DEBUG: State change notification posted ===");
}

- (void)terminate:(id)sender
{
    NSLog(@"GWorkspace requesting Firefox termination");
    
    if ([self isFirefoxCurrentlyRunning]) {
        // Try graceful shutdown first
        NSTask *quitTask = [[NSTask alloc] init];
        [quitTask setLaunchPath:@"/usr/local/bin/xdotool"];
        [quitTask setArguments:@[@"search", @"--class", @"firefox", @"key", @"ctrl+q"]];
        [quitTask setStandardOutput:[NSPipe pipe]];
        [quitTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [quitTask launch];
            [quitTask waitUntilExit];
            NSLog(@"Sent quit command to Firefox");
            
            // Give Firefox a moment to quit gracefully, then force quit if needed
            [self performSelector:@selector(forceQuitIfNeeded) withObject:nil afterDelay:3.0];
            
        NS_HANDLER
            NSLog(@"Failed to send quit command: %@", localException);
            
            // Fallback: terminate the process directly
            if (firefoxTask && [firefoxTask isRunning]) {
                [firefoxTask terminate];
            }
        NS_ENDHANDLER
        
        [quitTask release];
    }
}

- (void)forceQuitIfNeeded
{
    // Check if Firefox is still running after graceful quit attempt
    if ([self isFirefoxCurrentlyRunning] && firefoxTask && [firefoxTask isRunning]) {
        NSLog(@"Firefox didn't quit gracefully, force terminating");
        [firefoxTask terminate];
    }
}

// Additional methods for better GWorkspace integration
- (BOOL)isRunning
{
    return [self isFirefoxCurrentlyRunning];
}

- (NSNumber *)processIdentifier
{
    if (firefoxTask && [firefoxTask isRunning]) {
        return @([firefoxTask processIdentifier]);
    }
    return nil;
}

- (void)application:(NSApplication *)sender openFile:(NSString *)filename
{
    NSLog(@"GWorkspace requesting to open file: %@", filename);
    [self openFileInFirefox:filename activate:YES];
}

- (void)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename
{
    NSLog(@"GWorkspace requesting to open file without UI: %@", filename);
    [self openFileInFirefox:filename activate:NO];
}

- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate
{
    if (![self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox not running, launching with file: %@", filename);
        
        firefoxTask = [[NSTask alloc] init];
        [firefoxTask setLaunchPath:firefoxExecutablePath];
        [firefoxTask setArguments:@[filename]];
        
        NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
        [firefoxTask setEnvironment:environment];
        [environment release];
        
        [[NSNotificationCenter defaultCenter] 
            addObserver:self 
            selector:@selector(handleFirefoxTermination:) 
            name:NSTaskDidTerminateNotification 
            object:firefoxTask];
        
        NS_DURING
            [firefoxTask launch];
            isFirefoxRunning = YES;
            NSLog(@"Firefox launched with file, PID: %d", [firefoxTask processIdentifier]);
            
            if (shouldActivate) {
                [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
            }
        NS_HANDLER
            NSLog(@"Failed to launch Firefox with file: %@", localException);
            [firefoxTask release];
            firefoxTask = nil;
        NS_ENDHANDLER
        
    } else {
        NSLog(@"Firefox running, opening file in existing instance: %@", filename);
        
        // Use Firefox's remote protocol to open file
        NSTask *openTask = [[NSTask alloc] init];
        [openTask setLaunchPath:firefoxExecutablePath];
        [openTask setArguments:@[@"-remote", [NSString stringWithFormat:@"openURL(%@,new-tab)", filename]]];
        [openTask setStandardOutput:[NSPipe pipe]];
        [openTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [openTask launch];
            [openTask waitUntilExit];
            
            if (shouldActivate) {
                [self activateFirefoxWindows];
            }
        NS_HANDLER
            NSLog(@"Failed to open file in existing Firefox: %@", localException);
        NS_ENDHANDLER
        
        [openTask release];
    }
}

#pragma mark - Firefox Management Methods

- (void)activateFirefoxWindows
{
    NSLog(@"=== DEBUG: Attempting to activate Firefox windows ===");
    
    // First, let's debug what windows exist
    [self debugFirefoxWindows];
    
    // Method 1: Try wmctrl first (better for minimized windows)
    if ([self activateFirefoxWithWmctrl]) {
        NSLog(@"Firefox activated successfully with wmctrl");
        return;
    }
    
    // Method 2: Try the original xdotool approach
    NSLog(@"wmctrl failed, trying original xdotool approach");
    if ([self activateFirefoxWithXdotoolOriginal]) {
        NSLog(@"Firefox activated with original xdotool");
        return;
    }
    
    // Method 3: Fall back to individual window activation
    NSLog(@"Original xdotool failed, trying individual window activation");
    [self activateFirefoxWithXdotool];
}

- (BOOL)activateFirefoxWithXdotoolOriginal
{
    // Try the original approach that might work for multiple windows
    NSTask *xdotoolTask = [[NSTask alloc] init];
    [xdotoolTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [xdotoolTask setArguments:@[@"search", @"--class", @"firefox", @"windowactivate"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [xdotoolTask setStandardOutput:pipe];
    [xdotoolTask setStandardError:pipe];
    
    BOOL success = NO;
    NS_DURING
        [xdotoolTask launch];
        [xdotoolTask waitUntilExit];
        
        if ([xdotoolTask terminationStatus] == 0) {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"xdotool original output: %@", output);
            [output release];
            success = YES;
        } else {
            NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"xdotool original failed with output: %@", output);
            [output release];
        }
    NS_HANDLER
        NSLog(@"xdotool original exception: %@", localException);
    NS_ENDHANDLER
    
    [xdotoolTask release];
    return success;
}

- (void)debugFirefoxWindows
{
    NSLog(@"=== Debugging Firefox Windows ===");
    
    // Check for visible Firefox windows
    NSTask *visibleTask = [[NSTask alloc] init];
    [visibleTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [visibleTask setArguments:@[@"search", @"--onlyvisible", @"--class", @"firefox"]];
    NSPipe *visiblePipe = [NSPipe pipe];
    [visibleTask setStandardOutput:visiblePipe];
    [visibleTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [visibleTask launch];
        [visibleTask waitUntilExit];
        
        if ([visibleTask terminationStatus] == 0) {
            NSData *data = [[visiblePipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSArray *visibleWindows = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"];
            NSLog(@"Visible Firefox windows (%lu): %@", (unsigned long)[visibleWindows count], output);
            [output release];
        } else {
            NSLog(@"No visible Firefox windows found");
        }
    NS_HANDLER
        NSLog(@"Failed to check visible Firefox windows: %@", localException);
    NS_ENDHANDLER
    [visibleTask release];
    
    // Check for all Firefox windows (including minimized)
    NSTask *allTask = [[NSTask alloc] init];
    [allTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [allTask setArguments:@[@"search", @"--class", @"firefox"]];
    NSPipe *allPipe = [NSPipe pipe];
    [allTask setStandardOutput:allPipe];
    [allTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [allTask launch];
        [allTask waitUntilExit];
        
        if ([allTask terminationStatus] == 0) {
            NSData *data = [[allPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSArray *allWindows = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"];
            NSLog(@"All Firefox windows (%lu): %@", (unsigned long)[allWindows count], output);
            [output release];
        } else {
            NSLog(@"No Firefox windows found at all");
        }
    NS_HANDLER
        NSLog(@"Failed to check all Firefox windows: %@", localException);
    NS_ENDHANDLER
    [allTask release];
    
    // Also check window manager info
    NSTask *wmctrlList = [[NSTask alloc] init];
    [wmctrlList setLaunchPath:@"/usr/local/bin/wmctrl"];
    [wmctrlList setArguments:@[@"-l"]];
    NSPipe *wmPipe = [NSPipe pipe];
    [wmctrlList setStandardOutput:wmPipe];
    [wmctrlList setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [wmctrlList launch];
        [wmctrlList waitUntilExit];
        
        if ([wmctrlList terminationStatus] == 0) {
            NSData *data = [[wmPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSLog(@"wmctrl window list:\n%@", output);
            [output release];
        }
    NS_HANDLER
        NSLog(@"Failed to get wmctrl window list: %@", localException);
    NS_ENDHANDLER
    [wmctrlList release];
    
    NSLog(@"=== End Firefox Window Debug ===");
}

- (BOOL)activateFirefoxWithWmctrl
{
    NSTask *wmctrlTask = [[NSTask alloc] init];
    [wmctrlTask setLaunchPath:@"/usr/local/bin/wmctrl"];
    [wmctrlTask setArguments:@[@"-a", @"firefox"]];
    [wmctrlTask setStandardOutput:[NSPipe pipe]];
    [wmctrlTask setStandardError:[NSPipe pipe]];
    
    BOOL success = NO;
    NS_DURING
        [wmctrlTask launch];
        [wmctrlTask waitUntilExit];
        
        if ([wmctrlTask terminationStatus] == 0) {
            success = YES;
        }
    NS_HANDLER
        NSLog(@"wmctrl failed: %@", localException);
    NS_ENDHANDLER
    
    [wmctrlTask release];
    return success;
}

- (void)activateFirefoxWithXdotool
{
    // First, get all Firefox window IDs
    NSTask *searchTask = [[NSTask alloc] init];
    [searchTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [searchTask setArguments:@[@"search", @"--class", @"firefox"]];
    
    NSPipe *searchPipe = [NSPipe pipe];
    [searchTask setStandardOutput:searchPipe];
    [searchTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [searchTask launch];
        [searchTask waitUntilExit];
        
        if ([searchTask terminationStatus] == 0) {
            NSData *data = [[searchPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSArray *windowIDs = [[output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] componentsSeparatedByString:@"\n"];
            [output release];
            
            // Activate each window individually
            for (NSString *windowID in windowIDs) {
                if ([windowID length] > 0) {
                    NSTask *activateTask = [[NSTask alloc] init];
                    [activateTask setLaunchPath:@"/usr/local/bin/xdotool"];
                    [activateTask setArguments:@[@"windowactivate", windowID]];
                    [activateTask setStandardOutput:[NSPipe pipe]];
                    [activateTask setStandardError:[NSPipe pipe]];
                    
                    NS_DURING
                        [activateTask launch];
                        [activateTask waitUntilExit];
                    NS_HANDLER
                        NSLog(@"Failed to activate window %@: %@", windowID, localException);
                    NS_ENDHANDLER
                    
                    [activateTask release];
                }
            }
            
            NSLog(@"Firefox windows activated successfully with xdotool (%lu windows)", (unsigned long)[windowIDs count]);
        } else {
            NSLog(@"xdotool search failed or no Firefox windows found");
        }
    NS_HANDLER
        NSLog(@"Failed to run xdotool search: %@", localException);
    NS_ENDHANDLER
    
    [searchTask release];
}

- (void)waitForFirefoxToStart
{
    // Check if Firefox has created windows yet (use --onlyvisible to ensure windows are ready)
    NSTask *checkTask = [[NSTask alloc] init];
    [checkTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [checkTask setArguments:@[@"search", @"--onlyvisible", @"--class", @"firefox"]];
    [checkTask setStandardOutput:[NSPipe pipe]];
    [checkTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [checkTask launch];
        [checkTask waitUntilExit];
        
        if ([checkTask terminationStatus] == 0) {
            // Firefox windows found, activate them
            [self activateFirefoxWindows];
        } else {
            // No windows yet, try again in 1 second
            [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
        }
    NS_HANDLER
        NSLog(@"Failed to check for Firefox windows: %@", localException);
    NS_ENDHANDLER
    
    [checkTask release];
}

- (void)launchFirefox
{
    if (isFirefoxRunning && firefoxTask && [firefoxTask isRunning]) {
        NSLog(@"Firefox is already running");
        [self activateFirefoxWindows];
        return;
    }
    
    NSLog(@"Launching Firefox from: %@", firefoxExecutablePath);
    
    // Notify GWorkspace that we're about to launch
    NSDictionary *launchInfo = @{
        @"NSApplicationName": @"Firefox",
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:NSWorkspaceWillLaunchApplicationNotification
                      object:[NSWorkspace sharedWorkspace]
                    userInfo:launchInfo];
    
    firefoxTask = [[NSTask alloc] init];
    [firefoxTask setLaunchPath:firefoxExecutablePath];
    [firefoxTask setArguments:@[]];
    
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [firefoxTask setEnvironment:environment];
    [environment release];
    
    [[NSNotificationCenter defaultCenter] 
        addObserver:self 
        selector:@selector(handleFirefoxTermination:) 
        name:NSTaskDidTerminateNotification 
        object:firefoxTask];
    
    NS_DURING
        [firefoxTask launch];
        isFirefoxRunning = YES;
        NSLog(@"Firefox launched successfully with PID: %d", [firefoxTask processIdentifier]);
        
        // Notify GWorkspace that launch completed
        NSDictionary *didLaunchInfo = @{
            @"NSApplicationName": @"Firefox",
            @"NSApplicationPath": [[NSBundle mainBundle] bundlePath],
            @"NSApplicationProcessIdentifier": @([firefoxTask processIdentifier])
        };
        
        [[NSNotificationCenter defaultCenter] 
            postNotificationName:NSWorkspaceDidLaunchApplicationNotification
                          object:[NSWorkspace sharedWorkspace]
                        userInfo:didLaunchInfo];
        
        // Wait for Firefox to create windows, then activate them
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
        
    NS_HANDLER
        NSLog(@"Failed to launch Firefox: %@", localException);
        isFirefoxRunning = NO;
        [firefoxTask release];
        firefoxTask = nil;
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Firefox Launch Error"];
        [alert setInformativeText:[NSString stringWithFormat:@"Could not launch Firefox from %@. Please check that Firefox is installed.", firefoxExecutablePath]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        
        [NSApp terminate:self];
    NS_ENDHANDLER
}

- (BOOL)isFirefoxCurrentlyRunning
{
    if (firefoxTask && [firefoxTask isRunning]) {
        return YES;
    }
    
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/pgrep"];
    [task setArguments:@[@"-f", @"firefox"]];
    
    NSPipe *pipe = [NSPipe pipe];
    [task setStandardOutput:pipe];
    [task setStandardError:[NSPipe pipe]];
    
    BOOL running = NO;
    NS_DURING
        [task launch];
        [task waitUntilExit];
        
        if ([task terminationStatus] == 0) {
            running = YES;
            NSLog(@"Firefox process found via pgrep");
        }
    NS_HANDLER
        NSLog(@"pgrep command failed: %@", localException);
        running = NO;
    NS_ENDHANDLER
    
    [task release];
    return running;
}

- (void)handleFirefoxTermination:(NSNotification *)notification
{
    NSTask *task = [notification object];
    
    if (task == firefoxTask) {
        NSLog(@"=== DEBUG: Firefox process terminated (PID: %d) ===", [task processIdentifier]);
        isFirefoxRunning = NO;
        
        // Notify GWorkspace that the application terminated
        NSDictionary *terminationInfo = @{
            @"NSApplicationName": @"Firefox",
            @"NSApplicationPath": [[NSBundle mainBundle] bundlePath],
            @"NSApplicationProcessIdentifier": @([task processIdentifier])
        };
        
        [[NSNotificationCenter defaultCenter] 
            postNotificationName:NSWorkspaceDidTerminateApplicationNotification
                          object:[NSWorkspace sharedWorkspace]
                        userInfo:terminationInfo];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
        
        NSLog(@"=== DEBUG: Firefox has quit, but wrapper staying running ===");
        // DO NOT terminate the wrapper - keep it running for future launches
    }
}

#pragma mark - Application Delegate Methods

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    NSLog(@"Firefox app wrapper activated from dock");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is already running, activating windows");
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
    
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    // Never terminate just because windows close - we're a background service
    NSLog(@"=== DEBUG: Refusing to terminate after last window closed ===");
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    NSLog(@"=== DEBUG: Application termination requested ===");
    
    // For now, let's just refuse to terminate to see what's trying to quit us
    NSLog(@"Refusing termination to keep wrapper running");
    return NSTerminateCancel;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"Firefox launcher will terminate");
    
    if (serviceConnection) {
        [serviceConnection invalidate];
        serviceConnection = nil;
    }
    
    // Clean up Firefox task if still running
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
    }
}

- (void)dealloc
{
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
    }
    [super dealloc];
}

@end
