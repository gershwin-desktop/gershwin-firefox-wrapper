#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <sys/event.h>
#import <dispatch/dispatch.h>

@protocol ApplicationWrapperProtocol
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)hide:(id)sender;
- (void)unhideWithoutActivation;
- (BOOL)isHidden;
- (void)terminate:(id)sender;
- (BOOL)isRunning;
- (NSNumber *)processIdentifier;
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename;
- (BOOL)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename;
@end

@interface ApplicationWrapper : NSObject <ApplicationWrapperProtocol>
{
    NSString *applicationExecutablePath;
    NSTask *applicationTask;
    
    pid_t applicationPID;
    BOOL terminationInProgress;
    
    dispatch_source_t procMonitorSource;
    dispatch_queue_t monitorQueue;
    
    int kqueueFD;
    NSThread *kqueueThread;
    
    BOOL connectionEstablished;
    BOOL isPrimaryInstance;
    
    BOOL dockIconVisible;
    BOOL isTransformingProcess;
    
    NSMutableArray *cachedWindowList;
    NSDate *lastWindowListUpdate;
    
    BOOL systemSleepDetected;
    
    NSString *applicationName;
    NSString *serviceName;
    NSString *windowSearchString;
    NSString *bundleIdentifier;
    
    NSMutableSet *trackedPIDs;
    pid_t primaryLaunchedPID;
}

@property (nonatomic, retain) NSString *applicationName;
@property (nonatomic, retain) NSString *serviceName;
@property (nonatomic, retain) NSString *windowSearchString;
@property (nonatomic, retain) NSString *bundleIdentifier;
@property (nonatomic, retain) NSMutableSet *trackedPIDs;

- (id)initWithConfiguration:(NSDictionary *)config;

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

- (BOOL)establishSingleInstance;
- (void)delegateToExistingInstance;

- (void)launchApplication;
- (void)launchApplicationWithArgs:(NSArray *)arguments;
- (BOOL)isApplicationCurrentlyRunning;
- (void)activateApplicationWindows;
- (void)handleApplicationTermination:(NSNotification *)notification;
- (NSArray *)getChildProcesses:(pid_t)parentPID;
- (void)trackPID:(pid_t)pid;
- (void)untrackPID:(pid_t)pid;
- (void)discoverChildProcesses;
- (void)checkApplicationStatus;

- (void)startEventDrivenMonitoring:(pid_t)applicationProcessID;
- (void)stopEventDrivenMonitoring;
- (void)applicationProcessExited:(int)exitStatus;
- (void)initiateWrapperTermination;

- (void)setupGCDProcessMonitoring:(pid_t)pid;
- (void)cleanupGCDMonitoring;

- (void)setupKqueueChildTracking:(pid_t)parentPID;
- (void)kqueueMonitoringThread:(id)arg;
- (void)stopKqueueMonitoring;

- (void)ensureDockIconVisible;
- (void)updateDockIconState:(BOOL)visible;
- (void)completeTransformationProcess;

- (BOOL)establishServiceConnection;
- (void)invalidateServiceConnection;

- (BOOL)activateApplicationWithWmctrl;
- (NSArray *)getCachedWindowList;
- (void)invalidateWindowListCache;
- (NSArray *)getApplicationWindowIDs;
- (void)waitForApplicationToStart;

- (void)registerForSystemEvents;
- (void)handleSystemSleep:(NSNotification *)notification;
- (void)handleSystemWake:(NSNotification *)notification;

- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)hide:(id)sender;
- (void)unhideWithoutActivation;
- (BOOL)isHidden;
- (void)terminate:(id)sender;
- (BOOL)isRunning;
- (NSNumber *)processIdentifier;

- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename;
- (BOOL)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename;
- (void)openFileInApplication:(NSString *)filename activate:(BOOL)shouldActivate;

- (void)postApplicationLaunchNotification;
- (void)postApplicationTerminationNotification;
- (void)notifyGWorkspaceOfStateChange;

- (void)handleInitialApplicationState;
- (BOOL)waitForApplicationToQuit:(NSTimeInterval)timeout;
- (void)emergencyExit;

@end
