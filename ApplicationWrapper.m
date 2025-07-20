#import "ApplicationWrapper.h"
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <sys/event.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>

static const NSTimeInterval kWindowListCacheTimeout = 1.0;

@implementation ApplicationWrapper

@synthesize applicationName;
@synthesize serviceName;
@synthesize windowSearchString;
@synthesize bundleIdentifier;
@synthesize trackedPIDs;

- (id)init
{
    NSDictionary *defaultConfig = @{
        @"applicationName": @APPLICATION_NAME,
        @"executablePath": @EXECUTABLE_PATH,
        @"serviceName": @SERVICE_NAME,
        @"windowSearchString": @WINDOW_SEARCH_STRING,
        @"bundleIdentifier": @BUNDLE_IDENTIFIER
    };
    
    return [self initWithConfiguration:defaultConfig];
}

- (id)initWithConfiguration:(NSDictionary *)config
{
    self = [super init];
    if (self) {
        applicationExecutablePath = [[config objectForKey:@"executablePath"] retain];
        applicationTask = nil;
        
        applicationPID = 0;
        terminationInProgress = NO;
        
        procMonitorSource = NULL;
        monitorQueue = dispatch_queue_create("application.monitor", DISPATCH_QUEUE_SERIAL);
        
        kqueueFD = -1;
        kqueueThread = nil;
        
        connectionEstablished = NO;
        isPrimaryInstance = NO;
        
        dockIconVisible = NO;
        isTransformingProcess = NO;
        
        cachedWindowList = [[NSMutableArray alloc] init];
        lastWindowListUpdate = nil;
        
        systemSleepDetected = NO;
        
        self.applicationName = [config objectForKey:@"applicationName"];
        self.serviceName = [config objectForKey:@"serviceName"];
        self.windowSearchString = [config objectForKey:@"windowSearchString"];
        self.bundleIdentifier = [config objectForKey:@"bundleIdentifier"];
        
        self.trackedPIDs = [NSMutableSet set];
        primaryLaunchedPID = 0;
        
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
    
    [self postApplicationLaunchNotification];
    
    NSString *iconPath = [[NSBundle mainBundle] pathForResource:self.applicationName ofType:@"png"];
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
    [self performSelector:@selector(handleInitialApplicationState) withObject:nil afterDelay:0.1];
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    if ([self isApplicationCurrentlyRunning]) {
        [self activateApplicationWindows];
    } else {
        [self launchApplication];
    }
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if (terminationInProgress) {
        return NSTerminateNow;
    }
    
    if ([self isApplicationCurrentlyRunning]) {
        return NSTerminateCancel;
    }
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self stopEventDrivenMonitoring];
    [self invalidateServiceConnection];
    
    if (applicationTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:applicationTask];
        [applicationTask release];
        applicationTask = nil;
    }
}

- (BOOL)establishSingleInstance
{
    NSConnection *connection = [NSConnection defaultConnection];
    [connection setRootObject:self];
    
    isPrimaryInstance = [connection registerName:self.serviceName];
    
    if (!isPrimaryInstance) {
        NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:self.serviceName host:nil];
        if (existingConnection) {
            id<ApplicationWrapperProtocol> existingLauncher = (id<ApplicationWrapperProtocol>)[existingConnection rootProxy];
            if (existingLauncher) {
                NS_DURING
                    BOOL isRunning = [existingLauncher isRunning];
                    (void)isRunning;
                    return NO;
                NS_HANDLER
                    isPrimaryInstance = [connection registerName:self.serviceName];
                NS_ENDHANDLER
            }
        }
    }
    
    return isPrimaryInstance;
}

- (void)delegateToExistingInstance
{
    NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:self.serviceName host:nil];
    if (existingConnection) {
        id<ApplicationWrapperProtocol> existingLauncher = (id<ApplicationWrapperProtocol>)[existingConnection rootProxy];
        if (existingLauncher) {
            NS_DURING
                [existingLauncher activateIgnoringOtherApps:YES];
            NS_HANDLER
            NS_ENDHANDLER
        }
    }
}

- (void)launchApplication
{
    [self launchApplicationWithArgs:@[]];
}

- (void)launchApplicationWithArgs:(NSArray *)arguments
{
    if ([self isApplicationCurrentlyRunning]) {
        [self activateApplicationWindows];
        return;
    }
    
    if (applicationTask && [applicationTask isRunning]) {
        [self activateApplicationWindows];
        return;
    }
    
    [self.trackedPIDs removeAllObjects];
    primaryLaunchedPID = 0;
    
    [self postApplicationLaunchNotification];
    
    applicationTask = [[NSTask alloc] init];
    [applicationTask setLaunchPath:applicationExecutablePath];
    [applicationTask setArguments:arguments];
    
    NSMutableDictionary *environment = [[[NSProcessInfo processInfo] environment] mutableCopy];
    [applicationTask setEnvironment:environment];
    [environment release];
    
    [[NSNotificationCenter defaultCenter] 
        addObserver:self 
        selector:@selector(handleApplicationTermination:) 
        name:NSTaskDidTerminateNotification 
        object:applicationTask];
    
    NS_DURING
        [applicationTask launch];
        applicationPID = [applicationTask processIdentifier];
        primaryLaunchedPID = applicationPID;
        [self trackPID:applicationPID];
        
        [self startEventDrivenMonitoring:applicationPID];
        
        [self performSelector:@selector(discoverChildProcesses) withObject:nil afterDelay:2.0];
        [self performSelector:@selector(waitForApplicationToStart) withObject:nil afterDelay:0.5];
        
    NS_HANDLER
        applicationPID = 0;
        primaryLaunchedPID = 0;
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:applicationTask];
        [applicationTask release];
        applicationTask = nil;
        
        NSAlert *alert = [[NSAlert alloc] init];
        [alert setMessageText:[NSString stringWithFormat:@"%@ Launch Error", self.applicationName]];
        [alert setInformativeText:[NSString stringWithFormat:@"Could not launch %@ from %@. Please check that %@ is installed.", self.applicationName, applicationExecutablePath, self.applicationName]];
        [alert addButtonWithTitle:@"OK"];
        [alert runModal];
        [alert release];
        
        [NSApp terminate:self];
    NS_ENDHANDLER
}

- (NSArray *)getChildProcesses:(pid_t)parentPID
{
    int mib[4];
    size_t size;
    struct kinfo_proc *procs;
    int nprocs;
    NSMutableArray *children = [[NSMutableArray alloc] init];
    
    mib[0] = CTL_KERN;
    mib[1] = KERN_PROC;
    mib[2] = KERN_PROC_PROC;
    mib[3] = 0;
    
    if (sysctl(mib, 4, NULL, &size, NULL, 0) < 0) {
        return [children autorelease];
    }
    
    procs = malloc(size);
    if (procs == NULL) {
        return [children autorelease];
    }
    
    if (sysctl(mib, 4, procs, &size, NULL, 0) < 0) {
        free(procs);
        return [children autorelease];
    }
    
    nprocs = size / sizeof(struct kinfo_proc);
    
    for (int i = 0; i < nprocs; i++) {
        if (procs[i].ki_ppid == parentPID) {
            [children addObject:@(procs[i].ki_pid)];
        }
    }
    
    free(procs);
    return [children autorelease];
}

- (void)trackPID:(pid_t)pid
{
    [self.trackedPIDs addObject:@(pid)];
}

- (void)untrackPID:(pid_t)pid
{
    [self.trackedPIDs removeObject:@(pid)];
}

- (void)discoverChildProcesses
{
    if (primaryLaunchedPID > 0) {
        NSArray *children = [self getChildProcesses:primaryLaunchedPID];
        for (NSNumber *childPID in children) {
            [self trackPID:[childPID intValue]];
        }
    }
}

- (BOOL)isApplicationCurrentlyRunning 
{
    for (NSNumber *pidNumber in [self.trackedPIDs copy]) {
        pid_t pid = [pidNumber intValue];
        if (kill(pid, 0) == 0) {
            return YES;
        } else {
            [self untrackPID:pid];
        }
    }
    return NO;
}

- (void)startEventDrivenMonitoring:(pid_t)applicationProcessID
{
    if (terminationInProgress) return;
    
    applicationPID = applicationProcessID;
    
    [self setupKqueueChildTracking:applicationPID];
    
    [self setupGCDProcessMonitoring:applicationPID];
    
    [self performSelector:@selector(checkApplicationStatus) withObject:nil afterDelay:2.0];
}

- (void)stopEventDrivenMonitoring
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(checkApplicationStatus) object:nil];
    
    [self cleanupGCDMonitoring];
    
    [self stopKqueueMonitoring];
}

- (void)applicationProcessExited:(int)exitStatus
{
    if (terminationInProgress) return;
    
    if (![self isApplicationCurrentlyRunning]) {
        [self postApplicationTerminationNotification];
        
        if ([NSThread isMainThread]) {
            [self initiateWrapperTermination];
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self initiateWrapperTermination];
            });
        }
    } else {
        [self performSelector:@selector(checkApplicationStatus) withObject:nil afterDelay:1.0];
    }
}

- (void)checkApplicationStatus
{
    if (terminationInProgress) return;
    
    if (applicationPID > 0) {
        if (kill(applicationPID, 0) == -1 && errno == ESRCH) {
            [self untrackPID:applicationPID];
        }
    }
    
    if (![self isApplicationCurrentlyRunning]) {
        [self applicationProcessExited:0];
        return;
    }
    
    [self performSelector:@selector(checkApplicationStatus) withObject:nil afterDelay:3.0];
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
            [self untrackPID:pid];
            if (![self isApplicationCurrentlyRunning]) {
                [self applicationProcessExited:0];
            }
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
                [self applicationProcessExited:(int)event.data];
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

- (void)handleApplicationTermination:(NSNotification *)notification
{
    NSTask *task = [notification object];
    
    if (task == applicationTask) {
        int exitStatus = [task terminationStatus];
        
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:applicationTask];
        [applicationTask release];
        applicationTask = nil;
        applicationPID = 0;
        
        [self applicationProcessExited:exitStatus];
    }
}

- (void)ensureDockIconVisible
{
    if (dockIconVisible || isTransformingProcess) {
        return;
    }
    
    isTransformingProcess = YES;
    [self updateDockIconState:YES];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        [self completeTransformationProcess];
    });
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
    connectionEstablished = NO;
}

- (NSArray *)getCachedWindowList
{
    NSDate *now = [NSDate date];
    
    if (lastWindowListUpdate && 
        [now timeIntervalSinceDate:lastWindowListUpdate] < kWindowListCacheTimeout &&
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

- (NSArray *)getApplicationWindowIDs
{
    NSArray *lines = [self getCachedWindowList];
    NSMutableArray *applicationWindowIDs = [[NSMutableArray alloc] init];
    
    for (NSString *line in lines) {
        if ([line length] > 0) {
            NSRange appRange = [line rangeOfString:self.windowSearchString options:NSCaseInsensitiveSearch];
            
            if (appRange.location != NSNotFound) {
                NSArray *components = [line componentsSeparatedByString:@" "];
                if ([components count] > 0) {
                    NSString *windowID = [components objectAtIndex:0];
                    [applicationWindowIDs addObject:windowID];
                }
            }
        }
    }
    
    return [applicationWindowIDs autorelease];
}

- (BOOL)activateApplicationWithWmctrl
{
    NSArray *applicationWindowIDs = [self getApplicationWindowIDs];
    BOOL success = NO;
    
    for (NSString *windowID in applicationWindowIDs) {
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

- (void)activateApplicationWindows
{
    [self activateApplicationWithWmctrl];
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
    
    if (applicationPID > 0) {
        [self startEventDrivenMonitoring:applicationPID];
    }
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1.0 * NSEC_PER_SEC), 
                   dispatch_get_main_queue(), ^{
        [self ensureDockIconVisible];
    });
}

- (void)activateIgnoringOtherApps:(BOOL)flag
{
    if ([self isApplicationCurrentlyRunning]) {
        [self activateApplicationWindows];
        [self notifyGWorkspaceOfStateChange];
    } else {
        [self launchApplication];
    }
}

- (void)hide:(id)sender
{
    NSArray *applicationWindowIDs = [self getApplicationWindowIDs];
    
    for (NSString *windowID in applicationWindowIDs) {
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
    NSArray *applicationWindowIDs = [self getApplicationWindowIDs];
    
    for (NSString *windowID in applicationWindowIDs) {
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
    NSArray *applicationWindowIDs = [self getApplicationWindowIDs];
    return [applicationWindowIDs count] == 0;
}

- (void)terminate:(id)sender
{
    if ([self isApplicationCurrentlyRunning]) {
        NSTask *quitTask = [[NSTask alloc] init];
        [quitTask setLaunchPath:@"/usr/local/bin/wmctrl"];
        [quitTask setArguments:@[@"-c", self.windowSearchString]];
        [quitTask setStandardOutput:[NSPipe pipe]];
        [quitTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [quitTask launch];
            [quitTask waitUntilExit];
        NS_HANDLER
        NS_ENDHANDLER
        
        [quitTask release];
        
        if ([self waitForApplicationToQuit:5.0]) {
            [self initiateWrapperTermination];
        } else {
            for (NSNumber *pidNumber in [self.trackedPIDs copy]) {
                pid_t pid = [pidNumber intValue];
                kill(pid, SIGTERM);
            }
            
            if (![self waitForApplicationToQuit:2.0]) {
                for (NSNumber *pidNumber in [self.trackedPIDs copy]) {
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
    return [self isApplicationCurrentlyRunning];
}

- (NSNumber *)processIdentifier
{
    if (applicationTask && [applicationTask isRunning]) {
        return @([applicationTask processIdentifier]);
    }
    return nil;
}

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename
{
    [self openFileInApplication:filename activate:YES];
    return YES;
}

- (BOOL)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename
{
    [self openFileInApplication:filename activate:NO];
    return YES;
}

- (void)openFileInApplication:(NSString *)filename activate:(BOOL)shouldActivate
{
    if (![self isApplicationCurrentlyRunning]) {
        [self launchApplicationWithArgs:@[filename]];
    } else {
        NSTask *openTask = [[NSTask alloc] init];
        [openTask setLaunchPath:applicationExecutablePath];
        [openTask setArguments:@[@"-remote", [NSString stringWithFormat:@"openURL(%@,new-tab)", filename]]];
        [openTask setStandardOutput:[NSPipe pipe]];
        [openTask setStandardError:[NSPipe pipe]];
        
        NS_DURING
            [openTask launch];
            [openTask waitUntilExit];
            
            if (shouldActivate) {
                [self activateApplicationWindows];
            }
        NS_HANDLER
        NS_ENDHANDLER
        
        [openTask release];
    }
}

- (void)postApplicationLaunchNotification
{
    NSDictionary *launchInfo = @{
        @"NSApplicationName": self.applicationName,
        @"NSApplicationPath": [[NSBundle mainBundle] bundlePath]
    };
    
    [[NSNotificationCenter defaultCenter] 
        postNotificationName:NSWorkspaceDidLaunchApplicationNotification
                      object:[NSWorkspace sharedWorkspace]
                    userInfo:launchInfo];
}

- (void)postApplicationTerminationNotification
{
    NSDictionary *terminationInfo = @{
        @"NSApplicationName": self.applicationName,
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
        @"NSApplicationName": self.applicationName,
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

- (void)handleInitialApplicationState
{
    if ([self isApplicationCurrentlyRunning]) {
        [self activateApplicationWindows];
    } else {
        [self launchApplication];
    }
}

- (BOOL)waitForApplicationToQuit:(NSTimeInterval)timeout
{
    NSDate *startTime = [NSDate date];
    
    while ([[NSDate date] timeIntervalSinceDate:startTime] < timeout) {
        if (![self isApplicationCurrentlyRunning]) {
            return YES;
        }
        usleep(100000);
    }
    
    return NO;
}

- (void)waitForApplicationToStart
{
    NSArray *applicationWindowIDs = [self getApplicationWindowIDs];
    
    if ([applicationWindowIDs count] > 0) {
        [self activateApplicationWindows];
    } else {
        [self performSelector:@selector(waitForApplicationToStart) withObject:nil afterDelay:0.5];
    }
}

- (void)dealloc
{
    [self stopEventDrivenMonitoring];
    [self invalidateServiceConnection];
    
    [applicationExecutablePath release];
    [cachedWindowList release];
    [lastWindowListUpdate release];
    [applicationName release];
    [serviceName release];
    [windowSearchString release];
    [bundleIdentifier release];
    [trackedPIDs release];
    
    if (applicationTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:applicationTask];
        [applicationTask release];
    }
    
    if (monitorQueue) {
        dispatch_release(monitorQueue);
    }
    
    [super dealloc];
}

@end
