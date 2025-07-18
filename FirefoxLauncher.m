#import "FirefoxLauncher.h"

@implementation FirefoxLauncher

- (id)init
{
    self = [super init];
    if (self) {
        firefoxExecutablePath = @"/usr/local/bin/firefox";
        isFirefoxRunning = NO;
        firefoxTask = nil;
        serviceConnection = nil;
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    NSDebugLog(@"=== DEBUG: Firefox wrapper starting up ===");
    
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
    
    NSString *appName = @"Firefox";
    
    NSDebugLog(@"Attempting to register distributed object as '%@'", appName);
    
    if (![serviceConnection registerName:appName]) {
        NSDebugLog(@"Registration failed - another Firefox wrapper may be running");
        [NSApp terminate:self];
        return;
    }
    
    NSDebugLog(@"Firefox launcher successfully registered as '%@'", appName);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    NSDebugLog(@"=== DEBUG: Application finished launching ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Firefox is already running, activating windows");
        [self activateFirefoxWindows];
    } else {
        NSDebugLog(@"Firefox not running, launching it");
        [self launchFirefox];
    }
    
    [self startPeriodicFirefoxMonitoring];
    
    NSDebugLog(@"=== DEBUG: Application setup complete ===");
}

- (void)startPeriodicFirefoxMonitoring
{
    NSDebugLog(@"Starting Firefox monitoring (5 second intervals)");
    
    [NSTimer scheduledTimerWithTimeInterval:5.0
                                     target:self
                                   selector:@selector(periodicFirefoxCheck:)
                                   userInfo:nil
                                    repeats:YES];
}

- (void)periodicFirefoxCheck:(NSTimer *)timer
{
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
        NSDebugLog(@"Firefox check failed: %@", localException);
        firefoxRunning = NO;
    NS_ENDHANDLER
    
    [task release];
    
    static BOOL wasRunning = YES;
    
    if (wasRunning && !firefoxRunning) {
        NSDebugLog(@"Firefox stopped - terminating wrapper");
        [timer invalidate];
        [NSApp terminate:self];
    }
    
    wasRunning = firefoxRunning;
}

#pragma mark - GWorkspace Integration Methods

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    NSDebugLog(@"=== DEBUG: GWorkspace requesting Firefox activation (ignoreOthers: %@) ===", flag ? @"YES" : @"NO");
    NSDebugLog(@"Current Firefox running state: %@", [self isFirefoxCurrentlyRunning] ? @"YES" : @"NO");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Firefox is running, activating windows");
        [self activateFirefoxWindows];
        [self notifyGWorkspaceOfStateChange];
    } else {
        NSDebugLog(@"Firefox not running, launching it first");
        [self launchFirefox];
    }
    
    NSDebugLog(@"=== DEBUG: Activation request completed ===");
}

- (void)hide:(id)sender
{
    NSDebugLog(@"=== DEBUG: GWorkspace requesting Firefox hide ===");
    
    NSTask *listTask = [[NSTask alloc] init];
    [listTask setLaunchPath:@"/usr/local/bin/wmctrl"];
    [listTask setArguments:@[@"-l"]];
    
    NSPipe *listPipe = [NSPipe pipe];
    [listTask setStandardOutput:listPipe];
    [listTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [listTask launch];
        [listTask waitUntilExit];
        
        if ([listTask terminationStatus] == 0) {
            NSData *data = [[listPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            NSMutableArray *firefoxWindowIDs = [[NSMutableArray alloc] init];
            
            for (NSString *line in lines) {
                if ([line length] > 0) {
                    NSRange firefoxRange = [line rangeOfString:@"Firefox" options:NSCaseInsensitiveSearch];
                    NSRange mozillaRange = [line rangeOfString:@"Mozilla" options:NSCaseInsensitiveSearch];
                    
                    if (firefoxRange.location != NSNotFound || mozillaRange.location != NSNotFound) {
                        NSArray *components = [line componentsSeparatedByString:@" "];
                        if ([components count] > 0) {
                            NSString *windowID = [components objectAtIndex:0];
                            [firefoxWindowIDs addObject:windowID];
                        }
                    }
                }
            }
            
            [output release];
            
            if ([firefoxWindowIDs count] > 0) {
                NSDebugLog(@"Minimizing %lu Firefox windows", (unsigned long)[firefoxWindowIDs count]);
                
                for (NSString *windowID in firefoxWindowIDs) {
                    NSTask *minimizeTask = [[NSTask alloc] init];
                    [minimizeTask setLaunchPath:@"/usr/local/bin/wmctrl"];
                    [minimizeTask setArguments:@[@"-i", @"-b", @"add,hidden", windowID]];
                    [minimizeTask setStandardOutput:[NSPipe pipe]];
                    [minimizeTask setStandardError:[NSPipe pipe]];
                    
                    NS_DURING
                        [minimizeTask launch];
                        [minimizeTask waitUntilExit];
                        NSDebugLog(@"Window %@ minimize result: %d", windowID, [minimizeTask terminationStatus]);
                    NS_HANDLER
                        NSDebugLog(@"Failed to minimize window %@: %@", windowID, localException);
                    NS_ENDHANDLER
                    
                    [minimizeTask release];
                }
                
                NSDebugLog(@"Firefox windows minimized (%lu windows)", (unsigned long)[firefoxWindowIDs count]);
                [self notifyGWorkspaceOfStateChange];
            } else {
                NSDebugLog(@"No Firefox windows found to hide");
            }
            
            [firefoxWindowIDs release];
        } else {
            NSDebugLog(@"wmctrl failed to list windows");
        }
    NS_HANDLER
        NSDebugLog(@"Failed to list windows with wmctrl: %@", localException);
    NS_ENDHANDLER
    
    [listTask release];
    NSDebugLog(@"=== DEBUG: Hide request completed ===");
}

- (void)unhideWithoutActivation
{
    NSDebugLog(@"=== DEBUG: GWorkspace requesting Firefox unhide without activation ===");
    
    NSTask *listTask = [[NSTask alloc] init];
    [listTask setLaunchPath:@"/usr/local/bin/wmctrl"];
    [listTask setArguments:@[@"-l"]];
    
    NSPipe *listPipe = [NSPipe pipe];
    [listTask setStandardOutput:listPipe];
    [listTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [listTask launch];
        [listTask waitUntilExit];
        
        if ([listTask terminationStatus] == 0) {
            NSData *data = [[listPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            NSMutableArray *firefoxWindowIDs = [[NSMutableArray alloc] init];
            
            for (NSString *line in lines) {
                if ([line length] > 0) {
                    NSRange firefoxRange = [line rangeOfString:@"Firefox" options:NSCaseInsensitiveSearch];
                    NSRange mozillaRange = [line rangeOfString:@"Mozilla" options:NSCaseInsensitiveSearch];
                    
                    if (firefoxRange.location != NSNotFound || mozillaRange.location != NSNotFound) {
                        NSArray *components = [line componentsSeparatedByString:@" "];
                        if ([components count] > 0) {
                            NSString *windowID = [components objectAtIndex:0];
                            [firefoxWindowIDs addObject:windowID];
                        }
                    }
                }
            }
            
            [output release];
            
            if ([firefoxWindowIDs count] > 0) {
                NSDebugLog(@"Unhiding %lu Firefox windows", (unsigned long)[firefoxWindowIDs count]);
                
                for (NSString *windowID in firefoxWindowIDs) {
                    NSTask *unhideTask = [[NSTask alloc] init];
                    [unhideTask setLaunchPath:@"/usr/local/bin/wmctrl"];
                    [unhideTask setArguments:@[@"-i", @"-b", @"remove,hidden", windowID]];
                    [unhideTask setStandardOutput:[NSPipe pipe]];
                    [unhideTask setStandardError:[NSPipe pipe]];
                    
                    NS_DURING
                        [unhideTask launch];
                        [unhideTask waitUntilExit];
                        NSDebugLog(@"Window %@ unhide result: %d", windowID, [unhideTask terminationStatus]);
                    NS_HANDLER
                        NSDebugLog(@"Failed to unhide window %@: %@", windowID, localException);
                    NS_ENDHANDLER
                    
                    [unhideTask release];
                }
                
                NSDebugLog(@"Firefox windows unhidden (%lu windows)", (unsigned long)[firefoxWindowIDs count]);
                [self notifyGWorkspaceOfStateChange];
            } else {
                NSDebugLog(@"No Firefox windows found to unhide");
            }
            
            [firefoxWindowIDs release];
        } else {
            NSDebugLog(@"wmctrl failed to list windows");
        }
    NS_HANDLER
        NSDebugLog(@"Failed to list windows with wmctrl: %@", localException);
    NS_ENDHANDLER
    
    [listTask release];
    NSDebugLog(@"=== DEBUG: Unhide request completed ===");
}

- (BOOL)isHidden
{
    NSDebugLog(@"=== DEBUG: GWorkspace asking if Firefox is hidden ===");
    
    NSTask *listTask = [[NSTask alloc] init];
    [listTask setLaunchPath:@"/usr/local/bin/wmctrl"];
    [listTask setArguments:@[@"-l"]];
    
    NSPipe *listPipe = [NSPipe pipe];
    [listTask setStandardOutput:listPipe];
    [listTask setStandardError:[NSPipe pipe]];
    
    BOOL hasVisibleWindows = NO;
    
    NS_DURING
        [listTask launch];
        [listTask waitUntilExit];
        
        if ([listTask terminationStatus] == 0) {
            NSData *data = [[listPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            
            for (NSString *line in lines) {
                if ([line length] > 0) {
                    NSRange firefoxRange = [line rangeOfString:@"Firefox" options:NSCaseInsensitiveSearch];
                    NSRange mozillaRange = [line rangeOfString:@"Mozilla" options:NSCaseInsensitiveSearch];
                    
                    if (firefoxRange.location != NSNotFound || mozillaRange.location != NSNotFound) {
                        hasVisibleWindows = YES;
                        break;
                    }
                }
            }
            
            [output release];
        }
    NS_HANDLER
        NSDebugLog(@"Failed to check Firefox window visibility: %@", localException);
    NS_ENDHANDLER
    
    [listTask release];
    
    BOOL hidden = !hasVisibleWindows;
    NSDebugLog(@"Firefox is hidden: %@", hidden ? @"YES" : @"NO");
    return hidden;
}

- (void)notifyGWorkspaceOfStateChange
{
    NSDebugLog(@"=== DEBUG: Notifying GWorkspace of state change ===");
    
    NSDictionary *userInfo = @{
        @"NSApplicationName": @"Firefox",
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    if ([self isHidden]) {
        NSDebugLog(@"Posting NSApplicationDidHideNotification");
        [nc postNotificationName:NSApplicationDidHideNotification 
                          object:NSApp 
                        userInfo:userInfo];
    } else {
        NSDebugLog(@"Posting NSApplicationDidUnhideNotification");
        [nc postNotificationName:NSApplicationDidUnhideNotification 
                          object:NSApp 
                        userInfo:userInfo];
    }
    
    NSDebugLog(@"=== DEBUG: State change notification posted ===");
}

- (void)terminate:(id)sender
{
    NSDebugLog(@"=== DEBUG: GWorkspace requesting Firefox termination ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Terminating all Firefox processes");
        
        NSTask *quitTask = [[NSTask alloc] init];
        [quitTask setLaunchPath:@"/usr/local/bin/wmctrl"];
        [quitTask setArguments:@[@"-c", @"Firefox"]];
        [quitTask setStandardOutput:[NSPipe pipe]];
        [quitTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [quitTask launch];
            [quitTask waitUntilExit];
            NSDebugLog(@"Sent close command to Firefox windows");
            
            [self performSelector:@selector(forceQuitIfNeeded) withObject:nil afterDelay:3.0];
            
        NS_HANDLER
            NSDebugLog(@"Failed to send close command: %@", localException);
            
            if (firefoxTask && [firefoxTask isRunning]) {
                [firefoxTask terminate];
            }
        NS_ENDHANDLER
        
        [quitTask release];
    } else {
        NSDebugLog(@"No Firefox processes running, terminating wrapper immediately");
        [NSApp terminate:self];
    }
}

- (void)forceQuitFirefoxAndExit
{
    NSDebugLog(@"=== DEBUG: Force quitting Firefox and exiting wrapper ===");
    
    NSTask *killTask = [[NSTask alloc] init];
    [killTask setLaunchPath:@"/usr/bin/pkill"];
    [killTask setArguments:@[@"-f", @"firefox"]];
    [killTask setStandardOutput:[NSPipe pipe]];
    [killTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [killTask launch];
        [killTask waitUntilExit];
        NSDebugLog(@"Force killed Firefox processes");
    NS_HANDLER
        NSDebugLog(@"Failed to force kill Firefox: %@", localException);
    NS_ENDHANDLER
    
    [killTask release];
    
    [NSApp terminate:self];
}

- (void)forceQuitIfNeeded
{
    if ([self isFirefoxCurrentlyRunning] && firefoxTask && [firefoxTask isRunning]) {
        NSDebugLog(@"Firefox didn't quit gracefully, force terminating");
        [firefoxTask terminate];
    }
}

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
    NSDebugLog(@"GWorkspace requesting to open file: %@", filename);
    [self openFileInFirefox:filename activate:YES];
}

- (void)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename
{
    NSDebugLog(@"GWorkspace requesting to open file without UI: %@", filename);
    [self openFileInFirefox:filename activate:NO];
}

- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate
{
    if (![self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Firefox not running, launching with file: %@", filename);
        
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
            NSDebugLog(@"Firefox launched with file, PID: %d", [firefoxTask processIdentifier]);
            
            if (shouldActivate) {
                [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
            }
        NS_HANDLER
            NSDebugLog(@"Failed to launch Firefox with file: %@", localException);
            [firefoxTask release];
            firefoxTask = nil;
        NS_ENDHANDLER
        
    } else {
        NSDebugLog(@"Firefox running, opening file in existing instance: %@", filename);
        
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
            NSDebugLog(@"Failed to open file in existing Firefox: %@", localException);
        NS_ENDHANDLER
        
        [openTask release];
    }
}

#pragma mark - Firefox Management Methods

- (void)activateFirefoxWindows
{
    NSDebugLog(@"Activating Firefox windows with wmctrl");
    [self activateFirefoxWithWmctrl];
}

- (BOOL)activateFirefoxWithWmctrl
{
    NSDebugLog(@"Attempting to activate all Firefox windows with wmctrl");
    
    NSTask *listTask = [[NSTask alloc] init];
    [listTask setLaunchPath:@"/usr/local/bin/wmctrl"];
    [listTask setArguments:@[@"-l"]];
    
    NSPipe *listPipe = [NSPipe pipe];
    [listTask setStandardOutput:listPipe];
    [listTask setStandardError:[NSPipe pipe]];
    
    BOOL success = NO;
    
    NS_DURING
        [listTask launch];
        [listTask waitUntilExit];
        
        if ([listTask terminationStatus] == 0) {
            NSData *data = [[listPipe fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            NSMutableArray *firefoxWindowIDs = [[NSMutableArray alloc] init];
            
            for (NSString *line in lines) {
                if ([line length] > 0) {
                    NSRange firefoxRange = [line rangeOfString:@"Firefox" options:NSCaseInsensitiveSearch];
                    NSRange mozillaRange = [line rangeOfString:@"Mozilla" options:NSCaseInsensitiveSearch];
                    
                    if (firefoxRange.location != NSNotFound || mozillaRange.location != NSNotFound) {
                        NSArray *components = [line componentsSeparatedByString:@" "];
                        if ([components count] > 0) {
                            NSString *windowID = [components objectAtIndex:0];
                            [firefoxWindowIDs addObject:windowID];
                            NSDebugLog(@"Found Firefox window ID: %@", windowID);
                        }
                    }
                }
            }
            
            [output release];
            
            if ([firefoxWindowIDs count] > 0) {
                NSDebugLog(@"Activating %lu Firefox windows with wmctrl", (unsigned long)[firefoxWindowIDs count]);
                
                for (NSString *windowID in firefoxWindowIDs) {
                    NSTask *activateTask = [[NSTask alloc] init];
                    [activateTask setLaunchPath:@"/usr/local/bin/wmctrl"];
                    [activateTask setArguments:@[@"-i", @"-a", windowID]];
                    [activateTask setStandardOutput:[NSPipe pipe]];
                    [activateTask setStandardError:[NSPipe pipe]];
                    
                    NS_DURING
                        [activateTask launch];
                        [activateTask waitUntilExit];
                        
                        if ([activateTask terminationStatus] == 0) {
                            NSDebugLog(@"Successfully activated window %@", windowID);
                            success = YES;
                        } else {
                            NSDebugLog(@"Failed to activate window %@", windowID);
                        }
                    NS_HANDLER
                        NSDebugLog(@"Exception activating window %@: %@", windowID, localException);
                    NS_ENDHANDLER
                    
                    [activateTask release];
                }
            } else {
                NSDebugLog(@"No Firefox windows found in wmctrl output");
            }
            
            [firefoxWindowIDs release];
        } else {
            NSDebugLog(@"wmctrl -l failed with status: %d", [listTask terminationStatus]);
        }
    NS_HANDLER
        NSDebugLog(@"wmctrl list command failed: %@", localException);
    NS_ENDHANDLER
    
    [listTask release];
    return success;
}

- (void)waitForFirefoxToStart
{
    NSTask *listTask = [[NSTask alloc] init];
    [listTask setLaunchPath:@"/usr/local/bin/wmctrl"];
    [listTask setArguments:@[@"-l"]];
    [listTask setStandardOutput:[NSPipe pipe]];
    [listTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [listTask launch];
        [listTask waitUntilExit];
        
        if ([listTask terminationStatus] == 0) {
            NSData *data = [[[listTask standardOutput] fileHandleForReading] readDataToEndOfFile];
            NSString *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            
            BOOL foundFirefoxWindow = NO;
            NSArray *lines = [output componentsSeparatedByString:@"\n"];
            for (NSString *line in lines) {
                if ([line length] > 0) {
                    NSRange firefoxRange = [line rangeOfString:@"Firefox" options:NSCaseInsensitiveSearch];
                    NSRange mozillaRange = [line rangeOfString:@"Mozilla" options:NSCaseInsensitiveSearch];
                    
                    if (firefoxRange.location != NSNotFound || mozillaRange.location != NSNotFound) {
                        foundFirefoxWindow = YES;
                        break;
                    }
                }
            }
            
            [output release];
            
            if (foundFirefoxWindow) {
                [self activateFirefoxWindows];
            } else {
                [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
            }
        } else {
            [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
        }
    NS_HANDLER
        NSDebugLog(@"Failed to check for Firefox windows: %@", localException);
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
    NS_ENDHANDLER
    
    [listTask release];
}

- (void)launchFirefox
{
    if (isFirefoxRunning && firefoxTask && [firefoxTask isRunning]) {
        NSDebugLog(@"Firefox is already running");
        [self activateFirefoxWindows];
        return;
    }
    
    NSDebugLog(@"Launching Firefox from: %@", firefoxExecutablePath);
    
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
        NSDebugLog(@"Firefox launched successfully with PID: %d", [firefoxTask processIdentifier]);
        
        NSDictionary *didLaunchInfo = @{
            @"NSApplicationName": @"Firefox",
            @"NSApplicationPath": [[NSBundle mainBundle] bundlePath],
            @"NSApplicationProcessIdentifier": @([firefoxTask processIdentifier])
        };
        
        [[NSNotificationCenter defaultCenter] 
            postNotificationName:NSWorkspaceDidLaunchApplicationNotification
                          object:[NSWorkspace sharedWorkspace]
                        userInfo:didLaunchInfo];
        
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:1.0];
        
    NS_HANDLER
        NSDebugLog(@"Failed to launch Firefox: %@", localException);
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
        NSDebugLog(@"=== DEBUG: Firefox process terminated (PID: %d) ===", [task processIdentifier]);
        isFirefoxRunning = NO;
        
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
        
        [self performSelector:@selector(checkForRemainingFirefoxProcesses) 
                   withObject:nil 
                   afterDelay:1.0];
    }
}

- (void)checkForRemainingFirefoxProcesses
{
    NSDebugLog(@"=== DEBUG: Checking for remaining Firefox processes ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Other Firefox processes still running, keeping wrapper alive");
        
        [self performSelector:@selector(checkForRemainingFirefoxProcesses) 
                   withObject:nil 
                   afterDelay:2.0];
    } else {
        NSDebugLog(@"No Firefox processes remaining, terminating wrapper");
        [NSApp terminate:self];
    }
}

#pragma mark - Application Delegate Methods

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    NSDebugLog(@"Firefox app wrapper activated from dock");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Firefox is already running, activating windows");
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
    
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    NSDebugLog(@"=== DEBUG: Refusing to terminate after last window closed ===");
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    NSDebugLog(@"=== DEBUG: Application termination requested ===");
    
    if ([self isFirefoxCurrentlyRunning]) {
        NSDebugLog(@"Firefox is still running, refusing termination");
        return NSTerminateCancel;
    } else {
        NSDebugLog(@"No Firefox processes running, allowing termination");
        return NSTerminateNow;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSDebugLog(@"=== DEBUG: Firefox launcher will terminate ===");
    
    if (serviceConnection) {
        [serviceConnection invalidate];
        serviceConnection = nil;
    }
    
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
    }
    
    NSDebugLog(@"=== DEBUG: Firefox launcher cleanup complete ===");
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