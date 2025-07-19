#import "FirefoxLauncher.h"
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <signal.h>

// FreeBSD libdispatch support check
#ifndef HAS_LIBDISPATCH
#define HAS_LIBDISPATCH 0
#endif

// Constants for configuration
static const NSTimeInterval kDefaultMonitoringInterval = 0.2;
static const NSTimeInterval kSlowMonitoringInterval = 2.0;
static const NSTimeInterval kWindowListCacheTimeout = 1.0;
static const NSTimeInterval kDockStateVerificationInterval = 0.5;
static const NSTimeInterval kConnectionRetryInterval = 1.0;
static const int kMaxConnectionRetries = 5;
static const int kStableStateThreshold = 6;
static const NSTimeInterval kCrashDetectionWindow = 30.0;

// State persistence keys
static NSString * const kFirefoxWasPreviouslyRunning = @"FirefoxWasPreviouslyRunning";
static NSString * const kDockIconWasVisible = @"DockIconWasVisible";
static NSString * const kLastShutdownTime = @"LastShutdownTime";

@implementation FirefoxLauncher

#pragma mark - Initialization

- (id)init
{
    self = [super init];
    if (self) {
        firefoxExecutablePath = [@"/usr/local/bin/firefox" retain];
        isFirefoxRunning = NO;
        firefoxTask = nil;
        serviceConnection = nil;
        monitoringTimer = nil;
        retryTimer = nil;
        shouldTerminateWhenFirefoxQuits = YES;
        
        // Initialize monitoring state
        wasFirefoxRunning = NO;
        isFirstMonitoringRun = YES;
        stableStateCount = 0;
        lastStateChangeTime = [[NSDate date] retain];
        
        // Initialize connection state
        connectionEstablished = NO;
        connectionRetryCount = 0;
        
        // Initialize dock management
        dockIconVisible = NO;
        isTransformingProcess = NO;
        
        // Initialize performance optimization
        cachedWindowList = [[NSMutableArray alloc] init];
        lastWindowListUpdate = nil;
        windowListCacheTimeout = kWindowListCacheTimeout;
        
        // Initialize edge case handling
        terminationPending = NO;
        systemSleepDetected = NO;
        firefoxCrashedRecently = NO;
        lastCrashTime = nil;
        
        // Load persistent state
        [self loadPersistentState];
        
        // Register for system events
        [self registerForSystemEvents];
    }
    return self;
}

#pragma mark - Application Lifecycle

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    // PRIORITY 1: Establish service connection with retry logic
    if (![self establishServiceConnection]) {
        // Schedule retry if initial connection fails
        retryTimer = [NSTimer scheduledTimerWithTimeInterval:kConnectionRetryInterval
                                                       target:self
                                                     selector:@selector(retryServiceConnection:)
                                                     userInfo:nil
                                                      repeats:YES];
        return;
    }
    
    // PRIORITY 2: Set up initial dock state
    [self ensureDockIconVisible];
    
    // PRIORITY 3: Post initial launch notification
    [self postFirefoxLaunchNotification];
    
    // PRIORITY 4: Set up icon if available
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:@"Firefox" ofType:@"png"];
    if (iconPath && [[NSFileManager defaultManager] fileExistsAtPath:iconPath]) {
        NSImage *icon = [[NSImage alloc] initWithContentsOfFile:iconPath];
        if (icon) {
            [NSApp setApplicationIconImage:icon];
            [icon release];
        }
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self startSmartFirefoxMonitoring];
    [self performSelector:@selector(handleInitialFirefoxState) withObject:nil afterDelay:0.1];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    // Cancel pending termination if user reactivates
    if (terminationPending) {
        [NSObject cancelPreviousPerformRequestsWithTarget:self 
                                                 selector:@selector(delayedTerminate) 
                                                   object:nil];
        terminationPending = NO;
    }
    
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
    
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if ([self isFirefoxCurrentlyRunning]) {
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self stopFirefoxMonitoring];
    [self savePersistentState];
    [self invalidateServiceConnection];
    
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
    }
}

#pragma mark - Dynamic Dock Management (GNUstep/X11 Compatible)

- (void)ensureDockIconVisible
{
    if (dockIconVisible || isTransformingProcess) {
        return;
    }
    
    isTransformingProcess = YES;
    [self updateDockIconState:YES];
    
    // Schedule verification
    dockStateVerificationTimer = [NSTimer scheduledTimerWithTimeInterval:kDockStateVerificationInterval
                                                                   target:self
                                                                 selector:@selector(verifyDockState:)
                                                                 userInfo:@{@"expectedState": @YES}
                                                                  repeats:NO];
}

- (void)ensureDockIconHidden
{
    if (!dockIconVisible || isTransformingProcess) {
        return;
    }
    
    isTransformingProcess = YES;
    [self updateDockIconState:NO];
    
    // Schedule verification
    dockStateVerificationTimer = [NSTimer scheduledTimerWithTimeInterval:kDockStateVerificationInterval
                                                                   target:self
                                                                 selector:@selector(verifyDockState:)
                                                                 userInfo:@{@"expectedState": @NO}
                                                                  repeats:NO];
}

- (void)updateDockIconState:(BOOL)visible
{
    // For GNUstep/X11, we use application activation policy simulation
    if (visible) {
        // Make application visible in dock-like panels
        [NSApp activateIgnoringOtherApps:YES];
        dockIconVisible = YES;
        [self updateStateValue:[NSNumber numberWithBool:YES] forKey:kDockIconWasVisible];
    } else {
        // Hide application from dock-like panels  
        [NSApp hide:self];
        dockIconVisible = NO;
        [self updateStateValue:[NSNumber numberWithBool:NO] forKey:kDockIconWasVisible];
    }
    
    // Small delay to ensure state change completes
#if HAS_LIBDISPATCH
    // Use GCD if available (preferred)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        self->isTransformingProcess = NO;
    });
#else
    // Fallback to NSObject performSelector
    [self performSelector:@selector(completeTransformationProcess) withObject:nil afterDelay:0.1];
#endif
}

- (void)completeTransformationProcess
{
    isTransformingProcess = NO;
}

- (BOOL)isDockIconCurrentlyVisible
{
    // On GNUstep/X11, check if application is active/visible
    return dockIconVisible && ![NSApp isHidden];
}

- (void)verifyDockState:(NSTimer *)timer
{
    NSDictionary *userInfo = [timer userInfo];
    BOOL expectedState = [[userInfo objectForKey:@"expectedState"] boolValue];
    
    if ([self isDockIconCurrentlyVisible] != expectedState) {
        // State verification failed, schedule retry
        retryTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                       target:self
                                                     selector:@selector(retryDockOperation:)
                                                     userInfo:userInfo
                                                      repeats:NO];
    }
}

- (void)retryDockOperation:(NSTimer *)timer
{
    NSDictionary *userInfo = [timer userInfo];
    BOOL expectedState = [[userInfo objectForKey:@"expectedState"] boolValue];
    
    if (expectedState) {
        [self ensureDockIconVisible];
    } else {
        [self ensureDockIconHidden];
    }
}

#pragma mark - Enhanced Connection Management

- (BOOL)establishServiceConnection
{
    if (connectionEstablished) {
        return YES;
    }
    
    serviceConnection = [[NSConnection defaultConnection] retain];
    [serviceConnection setRootObject:self];
    
    // Set protocol for performance optimization
    [serviceConnection setRootObject:self];
    
    NSString *appName = @"Firefox";
    
    if ([serviceConnection registerName:appName]) {
        connectionEstablished = YES;
        connectionRetryCount = 0;
        return YES;
    }
    
    // Check if another instance exists
    NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:appName host:nil];
    if (existingConnection) {
        // Another instance is running, delegate to it and exit
        id<FirefoxLauncherProtocol> existingLauncher = (id<FirefoxLauncherProtocol>)[existingConnection rootProxy];
        if (existingLauncher) {
            NS_DURING
                [existingLauncher activateIgnoringOtherApps:YES];
            NS_HANDLER
            NS_ENDHANDLER
        }
        [NSApp terminate:self];
        return NO;
    }
    
    return NO;
}

- (void)retryServiceConnection:(NSTimer *)timer
{
    connectionRetryCount++;
    
    if (connectionRetryCount > kMaxConnectionRetries) {
        [timer invalidate];
        retryTimer = nil;
        [NSApp terminate:self];
        return;
    }
    
    if ([self establishServiceConnection]) {
        [timer invalidate];
        retryTimer = nil;
        
        // Continue with initialization
        [self ensureDockIconVisible];
        [self postFirefoxLaunchNotification];
    }
}

- (void)invalidateServiceConnection
{
    if (serviceConnection) {
        [serviceConnection invalidate];
        [serviceConnection release];
        serviceConnection = nil;
        connectionEstablished = NO;
    }
}

#pragma mark - Enhanced Firefox Process Management

- (NSArray *)getAllFirefoxProcessIDs
{
    int mib[4];
    size_t size;
    struct kinfo_proc *procs;
    int nprocs;
    NSMutableArray *firefoxPIDs = [[NSMutableArray alloc] init];
    
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PROC;
    mib[3] = 0;
    
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
        return [firefoxPIDs autorelease];
    }
    
    procs = malloc(size);
    if (procs == NULL) {
        return [firefoxPIDs autorelease];
    }
    
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return [firefoxPIDs autorelease];
    }
    
    nprocs = size / sizeof(struct kinfo_proc);
    
    for (int i = 0; i < nprocs; i++) {
        NSString *execPath = [self getExecutablePathForPID:procs[i].ki_pid];
        if (execPath && [execPath isEqualToString:firefoxExecutablePath]) {
            [firefoxPIDs addObject:@(procs[i].ki_pid)];
        }
    }
    
    free(procs);
    return [firefoxPIDs autorelease];
}

- (BOOL)isFirefoxCurrentlyRunning 
{
    NSArray *pids = [self getAllFirefoxProcessIDs];
    return [pids count] > 0;
}

- (NSString *)getExecutablePathForPID:(pid_t)pid
{
    int mib[4];
    size_t size = ARG_MAX;
    char *args = malloc(size);
    
    if (args == NULL) return nil;
    
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_ARGS;
    mib[3] = pid;
    
    if (sysctl(mib, 4, args, &size, NULL, 0) == 0) {
        NSString *result = [NSString stringWithUTF8String:args];
        free(args);
        return result;
    }
    
    free(args);
    return nil;
}

- (void)launchFirefox
{
    // Check for recent crash
    if ([self isRecentCrash]) {
        // Add delay before launching after crash
        [self performSelector:@selector(launchFirefox) withObject:nil afterDelay:2.0];
        return;
    }
    
    // Double-check that Firefox isn't already running
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
        return;
    }
    
    if (isFirefoxRunning && firefoxTask && [firefoxTask isRunning]) {
        [self activateFirefoxWindows];
        return;
    }
    
    // Post launch notification
    [self postFirefoxLaunchNotification];
    
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
        
        [self updateStateValue:@YES forKey:kFirefoxWasPreviouslyRunning];
        
        // Schedule window activation
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
        
    NS_HANDLER
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

#pragma mark - Enhanced Monitoring System

- (void)startSmartFirefoxMonitoring
{
    [self stopFirefoxMonitoring];
    
    // Reset monitoring state
    wasFirefoxRunning = NO;
    isFirstMonitoringRun = YES;
    stableStateCount = 0;
    [lastStateChangeTime release];
    lastStateChangeTime = [[NSDate date] retain];
    
    // Determine initial monitoring interval
    NSTimeInterval interval = [self shouldUseAggressiveMonitoring] ? kDefaultMonitoringInterval : kSlowMonitoringInterval;
    
    monitoringTimer = [NSTimer scheduledTimerWithTimeInterval:interval
                                                       target:self
                                                     selector:@selector(smartFirefoxCheck:)
                                                     userInfo:nil
                                                      repeats:YES];
}

- (void)stopFirefoxMonitoring
{
    if (monitoringTimer) {
        [monitoringTimer invalidate];
        monitoringTimer = nil;
    }
}

- (void)smartFirefoxCheck:(NSTimer *)timer
{
    // Check for system sleep
    if (systemSleepDetected) {
        [self handleSystemWake:nil];
        return;
    }
    
    NSArray *firefoxPIDs = [self getAllFirefoxProcessIDs];
    BOOL firefoxRunning = [firefoxPIDs count] > 0;
    
    isFirefoxRunning = firefoxRunning;
    
    if (isFirstMonitoringRun) {
        wasFirefoxRunning = firefoxRunning;
        isFirstMonitoringRun = NO;
        
        if (firefoxRunning) {
            [self postFirefoxLaunchNotification];
        }
        return;
    }
    
    // Check for state change
    if (wasFirefoxRunning != firefoxRunning) {
        [lastStateChangeTime release];
        lastStateChangeTime = [[NSDate date] retain];
        stableStateCount = 0;
        
        if (wasFirefoxRunning && !firefoxRunning) {
            // Firefox quit
            [self detectFirefoxCrash];
            [self postFirefoxTerminationNotification];
            [self notifyGWorkspaceOfStateChange];
            
            if (shouldTerminateWhenFirefoxQuits) {
                [self performSelector:@selector(delayedTerminateAfterNotifications) 
                           withObject:nil 
                           afterDelay:0.1];
                return;
            }
        } else if (!wasFirefoxRunning && firefoxRunning) {
            // Firefox started
            [self postFirefoxLaunchNotification];
            [self notifyGWorkspaceOfStateChange];
        }
        
        wasFirefoxRunning = firefoxRunning;
    } else {
        stableStateCount++;
        [self optimizeMonitoringInterval];
    }
}

- (void)optimizeMonitoringInterval
{
    // Adjust monitoring frequency based on state stability
    if (stableStateCount > kStableStateThreshold) {
        NSTimeInterval currentInterval = [monitoringTimer timeInterval];
        NSTimeInterval newInterval = !isFirefoxRunning ? kSlowMonitoringInterval : kSlowMonitoringInterval;
        
        if (currentInterval != newInterval) {
            [monitoringTimer invalidate];
            monitoringTimer = [NSTimer scheduledTimerWithTimeInterval:newInterval
                                                               target:self
                                                             selector:@selector(smartFirefoxCheck:)
                                                             userInfo:nil
                                                              repeats:YES];
        }
        stableStateCount = 0;
    }
}

- (BOOL)shouldUseAggressiveMonitoring
{
    // Use aggressive monitoring during transitions or after crashes
    return firefoxCrashedRecently || 
           [[NSDate date] timeIntervalSinceDate:lastStateChangeTime] < 10.0;
}

#pragma mark - Window Management with Caching

- (NSArray *)getCachedWindowList
{
    NSDate *now = [NSDate date];
    
    if (lastWindowListUpdate && 
        [now timeIntervalSinceDate:lastWindowListUpdate] < windowListCacheTimeout &&
        [cachedWindowList count] > 0) {
        return cachedWindowList;
    }
    
    [self invalidateWindowListCache];
    
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
            [cachedWindowList removeAllObjects];
            [cachedWindowList addObjectsFromArray:lines];
            
            lastWindowListUpdate = [now retain];
            [output release];
        }
    NS_HANDLER
    NS_ENDHANDLER
    
    [listTask release];
    return cachedWindowList;
}

- (void)invalidateWindowListCache
{
    [cachedWindowList removeAllObjects];
    [lastWindowListUpdate release];
    lastWindowListUpdate = nil;
}

- (NSArray *)getFirefoxWindowIDs
{
    NSArray *lines = [self getCachedWindowList];
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
    
    return [firefoxWindowIDs autorelease];
}

- (BOOL)activateFirefoxWithWmctrl
{
    NSArray *firefoxWindowIDs = [self getFirefoxWindowIDs];
    BOOL success = NO;
    
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
                success = YES;
            }
        NS_HANDLER
        NS_ENDHANDLER
        
        [activateTask release];
    }
    
    return success;
}

- (void)activateFirefoxWindows
{
    [self activateFirefoxWithWmctrl];
}

#pragma mark - State Persistence

- (void)loadPersistentState
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    persistentState = [[NSMutableDictionary alloc] init];
    
    // Load previous state values
    id value = [defaults objectForKey:kFirefoxWasPreviouslyRunning];
    if (value) [persistentState setObject:value forKey:kFirefoxWasPreviouslyRunning];
    
    value = [defaults objectForKey:kDockIconWasVisible];
    if (value) [persistentState setObject:value forKey:kDockIconWasVisible];
    
    value = [defaults objectForKey:kLastShutdownTime];
    if (value) [persistentState setObject:value forKey:kLastShutdownTime];
}

- (void)savePersistentState
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    for (NSString *key in persistentState) {
        [defaults setObject:[persistentState objectForKey:key] forKey:key];
    }
    
    [defaults setObject:[NSDate date] forKey:kLastShutdownTime];
    [defaults synchronize];
}

- (void)updateStateValue:(id)value forKey:(NSString *)key
{
    if (value) {
        [persistentState setObject:value forKey:key];
    } else {
        [persistentState removeObjectForKey:key];
    }
}

- (id)getStateValueForKey:(NSString *)key
{
    return [persistentState objectForKey:key];
}

#pragma mark - System Event Handling (GNUstep Compatible)

- (void)registerForSystemEvents
{
    // Register for workspace notifications (GNUstep equivalent)
    [[[NSWorkspace sharedWorkspace] notificationCenter] 
        addObserver:self
        selector:@selector(handleSystemSleep:)
        name:NSWorkspaceWillSleepNotification
        object:nil];
    
    [[[NSWorkspace sharedWorkspace] notificationCenter] 
        addObserver:self
        selector:@selector(handleSystemWake:)
        name:NSWorkspaceDidWakeNotification
        object:nil];
}

- (void)handleSystemSleep:(NSNotification *)notification
{
    systemSleepDetected = YES;
    [self stopFirefoxMonitoring];
}

- (void)handleSystemWake:(NSNotification *)notification
{
    systemSleepDetected = NO;
    
    // Invalidate caches
    [self invalidateWindowListCache];
    
    // Restart monitoring with fresh state
    [self startSmartFirefoxMonitoring];
    
    // Verify and restore dock state
#if HAS_LIBDISPATCH
    // Use GCD if available (preferred)
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        [self ensureDockIconVisible];
    });
#else
    // Fallback to NSObject performSelector
    [self performSelector:@selector(ensureDockIconVisible) withObject:nil afterDelay:1.0];
#endif
}

#pragma mark - Edge Case Handling

- (void)detectFirefoxCrash
{
    // Check if Firefox quit unexpectedly (crashed)
    if (firefoxTask && [firefoxTask terminationStatus] != 0) {
        [self handleFirefoxCrash];
    }
}

- (void)handleFirefoxCrash
{
    firefoxCrashedRecently = YES;
    [lastCrashTime release];
    lastCrashTime = [[NSDate date] retain];
    
    // Schedule cleanup
    [self performSelector:@selector(cleanupAfterFirefoxCrash) withObject:nil afterDelay:1.0];
}

- (void)cleanupAfterFirefoxCrash
{
    // Clean up any zombie processes
    NSArray *remainingPIDs = [self getAllFirefoxProcessIDs];
    for (NSNumber *pidNumber in remainingPIDs) {
        pid_t pid = [pidNumber intValue];
        kill(pid, SIGTERM);
    }
    
    // Mark crash handling as complete after delay
    [self performSelector:@selector(clearCrashFlag) withObject:nil afterDelay:kCrashDetectionWindow];
}

- (void)clearCrashFlag
{
    firefoxCrashedRecently = NO;
}

- (BOOL)isRecentCrash
{
    if (!lastCrashTime) return NO;
    return [[NSDate date] timeIntervalSinceDate:lastCrashTime] < kCrashDetectionWindow;
}

#pragma mark - GWorkspace Integration Methods

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
        [self notifyGWorkspaceOfStateChange];
    } else {
        [self launchFirefox];
    }
}

- (void)hide:(id)sender
{
    NSArray *firefoxWindowIDs = [self getFirefoxWindowIDs];
    
    for (NSString *windowID in firefoxWindowIDs) {
        NSTask *minimizeTask = [[NSTask alloc] init];
        [minimizeTask setLaunchPath:@"/usr/local/bin/wmctrl"];
        [minimizeTask setArguments:@[@"-i", @"-b", @"add,hidden", windowID]];
        [minimizeTask setStandardOutput:[NSPipe pipe]];
        [minimizeTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [minimizeTask launch];
            [minimizeTask waitUntilExit];
        NS_HANDLER
        NS_ENDHANDLER
        
        [minimizeTask release];
    }
    
    [self notifyGWorkspaceOfStateChange];
}

- (void)unhideWithoutActivation
{
    NSArray *firefoxWindowIDs = [self getFirefoxWindowIDs];
    
    for (NSString *windowID in firefoxWindowIDs) {
        NSTask *unhideTask = [[NSTask alloc] init];
        [unhideTask setLaunchPath:@"/usr/local/bin/wmctrl"];
        [unhideTask setArguments:@[@"-i", @"-b", @"remove,hidden", windowID]];
        [unhideTask setStandardOutput:[NSPipe pipe]];
        [unhideTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [unhideTask launch];
            [unhideTask waitUntilExit];
        NS_HANDLER
        NS_ENDHANDLER
        
        [unhideTask release];
    }
    
    [self notifyGWorkspaceOfStateChange];
}

- (BOOL)isHidden
{
    NSArray *firefoxWindowIDs = [self getFirefoxWindowIDs];
    return [firefoxWindowIDs count] == 0;
}

- (void)terminate:(id)sender
{
    NSArray *firefoxPIDs = [self getAllFirefoxProcessIDs];
    
    if ([firefoxPIDs count] > 0) {
        // Try graceful termination first
        NSTask *quitTask = [[NSTask alloc] init];
        [quitTask setLaunchPath:@"/usr/local/bin/wmctrl"];
        [quitTask setArguments:@[@"-c", @"Firefox"]];
        [quitTask setStandardOutput:[NSPipe pipe]];
        [quitTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [quitTask launch];
            [quitTask waitUntilExit];
        NS_HANDLER
        NS_ENDHANDLER
        
        [quitTask release];
        
        // Wait for graceful quit, then force if necessary
        if ([self waitForFirefoxToQuit:5.0]) {
            [NSApp terminate:self];
        } else {
            // Force termination
            NSArray *remainingPIDs = [self getAllFirefoxProcessIDs];
            for (NSNumber *pidNumber in remainingPIDs) {
                pid_t pid = [pidNumber intValue];
                kill(pid, SIGTERM);
            }
            
            if (![self waitForFirefoxToQuit:2.0]) {
                remainingPIDs = [self getAllFirefoxProcessIDs];
                for (NSNumber *pidNumber in remainingPIDs) {
                    pid_t pid = [pidNumber intValue];
                    kill(pid, SIGKILL);
                }
            }
            
            [self scheduleFirefoxTerminationCheck];
        }
    } else {
        [NSApp terminate:self];
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

#pragma mark - File Handling

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
    [self openFileInFirefox:filename activate:YES];
    return YES;
}

- (BOOL)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename
{
    [self openFileInFirefox:filename activate:NO];
    return YES;
}

- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate
{
    if (![self isFirefoxCurrentlyRunning]) {
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
            
            if (shouldActivate) {
                [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
            }
        NS_HANDLER
            [firefoxTask release];
            firefoxTask = nil;
        NS_ENDHANDLER
        
    } else {
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
        NS_ENDHANDLER
        
        [openTask release];
    }
}

#pragma mark - Notification System

- (void)postFirefoxLaunchNotification
{
    NSDictionary *launchInfo = @{
        @"NSApplicationName": @"Firefox",
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:NSWorkspaceDidLaunchApplicationNotification
                      object:[NSWorkspace sharedWorkspace]
                    userInfo:launchInfo];
}

- (void)postFirefoxTerminationNotification
{
    NSDictionary *terminationInfo = @{
        @"NSApplicationName": @"Firefox",
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:NSWorkspaceDidTerminateApplicationNotification
                      object:[NSWorkspace sharedWorkspace]
                    userInfo:terminationInfo];
}

- (void)notifyGWorkspaceOfStateChange
{
    NSDictionary *userInfo = @{
        @"NSApplicationName": @"Firefox",
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    
    if ([self isHidden]) {
        [nc postNotificationName:NSApplicationDidHideNotification 
                          object:NSApp 
                        userInfo:userInfo];
    } else {
        [nc postNotificationName:NSApplicationDidUnhideNotification 
                          object:NSApp 
                        userInfo:userInfo];
    }
}

#pragma mark - Memory Management

- (void)handleInitialFirefoxState
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
}

- (void)delayedTerminateAfterNotifications
{
    [self stopFirefoxMonitoring];
    [NSApp terminate:self];
}

- (void)delayedTerminate
{
    [NSApp terminate:self];
}

- (BOOL)waitForFirefoxToQuit:(NSTimeInterval)timeout
{
    NSDate *startTime = [NSDate date];
    
    while ([[NSDate date] timeIntervalSinceDate:startTime] < timeout) {
        if (![self isFirefoxCurrentlyRunning]) {
            return YES;
        }
        usleep(100000); // 0.1 second
    }
    
    return NO;
}

- (void)scheduleFirefoxTerminationCheck
{
    [self performSelector:@selector(finalTerminationCheck) withObject:nil afterDelay:1.0];
}

- (void)finalTerminationCheck
{
    if (![self isFirefoxCurrentlyRunning]) {
        [NSApp terminate:self];
    } else {
        [self performSelector:@selector(finalTerminationCheck) withObject:nil afterDelay:1.0];
    }
}

- (void)waitForFirefoxToStart
{
    NSArray *firefoxWindowIDs = [self getFirefoxWindowIDs];
    
    if ([firefoxWindowIDs count] > 0) {
        [self activateFirefoxWindows];
    } else {
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
    }
}

- (void)handleFirefoxTermination:(NSNotification *)notification
{
    NSTask *task = [notification object];
    
    if (task == firefoxTask) {
        [self postFirefoxTerminationNotification];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
        isFirefoxRunning = NO;
    }
}

#pragma mark - Missing Method Implementations

- (void)checkForRemainingFirefoxProcesses
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self performSelector:@selector(checkForRemainingFirefoxProcesses) 
                   withObject:nil 
                   afterDelay:0.5];
    } else {
        [NSApp terminate:self];
    }
}

- (BOOL)registerServiceWithRetry
{
    // Implementation of service registration with retry logic
    return [self establishServiceConnection];
}

- (void)handleDisplayReconfiguration
{
    // Handle display configuration changes
    [self invalidateWindowListCache];
    [self performSelector:@selector(ensureDockIconVisible) withObject:nil afterDelay:0.5];
}

- (void)scheduleDelayedCleanup
{
    // Schedule cleanup operations
    [self performSelector:@selector(cleanupAfterFirefoxCrash) withObject:nil afterDelay:2.0];
}

- (void)adjustTimersForSystemLoad
{
    // Adjust timer intervals based on system load
    // For GNUstep, we'll use simple load detection
    [self optimizeMonitoringInterval];
}

- (void)scheduleOperation:(SEL)selector withDelay:(NSTimeInterval)delay
{
    // Generic method to schedule operations with delay
    [self performSelector:selector withObject:nil afterDelay:delay];
}

- (void)dealloc
{
    [self stopFirefoxMonitoring];
    [self invalidateServiceConnection];
    
    [firefoxExecutablePath release];
    [lastStateChangeTime release];
    [persistentState release];
    [cachedWindowList release];
    [lastWindowListUpdate release];
    [lastCrashTime release];
    
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
    }
    
    [super dealloc];
}

@end
