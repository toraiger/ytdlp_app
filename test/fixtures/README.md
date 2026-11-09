`dash-tone.m4a` is a generated six-second 440 Hz test tone, not user audio.

It was encoded with FFmpeg AAC-LC, stereo, 44.1 kHz, 32 kb/s, using
`empty_moov+default_base_moof+dash` and one-second fragments. The major brand is
`dash`. Its empty initialization movie, track and media headers deliberately
declare the complete duration, matching the structural defect observed in the
submitted format-140 M4A. Fragment sample tables and media bytes are untouched.

The production header normalizer creates the corrected fixture during CI.
