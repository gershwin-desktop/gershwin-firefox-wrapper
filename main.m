#import <AppKit/AppKit.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <fcntl.h>
#import <errno.h>
#import <sys/file.h>
#import "FirefoxLauncher.h"

#define LOCK_FILE "/tmp/firefox-wrapper.lock"
#define LOCK_TIMEOUT 30

static int lockFileDescriptor = -1;

// Forward declarations
@interface FirefoxLauncher (InstanceDetection)
+ (BOOL)tryConnectToExistingInstance;
@end

BOOL acquireLockFileWithTimeout(void)
{
    int fd = open(LOCK_FILE, O_CREAT | O_WRONLY, 0644);
    if (fd == -1) {
        return NO;
    }
    
    // Try to acquire exclusive lock with timeout
    int attempts = 0;
    const int maxAttempts = LOCK_TIMEOUT;
    
    while (attempts < maxAttempts) {
        if (flock(fd, LOCK_EX | LOCK_NB) == 0) {
            // Successfully acquired lock
            lockFileDescriptor = fd;
            
            // Write our PID to the lock file
            ftruncate(fd, 0);
            char pid_str[32];
            snprintf(pid_str, sizeof(pid_str), "%d\n", getpid());
            write(fd, pid_str, strlen(pid_str));
            fsync(fd);
            
            return YES;
        }
        
        if (errno != EWOULDBLOCK && errno != EAGAIN) {
            // Real error occurred
            close(fd);
            return NO;
        }
        
        // Check if existing process is still running
        if ([FirefoxLauncher tryConnectToExistingInstance]) {
            close(fd);
            return NO;  // Successfully delegated to existing instance
        }
        
        sleep(1);
        attempts++;
    }
    
    // Timeout reached - assume stale lock
    close(fd);
    unlink(LOCK_FILE);
    
    // Try one more time
    fd = open(LOCK_FILE, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd != -1) {
        lockFileDescriptor = fd;
        char pid_str[32];
        snprintf(pid_str, sizeof(pid_str), "%d\n", getpid());
        write(fd, pid_str, strlen(pid_str));
        fsync(fd);
        return YES;
    }
    
    return NO;
}

void releaseLockFile(void)
{
    if (lockFileDescriptor != -1) {
        flock(lockFileDescriptor, LOCK_UN);
        close(lockFileDescriptor);
        lockFileDescriptor = -1;
    }
    unlink(LOCK_FILE);
}

void signalHandler(int sig)
{
    (void)sig; // Suppress unused parameter warning
    releaseLockFile();
    exit(0);
}

void emergencyCleanup(void)
{
    releaseLockFile();
}

@implementation FirefoxLauncher (InstanceDetection)

+ (BOOL)tryConnectToExistingInstance
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
    
    // Set up signal handlers early
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    signal(SIGHUP, signalHandler);
    signal(SIGPIPE, SIG_IGN);  // Ignore broken pipe signals
    
    // Register emergency cleanup
    atexit(emergencyCleanup);
    
    // Create NSApplication immediately for GWorkspace visibility
    NSApplication *app = [NSApplication sharedApplication];
    
    // Try to acquire the lock file with timeout and retry logic
    if (!acquireLockFileWithTimeout()) {
        // Either another instance is running and we delegated to it,
        // or we couldn't acquire the lock for some other reason
        fprintf(stderr, "Firefox wrapper: Could not acquire lock or delegated to existing instance\n");
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
