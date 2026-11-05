# AudioTags

The unmodified TagLib sources are from the official 2.3.2 release, commit
`deadc2990767dfbda0701e0ab35fdeea653db08f`:
https://github.com/taglib/taglib/tree/deadc2990767dfbda0701e0ab35fdeea653db08f

Only MP3, FLAC, their legacy APE/ID3 metadata, Xiph comments and shared toolkit
sources are compiled. `include/taglib_config.h` is the local build configuration.
TagLib is distributed under its LGPL-2.1 / MPL dual license; see `COPYING.LGPL`
and `COPYING.MPL`. The official sources were taken from the verified, unchanged
source snapshot already used by NeoDizzy.

utfcpp is pinned to `2d8e20b22dcb3e9b3c4f52103182ebda949c6089`; its MIT license
is included as `UTFCPP-LICENSE`.

The package manifest and MP3/FLAC bridge are NeoMusic code. The bridge's tag and
cover operations are adapted from NeoDizzy (GPL-3.0), limited to download
finalization. It does not decode or re-encode audio.
