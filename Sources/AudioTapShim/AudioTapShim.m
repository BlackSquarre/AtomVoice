#import "AudioTapShim.h"

BOOL AtomVoiceInstallAudioTap(AVAudioNode *node,
                               AVAudioNodeBus bus,
                               AVAudioFrameCount bufferSize,
                               AVAudioFormat *format,
                               AVAudioNodeTapBlock block) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[AudioEngine] installTap failed: %@ %@", exception.name, exception.reason);
        return NO;
    }
}

BOOL AtomVoiceInstallAudioTapWithError(AVAudioNode *node,
                                        AVAudioNodeBus bus,
                                        AVAudioFrameCount bufferSize,
                                        AVAudioFormat *format,
                                        AVAudioNodeTapBlock block,
                                        NSString **outError) {
    @try {
        [node installTapOnBus:bus bufferSize:bufferSize format:format block:block];
        return YES;
    } @catch (NSException *exception) {
        NSLog(@"[AudioEngine] installTap failed: %@ %@", exception.name, exception.reason);
        if (outError) {
            *outError = [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason];
        }
        return NO;
    }
}
