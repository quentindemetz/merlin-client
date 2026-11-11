# merlin — Mac app for the Merlin kids' speaker

A native macOS app (Swift/SwiftUI, in `macos/`) that replaces the Android app
`com.hellomerlin` 1.20.5 ("MERLIN – Gérer mon enceinte"), reverse-engineered
from the APK. It keeps a library of audio on this Mac, filled from the Merlin
catalog and your own files, and sends it to a Merlin speaker or an iPod. It
also backs the library up to S3.

An earlier Ruby command-line client and terminal UI lived in this repository
until commit `f956b00`; the git history still has it.

## Building

```sh
cd macos
./build-app.sh            # → build/Merlin.app (add --install to copy it to /Applications)
./test.sh                 # core tests (fake speaker, real pf helper script against a fake pfctl)
```

Both scripts work with the Xcode Command Line Tools alone. The app's state
(login, selected speaker, logs, pending reports, caches) lives in
`~/.config/merlin`; `$MERLIN_HOME` moves it.

## Using the app

### The library

The library is one folder, `~/Music/Merlin Library` by default (*Library ›
Choose Library Folder…* picks or creates another). It holds every audio file
and cover, each named after a UUID (`<uuid>.mp3`, `<uuid>.jpg`), next to
`Library.sqlite`, which stores everything known about them. The database only
records file names relative to the folder, so the folder can be moved, copied
to another disk or opened from another Mac as is.

* **Folders:** media is organised in folders: a Merlin collection, an album,
  or one you make. Each folder sits in a speaker section (Histoires, Musique,
  Documentaires…, plus the sections your speaker actually has, learned at each
  sync). Folders can be renamed, reordered, given a cover or moved to another
  section, and tracks renamed, moved or deleted.
* **From the Merlin catalog:** *Browse* and *Search* (logged in) show the
  catalog. *Download to Library* fetches the selected episodes, a whole
  collection, or one episode from its page. Episodes go into their
  collection's folder, made with the collection's cover on first use; episodes
  without a collection go to "Épisodes Merlin". Episodes already in the library
  can't be downloaded again: catalog rows show a checkmark and *Downloaded*
  (collections show how many episodes you have), and the download buttons are
  disabled for them. Downloads run one at a time in the background; the bar at
  the bottom shows the bytes downloaded out of the total queued (sizes come
  from the catalog), with speed, time left and a Cancel button.
* **Purchases:** some paid audio (on `secure.bayard.io`) has no usable
  catalog link; Merlin only signs it in the sync plan of a speaker the episode
  is waiting to be sent to. Downloading such an episode or collection works
  like any other: the app plays the app's part of a sync without the speaker.
  It adds the episodes to a speaker (the selected one first, then the others),
  starts a synchro, downloads from the plan, reports the synchro as aborted and
  cancels the addition, so the speaker is left as it was. Episodes the speaker
  already has are removed in Merlin (a synchro reported as a success), added
  again, and settled by a second success report; whatever else was waiting
  for the speaker is put aside meanwhile and restored. Merlin caps the titles
  per speaker (120 titles waiting at most, and its free space), so this goes in batches of up to 100 that shrink as needed. *Library › Import Purchases from
  Speaker* does it for every paid episode a speaker has.
* **From your files:** *Import Files…* in the toolbar, or drop files and folders
  on the library. They go into a folder per album tag ("Mes fichiers" for files
  without one), a new folder, or an existing one. Files are kept as they are
  (MP3 at any bitrate, AAC/ALAC, WAV, AIFF, FLAC); only formats macOS can't
  play (Ogg, Opus, WMA, WebM) are converted, to 256 kbps MP3. ffmpeg reads
  tags and artwork and does the conversions (`brew install ffmpeg`).
* **Device copies:** devices get converted copies only when they need one. The
  speaker needs MP3 at 44.1 kHz up to 192 kbps, so anything else gets a 128k
  (64k mono) copy at sync time. The iPod needs MP3, so other formats get a
  256k copy. Copies are made several at a time, cached in
  `~/.config/merlin/cache/converted/`, and remade only when the original changes.
* **Playing:** double-click a track (or select it and press Return or Space)
  to play it and the rest of its folder; folders have a Play button and a
  *Play Folder* menu item. The player bar at the bottom has previous / play /
  next and a seek bar; *Controls* has Play/Pause (⌥⌘P), Next (⌘→) and
  Previous (⌘←), and the keyboard's media keys and Control Center work too.
* **Covers** are kept at up to 600 px, enough for an iPod classic. They are
  also embedded in the MP3s themselves (ID3 picture frame; the folder's cover
  for tracks without their own), so the files show their art in any player.
  The tag's other frames are kept. Changing a folder's cover or moving tracks
  rewrites the embedded covers in the background, and a library made before
  this gets a one-time pass when it's opened. The speaker
  gets 128×128 crops made at each sync. A folder without a cover gets one with
  its name on it on the speaker, since the speaker doesn't display folder names.

### Sending to a speaker

*Send To › Speaker* (⇧⌘S) sends the library to the selected speaker (see
*Speaker transfers* below). Each device has its own
checklist of folders, all checked by default.

The speaker gets the checked folders in place of what Merlin's servers would
put on it. The synchro still starts on Merlin's servers, for the speaker's
Wi-Fi credentials, settings and the report. Merlin's sections (with their
covers) and the favorites node are kept, but emptied. Each library folder then
goes into the section of the same name (compared without case or accents), or
the first section. Titles are shortened to the speaker's 63 bytes. A sync from
the phone app puts Merlin's own content back until the next sync from the Mac.

* **Wi-Fi:** the app reads Wi-Fi names itself (CoreWLAN) and asks for Location
  Services at first launch.
* **Traffic filter:** the admin password is asked with the standard macOS
  dialog, at the first sync of the session. The same `pf` rules are applied by a
  small root helper that talks to the app over two private FIFOs and exits when the
  app quits (see *The traffic filter* below).
* **Quitting during a transfer** aborts it. The app reconnects to your network and reports the
  abort to Merlin before it exits.

### Sending to an iPod

*Send To › iPod* (or *Speaker › Copy to iPod*, ⇧⌘I) copies the library's checked
folders to a click-wheel iPod mounted as a disk. No Merlin account is needed.

On the iPod, each folder becomes an album and a playlist, and all tracks get the
genre "Merlin". Tracks without an artist get their folder's section as artist.
Copying again only copies what changed and removes what's no longer selected.

The database code is a Swift port of libgpod, the library Amarok uses for iPods
(`MerlinCore/ITunesDB.swift`). Unlike libgpod, it leaves the records Merlin didn't
write byte for byte: your own tracks, playlists, smart playlists and artwork links.
It also folds the iPod's play counts and On-The-Go playlists in.

* What Merlin added is listed in `iPod_Control/iTunes/Merlin.json`.
* The first database is kept as `iTunesDB.before-merlin`, and the previous one
  as `iTunesDB.merlin-previous`.
* Models up to the 5th-generation iPod (video), nano 1–2 and mini need no
  checksum. The classic and nano 3–4 need the hash58 checksum, keyed from the
  FireWire ID (read from `SysInfo`/`SysInfoExtended` or the USB serial number).
* **Covers:** each track gets its own cover, or its folder's. They're written
  at the sizes the model shows (`MerlinCore/ArtworkDB.swift`, ported from libgpod's
  artwork writer). Merlin's thumbnails go into their own `.ithmb` files, rewritten
  at each copy; the owner's artwork is kept. Covers show on the iPod photo,
  video, classic and nano 1–4.
* Not supported: shuffle, nano 5+, touch.
* Turn off automatic syncing for the iPod in Finder, or Finder may remove what
  Merlin copied.

### Backup

*Library › Back Up Now* (⇧⌘B) copies the library to an S3 bucket, and the app
does it again on its own about 90 seconds after the library changes (not while
downloads run or the Mac is on the speaker's Wi-Fi). *Library › Restore from
Backup…* rebuilds the library in a new or empty folder and opens it.

* **What goes up:** `files/<name>` for every audio file and cover the database
  refers to, then `Library.sqlite` (a consistent snapshot, uploaded after its
  files) and `backup.json` (track count, size, date, library id). Files are
  compared by size and MD5, so a backup only sends what's new or changed; the
  MD5s of local files are cached in `~/.config/merlin/cache/backup/`. Files
  the library dropped are deleted from the bucket once the new database is up.
* **One library per bucket:** each library has an id (kept by moves, copies and
  restores). A backup won't replace another library's backup unless you
  confirm it (*Back Up Now* asks; automatic backups don't).
* **Restore** downloads into hidden part files and puts the database in last,
  so an interrupted restore isn't a library yet: restoring into the same folder
  again picks up where it stopped.
* **Settings** (*Merlin › Settings…*): bucket, region, an optional folder in the
  bucket, the access key ID (in `config.json`) and the secret key (in the login
  Keychain, item "Merlin S3 Backup"). macOS asks before the app reads it; since
  the app is ad-hoc signed, a rebuild asks again.

The AWS side is in `infra/backup/` (Terraform): a private bucket (TLS only,
versioned, replaced or deleted files kept 90 days) and an IAM user,
`merlin-mac-app`, that can only list, read, write and delete in it. Its
access key is made outside Terraform so the secret stays out of the state:

```sh
cd infra/backup
eval "$(aws configure export-credentials --profile merlin --format env)"
terraform init && terraform apply
aws iam create-access-key --user-name merlin-mac-app   # → Merlin › Settings…
```

The state is local (`terraform.tfstate`, not committed). Tests against the real
bucket run with `MERLIN_S3_TEST_BUCKET=<bucket> AWS_REGION=… AWS_ACCESS_KEY_ID=…
AWS_SECRET_ACCESS_KEY=… ./test.sh --filter S3Integration`.

`MERLIN_API_BASE` / `MERLIN_TOKEN_URL`
point the app at another server, e.g. a local mock.

## Under the hood

### Speaker transfers

A sync starts on Merlin's servers, which return the plan (the speaker's Wi-Fi
credentials, settings and file list). The app then asks you to switch the
speaker on and press its **Wifi / Transfert** button, joins the speaker's
network, transfers, goes back to your usual network and reports the result.

Nothing talks to the Merlin API while the Mac is on the speaker's Wi-Fi. The
report is sent once the Mac is back online. If Merlin isn't reachable within
15 s, the report is saved and sent at the next sync.

### Why syncs need admin rights: the traffic filter

The speaker crashes if this Mac's other traffic reaches it. Joining its Wi-Fi makes the speaker (`192.168.4.1`) the gateway and DNS server for the whole Mac. Every app's reconnects, DNS lookups and captive-portal checks then hit a small device with no internet behind it, and it resets and reboots about 15 s later. The Android app avoids this by binding itself to the speaker network (`requestNetwork` + `bindProcessToNetwork`), so the speaker only ever sees the app's own connection.

On macOS, the app reproduces that with a temporary `pf` rule in the `com.apple/merlin` anchor:

```
pass out quick on en0 proto tcp from 192.168.4.0/24 to 192.168.4.1 port 50000
pass out quick on en0 proto udp from any port 68 to any port 67
block out quick on en0 from 192.168.4.0/24 to any
```

* **What it allows:** only the transfer and DHCP leave the Mac from the speaker's subnet. Routing is untouched.
* **When it's active:** it's applied just before joining the speaker Wi-Fi and removed as soon as the speaker part ends.
* **Admin password:** macOS asks for it with its standard dialog at the first sync of the session, and the app never sees it. It starts a small root helper that only knows "filter on" and "filter off", talks to the app over two private FIFOs, serves every sync until you quit, and exits with the app.
* **Leftovers:** if a sync dies, the next one removes the old rule first, or use *Speaker › Remove Traffic Filter…*.
* **Opting out:** the sync page has a toggle. The speaker will likely crash.

### Wi-Fi switching

1. **Remember:** right after Merlin answers the first request of a sync, the name of the network the Mac is on is noted. A `MERLIN…` network is never noted.
2. **Join:** the speaker's network is looked for every 3 s, and the Mac joins it as soon as it appears (with its password from the sync plan). It gives up after 10 min.
3. **Go back:** after the transfer, success or failure, the speaker network is removed from the Mac's saved networks and the Mac rejoins the remembered one. If that's impossible, Wi-Fi is turned off and on so macOS auto-joins its preferred network.

Since macOS 14, the current network's name and scan results are only available to apps with **Location Services**: the app asks at first launch (click **Allow**). Without it, the Mac keeps trying to join the speaker directly and lets macOS pick the network back.

### Speaker log and recovery

The speaker protocol is traced to `~/.config/merlin/logs/speaker-YYYY-MM-DD.log`: every command and reply with file names, status names and timings, plus timeouts and reconnects. Wi-Fi credentials are never written. Each file's result is also included in the sync report sent to Merlin. *Speaker › Show Logs Folder* opens it.

Like the phone app, a sync survives a speaker that stops answering. On a timeout or a dropped connection, it reconnects and retries the operation, up to 8 more times. Retries are quick: pauses of 1, 1, 2, 2, 3, 3, 5 and 5 s (22 s in total). This is a safety net for genuine Wi-Fi hiccups; the long outages seen during development were the speaker rebooting under the Mac's other traffic, which the traffic filter prevents. Files that already arrived are skipped by the existence check. A refusal from the speaker (e.g. `NOT_ENOUGH_SPACE`) is not retried.

Apart from applying the playlist, no single wait on the speaker exceeds 15 s. Commands and upload acceptance get 5 s. Existence checks take longer for big files, because the speaker reads and hashes the whole file first, at about 1.6 MB/s. Applying the playlist gets 120 s per attempt, because the speaker rebuilds its library. Firmware updates get 15 s.

### HTTP log

Every exchange with Merlin's servers (API calls, login and token refresh, downloads, connectivity checks) is appended to `~/.config/merlin/logs/http-YYYY-MM-DD.jsonl`. Each line is one exchange: id, time, method, URL, request headers and body, response status, headers and body, duration, or the network error. Files are mode 0600 and kept for 14 days. Example query: `jq 'select(.response.status >= 400 or .error)' ~/.config/merlin/logs/http-*.jsonl`.

Redaction happens before anything is written:

* **Removed:** tokens, passwords (account, speaker and home Wi-Fi), `Authorization` and cookie headers, signed-URL parameters, email and username, home Wi-Fi SSID, speaker names, MAC addresses.
* **Kept:** speaker access-point names (`MERLIN_…`), ids, catalog data.
* **Bodies:** API bodies are logged in full, up to 1 MB. Streamed text or JSON is logged up to 256 KB. Binary downloads are summarised as size, content type and SHA-256.

API calls time out after 10 s.

## Protocol notes

### Speaker — TCP `192.168.4.1:50000` on the speaker's own access point

Frame: `[len u8][cmd u8][payload][crc u32 LE]`, where `len = payload + 5`. The
CRC is CRC-32/MPEG-2 over `cmd + payload`. When a file transfer has been
accepted, the file bytes are streamed **unframed** on the same socket.

| cmd | request payload | response payload |
|---|---|---|
| 1 upload | `nameLen, name, size u32, sha256[32]` | status: 0 = send bytes now, 1 = SHA256_VALID (done / already there) |
| 2 ping | – | – |
| 3 / 4 | available / total storage | u32 |
| 5 firmware | – | `major, minor, patch u16` |
| 6 update playlist | JSON filename | status (ROOT_ELEMENT_IS_NOT_ARRAY, MUSIC_NOT_FOUND, …) |
| 7 update firmware | filename | status |
| 8 set date | u32 epoch of local wall-clock time | status |
| 9 end synchronisation, 10 reset | – | – |
| 13 get file | name | `status, nameLen, name, size u32, sha256`, then raw bytes |
| 14 battery | – | `level, charging` |
| 16 set Wi-Fi | `hidden, ssidLen, pwLen, ssid, pw` | status |
| 27 get date | – | u32 |
| 29 enabling hours | `h,m` × 4 (weekday start/end, weekend start/end; 10:00-10:00 = off) | status |
| 30 MAC | – | 6 bytes |
| 31 search file | `verify u8, name` | `status, nameLen, name, sha256` |
| 0xFF | – | unknown command |

Command files: uploading a 1-byte file named `clean_listening.cmd` clears the
stats, and `get_listening.cmd` can be downloaded through cmd 13.

### Cloud

* Login is Keycloak password grant: `POST https://sso.hello-merlin.com/auth/realms/hello-merlin/protocol/openid-connect/token` with `client_id=app`.
* The API lives at `https://api.hello-merlin.com/api/v1/`. Requests carry `Authorization: Bearer …`, `X-Setting-Id` (selects the speaker) and `X-Merlin-*` app headers.
* `POST synchros` with `{status: PENDING, type: TRANSFERT, …}` returns the plan: `id`, `fileList[{type, url, filename, title, filesize}]`, `playlistText`, `time_slot`, `ssid`/`password`, `pendingSsid`/`pendingPassword`.
* File URLs are downloaded without auth.
* Catalog endpoints (all GET):
  * `configs/multi` (gives `home_page_id`)
  * `pages/{id}/full`, made of `modules[]` keyed by `format`: `selection_slider`, `taxon_slider`, `taxon_grid_large`/`_small`, `taxon_slider_potatoes`, `website_purchase`
  * `taxonomies/{id}/full`
  * `collections/{id}/purchase-info` (includes the episodes)
  * `contents/{id}/full`
  * `contents/search/{q}`
  * `packs/list/offered`, `packs/preview/{id}`
  * `catalogs` (the speaker's content tree)

  Durations are in seconds.
* The basket uses:
  * `GET selections`
  * `POST selections {add, contents[]}`
  * `POST selections/collection {add, collectionId}`
  * `DELETE selections {contents[]}`
* `PUT synchros/{id}` sends the report: `status` SUCCESS/FAIL, `status_code` such as `100_SUCCEED`, `firmware_version`, `sd_size`, `available_size`, `mac_address`, `logs`.
