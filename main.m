#import <AppKit/AppKit.h>
#import <sys/types.h>
#import <unistd.h>
#import <stdlib.h>
#import <signal.h>
#import "ApplicationWrapper.h"

void signalHandler(int sig)
{
    (void)sig;
    exit(0);
}

@interface ApplicationWrapper (InstanceDetection)
+ (BOOL)checkForExistingInstance;
@end

@implementation ApplicationWrapper (InstanceDetection)

+ (BOOL)checkForExistingInstance
{
    NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:@SERVICE_NAME host:nil];
    if (existingConnection) {
        id<ApplicationWrapperProtocol> existingLauncher = (id<ApplicationWrapperProtocol>)[existingConnection rootProxy];
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
    
    if ([ApplicationWrapper checkForExistingInstance]) {
        [pool release];
        return 0;
    }
    
    NSMutableArray *launchArgs = [[NSMutableArray alloc] init];
    for (int i = 1; i < argc; i++) {
        [launchArgs addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    
    ApplicationWrapper *launcher = [[ApplicationWrapper alloc] init];
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
