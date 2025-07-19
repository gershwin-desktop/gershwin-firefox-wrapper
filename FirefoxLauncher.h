#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <sys/event.h>

#ifdef __has_include
  #if __has_include(<dispatch/dispatch.h>)
    #import <dispatch/dispatch.h>
    #define HAS_LIBDISPATCH 1
  #else
    #define HAS_LIBDISPATCH 0
  #endif
#else
  #define HAS_LIBDISPATCH 0
#endif

@protocol FirefoxLauncherProtocol
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

@interface FirefoxLauncher : NSObject <FirefoxLauncherProtocol>
{
    NSString *firefoxExecutablePath;
    BOOL isFirefoxRunning;
    NSTask *firefoxTask;
    NSConnection *serviceConnection;
    
    pid_t firefoxPID;
    BOOL terminationInProgress;
    
#if HAS_LIBDISPATCH
    dispatch_source_t procMonitorSource;
    dispatch_queue_t monitorQueue;
#endif
    
    int kqueueFD;
    NSThread *kqueueThread;
    
    BOOL connectionEstablished;
    BOOL isPrimaryInstance;
    
    BOOL dockIconVisible;
    BOOL isTransformingProcess;
    
    NSMutableArray *cachedWindowList;
    NSDate *lastWindowListUpdate;
    NSTimeInterval windowListCacheTimeout;
    
    BOOL systemSleepDetected;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

- (BOOL)establishSingleInstance;
- (void)delegateToExistingInstance;

- (void)launchFirefox;
- (void)launchFirefoxWithArgs:(NSArray *)arguments;
- (BOOL)isFirefoxCurrentlyRunning;
- (void)activateFirefoxWindows;
- (void)handleFirefoxTermination:(NSNotification *)notification;
- (NSArray *)getAllFirefoxProcessIDs;
- (NSString *)getExecutablePathForPID:(pid_t)pid;

- (void)startEventDrivenMonitoring:(pid_t)firefoxProcessID;
- (void)stopEventDrivenMonitoring;
- (void)firefoxProcessExited:(int)exitStatus;
- (void)initiateWrapperTermination;

#if HAS_LIBDISPATCH
- (void)setupGCDProcessMonitoring:(pid_t)pid;
- (void)cleanupGCDMonitoring;
#endif

- (void)setupKqueueChildTracking:(pid_t)parentPID;
- (void)kqueueMonitoringThread:(id)arg;
- (void)stopKqueueMonitoring;

- (void)ensureDockIconVisible;
- (void)ensureDockIconHidden;
- (BOOL)isDockIconCurrentlyVisible;
- (void)updateDockIconState:(BOOL)visible;
- (void)completeTransformationProcess;

- (BOOL)establishServiceConnection;
- (void)invalidateServiceConnection;

- (BOOL)activateFirefoxWithWmctrl;
- (NSArray *)getCachedWindowList;
- (void)invalidateWindowListCache;
- (NSArray *)getFirefoxWindowIDs;
- (void)waitForFirefoxToStart;

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
- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate;

- (void)postFirefoxLaunchNotification;
- (void)postFirefoxTerminationNotification;
- (void)notifyGWorkspaceOfStateChange;

- (void)handleInitialFirefoxState;
- (BOOL)waitForFirefoxToQuit:(NSTimeInterval)timeout;
- (void)emergencyExit;

@end
