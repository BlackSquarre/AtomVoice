#pragma once

#import <AVFoundation/AVFoundation.h>

BOOL AtomVoiceInstallAudioTap(AVAudioNode *node,
                              AVAudioNodeBus bus,
                              AVAudioFrameCount bufferSize,
                              AVAudioFormat *format,
                              AVAudioNodeTapBlock block);
