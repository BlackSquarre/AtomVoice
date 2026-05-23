#import "AudioTapShim.h"
#import <stdatomic.h>

struct AtomVoiceAtomicFlag {
    atomic_bool value;
};

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

AtomVoiceAtomicFlag *AtomVoiceAtomicFlagCreate(bool initialValue) {
    AtomVoiceAtomicFlag *flag = malloc(sizeof(AtomVoiceAtomicFlag));
    if (!flag) {
        return NULL;
    }
    atomic_init(&flag->value, initialValue);
    return flag;
}

void AtomVoiceAtomicFlagDestroy(AtomVoiceAtomicFlag *flag) {
    if (!flag) {
        return;
    }
    free(flag);
}

bool AtomVoiceAtomicFlagLoad(AtomVoiceAtomicFlag *flag) {
    if (!flag) {
        return false;
    }
    return atomic_load_explicit(&flag->value, memory_order_acquire);
}

void AtomVoiceAtomicFlagStore(AtomVoiceAtomicFlag *flag, bool value) {
    if (!flag) {
        return;
    }
    atomic_store_explicit(&flag->value, value, memory_order_release);
}
