# Previewed support summaries

Open **Output Status and Capabilities** from the menu or Dashboard, refresh the
status, then choose **Preview Support Summary**. The preview freezes one snapshot.
Only the exact JSON shown is saved after choosing a file in the save panel.
Closing/canceling does not save anything, and no path uploads data.

The summary includes validated build revision/dirty flag, numeric macOS version,
architecture, logical controller model counts, typed output status and age, and
counts of fixed diagnostic categories from at most the latest 5,000 in-memory
entries. Missing/late output snapshots remain unknown. This is not proof of game
receipt, hardware compatibility, latency or energy efficiency.

The exporter does **not accept or copy log messages**. It cannot export names,
serials, MAC addresses, browser-extension IDs, per-app mappings, filesystem paths,
raw input, NFC tag contents, headset audio or arbitrary preferences. Unknown log
categories are combined under `other`, not used as dictionary keys verbatim.
This deliberately gives less troubleshooting detail than a raw log attachment;
request a focused reproducer rather than silently including raw capture files.

The UTF-8 JSON is bounded to 64 KiB and saved with mode 0600. Private staging and
same-directory rename preserve the previous destination if writing fails.
Symbolic-link and non-regular destinations are refused. Save onto a trusted local
filesystem; this is not secure deletion, encryption, or a guarantee against other
software running as the same user. Review the preview before sharing it yourself.

Saving pins the chosen parent directory, stages a private regular file there,
handles short/interrupted writes, synchronizes the file, validates the destination
without following a symbolic link, and renames relative to that same directory.
Tests inject partial-write, synchronization and promotion failures and verify
that previous bytes survive and temporary files are removed. The UI shows an
explicit success message and cannot be dismissed interactively while saving.
Atomic replacement means complete-file visibility, not power-loss durability or
protection against a hostile process running as the same user. A renamed parent
keeps the saved file in the originally opened directory, not a replacement path.
