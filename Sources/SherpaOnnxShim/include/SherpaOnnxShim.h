#ifndef SHERPA_ONNX_SHIM_H
#define SHERPA_ONNX_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AtomVoiceSherpaContext AtomVoiceSherpaContext;
typedef struct AtomVoiceSherpaPunctuationContext AtomVoiceSherpaPunctuationContext;

AtomVoiceSherpaContext *AtomVoiceSherpaCreate(const char *lib_dir,
                                              const char *model_dir,
                                              char *error_message,
                                              int32_t error_message_size);

int32_t AtomVoiceSherpaAcceptWaveform(AtomVoiceSherpaContext *context,
                                      int32_t sample_rate,
                                      const float *samples,
                                      int32_t sample_count);

char *AtomVoiceSherpaGetResult(AtomVoiceSherpaContext *context);

char *AtomVoiceSherpaFinish(AtomVoiceSherpaContext *context);

void AtomVoiceSherpaDestroy(AtomVoiceSherpaContext *context);

void AtomVoiceSherpaFreeString(char *text);

AtomVoiceSherpaPunctuationContext *AtomVoiceSherpaPunctuationCreate(const char *lib_dir,
                                                                    const char *model_dir,
                                                                    char *error_message,
                                                                    int32_t error_message_size);

char *AtomVoiceSherpaPunctuationAddPunct(AtomVoiceSherpaPunctuationContext *context,
                                         const char *text);

void AtomVoiceSherpaPunctuationDestroy(AtomVoiceSherpaPunctuationContext *context);

#ifdef __cplusplus
}
#endif

#endif
