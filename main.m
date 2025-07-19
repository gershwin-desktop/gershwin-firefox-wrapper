#import <AppKit/AppKit.h>
#import <sys/types.h>
#import <sys/sysctl.h>
#import <sys/user.h>
#import <unistd.h>
#import <stdlib.h>
#import <string.h>
#import <fcntl.h>
#import <errno.h>
#import "FirefoxLauncher.h"

#define LOCK_FILE "/tmp/firefox-wrapper.lock"

BOOL acquireLockFile(void)
{
    int fd = open(LOCK_FILE, O_CREAT | O_EXCL | O_WRONLY, 0644);
    if (fd == -1) {
        if (errno == EEXIST) {
            // Lock file exists, try to contact existing instance via distributed objects
            NSConnection *existingConnection = [NSConnection connectionWithRegisteredName:@"Firefox" host:nil];
            if (existingConnection) {
                // Another instance is reachable, tell it to activate and exit
                FirefoxLauncher *existingLauncher = (FirefoxLauncher *)[existingConnection rootProxy];
                if (existingLauncher) {
                    NS_DURING
                        [existingLauncher activateIgnoringOtherApps:YES];
                    NS_HANDLER
                        // If communication fails, continue anyway
                    NS_ENDHANDLER
                }
                return NO; // Don't start second instance
            } else {
                // Lock file exists but no distributed object, remove stale lock
                unlink(LOCK_FILE);
                fd = open(LOCK_FILE, O_CREAT | O_EXCL | O_WRONLY, 0644);
            }
        }
        
        if (fd == -1) {
            return NO;
        }
    }
    
    // Write our PID to the lock file
    char pid_str[32];
    snprintf(pid_str, sizeof(pid_str), "%d\n", getpid());
    write(fd, pid_str, strlen(pid_str));
    close(fd);
    
    return YES;
}

void releaseLockFile(void)
{
    unlink(LOCK_FILE);
}

void signalHandler(int sig)
{
    releaseLockFile();
    exit(0);
}

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    // Create NSApplication immediately so GWorkspace sees us as running
    [NSApplication sharedApplication];
    
    // Try to acquire the lock file and check for existing instance
    if (!acquireLockFile()) {
        // Another instance is running and we've already told it to activate
        fprintf(stderr, "Firefox wrapper: Delegated to existing instance, exiting\n");
        [pool release];
        return 0;
    }
    
    // Set up signal handlers to clean up lock file on exit
    signal(SIGTERM, signalHandler);
    signal(SIGINT, signalHandler);
    signal(SIGHUP, signalHandler);
    
    // Register cleanup function for normal exit
    atexit(releaseLockFile);
    
    fprintf(stderr, "Firefox wrapper: Starting as primary instance\n");
    
    FirefoxLauncher *launcher = [[FirefoxLauncher alloc] init];
    [NSApp setDelegate:launcher];
    int result = NSApplicationMain(argc, argv);
    [pool release];
    return result;
}
