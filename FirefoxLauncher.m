#import "FirefoxLauncher.h"

@implementation FirefoxLauncher

- (id)init
{
    self = [super init];
    if (self) {
        firefoxExecutablePath = @"/usr/local/bin/firefox";
        isFirefoxRunning = NO;
        firefoxTask = nil;
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
    
    if (![serviceConnection registerName:@"FirefoxLauncher"]) {
        NSConnection *existing = [NSConnection connectionWithRegisteredName:@"FirefoxLauncher" host:nil];
        if (existing) {
            NSLog(@"Firefox launcher already running, activating existing instance");
            
            // Activate Firefox windows before exiting
            [self activateFirefoxWindows];
        }
        exit(0);
    }
    
    NSLog(@"Firefox launcher initialized");
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
    // Remove --onlyvisible to find minimized windows too
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

- (void)activateFirefoxWindowsWithDelay:(NSTimeInterval)delay
{
    // Use a timer to activate windows after a delay (useful for new launches)
    [NSTimer scheduledTimerWithTimeInterval:delay
                                     target:self
                                   selector:@selector(activateFirefoxWindows)
                                   userInfo:nil
                                    repeats:NO];
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
            NSLog(@"Visible Firefox windows: %@", [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
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
            NSLog(@"All Firefox windows: %@", [output stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]);
            [output release];
        } else {
            NSLog(@"No Firefox windows found at all");
        }
    NS_HANDLER
        NSLog(@"Failed to check all Firefox windows: %@", localException);
    NS_ENDHANDLER
    [allTask release];
    
    NSLog(@"=== End Firefox Window Debug ===");
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
