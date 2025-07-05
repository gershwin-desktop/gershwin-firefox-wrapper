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
- (BOOL)isFirefoxCurrentlyRunning;
- (void)handleFirefoxTermination:(NSNotification *)notification;

@end