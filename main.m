#import <AppKit/AppKit.h>
#import <sys/types.h>
#import <unistd.h>
#import <stdlib.h>
#import <signal.h>
#import "FirefoxLauncher.h"

// Simple signal handler for clean shutdown
void signalHandler(int sig)
{
    (void)sig; // Suppress unused parameter warning
    exit(0);
}

// Forward declaration for instance detection
@interface FirefoxLauncher (InstanceDetection)
+ (BOOL)checkForExistingInstance;
@end

@implementation FirefoxLauncher (InstanceDetection)

+ (BOOL)checkForExistingInstance
{
    // Try to connect to existing instance via distributed objects
    NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:@"Firefox" host:nil];
    if (existingConnection) {
        id<FirefoxLauncherProtocol> existingLauncher = (id<FirefoxLauncherProtocol>)[existingConnection rootProxy];
        if (existingLauncher) {
            NS_DURING
                // Test if the connection is actually working
                BOOL isRunning = [existingLauncher isRunning];
                (void)isRunning; // Suppress unused variable warning
                
                // If we get here, connection is valid - delegate activation
                [existingLauncher activateIgnoringOtherApps:YES];
                fprintf(stderr, "Firefox wrapper: Delegated to existing instance\n");
                return YES;
            NS_HANDLER
                // Connection failed - existing instance is dead
                fprintf(stderr, "Firefox wrapper: Existing instance connection failed, continuing as new instance\n");
            NS_ENDHANDLER
        }
    }
    
    return NO;
}

@end

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Set up signal handlers for clean shutdown
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    signal(SIGHUP, signalHandler);
    signal(SIGPIPE, SIG_IGN);  // Ignore broken pipe signals
    
    // Create NSApplication immediately for GWorkspace visibility
    NSApplication *app = [NSApplication sharedApplication];
    
    // Simple instance check - no lock files needed
    if ([FirefoxLauncher checkForExistingInstance]) {
        fprintf(stderr, "Firefox wrapper: Delegated to existing instance\n");
        [pool release];
        return 0;
    }
    
    fprintf(stderr, "Firefox wrapper: Starting as primary instance (PID: %d)\n", getpid());
    
    // Handle command line arguments
    NSMutableArray *launchArgs = [[NSMutableArray alloc] init];
    for (int i = 1; i < argc; i++) {
        [launchArgs addObject:[NSString stringWithUTF8String:argv[i]]];
    }
    
    // Create and configure the launcher
    FirefoxLauncher *launcher = [[FirefoxLauncher alloc] init];
    [app setDelegate:launcher];
    
    // Pass any command line arguments to the launcher
    if ([launchArgs count] > 0) {
        // Handle file arguments that might have been passed
        for (NSString *arg in launchArgs) {
            if ([[NSFileManager defaultManager] fileExistsAtPath:arg]) {
                [launcher application:app openFile:arg];
            }
        }
    }
    
    [launchArgs release];
    
    // Start the application main loop
    int result = NSApplicationMain(argc, argv);
    
    // Cleanup
    [launcher release];
    [pool release];
    
    return result;
}
