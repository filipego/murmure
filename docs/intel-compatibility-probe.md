# Intel compatibility probe

The shipping Murmure app remains Apple Silicon only and requires macOS 26. This probe is a
separate, reduced experiment for the 2020 Intel MacBook Air. It uses Apple's older Speech
framework with on-device recognition and does not include Command Mode, Apple Intelligence,
or the macOS 26 `SpeechAnalyzer` pipeline.

Build it on the development Mac:

```bash
make intel-probe
```

Copy this one executable to the Intel Mac:

```text
~/Library/Caches/MurmurYouTubeBuild/MurmureIntelSpeechProbe
```

Run it from Terminal with a short prerecorded audio file and an optional locale. The file can
be WAV, M4A, or another format accepted by Apple's Speech framework.

```bash
/usr/bin/time -l ./MurmureIntelSpeechProbe sample.m4a en-US
```

The probe requests Speech Recognition permission, forces on-device recognition, and prints a
JSON report containing architecture, macOS version, locale, recognizer availability, on-device
support, latency, transcript, and any error. `/usr/bin/time -l` reports peak memory separately.

Test at least English plus the languages that matter to the intended user. Record accuracy,
latency, peak memory, and whether `supportsOnDeviceRecognition` is true. Run the same sample
twice because the first invocation may include model preparation.

Compilation proves only that an x86_64 macOS 15 executable can be produced. Intel support must
remain unclaimed until this probe is run on the actual 2020 Intel Air. A 2014 or 2015 Mac using
an unofficial macOS installation is experimental and requires a separate physical test.
