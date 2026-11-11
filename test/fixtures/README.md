`dash-tone.m4a` is a generated six-second 440 Hz test tone, not user audio.

It was encoded with FFmpeg AAC-LC, stereo, 44.1 kHz, 32 kb/s, using
`empty_moov+default_base_moof+dash` and one-second fragments. The major brand is
`dash`. Its empty initialization movie, track and media headers deliberately
declare the complete duration, matching the structural defect observed in the
submitted format-140 M4A. Fragment sample tables and media bytes are untouched.

The production header normalizer creates the corrected fixture during CI.

`scripts/prepare_m4a_fixtures.dart` uses the shared test helper to add single-entry
version-0/version-1 edit lists, zero/nonzero starts, and a distinct movie clock.
The generated variants retain the original AAC bytes and relative fragment
addresses. AVFoundation checks every variant over local files and HTTP, plus
seeking and a three-item queue. No uploaded user media is included.
