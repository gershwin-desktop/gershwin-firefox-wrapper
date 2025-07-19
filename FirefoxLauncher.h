#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <sys/event.h>

// FreeBSD libdispatch support (if available)
#ifdef __has_include
  #if __has_include(<dispatch/dispatch.h>)
    #import <dispatch/dispatch.h>
    #define HAS_LIBDISPATCH 1
  #else
    #define HAS_LIBDISPATCH 0
  #endif
#else
  // Fallback for older compilers
  #define HAS_LIBDISPATCH 0
#endif

// Protocol declaration for distributed objects
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
    
    // Event-driven monitoring (no PID tracking needed)
    pid_t firefoxPID;
    BOOL terminationInProgress;
    
#if HAS_LIBDISPATCH
    // GCD process monitoring
    dispatch_source_t procMonitorSource;
    dispatch_queue_t monitorQueue;
#endif
    
    // kqueue for child process tracking
    int kqueueFD;
    NSThread *kqueueThread;
    
    // Connection and state management
    BOOL connectionEstablished;
    BOOL isPrimaryInstance;
    
    // Dynamic dock management (FreeBSD/GNUstep compatible)
    BOOL dockIconVisible;
    BOOL isTransformingProcess;
    
    // Window management with caching
    NSMutableArray *cachedWindowList;
    NSDate *lastWindowListUpdate;
    NSTimeInterval windowListCacheTimeout;
    
    // System event handling
    BOOL systemSleepDetected;
}

#pragma mark - Application Lifecycle
- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

#pragma mark - Single Instance Management
- (BOOL)establishSingleInstance;
- (void)delegateToExistingInstance;

#pragma mark - Firefox Process Management
- (void)launchFirefox;
- (void)launchFirefoxWithArgs:(NSArray *)arguments;
- (BOOL)isFirefoxCurrentlyRunning;
- (void)activateFirefoxWindows;
- (void)handleFirefoxTermination:(NSNotification *)notification;
- (NSArray *)getAllFirefoxProcessIDs;
- (NSString *)getExecutablePathForPID:(pid_t)pid;

#pragma mark - Event-Driven Monitoring System
- (void)startEventDrivenMonitoring:(pid_t)firefoxProcessID;
- (void)stopEventDrivenMonitoring;
- (void)firefoxProcessExited:(int)exitStatus;
- (void)initiateWrapperTermination;

#if HAS_LIBDISPATCH
#pragma mark - GCD Process Monitoring
- (void)setupGCDProcessMonitoring:(pid_t)pid;
- (void)cleanupGCDMonitoring;
#endif

#pragma mark - kqueue Child Process Tracking
- (void)setupKqueueChildTracking:(pid_t)parentPID;
- (void)kqueueMonitoringThread:(id)arg;
- (void)stopKqueueMonitoring;

#pragma mark - Dynamic Dock Management
- (void)ensureDockIconVisible;
- (void)ensureDockIconHidden;
- (BOOL)isDockIconCurrentlyVisible;
- (void)updateDockIconState:(BOOL)visible;
- (void)completeTransformationProcess;

#pragma mark - Connection Management
- (BOOL)establishServiceConnection;
- (void)invalidateServiceConnection;

#pragma mark - Window Management with Caching
- (BOOL)activateFirefoxWithWmctrl;
- (NSArray *)getCachedWindowList;
- (void)invalidateWindowListCache;
- (NSArray *)getFirefoxWindowIDs;
- (void)waitForFirefoxToStart;

#pragma mark - System Event Handling
- (void)registerForSystemEvents;
- (void)handleSystemSleep:(NSNotification *)notification;
- (void)handleSystemWake:(NSNotification *)notification;

#pragma mark - GWorkspace Integration Methods
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)hide:(id)sender;
- (void)unhideWithoutActivation;
- (BOOL)isHidden;
- (void)terminate:(id)sender;
- (BOOL)isRunning;
- (NSNumber *)processIdentifier;

#pragma mark - File Handling
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename;
- (BOOL)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename;
- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate;

#pragma mark - Notification System
- (void)postFirefoxLaunchNotification;
- (void)postFirefoxTerminationNotification;
- (void)notifyGWorkspaceOfStateChange;

#pragma mark - Utility Methods
- (void)handleInitialFirefoxState;
- (BOOL)waitForFirefoxToQuit:(NSTimeInterval)timeout;
- (void)emergencyExit;

@end
