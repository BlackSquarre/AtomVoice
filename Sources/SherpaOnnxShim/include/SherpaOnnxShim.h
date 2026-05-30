#ifndef SHERPA_ONNX_SHIM_H
#define SHERPA_ONNX_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct AtomVoiceSherpaContext AtomVoiceSherpaContext;
typedef struct AtomVoiceSherpaPunctuationContext AtomVoiceSherpaPunctuationContext;

/// 由 Swift 层传入具体文件名；不同 Sherpa 模型 zip 包的 encoder/decoder/joiner 命名差异很大
/// (Swift passes the exact filenames; encoder/decoder/joiner naming varies across Sherpa model archives)
AtomVoiceSherpaContext *AtomVoiceSherpaCreate(const char *lib_dir,
                                               const char *model_dir,
                                               const char *encoder_name,
                                               const char *decoder_name,
                                               const char *joiner_name,
                                               const char *tokens_name,
                                               const char *provider,
                                               char *error_message,
                                               int32_t error_message_size);

/// Paraformer 仍然走 sherpa-onnx online recognizer，只是模型字段从 transducer 切到 paraformer。
/// (Paraformer still uses sherpa-onnx's online recognizer; only the model config switches
/// from transducer fields to paraformer fields.)
AtomVoiceSherpaContext *AtomVoiceSherpaCreateParaformer(const char *lib_dir,
                                                        const char *model_dir,
                                                        const char *encoder_name,
                                                        const char *decoder_name,
                                                        const char *tokens_name,
                                                        const char *provider,
                                                        char *error_message,
                                                        int32_t error_message_size);

int32_t AtomVoiceSherpaAcceptWaveform(AtomVoiceSherpaContext *context,
                                      int32_t sample_rate,
                                      const float *samples,
                                      int32_t sample_count);

char *AtomVoiceSherpaGetResult(AtomVoiceSherpaContext *context);

char *AtomVoiceSherpaFinish(AtomVoiceSherpaContext *context);

void AtomVoiceSherpaDestroy(AtomVoiceSherpaContext *context);

int32_t AtomVoiceSherpaResetStream(AtomVoiceSherpaContext *context);

void AtomVoiceSherpaFreeString(char *text);

AtomVoiceSherpaPunctuationContext *AtomVoiceSherpaPunctuationCreate(const char *lib_dir,
                                                                     const char *model_dir,
                                                                     const char *provider,
                                                                     char *error_message,
                                                                     int32_t error_message_size);

char *AtomVoiceSherpaPunctuationAddPunct(AtomVoiceSherpaPunctuationContext *context,
                                         const char *text);

void AtomVoiceSherpaPunctuationDestroy(AtomVoiceSherpaPunctuationContext *context);

#ifdef __cplusplus
}
#endif

#endif
