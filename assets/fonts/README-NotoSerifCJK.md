# Noto Serif CJK SC

The novel reader's existing “衬线” option uses the bundled, unmodified
`NotoSerifCJKsc-Regular.otf`. Android's standard Chinese serif fallback is
Noto Serif CJK; bundling it gives the same Chinese typeface on iOS, Windows,
Android, macOS and Linux without depending on installed system fonts.

Only the regular face is bundled. The reader's medium/bold settings use the
renderer's synthetic weights, as with Android's regular-only serif fallback.
The complete SC face also includes traditional Chinese, Japanese and Korean
glyphs. Fonts are not subsetted to the app's own UI text, since novels can
contain arbitrary characters.

- Upstream: https://github.com/notofonts/noto-cjk
- Revision: `f8d157532fbfaeda587e826d4cd5b21a49186f7c`
- File: `Serif/OTF/SimplifiedChinese/NotoSerifCJKsc-Regular.otf`
- Git blob SHA-1: `cba8a4783cc38574ac7cda52cae7d9b4241c07a5`
- License: SIL Open Font License 1.1; see `OFL-NotoSerifCJK.txt`.

The license is included in the application assets and Flutter's license list.
