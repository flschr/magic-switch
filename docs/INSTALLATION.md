# Install Magic Switch safely

1. Transfer the ZIP or DMG to each Mac. Never transfer the unpacked `.app`
   through iCloud Drive, Dropbox, a NAS, or another sync provider.
2. Unpack the ZIP locally, or open the DMG.
3. Move **Magic Switch.app** to **Applications**.
4. Open it from Applications. For a private, non-notarized build, Control-click
   the app and choose **Open** the first time.
5. In **Settings → Pairing**, generate a code on one Mac and enter the same code
   on the other Mac.

Version 2.29.2 intentionally uses this fork's own app and Keychain identity.
When upgrading from an older build, macOS treats it as a clean installation:
select the keyboard, mouse, and other Mac again, then create a new pairing code.

Keychain error `-67028` means the app bundle changed after it was signed. Delete
that copy and reinstall from the ZIP or DMG. Re-pairing or deleting Keychain
items cannot repair a damaged app bundle.

Keychain error `-25244` means an older build created the pairing key under a
different app identity. Version 2.29.2 no longer reads that legacy item; install
2.29.2 on both Macs and pair them with a newly generated code.
