#import <AppKit/AppKit.h>
#import "FirefoxLauncher.h"

int main(int argc, const char *argv[])
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    
    [NSApplication sharedApplication];
    
    FirefoxLauncher *launcher = [[FirefoxLauncher alloc] init];
    [NSApp setDelegate:launcher];

    int result = NSApplicationMain(argc, argv);
    
    [pool release];
    return result;
}