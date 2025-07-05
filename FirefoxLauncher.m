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
        }
        exit(0);
    }
    
    NSLog(@"Firefox launcher initialized");
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    if ([self isFirefoxCurrentlyRunning]) {
        NSLog(@"Firefox is already running");
    } else {
        NSLog(@"Firefox not running, launching it");
        [self launchFirefox];
    }
}

- (void)launchFirefox
{
    if (isFirefoxRunning && firefoxTask && [firefoxTask isRunning]) {
        NSLog(@"Firefox is already running");
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
        NSLog(@"Firefox is already running");
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