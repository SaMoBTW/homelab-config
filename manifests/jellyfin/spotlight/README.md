Abyss Spotlight add-on, vendored from
https://github.com/AumGupta/abyss-jellyfin/tree/ac84b8840ce7eb7521760bc0d1ed2a045616a0be/scripts/spotlight
(reviewed 2026-09-30: talks only to this Jellyfin server, plus an admin-only,
token-free GitHub release check). To update, copy the three files from a newer
commit and review them again.

The deployment's init container copies Jellyfin's web client into an emptyDir,
adds these files under ui/ and injects the loader <script> into index.html.
JELLYFIN_WEB_DIR points Jellyfin at that copy, so the image's own files are
never modified and every restart or image update re-applies it.
