#include "SherpaOnnxShim.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct SherpaOnnxOnlineTransducerModelConfig {
  const char *encoder;
  const char *decoder;
  const char *joiner;
} SherpaOnnxOnlineTransducerModelConfig;

typedef struct SherpaOnnxOnlineParaformerModelConfig {
  const char *encoder;
  const char *decoder;
} SherpaOnnxOnlineParaformerModelConfig;

typedef struct SherpaOnnxOnlineZipformer2CtcModelConfig {
  const char *model;
} SherpaOnnxOnlineZipformer2CtcModelConfig;

typedef struct SherpaOnnxOnlineNemoCtcModelConfig {
  const char *model;
} SherpaOnnxOnlineNemoCtcModelConfig;

typedef struct SherpaOnnxOnlineToneCtcModelConfig {
  const char *model;
} SherpaOnnxOnlineToneCtcModelConfig;

typedef struct SherpaOnnxOnlineModelConfig {
  SherpaOnnxOnlineTransducerModelConfig transducer;
  SherpaOnnxOnlineParaformerModelConfig paraformer;
  SherpaOnnxOnlineZipformer2CtcModelConfig zipformer2_ctc;
  const char *tokens;
  int32_t num_threads;
  const char *provider;
  int32_t debug;
  const char *model_type;
  const char *modeling_unit;
  const char *bpe_vocab;
  const char *tokens_buf;
  int32_t tokens_buf_size;
  SherpaOnnxOnlineNemoCtcModelConfig nemo_ctc;
  SherpaOnnxOnlineToneCtcModelConfig t_one_ctc;
} SherpaOnnxOnlineModelConfig;

typedef struct SherpaOnnxFeatureConfig {
  int32_t sample_rate;
  int32_t feature_dim;
} SherpaOnnxFeatureConfig;

typedef struct SherpaOnnxOnlineCtcFstDecoderConfig {
  const char *graph;
  int32_t max_active;
} SherpaOnnxOnlineCtcFstDecoderConfig;

typedef struct SherpaOnnxHomophoneReplacerConfig {
  const char *dict_dir;
  const char *lexicon;
  const char *rule_fsts;
} SherpaOnnxHomophoneReplacerConfig;

typedef struct SherpaOnnxOnlineRecognizerConfig {
  SherpaOnnxFeatureConfig feat_config;
  SherpaOnnxOnlineModelConfig model_config;
  const char *decoding_method;
  int32_t max_active_paths;
  int32_t enable_endpoint;
  float rule1_min_trailing_silence;
  float rule2_min_trailing_silence;
  float rule3_min_utterance_length;
  const char *hotwords_file;
  float hotwords_score;
  SherpaOnnxOnlineCtcFstDecoderConfig ctc_fst_decoder_config;
  const char *rule_fsts;
  const char *rule_fars;
  float blank_penalty;
  const char *hotwords_buf;
  int32_t hotwords_buf_size;
  SherpaOnnxHomophoneReplacerConfig hr;
} SherpaOnnxOnlineRecognizerConfig;

typedef struct SherpaOnnxOnlineRecognizerResult {
  const char *text;
  const char *tokens;
  const char *const *tokens_arr;
  float *timestamps;
  int32_t count;
  const char *json;
} SherpaOnnxOnlineRecognizerResult;

typedef struct SherpaOnnxOfflinePunctuationModelConfig {
  const char *ct_transformer;
  int32_t num_threads;
  int32_t debug;
  const char *provider;
} SherpaOnnxOfflinePunctuationModelConfig;

typedef struct SherpaOnnxOfflinePunctuationConfig {
  SherpaOnnxOfflinePunctuationModelConfig model;
} SherpaOnnxOfflinePunctuationConfig;

typedef struct SherpaOnnxOnlineRecognizer SherpaOnnxOnlineRecognizer;
typedef struct SherpaOnnxOnlineStream SherpaOnnxOnlineStream;
typedef struct SherpaOnnxOfflinePunctuation SherpaOnnxOfflinePunctuation;

typedef const SherpaOnnxOnlineRecognizer *(*CreateRecognizerFn)(const SherpaOnnxOnlineRecognizerConfig *config);
typedef void (*DestroyRecognizerFn)(const SherpaOnnxOnlineRecognizer *recognizer);
typedef const SherpaOnnxOnlineStream *(*CreateStreamFn)(const SherpaOnnxOnlineRecognizer *recognizer);
typedef void (*DestroyStreamFn)(const SherpaOnnxOnlineStream *stream);
typedef void (*AcceptWaveformFn)(const SherpaOnnxOnlineStream *stream, int32_t sample_rate, const float *samples, int32_t n);
typedef int32_t (*IsReadyFn)(const SherpaOnnxOnlineRecognizer *recognizer, const SherpaOnnxOnlineStream *stream);
typedef void (*DecodeFn)(const SherpaOnnxOnlineRecognizer *recognizer, const SherpaOnnxOnlineStream *stream);
typedef const SherpaOnnxOnlineRecognizerResult *(*GetResultFn)(const SherpaOnnxOnlineRecognizer *recognizer, const SherpaOnnxOnlineStream *stream);
typedef void (*DestroyResultFn)(const SherpaOnnxOnlineRecognizerResult *result);
typedef void (*InputFinishedFn)(const SherpaOnnxOnlineStream *stream);
typedef const SherpaOnnxOfflinePunctuation *(*CreatePunctuationFn)(const SherpaOnnxOfflinePunctuationConfig *config);
typedef void (*DestroyPunctuationFn)(const SherpaOnnxOfflinePunctuation *punctuation);
typedef const char *(*AddPunctFn)(const SherpaOnnxOfflinePunctuation *punctuation, const char *text);
typedef void (*FreePunctTextFn)(const char *text);

struct AtomVoiceSherpaContext {
  void *onnxruntime_handle;
  void *sherpa_handle;
  const SherpaOnnxOnlineRecognizer *recognizer;
  const SherpaOnnxOnlineStream *stream;
  CreateRecognizerFn create_recognizer;
  DestroyRecognizerFn destroy_recognizer;
  CreateStreamFn create_stream;
  DestroyStreamFn destroy_stream;
  AcceptWaveformFn accept_waveform;
  IsReadyFn is_ready;
  DecodeFn decode;
  GetResultFn get_result;
  DestroyResultFn destroy_result;
  InputFinishedFn input_finished;
};

struct AtomVoiceSherpaPunctuationContext {
  void *onnxruntime_handle;
  void *sherpa_handle;
  const SherpaOnnxOfflinePunctuation *punctuation;
  DestroyPunctuationFn destroy_punctuation;
  AddPunctFn add_punct;
  FreePunctTextFn free_punct_text;
};

static void set_error(char *error_message, int32_t error_message_size, const char *format, ...) {
  if (!error_message || error_message_size <= 0) { return; }

  va_list args;
  va_start(args, format);
  vsnprintf(error_message, (size_t)error_message_size, format, args);
  va_end(args);
}

static void make_path(char *out, size_t out_size, const char *dir, const char *name) {
  snprintf(out, out_size, "%s/%s", dir, name);
}

static int path_exists(const char *path) {
  return access(path, R_OK) == 0;
}

static int load_symbol(void *handle, const char *name, void **out, char *error_message, int32_t error_message_size) {
  *out = dlsym(handle, name);
  if (!*out) {
    set_error(error_message, error_message_size, "Missing symbol %s: %s", name, dlerror());
    return 0;
  }
  return 1;
}

static char *copy_text(const char *text) {
  const char *source = text ? text : "";
  size_t length = strlen(source);
  char *copy = (char *)malloc(length + 1);
  if (!copy) { return NULL; }
  memcpy(copy, source, length + 1);
  return copy;
}

static void decode_available(AtomVoiceSherpaContext *context) {
  while (context->is_ready(context->recognizer, context->stream)) {
    context->decode(context->recognizer, context->stream);
  }
}

AtomVoiceSherpaContext *AtomVoiceSherpaCreate(const char *lib_dir,
                                              const char *model_dir,
                                              char *error_message,
                                              int32_t error_message_size) {
  if (error_message && error_message_size > 0) { error_message[0] = '\0'; }
  if (!lib_dir || !model_dir) {
    set_error(error_message, error_message_size, "Missing runtime or model path");
    return NULL;
  }

  char onnxruntime_path[4096];
  char sherpa_path[4096];
  make_path(onnxruntime_path, sizeof(onnxruntime_path), lib_dir, "libonnxruntime.1.24.4.dylib");
  make_path(sherpa_path, sizeof(sherpa_path), lib_dir, "libsherpa-onnx-c-api.dylib");

  if (!path_exists(onnxruntime_path) || !path_exists(sherpa_path)) {
    set_error(error_message, error_message_size, "Sherpa runtime libraries not found in %s", lib_dir);
    return NULL;
  }

  char encoder[4096];
  char decoder[4096];
  char joiner[4096];
  char tokens[4096];
  make_path(encoder, sizeof(encoder), model_dir, "encoder-epoch-99-avg-1.int8.onnx");
  make_path(decoder, sizeof(decoder), model_dir, "decoder-epoch-99-avg-1.onnx");
  make_path(joiner, sizeof(joiner), model_dir, "joiner-epoch-99-avg-1.int8.onnx");
  make_path(tokens, sizeof(tokens), model_dir, "tokens.txt");

  if (!path_exists(encoder) || !path_exists(decoder) || !path_exists(joiner) || !path_exists(tokens)) {
    set_error(error_message, error_message_size, "Sherpa model files not found in %s", model_dir);
    return NULL;
  }

  AtomVoiceSherpaContext *context = (AtomVoiceSherpaContext *)calloc(1, sizeof(AtomVoiceSherpaContext));
  if (!context) {
    set_error(error_message, error_message_size, "Out of memory");
    return NULL;
  }

  context->onnxruntime_handle = dlopen(onnxruntime_path, RTLD_NOW | RTLD_GLOBAL);
  if (!context->onnxruntime_handle) {
    set_error(error_message, error_message_size, "Failed to load onnxruntime: %s", dlerror());
    AtomVoiceSherpaDestroy(context);
    return NULL;
  }

  context->sherpa_handle = dlopen(sherpa_path, RTLD_NOW | RTLD_LOCAL);
  if (!context->sherpa_handle) {
    set_error(error_message, error_message_size, "Failed to load sherpa-onnx: %s", dlerror());
    AtomVoiceSherpaDestroy(context);
    return NULL;
  }

#define LOAD_REQUIRED(symbol_name, field_name) \
  if (!load_symbol(context->sherpa_handle, symbol_name, (void **)&context->field_name, error_message, error_message_size)) { \
    AtomVoiceSherpaDestroy(context); \
    return NULL; \
  }

  LOAD_REQUIRED("SherpaOnnxCreateOnlineRecognizer", create_recognizer)
  LOAD_REQUIRED("SherpaOnnxDestroyOnlineRecognizer", destroy_recognizer)
  LOAD_REQUIRED("SherpaOnnxCreateOnlineStream", create_stream)
  LOAD_REQUIRED("SherpaOnnxDestroyOnlineStream", destroy_stream)
  LOAD_REQUIRED("SherpaOnnxOnlineStreamAcceptWaveform", accept_waveform)
  LOAD_REQUIRED("SherpaOnnxIsOnlineStreamReady", is_ready)
  LOAD_REQUIRED("SherpaOnnxDecodeOnlineStream", decode)
  LOAD_REQUIRED("SherpaOnnxGetOnlineStreamResult", get_result)
  LOAD_REQUIRED("SherpaOnnxDestroyOnlineRecognizerResult", destroy_result)
  LOAD_REQUIRED("SherpaOnnxOnlineStreamInputFinished", input_finished)

#undef LOAD_REQUIRED

  SherpaOnnxOnlineRecognizerConfig config;
  memset(&config, 0, sizeof(config));
  config.feat_config.sample_rate = 16000;
  config.feat_config.feature_dim = 80;
  config.model_config.transducer.encoder = encoder;
  config.model_config.transducer.decoder = decoder;
  config.model_config.transducer.joiner = joiner;
  config.model_config.tokens = tokens;
  config.model_config.num_threads = 1;
  config.model_config.provider = "cpu";
  config.decoding_method = "greedy_search";

  context->recognizer = context->create_recognizer(&config);
  if (!context->recognizer) {
    set_error(error_message, error_message_size, "Failed to create sherpa-onnx recognizer");
    AtomVoiceSherpaDestroy(context);
    return NULL;
  }

  context->stream = context->create_stream(context->recognizer);
  if (!context->stream) {
    set_error(error_message, error_message_size, "Failed to create sherpa-onnx stream");
    AtomVoiceSherpaDestroy(context);
    return NULL;
  }

  return context;
}

int32_t AtomVoiceSherpaAcceptWaveform(AtomVoiceSherpaContext *context,
                                      int32_t sample_rate,
                                      const float *samples,
                                      int32_t sample_count) {
  if (!context || !context->stream || !samples || sample_count <= 0) { return 0; }

  context->accept_waveform(context->stream, sample_rate, samples, sample_count);
  decode_available(context);
  return 1;
}

char *AtomVoiceSherpaGetResult(AtomVoiceSherpaContext *context) {
  if (!context || !context->recognizer || !context->stream) { return NULL; }

  const SherpaOnnxOnlineRecognizerResult *result = context->get_result(context->recognizer, context->stream);
  char *text = copy_text(result ? result->text : "");
  if (result) { context->destroy_result(result); }
  return text;
}

char *AtomVoiceSherpaFinish(AtomVoiceSherpaContext *context) {
  if (!context || !context->stream) { return NULL; }

  context->input_finished(context->stream);
  decode_available(context);
  return AtomVoiceSherpaGetResult(context);
}

void AtomVoiceSherpaDestroy(AtomVoiceSherpaContext *context) {
  if (!context) { return; }

  if (context->stream && context->destroy_stream) {
    context->destroy_stream(context->stream);
  }
  if (context->recognizer && context->destroy_recognizer) {
    context->destroy_recognizer(context->recognizer);
  }
  if (context->sherpa_handle) {
    dlclose(context->sherpa_handle);
  }
  if (context->onnxruntime_handle) {
    dlclose(context->onnxruntime_handle);
  }
  free(context);
}

void AtomVoiceSherpaFreeString(char *text) {
  free(text);
}

AtomVoiceSherpaPunctuationContext *AtomVoiceSherpaPunctuationCreate(const char *lib_dir,
                                                                    const char *model_dir,
                                                                    char *error_message,
                                                                    int32_t error_message_size) {
  if (error_message && error_message_size > 0) { error_message[0] = '\0'; }
  if (!lib_dir || !model_dir) {
    set_error(error_message, error_message_size, "Missing runtime or punctuation model path");
    return NULL;
  }

  char onnxruntime_path[4096];
  char sherpa_path[4096];
  char model_path[4096];
  make_path(onnxruntime_path, sizeof(onnxruntime_path), lib_dir, "libonnxruntime.1.24.4.dylib");
  make_path(sherpa_path, sizeof(sherpa_path), lib_dir, "libsherpa-onnx-c-api.dylib");
  make_path(model_path, sizeof(model_path), model_dir, "model.int8.onnx");

  if (!path_exists(onnxruntime_path) || !path_exists(sherpa_path)) {
    set_error(error_message, error_message_size, "Sherpa runtime libraries not found in %s", lib_dir);
    return NULL;
  }
  if (!path_exists(model_path)) {
    set_error(error_message, error_message_size, "Sherpa punctuation model not found in %s", model_dir);
    return NULL;
  }

  AtomVoiceSherpaPunctuationContext *context =
      (AtomVoiceSherpaPunctuationContext *)calloc(1, sizeof(AtomVoiceSherpaPunctuationContext));
  if (!context) {
    set_error(error_message, error_message_size, "Out of memory");
    return NULL;
  }

  context->onnxruntime_handle = dlopen(onnxruntime_path, RTLD_NOW | RTLD_GLOBAL);
  if (!context->onnxruntime_handle) {
    set_error(error_message, error_message_size, "Failed to load onnxruntime: %s", dlerror());
    AtomVoiceSherpaPunctuationDestroy(context);
    return NULL;
  }

  context->sherpa_handle = dlopen(sherpa_path, RTLD_NOW | RTLD_LOCAL);
  if (!context->sherpa_handle) {
    set_error(error_message, error_message_size, "Failed to load sherpa-onnx: %s", dlerror());
    AtomVoiceSherpaPunctuationDestroy(context);
    return NULL;
  }

  CreatePunctuationFn create_punctuation = NULL;
  if (!load_symbol(context->sherpa_handle, "SherpaOnnxCreateOfflinePunctuation", (void **)&create_punctuation, error_message, error_message_size) ||
      !load_symbol(context->sherpa_handle, "SherpaOnnxDestroyOfflinePunctuation", (void **)&context->destroy_punctuation, error_message, error_message_size) ||
      !load_symbol(context->sherpa_handle, "SherpaOfflinePunctuationAddPunct", (void **)&context->add_punct, error_message, error_message_size) ||
      !load_symbol(context->sherpa_handle, "SherpaOfflinePunctuationFreeText", (void **)&context->free_punct_text, error_message, error_message_size)) {
    AtomVoiceSherpaPunctuationDestroy(context);
    return NULL;
  }

  SherpaOnnxOfflinePunctuationConfig config;
  memset(&config, 0, sizeof(config));
  config.model.ct_transformer = model_path;
  config.model.num_threads = 1;
  config.model.provider = "cpu";

  context->punctuation = create_punctuation(&config);
  if (!context->punctuation) {
    set_error(error_message, error_message_size, "Failed to create sherpa-onnx punctuation model");
    AtomVoiceSherpaPunctuationDestroy(context);
    return NULL;
  }

  return context;
}

char *AtomVoiceSherpaPunctuationAddPunct(AtomVoiceSherpaPunctuationContext *context,
                                         const char *text) {
  if (!context || !context->punctuation || !context->add_punct || !text) { return NULL; }

  const char *punctuated = context->add_punct(context->punctuation, text);
  char *copy = copy_text(punctuated);
  if (punctuated && context->free_punct_text) {
    context->free_punct_text(punctuated);
  }
  return copy;
}

void AtomVoiceSherpaPunctuationDestroy(AtomVoiceSherpaPunctuationContext *context) {
  if (!context) { return; }

  if (context->punctuation && context->destroy_punctuation) {
    context->destroy_punctuation(context->punctuation);
  }
  if (context->sherpa_handle) {
    dlclose(context->sherpa_handle);
  }
  if (context->onnxruntime_handle) {
    dlclose(context->onnxruntime_handle);
  }
  free(context);
}
