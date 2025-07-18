#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface FirefoxLauncher : NSObject
{
    NSString *firefoxExecutablePath;
    BOOL isFirefoxRunning;
    NSTask *firefoxTask;
    NSConnection *serviceConnection;
}

// Application lifecycle
- (void)applicationWillFinishLaunching:(NSNotification *)notification;
- (void)applicationDidFinishLaunching:(NSNotification *)notification;
- (BOOL)applicationShouldHandleReopen:(NSApplication *)theApplication hasVisibleWindows:(BOOL)flag;
- (void)applicationWillTerminate:(NSNotification *)notification;
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender;

// Firefox management
- (void)launchFirefox;
- (BOOL)isFirefoxCurrentlyRunning;
- (void)activateFirefoxWindows;
- (void)handleFirefoxTermination:(NSNotification *)notification;
- (void)checkForRemainingFirefoxProcesses;

// GWorkspace integration methods
- (void)activateIgnoringOtherApps:(BOOL)flag;
- (void)hide:(id)sender;
- (void)unhideWithoutActivation;
- (BOOL)isHidden;
- (void)terminate:(id)sender;
- (void)application:(NSApplication *)sender openFile:(NSString *)filename;
- (void)application:(NSApplication *)sender openFileWithoutUI:(NSString *)filename;

// Helper methods
- (void)openFileInFirefox:(NSString *)filename activate:(BOOL)shouldActivate;
- (BOOL)activateFirefoxWithWmctrl;
- (void)waitForFirefoxToStart;
- (void)notifyGWorkspaceOfStateChange;
- (void)startPeriodicFirefoxMonitoring;
- (void)periodicFirefoxCheck:(NSTimer *)timer;
- (BOOL)isRunning;
- (NSNumber *)processIdentifier;

@end