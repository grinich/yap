// Offline Sparkle configuration probe. This is a command-line validator, not an app launch.
#import <Foundation/Foundation.h>
#import <Sparkle/Sparkle.h>

@interface OfflineUpdaterDelegate : NSObject <SPUUpdaterDelegate>
@end

@implementation OfflineUpdaterDelegate
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"com.grinich.yap.updater-validation" code:1
                                userInfo:@{NSLocalizedDescriptionKey: @"Update checks are disabled in this offline validator."}];
    }
    return NO;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "Usage: validate-updater-startup path/to/Fixture.app\n");
            return 2;
        }
        NSBundle *bundle = [NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
        if (bundle == nil || ![bundle.bundlePath.pathExtension isEqualToString:@"app"]) {
            fprintf(stderr, "Expected an app bundle.\n");
            return 2;
        }
        OfflineUpdaterDelegate *delegate = [OfflineUpdaterDelegate new];
        SPUStandardUserDriver *driver = [[SPUStandardUserDriver alloc] initWithHostBundle:bundle delegate:nil];
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle
                                                        userDriver:driver delegate:delegate];
        NSError *error = nil;
        // This synchronous API validates configuration. Unlike the standard controller,
        // it returns an error instead of showing an alert. No NSApplication or run loop
        // is started; its scheduled update cycle cannot run before this process exits.
        if (![updater startUpdater:&error]) {
            fprintf(stderr, "Sparkle startup rejected configuration (%ld): %s\n",
                    (long)error.code, error.localizedDescription.UTF8String);
            return 1;
        }
        puts("PASS: Sparkle accepted the updater configuration without running an update check.");
    }
    return 0;
}
