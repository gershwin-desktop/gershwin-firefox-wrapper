#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>

@interface FirefoxLauncher : NSObject <NSApplicationDelegate>
{
    NSTask *firefoxTask;
    NSString *firefoxExecutablePath;
    BOOL isFirefoxRunning;
    NSConnection *serviceConnection;
}

- (void)launchFirefox;
- (void)activateFirefox;
- (BOOL)isFirefoxCurrentlyRunning;
- (void)handleFirefoxTermination:(NSNotification *)notification;

@end