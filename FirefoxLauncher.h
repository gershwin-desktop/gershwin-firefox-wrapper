#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface FirefoxLauncher : NSObject
{
    NSString *firefoxExecutablePath;
    BOOL isFirefoxRunning;
    NSTask *firefoxTask;
    NSConnection *serviceConnection;
    NSTimer *monitoringTimer;
    BOOL shouldTerminateWhenFirefoxQuits;
    
    // Monitoring state variables (previously static)
    BOOL wasFirefoxRunning;
    BOOL isFirstMonitoringRun;
    int stableStateCount;
    
    // Flag to track if termination is pending
    BOOL terminationPending;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

- (void)launchFirefox;
- (BOOL)isFirefoxCurrentlyRunning;
- (void)activateFirefoxWindows;
- (void)handleFirefoxTermination:(NSNotification *)notification;
- (void)checkForRemainingFirefoxProcesses;

- (void)startSmartFirefoxMonitoring;
- (void)stopFirefoxMonitoring;
- (void)smartFirefoxCheck:(NSTimer *)timer;
- (NSArray *)getAllFirefoxProcessIDs;
- (BOOL)waitForFirefoxToQuit:(NSTimeInterval)timeout;
- (void)scheduleFirefoxTerminationCheck;
- (void)finalTerminationCheck;

- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)hide:(id)sender;
- (void)unhideWithoutActivation;
- (BOOL)isHidden;
- (void)terminate:(id)sender;
- (BOOL)application:(NSApplication *)sender openFile:(NSString *)filename;
- (BOOL)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename;

- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate;
- (BOOL)activateFirefoxWithWmctrl;
- (void)waitForFirefoxToStart;
- (void)notifyGWorkspaceOfStateChange;
- (BOOL)isRunning;
- (NSNumber *)processIdentifier;
- (NSString *)getExecutablePathForPID:(pid_t)pid;

- (void)postFirefoxLaunchNotification;
- (void)postFirefoxTerminationNotification;
- (void)handleInitialFirefoxState;
- (void)delayedTerminate;
- (void)delayedTerminateAfterNotifications;

@end
