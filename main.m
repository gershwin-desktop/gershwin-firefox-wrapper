#import <AppKit/AppKit.h>
#import <sys/types.h>
#import <unistd.h>
#import <stdlib.h>
#import <signal.h>
#import "FirefoxLauncher.h"

void signalHandler(int sig)
{
    (void)sig;
    exit(0);
}

@interface FirefoxLauncher (InstanceDetection)
+ (BOOL)checkForExistingInstance;
@end

@implementation FirefoxLauncher (InstanceDetection)

+ (BOOL)checkForExistingInstance
{
    NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:@"Firefox" host:nil];
    if (existingConnection) {
        id<FirefoxLauncherProtocol> existingLauncher = (id<FirefoxLauncherProtocol>)[existingConnection rootProxy];
        if (existingLauncher) {
            NS_DURING
                BOOL isRunning = [existingLauncher isRunning];
                (void)isRunning;
                
                [existingLauncher activateIgnoringOtherApps:YES];
                return YES;
            NS_HANDLER
            NS_ENDHANDLER
        }
    }
    
    return NO;
}

@end

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    signal(SIGHUP, signalHandler);
    signal(SIGPIPE, SIG_IGN);
    
    NSApplication *app = [NSApplication sharedApplication];
    
    if ([FirefoxLauncher checkForExistingInstance]) {
        [pool release];
        return 0;
    }
    
    NSMutableArray *launchArgs = [[NSMutableArray alloc] init];
    for (int i = 1; i < argc; i++) {
        [launchArgs addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    
    FirefoxLauncher *launcher = [[FirefoxLauncher alloc] init];
    [app setDelegate:launcher];
    
    if ([launchArgs count] > 0) {
        for (NSString *arg in launchArgs) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:arg]) {
                [launcher application:app openFile:arg];
            }
        }
    }
    
    [launchArgs release];
    
    int result = NSApplicationMain(argc, argv);
    
    [launcher release];
    [pool release];
    
    return result;
}
