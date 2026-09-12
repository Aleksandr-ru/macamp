#import "AudioPlaybackExceptionGuard.h"

BOOL MacAmpPlayAudioPlayerNode(AVAudioPlayerNode *node, NSError **error) {
    if (error != NULL) {
        *error = nil;
    }

    @try {
        [node play];
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name ?: @"Unknown AVAudioPlayerNode exception";
            *error = [NSError errorWithDomain:@"ru.aleksandr.macAmp.audio"
                                          code:1
                                      userInfo:@{NSLocalizedDescriptionKey: reason}];
        }
        return NO;
    }
}
