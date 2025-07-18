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
    
    if (![serviceConnection registerName:appName]) {
        NSConnection *existing = [NSConnection connectionWithRegisteredName:appName host:nil];
        if (existing) {
            NSLog(@"Firefox launcher already running, activating existing instance");
            
            // Try to contact the existing wrapper to activate Firefox
            id proxy = [existing rootProxy];
            if (proxy && [proxy respondsToSelector:@selector(activateIgnoringOtherApps:)]) {
                [proxy activateIgnoringOtherApps:YES];
            } else {
                // Fallback to direct activation
                [self activateFirefoxWindows];
            }
        }
        exit(0);
    }
    
    NSLog(@"Firefox launcher initialized and registered as '%@'", appName);
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is already running");
        [self activateFirefoxWindows];
    } else {
        NSLog(@"Firefox not running, launching it");
        [self launchFirefox];
    }
}

#pragma mark - GWorkspace Integration Methods

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    NSLog(@"GWorkspace requesting Firefox activation (ignoreOthers: %@)", flag ? @"YES" : @"NO");
    
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        NSLog(@"Firefox not running, launching it first");
        [self launchFirefox];
    }
}

- (void)hide:(id)sender
{
    NSLog(@"GWorkspace requesting Firefox hide");
    
    // Use xdotool to minimize all Firefox windows
    NSTask *hideTask = [[NSTask alloc] init];
    [hideTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [hideTask setArguments:@[@"search", @"--class", @"firefox", @"windowminimize", @"%@"]];
    [hideTask setStandardOutput:[NSPipe pipe]];
    [hideTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [hideTask launch];
        [hideTask waitUntilExit];
        NSLog(@"Firefox windows minimized");
    NS_HANDLER
        NSLog(@"Failed to minimize Firefox windows: %@", localException);
    NS_ENDHANDLER
    
    [hideTask release];
}

- (void)unhideWithoutActivation
{
    NSLog(@"GWorkspace requesting Firefox unhide without activation");
    
    // Use xdotool to unminimize Firefox windows without bringing to front
    NSTask *unhideTask = [[NSTask alloc] init];
    [unhideTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [unhideTask setArguments:@[@"search", @"--class", @"firefox", @"set_window", @"--property", @"_NET_WM_STATE", @"--remove", @"_NET_WM_STATE_HIDDEN", @"%@"]];
    [unhideTask setStandardOutput:[NSPipe pipe]];
    [unhideTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [unhideTask launch];
        [unhideTask waitUntilExit];
        NSLog(@"Firefox windows unhidden");
    NS_HANDLER
        NSLog(@"Failed to unhide Firefox windows: %@", localException);
    NS_ENDHANDLER
    
    [unhideTask release];
}

- (BOOL)isHidden
{
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
    NS_HANDLER
        NSLog(@"Failed to check Firefox window visibility: %@", localException);
    NS_ENDHANDLER
    
    [checkTask release];
    return !hasVisibleWindows; // Hidden if no visible windows
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
    NSLog(@"Attempting to activate Firefox windows with multiple methods");
    
    // Method 1: Try wmctrl first (better for minimized windows)
    if ([self activateFirefoxWithWmctrl]) {
        NSLog(@"Firefox activated successfully with wmctrl");
        return;
    }
    
    // Method 2: Fall back to xdotool
    NSLog(@"wmctrl failed, trying xdotool");
    [self activateFirefoxWithXdotool];
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
    // Use xdotool to find and activate Firefox windows (including minimized ones)
    NSTask *xdotoolTask = [[NSTask alloc] init];
    [xdotoolTask setLaunchPath:@"/usr/local/bin/xdotool"];
    [xdotoolTask setArguments:@[@"search", @"--class", @"firefox", @"windowactivate", @"%@"]];
    
    // Redirect output to avoid cluttering logs
    [xdotoolTask setStandardOutput:[NSPipe pipe]];
    [xdotoolTask setStandardError:[NSPipe pipe]];
    
    NS_DURING
        [xdotoolTask launch];
        [xdotoolTask waitUntilExit];
        
        if ([xdotoolTask terminationStatus] == 0) {
            NSLog(@"Firefox windows activated successfully with xdotool");
        } else {
            NSLog(@"xdotool activation failed or no Firefox windows found");
        }
    NS_HANDLER
        NSLog(@"Failed to run xdotool: %@", localException);
    NS_ENDHANDLER
    
    [xdotoolTask release];
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
        NSLog(@"Firefox process terminated (PID: %d)", [task processIdentifier]);
        isFirefoxRunning = NO;
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
        
        NSLog(@"Firefox has quit, terminating Firefox launcher");
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

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"Firefox launcher will terminate");
    
    if (serviceConnection) {
        [serviceConnection invalidate];
    }
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    return NSTerminateNow;
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
