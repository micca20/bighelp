# bighelp font provenance

Only font software with verified iOS application embedding and redistribution
rights may be added to this directory or to `UIAppFonts`.

## Bundled font: Noto Sans 2.015

- Copyright: Copyright 2022 The Noto Project Authors.
- License: SIL Open Font License 1.1, reproduced in `OFL.txt`.
- Official release: https://github.com/notofonts/latin-greek-cyrillic/releases/tag/NotoSans-v2.015
- Release archive: https://github.com/notofonts/latin-greek-cyrillic/releases/download/NotoSans-v2.015/NotoSans-v2.015.zip
- Archive path for both faces: `NotoSans/full/ttf/`.
- Release archive SHA-256: `0c34df072a3fa7efbb7cbf34950e1f971a4447cffe365d3a359e2d4089b958f5`.

| Repository file | PostScript name | SHA-256 |
| --- | --- | --- |
| `NotoSans-Regular.ttf` | `NotoSans-Regular` | `f5f552c8c5edb61fe6efb824baf4d4de47b1a8689ab4925ff43f7bd6a4ebece5` |
| `NotoSans-SemiBold.ttf` | `NotoSans-SemiBold` | `bfcab863fec70318e9af8ead5266176a5231a77e693dacfc10f572754f9463a6` |
| `OFL.txt` | n/a | `cee9892f9f0cc8fe882c9e9537ee6a89621d86ee7ceaf70b02e2b2b1c25c061a` |

## Unbundled fonts blocked on official app licenses

None of the files below is present in the repository or declared in
`UIAppFonts`. Candidate names stay in the theme so a future licensed file can
be added without changing the visual contract.

Every blocked face must have the following authoritative acceptance evidence
recorded here before its binary is included:

1. The licensed app-embedding grant or receipt for this application.
2. The exact delivered filename from the officially licensed vendor delivery.
3. The embedded PostScript name read from that delivered binary.
4. The SHA-256 of that exact delivered binary.
5. The official source and version.
6. Successful app-bundle and runtime validation, including `UIAppFonts`, the
   bundle-root resource, CoreText registration, and `UIFont` construction.

| Requested face | Official app-license source | Vendor-controlled delivery and gate |
| --- | --- | --- |
| Söhne Buch | Klim Type Foundry Söhne: https://klim.co.nz/fonts/soehne/ and App Font Licence: https://klim.co.nz/licences/app-fonts/ | The official licensed vendor delivery controls the exact filename. Include only after all authoritative acceptance evidence above is recorded. Desktop, web, and test fonts are not acceptable. |
| Söhne Halbfett | Klim Type Foundry Söhne: https://klim.co.nz/fonts/soehne/ and App Font Licence: https://klim.co.nz/licences/app-fonts/ | The official licensed vendor delivery controls the exact filename. Include only after all authoritative acceptance evidence above is recorded. Desktop, web, and test fonts are not acceptable. |
| Söhne Mono | Klim Type Foundry Söhne Mono: https://klim.co.nz/fonts/soehne-mono/ and App Font Licence: https://klim.co.nz/licences/app-fonts/ | The official licensed vendor delivery controls the exact filename. Include only after all authoritative acceptance evidence above is recorded. Until then, code uses the system monospace design. |
| OpenAI Sans | Official OpenAI brand program: https://openai.com/brand/ | The official licensed vendor delivery controls the exact filename. Include only after all authoritative acceptance evidence above, including an explicit redistribution grant for this application, is recorded. Public brand guidance, browser, trial, and desktop files are not sufficient. |
| Sigurd Variable | Blaze Type Sigurd: https://blazetype.eu/typefaces/sigurd/ and App/Game license: https://blazetype.eu/license/ | The official licensed vendor delivery controls the exact filename. Include only after all authoritative acceptance evidence above is recorded. Trial and browser files are not acceptable. |
| Rules Variable | Blaze Type Rules: https://blazetype.eu/typefaces/rules/ and App/Game license: https://blazetype.eu/license/ | The official licensed vendor delivery controls the exact filename. Include only after all authoritative acceptance evidence above is recorded. Trial and browser files are not acceptable. |
| Segoe UI Regular | Microsoft Segoe UI source/file list: https://learn.microsoft.com/en-us/typography/font-list/segoe-ui and redistribution gate: https://learn.microsoft.com/en-us/typography/fonts/font-faq | Microsoft lists `Segoeui.ttf`, but the face remains blocked until all authoritative acceptance evidence above, including Monotype/Microsoft extended app rights for this non-Windows application, is recorded. Copies extracted from Windows or Office are not acceptable. |
| Segoe UI Semibold | Microsoft Segoe UI source/file list: https://learn.microsoft.com/en-us/typography/font-list/segoe-ui and redistribution gate: https://learn.microsoft.com/en-us/typography/fonts/font-faq | Microsoft lists `Seguisb.ttf`, but the face remains blocked until all authoritative acceptance evidence above, including Monotype/Microsoft extended app rights for this non-Windows application, is recorded. Copies extracted from Windows or Office are not acceptable. |

There is no verified Rules Mono Variable deliverable in the approved font
contract. Nous code therefore deliberately uses the system monospace fallback
until a separately licensed, real monospace face is supplied and validated.
