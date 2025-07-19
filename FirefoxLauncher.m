#import "FirefoxLauncher.h"
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <sys/event.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>

#ifndef HAS_LIBDISPATCH
#define HAS_LIBDISPATCH 0
#endif

static const NSTimeInterval kWindowListCacheTimeout = 1.0;

@implementation FirefoxLauncher

- (id)init
{
    self = [super init];
    if (self) {
        firefoxExecutablePath = [@"/usr/local/bin/firefox" retain];
        isFirefoxRunning = NO;
        firefoxTask = nil;
        serviceConnection = nil;
        
        firefoxPID = 0;
        terminationInProgress = NO;
        
#if HAS_LIBDISPATCH
        procMonitorSource = NULL;
        monitorQueue = dispatch_queue_create("firefox.monitor", DISPATCH_QUEUE_SERIAL);
#endif
        
        kqueueFD = -1;
        kqueueThread = nil;
        
        connectionEstablished = NO;
        isPrimaryInstance = NO;
        
        dockIconVisible = NO;
        isTransformingProcess = NO;
        
        cachedWindowList = [[NSMutableArray alloc] init];
        lastWindowListUpdate = nil;
        windowListCacheTimeout = kWindowListCacheTimeout;
        
        systemSleepDetected = NO;
        
        [self registerForSystemEvents];
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
    if (![self establishSingleInstance]) {
        [self delegateToExistingInstance];
        [NSApp terminate:self];
        return;
    }
    
    if (![self establishServiceConnection]) {
    }
    
    [self ensureDockIconVisible];
    
    [self postFirefoxLaunchNotification];
    
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
    [self performSelector:@selector(handleInitialFirefoxState) withObject:nil afterDelay:0.1];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if (terminationInProgress) {
        return NSTerminateNow;
    }
    
    if ([self isFirefoxCurrentlyRunning]) {
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self stopEventDrivenMonitoring];
    [self invalidateServiceConnection];
    
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
    }
}

- (BOOL)establishSingleInstance
{
    NSConnection *connection = [NSConnection defaultConnection];
    [connection setRootObject:self];
    
    isPrimaryInstance = [connection registerName:@"Firefox"];
    
    if (!isPrimaryInstance) {
        NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:@"Firefox" host:nil];
        if (existingConnection) {
            id<FirefoxLauncherProtocol> existingLauncher = (id<FirefoxLauncherProtocol>)[existingConnection rootProxy];
            if (existingLauncher) {
                NS_DURING
                    BOOL isRunning = [existingLauncher isRunning];
                    (void)isRunning;
                    return NO;
                NS_HANDLER
                    isPrimaryInstance = [connection registerName:@"Firefox"];
                NS_ENDHANDLER
            }
        }
    }
    
    return isPrimaryInstance;
}

- (void)delegateToExistingInstance
{
    NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:@"Firefox" host:nil];
    if (existingConnection) {
        id<FirefoxLauncherProtocol> existingLauncher = (id<FirefoxLauncherProtocol>)[existingConnection rootProxy];
        if (existingLauncher) {
            NS_DURING
                [existingLauncher activateIgnoringOtherApps:YES];
            NS_HANDLER
            NS_ENDHANDLER
        }
    }
}

- (void)launchFirefox
{
    [self launchFirefoxWithArgs:@[]];
}

- (void)launchFirefoxWithArgs:(NSArray *)arguments
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
        return;
    }
    
    if (firefoxTask && [firefoxTask isRunning]) {
        [self activateFirefoxWindows];
        return;
    }
    
    [self postFirefoxLaunchNotification];
    
    firefoxTask = [[NSTask alloc] init];
    [firefoxTask setLaunchPath:firefoxExecutablePath];
    [firefoxTask setArguments:arguments];
    
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
        firefoxPID = [firefoxTask processIdentifier];
        
        [self startEventDrivenMonitoring:firefoxPID];
        
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
        
    NS_HANDLER
        isFirefoxRunning = NO;
        firefoxPID = 0;
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
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

- (void)startEventDrivenMonitoring:(pid_t)firefoxProcessID
{
    if (terminationInProgress) return;
    
    firefoxPID = firefoxProcessID;
    
    [self setupKqueueChildTracking:firefoxPID];
    
#if HAS_LIBDISPATCH
    [self setupGCDProcessMonitoring:firefoxPID];
#endif
    
    [self performSelector:@selector(checkFirefoxStatus) withObject:nil afterDelay:2.0];
}

- (void)stopEventDrivenMonitoring
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkFirefoxStatus) object:nil];
    
#if HAS_LIBDISPATCH
    [self cleanupGCDMonitoring];
#endif
    
    [self stopKqueueMonitoring];
}

- (void)firefoxProcessExited:(int)exitStatus
{
    if (terminationInProgress) return;
    
    if (![self isFirefoxCurrentlyRunning]) {
        [self postFirefoxTerminationNotification];
        
        if ([NSThread isMainThread]) {
            [self initiateWrapperTermination];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self initiateWrapperTermination];
            });
        }
    } else {
        [self performSelector:@selector(checkFirefoxStatus) withObject:nil afterDelay:1.0];
    }
}

- (void)checkFirefoxStatus
{
    if (terminationInProgress) return;
    
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/test-firefox-wrapper-termination"]) {
        [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/test-firefox-wrapper-termination" error:nil];
        [self testTermination];
        return;
    }
    
    if (firefoxPID > 0) {
        if (kill(firefoxPID, 0) == -1 && errno == ESRCH) {
            [self firefoxProcessExited:0];
            return;
        }
    }
    
    NSArray *firefoxPIDs = [self getAllFirefoxProcessIDs];
    
    if ([firefoxPIDs count] == 0) {
        [self firefoxProcessExited:0];
        return;
    }
    
    [self performSelector:@selector(checkFirefoxStatus) withObject:nil afterDelay:3.0];
}

- (void)initiateWrapperTermination
{
    if (terminationInProgress) return;
    
    terminationInProgress = YES;
    
    [self stopEventDrivenMonitoring];
    
    if (![NSThread isMainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [NSApp terminate:self];
        });
    } else {
        [NSApp terminate:self];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2.0 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        exit(0);
    });
}

- (void)emergencyExit
{
    exit(0);
}

#if HAS_LIBDISPATCH
- (void)setupGCDProcessMonitoring:(pid_t)pid
{
    if (procMonitorSource) {
        dispatch_source_cancel(procMonitorSource);
        procMonitorSource = NULL;
    }
    
    procMonitorSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, pid,
                                              DISPATCH_PROC_EXIT, monitorQueue);
    
    if (!procMonitorSource) {
        return;
    }
    
    dispatch_source_set_event_handler(procMonitorSource, ^{
        uint32_t flags = dispatch_source_get_data(procMonitorSource);
        
        if (flags & DISPATCH_PROC_EXIT) {
            [self firefoxProcessExited:0];
        }
    });
    
    dispatch_source_set_cancel_handler(procMonitorSource, ^{
        procMonitorSource = NULL;
    });
    
    dispatch_resume(procMonitorSource);
}

- (void)cleanupGCDMonitoring
{
    if (procMonitorSource) {
        dispatch_source_cancel(procMonitorSource);
        procMonitorSource = NULL;
    }
}
#endif

- (void)setupKqueueChildTracking:(pid_t)parentPID
{
    [self stopKqueueMonitoring];
    
    kqueueFD = kqueue();
    if (kqueueFD == -1) {
        return;
    }
    
    struct kevent event;
    EV_SET(&event, parentPID, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT,
           NOTE_EXIT, 0, NULL);
    
    if (kevent(kqueueFD, &event, 1, NULL, 0, NULL) == -1) {
        close(kqueueFD);
        kqueueFD = -1;
        return;
    }
    
    kqueueThread = [[NSThread alloc] initWithTarget:self 
                                            selector:@selector(kqueueMonitoringThread:) 
                                              object:@(parentPID)];
    [kqueueThread start];
}

- (void)kqueueMonitoringThread:(id)arg
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    pid_t parentPID = [(NSNumber *)arg intValue];
    
    struct kevent event;
    while (!terminationInProgress) {
        int nev = kevent(kqueueFD, NULL, 0, &event, 1, NULL);
        
        if (nev == -1) {
            if (errno == EINTR) continue;
            break;
        }
        
        if (nev > 0) {
            if (event.fflags & NOTE_EXIT && (pid_t)event.ident == parentPID) {
                [self firefoxProcessExited:(int)event.data];
                break;
            }
        }
    }
    
    [pool release];
}

- (void)stopKqueueMonitoring
{
    if (kqueueThread) {
        [kqueueThread release];
        kqueueThread = nil;
    }
    
    if (kqueueFD != -1) {
        close(kqueueFD);
        kqueueFD = -1;
    }
}

- (void)handleFirefoxTermination:(NSNotification *)notification
{
    NSTask *task = [notification object];
    
    if (task == firefoxTask) {
        int exitStatus = [task terminationStatus];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
        firefoxTask = nil;
        isFirefoxRunning = NO;
        firefoxPID = 0;
        
        [self firefoxProcessExited:exitStatus];
    }
}

- (void)ensureDockIconVisible
{
    if (dockIconVisible || isTransformingProcess) {
        return;
    }
    
    isTransformingProcess = YES;
    [self updateDockIconState:YES];
    
#if HAS_LIBDISPATCH
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        [self completeTransformationProcess];
    });
#else
    [self performSelector:@selector(completeTransformationProcess) withObject:nil afterDelay:0.1];
#endif
}

- (void)ensureDockIconHidden
{
    if (!dockIconVisible || isTransformingProcess) {
        return;
    }
    
    isTransformingProcess = YES;
    [self updateDockIconState:NO];
    
#if HAS_LIBDISPATCH
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        [self completeTransformationProcess];
    });
#else
    [self performSelector:@selector(completeTransformationProcess) withObject:nil afterDelay:0.1];
#endif
}

- (void)updateDockIconState:(BOOL)visible
{
    if (visible) {
        [NSApp activateIgnoringOtherApps:YES];
        dockIconVisible = YES;
    } else {
        [NSApp hide:self];
        dockIconVisible = NO;
    }
}

- (void)completeTransformationProcess
{
    isTransformingProcess = NO;
}

- (BOOL)isDockIconCurrentlyVisible
{
    return dockIconVisible && ![NSApp isHidden];
}

- (BOOL)establishServiceConnection
{
    if (connectionEstablished) {
        return YES;
    }
    
    connectionEstablished = isPrimaryInstance;
    return connectionEstablished;
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

- (void)registerForSystemEvents
{
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
    [self stopEventDrivenMonitoring];
}

- (void)handleSystemWake:(NSNotification *)notification
{
    systemSleepDetected = NO;
    [self invalidateWindowListCache];
    
    if (firefoxPID > 0) {
        [self startEventDrivenMonitoring:firefoxPID];
    }
    
#if HAS_LIBDISPATCH
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        [self ensureDockIconVisible];
    });
#else
    [self performSelector:@selector(ensureDockIconVisible) withObject:nil afterDelay:1.0];
#endif
}

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
        
        if ([self waitForFirefoxToQuit:5.0]) {
            [self initiateWrapperTermination];
        } else {
            for (NSNumber *pidNumber in firefoxPIDs) {
                pid_t pid = [pidNumber intValue];
                kill(pid, SIGTERM);
            }
            
            if (![self waitForFirefoxToQuit:2.0]) {
                for (NSNumber *pidNumber in firefoxPIDs) {
                    pid_t pid = [pidNumber intValue];
                    kill(pid, SIGKILL);
                }
            }
            
            [self initiateWrapperTermination];
        }
    } else {
        [self initiateWrapperTermination];
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
        [self launchFirefoxWithArgs:@[filename]];
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

- (void)handleInitialFirefoxState
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
}

- (void)testTermination
{
    if (![self isFirefoxCurrentlyRunning]) {
        [self firefoxProcessExited:0];
    }
}

- (BOOL)waitForFirefoxToQuit:(NSTimeInterval)timeout
{
    NSDate *startTime = [NSDate date];
    
    while ([[NSDate date] timeIntervalSinceDate:startTime] < timeout) {
        if (![self isFirefoxCurrentlyRunning]) {
            return YES;
        }
        usleep(100000);
    }
    
    return NO;
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

- (void)dealloc
{
    [self stopEventDrivenMonitoring];
    [self invalidateServiceConnection];
    
    [firefoxExecutablePath release];
    [cachedWindowList release];
    [lastWindowListUpdate release];
    
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
    }
    
#if HAS_LIBDISPATCH
    if (monitorQueue) {
        dispatch_release(monitorQueue);
    }
#endif
    
    [super dealloc];
}

@end
