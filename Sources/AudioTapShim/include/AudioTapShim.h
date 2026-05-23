#pragma once

#import <AVFoundation/AVFoundation.h>
#import <stdbool.h>

typedef struct AtomVoiceAtomicFlag AtomVoiceAtomicFlag;

BOOL AtomVoiceInstallAudioTap(AVAudioNode *node,
                               AVAudioNodeBus bus,
                               AVAudioFrameCount bufferSize,
                               AVAudioFormat *format,
                               AVAudioNodeTapBlock block);

BOOL AtomVoiceInstallAudioTapWithError(AVAudioNode *node,
                                        AVAudioNodeBus bus,
                                        AVAudioFrameCount bufferSize,
                                        AVAudioFormat *format,
                                        AVAudioNodeTapBlock block,
                                        NSString **outError);

AtomVoiceAtomicFlag *AtomVoiceAtomicFlagCreate(bool initialValue);
void AtomVoiceAtomicFlagDestroy(AtomVoiceAtomicFlag *flag);
bool AtomVoiceAtomicFlagLoad(AtomVoiceAtomicFlag *flag);
void AtomVoiceAtomicFlagStore(AtomVoiceAtomicFlag *flag, bool value);
