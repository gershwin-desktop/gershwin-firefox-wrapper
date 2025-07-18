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
        NSLog(@"Registration failed - another Firefox wrapper may be running");
        // Don't try to contact existing instance - just exit cleanly
        [NSApp terminate:self];
        return;
    }
    
    NSLog(@"Firefox launcher successfully registered as '%@'", appName);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSLog(@"=== DEBUG: Application finished launching ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is already running, activating windows");
        [self activateFirefoxWindows];
    } else {
        NSLog(@"Firefox not running, launching it");
        [self launchFirefox];
    }
    
    // Start simple periodic monitoring
    [self startPeriodicFirefoxMonitoring];
    
    NSLog(@"=== DEBUG: Application setup complete ===");
}

- (void)startPeriodicFirefoxMonitoring
{
    NSLog(@"Starting Firefox monitoring (5 second intervals)");
    
    // Check every 5 seconds - less frequent to avoid blocking
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                     target:self
                                   selector:@selector(periodicFirefoxCheck:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)periodicFirefoxCheck:(NSTimer *)timer
{
    // Quick, non-blocking check
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/pgrep"];
    [task setArguments:@[@"-f", @"firefox"]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    BOOL firefoxRunning = NO;
    
    NS_DURING
        [task launch];
        [task waitUntilExit];
        firefoxRunning = ([task terminationStatus] == 0);
    NS_HANDLER
        NSLog(@"Firefox check failed: %@", localException);
        firefoxRunning = NO;
    NS_ENDHANDLER
    
    [task release];
    
    static BOOL wasRunning = YES; // Assume Firefox was running when we started
    
    if (wasRunning && !firefoxRunning) {
        NSLog(@"Firefox stopped - terminating wrapper");
        [timer invalidate];
        [NSApp terminate:self];
    }
    
    wasRunning = firefoxRunning;
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
    NSLog(@"=== DEBUG: GWorkspace requesting Firefox termination ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Terminating all Firefox processes");
        
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
    } else {
        NSLog(@"No Firefox processes running, terminating wrapper immediately");
        [NSApp terminate:self];
    }
}

- (void)forceQuitFirefoxAndExit
{
    NSLog(@"=== DEBUG: Force quitting Firefox and exiting wrapper ===");
    
    // Force quit all Firefox processes
    NSTask *killTask = [[NSTask alloc] init];
    [killTask setLaunchPath:@"/usr/bin/pkill"];
    [killTask setArguments:@[@"-f", @"firefox"]];
    [killTask setStandardOutput:[NSPipe pipe]];
    [killTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [killTask launch];
        [killTask waitUntilExit];
        NSLog(@"Force killed Firefox processes");
    NS_HANDLER
        NSLog(@"Failed to force kill Firefox: %@", localException);
    NS_ENDHANDLER
    
    [killTask release];
    
    // Terminate wrapper
    [NSApp terminate:self];
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
    NSLog(@"Activating Firefox windows");
    
    // Try wmctrl first - most reliable and handles all windows
    if ([self activateFirefoxWithWmctrl]) {
        NSLog(@"Firefox activated with wmctrl");
        return;
    }
    
    // Fallback to xdotool - activate ALL Firefox windows
    NSLog(@"wmctrl failed, trying xdotool for all windows");
    [self activateAllFirefoxWindowsWithXdotool];
}

- (void)activateAllFirefoxWindowsWithXdotool
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
            
            NSLog(@"Found %lu Firefox windows to activate", (unsigned long)[windowIDs count]);
            
            // Activate each window individually
            for (NSString *windowID in windowIDs) {
                if ([windowID length] > 0 && ![windowID isEqualToString:@""]) {
                    [self activateWindowWithID:windowID];
                }
            }
            
            NSLog(@"All Firefox windows activated");
        } else {
            NSLog(@"No Firefox windows found to activate");
        }
    NS_HANDLER
        NSLog(@"xdotool search failed: %@", localException);
    NS_ENDHANDLER
    
    [searchTask release];
}

- (void)activateWindowWithID:(NSString *)windowID
{
    NSTask *activateTask = [[NSTask alloc] init];
    [activateTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [activateTask setArguments:@[@"windowactivate", windowID]];
    [activateTask setStandardOutput:[NSPipe pipe]];
    [activateTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [activateTask launch];
        [activateTask waitUntilExit];
        
        if ([activateTask terminationStatus] == 0) {
            NSLog(@"Activated window %@", windowID);
        }
    NS_HANDLER
        NSLog(@"Failed to activate window %@: %@", windowID, localException);
    NS_ENDHANDLER
    
    [activateTask release];
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
    // Simple, fast check
    NSTask *task = [[NSTask alloc] init];
    [task setLaunchPath:@"/usr/bin/pgrep"];
    [task setArguments:@[@"-f", @"firefox"]];
    [task setStandardOutput:[NSPipe pipe]];
    [task setStandardError:[NSPipe pipe]];
    
    BOOL running = NO;
    NS_DURING
        [task launch];
        [task waitUntilExit];
        running = ([task terminationStatus] == 0);
    NS_HANDLER
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
        
        // Wait a moment for process cleanup, then check if any Firefox processes remain
        [self performSelector:@selector(checkForRemainingFirefoxProcesses) 
                   withObject:nil 
                   afterDelay:1.0];
    }
}

- (void)checkForRemainingFirefoxProcesses
{
    NSLog(@"=== DEBUG: Checking for remaining Firefox processes ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Other Firefox processes still running, keeping wrapper alive");
        
        // Start monitoring the remaining processes
        [self performSelector:@selector(checkForRemainingFirefoxProcesses) 
                   withObject:nil 
                   afterDelay:2.0];
    } else {
        NSLog(@"No Firefox processes remaining, terminating wrapper");
        [NSApp terminate:self];
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
    
    // Check if any Firefox processes are still running
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is still running, refusing termination");
        return NSTerminateCancel;
    } else {
        NSLog(@"No Firefox processes running, allowing termination");
        return NSTerminateNow;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"=== DEBUG: Firefox launcher will terminate ===");
    
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
    
    NSLog(@"=== DEBUG: Firefox launcher cleanup complete ===");
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
