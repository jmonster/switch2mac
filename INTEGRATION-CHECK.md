# Test-only combined candidate — do not merge this branch

This branch combines the code from PRs #1–#9 without modifying main or
merging any PR. The only test-only changes are this record and push-triggered
read-only workflow definitions. Production changes must land through the
individual PRs, in dependency order.

Tips: #1 d32ed57, #2 ae5996d, #3 2ee0d1c, #4 e4c6b3d,
#5 1babdaf, #6 5df0f78, #7 7a026de, #8 dbe8b15, #9 93419f2.
The #6 tip includes the explicit app-registration merge with #5.
No release, Developer ID signing, notarization, device access, or credentials
are exercised by these workflows. A successful run is not hardware qualification.
