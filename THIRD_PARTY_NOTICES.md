# Third-Party Notices

AtomVoice uses the following open-source components. Their licenses are reproduced below.

---

## Sherpa-ONNX

**Project:** https://github.com/k2-fsa/sherpa-onnx  
**Usage:** Downloaded on demand as a runtime dylib and ASR/punctuation model files; used for offline local speech recognition.  
**License:** Apache License, Version 2.0

```
Copyright (c) 2022-2024 k2-fsa (Next-generation Kaldi) contributors

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
```

---

## ONNX Runtime

**Project:** https://github.com/microsoft/onnxruntime  
**Usage:** Bundled inside the Sherpa-ONNX release archive (`libonnxruntime.dylib`); downloaded on demand as part of the Sherpa runtime.  
**License:** MIT License

```
Copyright (c) Microsoft Corporation. All rights reserved.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

All other components used by AtomVoice are Apple system frameworks (AVFoundation,
AppKit, Speech, Accelerate, Security, ServiceManagement, etc.) and are governed
by Apple's SDK license terms.
