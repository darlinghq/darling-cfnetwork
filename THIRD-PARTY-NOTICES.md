# Third-party material in this repository

Material in this repository that is not Apple's (see `src/APPLE_LICENSE`) and not under the GNU
GPL 3.0 is listed here.

## Public Suffix List, `src/Resources/public_suffix_list.dat`

- Maintained by the Public Suffix List project (Mozilla Foundation and contributors).
- Source: <https://publicsuffix.org/list/public_suffix_list.dat>, version
  2026-11-21_04-33-45_UTC, commit 87a2c1b8de5886a133ff4da21b2aa6fec88d8739 of
  <https://github.com/publicsuffix/list>; unmodified, with its licence notice at the top.
- Licence: Mozilla Public License, version 2.0 (<https://mozilla.org/MPL/2.0/>).
- Use: installed as `Resources/public_suffix_list.dat` of CFNetwork.framework and read at run
  time by `_CFHostIsDomainTopLevel` (`src/Host/CFHostPublicSuffix.c`). It is a separate data
  file, not compiled into the library. To update it, replace the file with a newer copy of the
  list from the source above and update the version here.
