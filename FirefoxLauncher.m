#import "FirefoxLauncher.h"
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <signal.h>

@implementation FirefoxLauncher

- (id)init
{
    self = [super init];
    if (self) {
        firefoxExecutablePath = @"/usr/local/bin/firefox";
        isFirefoxRunning = NO;
        firefoxTask = nil;
        serviceConnection = nil;
        monitoringTimer = nil;
        shouldTerminateWhenFirefoxQuits = YES;
        
        // Initialize monitoring state variables
        wasFirefoxRunning = NO;
        isFirstMonitoringRun = YES;
        stableStateCount = 0;
    }
    return self;
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

- (void)startSmartFirefoxMonitoring
{
    [self stopFirefoxMonitoring];
    
    // Reset monitoring state to ensure clean state on each start
    wasFirefoxRunning = NO;
    isFirstMonitoringRun = YES;
    stableStateCount = 0;
    
    NSTimeInterval interval = 0.5;
    
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
    
    if (wasFirefoxRunning != firefoxRunning) {
        stableStateCount = 0;
        
        if (wasFirefoxRunning && !firefoxRunning) {
            [self postFirefoxTerminationNotification];
            
            if (shouldTerminateWhenFirefoxQuits) {
                [timer invalidate];
                monitoringTimer = nil;
                [NSApp terminate:self];
                return;
            }
        } else if (!wasFirefoxRunning && firefoxRunning) {
            [self postFirefoxLaunchNotification];
        }
        
        wasFirefoxRunning = firefoxRunning;
        stableStateCount = 0;
    } else {
        stableStateCount++;
        
        if (stableStateCount > 10) {
            [timer invalidate];
            monitoringTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                               target:self
                                                             selector:@selector(smartFirefoxCheck:)
                                                             userInfo:nil
                                                              repeats:YES];
            stableStateCount = 0;
        }
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

- (void)applicationWillFinishLaunching:(NSNotification *)notification
{
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
    
    if (![serviceConnection registerName:appName]) {
        [NSApp terminate:self];
        return;
    }
}

- (void)retryServiceRegistration
{
    NSString *appName = @"Firefox";
    
    if (![serviceConnection registerName:appName]) {
        // If it still fails after waiting, terminate
        [NSApp terminate:self];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    [self startSmartFirefoxMonitoring];
    
    [self performSelector:@selector(handleInitialFirefoxState) withObject:nil afterDelay:0.1];
}

- (void)activateFirefoxAndExit
{
    [self activateFirefoxWindows];
    // Small delay to ensure activation completes before terminating
    [self performSelector:@selector(terminate:) withObject:self afterDelay:0.2];
}

- (void)handleInitialFirefoxState
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
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
            
            [firefoxWindowIDs release];
        }
    NS_HANDLER
    NS_ENDHANDLER
    
    [listTask release];
}

- (void)unhideWithoutActivation
{
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
            
            [firefoxWindowIDs release];
        }
    NS_HANDLER
    NS_ENDHANDLER
    
    [listTask release];
}

- (BOOL)isHidden
{
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
    NS_ENDHANDLER
    
    [listTask release];
    
    BOOL hidden = !hasVisibleWindows;
    return hidden;
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
        } else {
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
        }
        
        [self scheduleFirefoxTerminationCheck];
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

#pragma mark - Firefox Management Methods

- (void)activateFirefoxWindows
{
    [self activateFirefoxWithWmctrl];
}

- (BOOL)activateFirefoxWithWmctrl
{
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
                        }
                    }
                }
            }
            
            [output release];
            
            if ([firefoxWindowIDs count] > 0) {
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
            }
            
            [firefoxWindowIDs release];
        }
    NS_HANDLER
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
                [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
            }
        } else {
            [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
        }
    NS_HANDLER
        [self performSelector:@selector(waitForFirefoxToStart) withObject:nil afterDelay:0.5];
    NS_ENDHANDLER
    
    [listTask release];
}

- (void)launchFirefox
{
    if (isFirefoxRunning && firefoxTask && [firefoxTask isRunning]) {
        [self activateFirefoxWindows];
        return;
    }
    
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
        
        NSDictionary *didLaunchInfo = @{
            @"NSApplicationName": @"Firefox",
            @"NSApplicationPath": [[NSBundle mainBundle] bundlePath],
            @"NSApplicationProcessIdentifier": @([firefoxTask processIdentifier])
        };
        
        [[NSNotificationCenter defaultCenter] 
            postNotificationName:NSWorkspaceDidLaunchApplicationNotification
                          object:[NSWorkspace sharedWorkspace]
                        userInfo:didLaunchInfo];
        
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

- (void)handleFirefoxTermination:(NSNotification *)notification
{
    NSTask *task = [notification object];
    
    if (task == firefoxTask) {
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
    }
}

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

#pragma mark - Application Delegate Methods

- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag
{
    if ([self isFirefoxCurrentlyRunning]) {
        [self activateFirefoxWindows];
    } else {
        [self launchFirefox];
    }
    
    return NO;
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
    return NO;
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    if ([self isFirefoxCurrentlyRunning]) {
        return NSTerminateCancel;
    } else {
        return NSTerminateNow;
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    [self stopFirefoxMonitoring];
    
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
}

- (void)dealloc
{
    [self stopFirefoxMonitoring];
    
    if (firefoxTask) {
        [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                        name:NSTaskDidTerminateNotification 
                                                      object:firefoxTask];
        [firefoxTask release];
    }
    [super dealloc];
}

@end
