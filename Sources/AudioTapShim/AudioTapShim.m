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
