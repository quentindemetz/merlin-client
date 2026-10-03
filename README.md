# merlin — laptop client for the Merlin kids' speaker

A standalone Ruby (stdlib only) replacement for the Android app
`com.hellomerlin` 1.20.5 ("MERLIN – Gérer mon enceinte"), reverse-engineered
from the APK. It does the same content transfer as the app's "Mon enceinte"
tab, plus a few low-level speaker commands.

## Usage

```sh
bundle install                        # ratatui_ruby (native gem, compiles on first install)
bin/merlin                            # full-screen terminal UI (same as `bin/merlin tui`)
```

### Terminal UI

* **Log in / Log out.** After login, a single speaker is selected automatically. With several, you get a picker.
* **Speaker.** Pick which speaker the next actions apply to.
* **On my speaker.** The speaker's content tree. `space` marks items and `d` queues the marked ones (or the current one) for removal. `c` jumps to the catalog.
* **Browse / Search the catalog.** `enter` opens categories, collections and contents. `a` adds the marked episodes, or the collection under the cursor. Inside a collection, `A` adds every episode.
* **Basket.** Pending adds and removals. `x` cancels the marked ones, `s` starts a sync.
* **Sync now.** Runs the full transfer in the background with a live log. When it's time, a banner shows the speaker's Wi-Fi name and password; join it and press `enter`. You can switch on automatic Wi-Fi switching (macOS `networksetup`) before starting. When you start, the TUI briefly hands the terminal to `sudo` for your admin password; that's for the traffic filter described below, on by default. `ctrl-c` aborts, and the abort is reported to Merlin.

  Nothing talks to the Merlin API while you're on the speaker's Wi-Fi. After the transfer, a second banner asks you to rejoin your usual network. The report is sent as soon as Merlin is reachable again. If you skip the wait with `enter`, the report is saved and sent at the next sync.

### Why syncs need admin rights: the traffic filter

The speaker crashes if this Mac's other traffic reaches it. Joining its Wi-Fi makes the speaker (`192.168.4.1`) the gateway and DNS server for the whole Mac. Every app's reconnects, DNS lookups and captive-portal checks then hit a small device with no internet behind it, and it resets and reboots about 15 s later. The Android app avoids this by binding itself to the speaker network (`requestNetwork` + `bindProcessToNetwork`), so the speaker only ever sees the app's own connection.

On macOS, `sync` reproduces that with a temporary `pf` rule in the `com.apple/merlin` anchor:

```
pass out quick on en0 proto tcp from 192.168.4.0/24 to 192.168.4.1 port 50000
pass out quick on en0 proto udp from any port 68 to any port 67
block out quick on en0 from 192.168.4.0/24 to any
```

* **What it allows:** only the transfer and DHCP leave the Mac from the speaker's subnet. Routing is untouched.
* **When it's active:** it's applied just before joining the speaker Wi-Fi and removed as soon as the speaker part ends.
* **Admin password:** `sudo` asks for it once, before downloads. The tool never sees it. The sudo session is kept alive during long transfers.
* **Leftovers:** if a sync dies, the next one removes the old rule first, or you can run `bin/merlin unisolate`.
* **Opting out:** use `--no-isolate` or the toggle in the TUI. The speaker will likely crash.

### Speaker log and recovery

The speaker protocol is traced to `~/.config/merlin/logs/speaker-YYYY-MM-DD.log`: every command and reply with file names, status names and timings, plus timeouts and reconnects. Wi-Fi credentials are never written. Each file's result is also included in the sync report sent to Merlin.

Like the app, a sync survives a speaker that stops answering. On a timeout or a dropped connection, it reconnects and retries the operation, up to 8 more times. Retries are quick: pauses of 1, 1, 2, 2, 3, 3, 5 and 5 s (22 s in total), and 5 s per reconnect attempt. In auto mode it first rejoins the speaker Wi-Fi. This is a safety net for genuine Wi-Fi hiccups; the long outages seen during development were the speaker rebooting under the Mac's other traffic, which the traffic filter prevents. Files that already arrived are skipped by the existence check. A refusal from the speaker (e.g. `NOT_ENOUGH_SPACE`) is not retried.

Apart from applying the playlist, no single wait on the speaker exceeds 15 s. Commands, existence checks and upload acceptance get 5 s, as does any stalled send. An upload is then confirmed within 5 s plus 1 s per MB, capped at 15 s. TCP connect gets 3 s and the ping after a (re)connect gets 3 s. Applying the playlist gets 120 s per attempt, because the speaker rebuilds its library. Firmware updates get 15 s. Both are retried like everything else. After the transfer, the report waits up to 15 s for internet; otherwise it is sent at the next sync.

### HTTP log

Every HTTP exchange (API calls, login and token refresh, downloads, connectivity checks) is appended to `~/.config/merlin/logs/http-YYYY-MM-DD.jsonl`. Each line is one exchange: id, time, method, URL, request headers and body, response status, headers and body, duration, or the network error. Files are mode 0600 and kept for 14 days. `-v` also prints one summary line per call. Example query: `jq 'select(.response.status >= 400 or .error)' ~/.config/merlin/logs/http-*.jsonl`.

Redaction happens before anything is written, and before truncation:

* **Removed:** tokens, passwords (account, speaker and home Wi-Fi), `Authorization` and cookie headers, signed-URL parameters, email and username, home Wi-Fi SSID, speaker names, MAC addresses. Email addresses and JWTs inside free text are replaced too.
* **Kept:** speaker access-point names (`MERLIN_…`), ids, catalog data.
* **Bodies:** API bodies are logged in full, up to 1 MB. Streamed text or JSON is logged up to 256 KB. Binary downloads are summarised as size, content type and SHA-256.

All HTTP goes through Faraday with a 10 s timeout. That covers connecting and each read or write, so long downloads still work. Network failures surface as "can't reach … — is this Mac still on the speaker's Wi-Fi?" rather than crashing the app.

Keys everywhere: `↑↓`/`j k`, `PgUp`/`PgDn`, `enter`, `esc` back, and `q` quits from the menu.

### Command line

```sh
bin/merlin login you@example.com      # Hello Merlin account (password prompted)
bin/merlin speakers                   # list speakers; `bin/merlin use ID` to pick one
bin/merlin sync                       # full transfer
bin/merlin sync --auto-wifi           # same, switching Wi-Fi via networksetup
bin/merlin sync --dry-run             # create synchro + download files only
```

`sync` first talks to the cloud (to get the plan and download files), then asks
you to switch the speaker on, press its **Wifi / Transfert** button, and join
its `MERLIN…` Wi-Fi network. After the transfer you switch back and it sends the
report. With `--auto-wifi` it switches networks for you using `networksetup`. Add
`--home-ssid` if macOS won't tell it the name of your current network.

Browsing the catalog and choosing what goes on the speaker. Every listed line
starts with a kind and an id, which you pass to the next command. Add `--json`
to get the raw API response.

```sh
bin/merlin browse                     # store home page: sliders of taxa, collections, contents
bin/merlin browse PAGE_ID             # a sub-page ("[taxon] … → page X")
bin/merlin taxon ID                   # a category ("[taxon] … → taxon X")
bin/merlin collection ID              # details and episode list
bin/merlin content ID
bin/merlin search petit ours brun
bin/merlin library                    # what is / will be on the speaker
bin/merlin add CONTENT_ID...          # queue for the next `sync` (also: add-collection ID)
bin/merlin remove CONTENT_ID...       # queue removal from the speaker
bin/merlin basket                     # pending changes; `cancel ID...` drops entries
bin/merlin sync
```

Speaker-only commands (you must already be on the speaker's Wi-Fi):

```sh
bin/merlin info                       # firmware, battery, storage, clock, MAC
bin/merlin upload file.mp3 [NAME]     # skipped if an identical file is present
bin/merlin exists NAME
bin/merlin get NAME [OUT]
bin/merlin apply-playlist playlist-xyz.json
bin/merlin set-time
bin/merlin set-hours 07:30-19:00 off  # weekday window, weekend window
bin/merlin listening [OUT]            # raw listening stats (43-byte records)
```

Global options: `--host`, `--port`, `--setting-id`, `-v` (traces protocol and
HTTP traffic). State is stored in `~/.config/merlin` (override with
`$MERLIN_HOME`). That covers OAuth tokens (mode 0600; the password is never
stored), the selected speaker, downloaded files, and the last synchro plan.

Tests: `rake` (they use an in-process fake speaker and a fake HTTP server).

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
