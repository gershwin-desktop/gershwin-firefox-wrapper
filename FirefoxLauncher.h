#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

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

// Protocol declaration for distributed objects performance
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
#pragma mark - Helper Methods
- (void)completeTransformationProcess;

@end

@interface FirefoxLauncher : NSObject <FirefoxLauncherProtocol>
{
    NSString *firefoxExecutablePath;
    BOOL isFirefoxRunning;
    NSTask *firefoxTask;
    NSConnection *serviceConnection;
    NSTimer *monitoringTimer;
    NSTimer *retryTimer;
    BOOL shouldTerminateWhenFirefoxQuits;
    
    // Enhanced monitoring state variables
    BOOL wasFirefoxRunning;
    BOOL isFirstMonitoringRun;
    int stableStateCount;
    NSDate *lastStateChangeTime;
    
    // Connection and retry management
    BOOL connectionEstablished;
    int connectionRetryCount;
    NSMutableDictionary *persistentState;
    
    // Dynamic dock management (FreeBSD/GNUstep compatible)
    BOOL dockIconVisible;
    BOOL isTransformingProcess;
    NSTimer *dockStateVerificationTimer;
    
    // Performance optimization
    NSMutableArray *cachedWindowList;
    NSDate *lastWindowListUpdate;
    NSTimeInterval windowListCacheTimeout;
    
    // Edge case handling
    BOOL terminationPending;
    BOOL systemSleepDetected;
    BOOL firefoxCrashedRecently;
    NSDate *lastCrashTime;
}

#pragma mark - Application Lifecycle
- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

#pragma mark - Firefox Process Management
- (void)launchFirefox;
- (BOOL)isFirefoxCurrentlyRunning;
- (void)activateFirefoxWindows;
- (void)handleFirefoxTermination:(NSNotification *)notification;
- (void)checkForRemainingFirefoxProcesses;
- (NSArray *)getAllFirefoxProcessIDs;
- (NSString *)getExecutablePathForPID:(pid_t)pid;

#pragma mark - Enhanced Monitoring System
- (void)startSmartFirefoxMonitoring;
- (void)stopFirefoxMonitoring;
- (void)smartFirefoxCheck:(NSTimer *)timer;
- (BOOL)waitForFirefoxToQuit:(NSTimeInterval)timeout;
- (void)scheduleFirefoxTerminationCheck;
- (void)finalTerminationCheck;

#pragma mark - Dynamic Dock Management (GNUstep/X11)
- (void)ensureDockIconVisible;
- (void)ensureDockIconHidden;
- (BOOL)isDockIconCurrentlyVisible;
- (void)updateDockIconState:(BOOL)visible;
- (void)verifyDockState:(NSTimer *)timer;
- (void)retryDockOperation:(NSTimer *)timer;

#pragma mark - Connection Management with Retry Logic
- (BOOL)establishServiceConnection;
- (void)retryServiceConnection:(NSTimer *)timer;
- (BOOL)registerServiceWithRetry;
- (void)invalidateServiceConnection;

#pragma mark - Window Management with Caching
- (BOOL)activateFirefoxWithWmctrl;
- (NSArray *)getCachedWindowList;
- (void)invalidateWindowListCache;
- (NSArray *)getFirefoxWindowIDs;
- (void)waitForFirefoxToStart;

#pragma mark - State Persistence
- (void)loadPersistentState;
- (void)savePersistentState;
- (void)updateStateValue:(id)value forKey:(NSString *)key;
- (id)getStateValueForKey:(NSString *)key;

#pragma mark - System Event Handling
- (void)registerForSystemEvents;
- (void)handleSystemSleep:(NSNotification *)notification;
- (void)handleSystemWake:(NSNotification *)notification;
- (void)handleDisplayReconfiguration;

#pragma mark - Edge Case Handling
- (void)detectFirefoxCrash;
- (void)handleFirefoxCrash;
- (void)cleanupAfterFirefoxCrash;
- (BOOL)isRecentCrash;
- (void)scheduleDelayedCleanup;

#pragma mark - Performance Optimization
- (void)optimizeMonitoringInterval;
- (void)adjustTimersForSystemLoad;
- (BOOL)shouldUseAggressiveMonitoring;

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

#pragma mark - Delayed Operations
- (void)handleInitialFirefoxState;
- (void)delayedTerminate;
- (void)delayedTerminateAfterNotifications;

@end
