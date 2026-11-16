# AudioStreaming

Source: https://github.com/dimitris-c/AudioStreaming
Version: 1.2.8 (`4d9bb98aed4c4a3962fb31d4f7bb44c6696610de`)
License: MIT; see LICENSE.

MeloX changes:
- Seek using exact packet offsets and discard decoded frames up to the requested sample. When the parser cannot supply an exact offset, decode from the beginning of the audio data.
- Report buffering until decoded audio is ready and expose the pending seek state for the playback clock.
- Trim codec priming and remainder samples using the packet table, matching the native file timeline.
- Flush the final compressed packet at end of input.
- Preserve the source sample rate and channel count in the render graph.

Test fixtures are synthetic chirps generated for MeloX (FFmpeg lavfi), encoded as CBR/VBR MP3, AAC and FLAC.

NeoMusic trial baseline: MeloX commit 3b937b3682f6274ef6157aef156cd59d32ba3dc5, vendor/AudioStreaming.
Only the audio package and its decoder regression fixtures are included; MeloX application code is not included.

NeoMusic changes:
- Linear PCM seeks reopen the container and discard decoded frames to the target; its stream parser rejects discontinuous packet input. Generated WAV waveform regressions cover this path.
- Encoded waveform regression tests also cover 10%, 50%, and 90% positions.
- Paused seeks stop at buffered target samples before render consumption; playback intent can change while seeking.
- End-of-input without a readable audio format reports an error instead of remaining in buffering.
