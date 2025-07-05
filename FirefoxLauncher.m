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
    // Set up the application icon
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Firefox" ofType:@"png"];
    if (iconPath && [[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (icon) {
            [NSApp setApplicationIconImage:icon];
            [icon release];
        }
    }
    
    // Set up service for preventing multiple instances
    serviceConnection = [NSConnection defaultConnection];
    [serviceConnection setRootObject:self];
    
    if (![serviceConnection registerName:@"FirefoxLauncher"]) {
        // Another instance exists - activate it and exit
        NSConnection *existing = [NSConnection connectionWithRegisteredName:@"FirefoxLauncher" host:nil];
        if (existing) {
            // Try to activate the existing Firefox instance
            NSLog(@"Firefox launcher already running, activating existing instance");
        }
        // Exit this instance
        exit(0);
    }
    
    NSLog(@"Firefox launcher initialized");
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    // Check if Firefox is already running
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is already running, activating it");
        [self activateFirefox];
        // Don't exit - stay running to represent Firefox in the dock
    } else {
        NSLog(@"Firefox not running, launching it");
        [self launchFirefox];
    }
}

- (void)launchFirefox
{
    if (isFirefoxRunning && firefoxTask && [firefoxTask isRunning]) {
        NSLog(@"Firefox is already running");
        [self activateFirefox];
        return;
    }
    
    NSLog(@"Launching Firefox from: %@", firefoxExecutablePath);
    
    firefoxTask = [[NSTask alloc] init];
    [firefoxTask setLaunchPath:firefoxExecutablePath];
    [firefoxTask setArguments:@[]];  // Add any Firefox arguments here if needed
    
    // Set environment to prevent Firefox from detaching
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [firefoxTask setEnvironment:environment];
    [environment release];
    
    // Register for termination notification
    [[NSNotificationCenter defaultCenter] 
        addObserver:self 
        selector:@selector(handleFirefoxTermination:) 
        name:NSTaskDidTerminateNotification 
        object:firefoxTask];
    
    NS_DURING
        [firefoxTask launch];
        isFirefoxRunning = YES;
        NSLog(@"Firefox launched successfully with PID: %d", [firefoxTask processIdentifier]);
    NS_HANDLER
        NSLog(@"Failed to launch Firefox: %@", localException);
        isFirefoxRunning = NO;
        [firefoxTask release];
        firefoxTask = nil;
        
        // Show error dialog
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:@"Firefox Launch Error"];
        [alert setInformativeText:[NSString stringWithFormat:@"Could not launch Firefox from %@. Please check that Firefox is installed.", firefoxExecutablePath]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        
        // Exit the app since we can't launch Firefox
        [NSApp terminate:self];
    NS_ENDHANDLER
}

- (BOOL)isFirefoxCurrentlyRunning
{
    // First check our tracked task
    if (firefoxTask && [firefoxTask isRunning]) {
        return YES;
    }
    
    // Fallback: check system processes
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

- (void)activateFirefox
{
    NSLog(@"Firefox activation requested - window management not implemented");
    // Window management removed for now since wmctrl/xdotool don't work
    // The dock icon will still show Firefox is running
}

- (void)handleFirefoxTermination:(NSNotification *)notification
{
    NSTask *task = [notification object];
    
    if (task == firefoxTask) {
        NSLog(@"Firefox process terminated (PID: %d)", [task processIdentifier]);
        isFirefoxRunning = NO;
        
        // Clean up
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
        
        // Exit the launcher since Firefox has quit
        NSLog(@"Firefox has quit, terminating Firefox launcher");
        [NSApp terminate:self];
    }
}

// Handle dock icon clicks and app activation
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    NSLog(@"Firefox app wrapper activated from dock");
    
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefox];
    } else {
        [self launchFirefox];
    }
    
    return NO; // We don't have windows to show
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    NSLog(@"Firefox launcher will terminate");
    
    // Clean up service connection
    if (serviceConnection) {
        [serviceConnection invalidate];
    }
    
    // Note: We don't terminate Firefox when the launcher quits
    // Firefox should continue running independently
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    // Allow termination but don't kill Firefox
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