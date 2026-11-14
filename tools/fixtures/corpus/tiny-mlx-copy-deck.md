# Copy deck (English source strings)

**Status:** 2026-10-30, Phase 10.
- **Source of truth:** the source of truth for UI text. `Localizable.xcstrings` is generated from it, and `tools/ci/copy-sync.py` fails the build if a key exists in code but not here, or the reverse.
- **Translations:** P1, five languages: de, fr, es, nl, pt (G-017).
- **Precedence:** VISION.md wording is copied verbatim and wins on conflict. Phase 1 ChatGPT/Claude strings (`01-reference/copy-reference.md`) are used as **tone and pattern references only**. We never copy their brand phrases.

**Voice.**
- Calm, short, concrete. Second person.
- No exclamation marks in errors.
- Say what happened, then what to do. Never blame the user. No lectures anywhere: Normal is the model's own behaviour, and AntiChat adds nothing (D-005).
- Numbers are real. Never "0.0 GB", never a fake %.
- Sizes use one decimal under 10 GB ("6.6 GB") and none above ("22 GB"). Times use "~7 min", "≈1–2½ min" only in marketing.

**Placeholders:** `{name}` style. Plurals use xcstrings plural variants (`{count}`).

**Open items:**
- **Q1 (user):** Welcome line 4 and the Evil subtitle use the honest defaults "No lectures." and "Unfiltered. No lectures." (D-007). If the user picks their original words, only keys `onb.1.promise4` and `onb.3.subtitle` change.

## 1. Onboarding

| Key | String |
|---|---|
| `onb.brand.tag` | On-device AI |
| `onb.nav.back` | Back |
| `onb.nav.step` | {n} / 4 |
| `onb.1.headline` | AI that you own. |
| `onb.1.promise1` | Fully private. |
| `onb.1.promise2` | No accounts. |
| `onb.1.promise3` | Full control. |
| `onb.1.promise4` | No lectures. |
| `onb.1.small` | Runs privately on your Mac. |
| `onb.1.cta` | Get started |
| `onb.noInternet` | Connect to the internet to download your AI (one time) |
| `onb.2.title` | What do you want to enable? |
| `onb.2.subtitle` | Chat is the default. |
| `onb.pack.chat.name` / `.verb` | Chat / Talk and write |
| `onb.pack.voice.name` / `.verb` | Voice / Speak and listen |
| `onb.pack.photo.name` / `.verb` | Photo / Make pictures |
| `onb.pack.video.name` / `.verb` | Video / Make clips |
| `onb.pack.default` | Default |
| `onb.pack.size` | {size} · ~{minutes} min |
| `onb.pack.dimmed.ram` | Needs {gb} GB memory |
| `onb.pack.dimmed.chip` | Too slow on this Mac's chip |
| `onb.pack.dimmed.photo.t0` | Needs 16 GB memory (background removal still works) |
| `onb.hardware` | {chip} · {ram} GB memory · {free} GB available |
| `onb.hardware.probing` | Checking your Mac… |
| `onb.2.total` | Total {size} · ~{minutes} min |
| `onb.diskShort` | Needs {gb} GB more free space. Choose fewer, or free up space. |
| `onb.cta.continue` | Continue |
| `onb.3.title` | Evil Mode |
| `onb.3.subtitle` | Unfiltered. No lectures. |
| `onb.3.body` | No lectures, near-zero refusals, adult content allowed. It can be wrong, offensive or explicit. You're responsible for how you use it. One thing is blocked in every mode: sexual images or video involving minors. |
| `onb.3.toggle` | Enable Evil Mode |
| `onb.3.adult` | I'm 18 or older and responsible for how I use Evil Mode. |
| `onb.3.cost` | Evil adds {size} |
| `onb.3.availability.all` | Available for every pack you chose on this Mac. |
| `onb.3.availability.some` | Available for {packs} on this Mac. |
| `onb.3.availability.none` | Evil not available on this Mac yet. |
| `onb.3.later` | You can change this anytime in Settings. |
| `onb.4.title` | Preparing your AI |
| `onb.4.subtitle.ready` | Chat is ready. Open it while the others finish. |
| `onb.4.subtitle.waiting` | Getting Chat ready first. You can start typing now. |
| `onb.4.row.waiting` / `.downloading` / `.checking` / `.ready` / `.paused` / `.failed` | Waiting / {percent}% / Checking / Ready / Paused — no internet / Didn't finish. Retry |
| `onb.4.row.evil` | Evil Mode |
| `onb.4.footer` | {ready} of {total} ready |
| `onb.4.cta` | Open chat |
| `onb.4.mac.title` | Ready for your Mac |
| `onb.4.badge.accel` | Native acceleration |
| `onb.4.badge.silicon` | Apple silicon |
| `onb.4.mac.note` | Your models stay on this Mac. You can change them later in Settings → Capabilities. |
| `onb.4.search.label` | Search the web when it helps |
| `onb.4.search.note` | Your search words go to public search engines. Never your chats or your name. |
| `move.title` | Move AntiChat to Applications? |
| `move.body` | AntiChat needs to be in Applications to update itself. |
| `move.cta` / `move.later` | Move to Applications / Not now |

**DMG background and website (macOS gate, P-platform-01 option a):** "Drag to Applications · Requires macOS 26 Tahoe or later · Apple silicon". The in-app "AntiChat needs macOS 26…" screen from VISION §1.2 is dropped. macOS shows its own alert first (architecture §1.2).

## 2. Main window, sidebar, menus

| Key | String |
|---|---|
| `side.newChat` | New chat |
| `side.search` | Search |
| `side.library` | Library |
| `side.projects` | Projects |
| `side.pinned` / `side.today` / `side.week` / `side.older` | Pinned / Today / Previous 7 days / Older |
| `side.untitled` | New chat |
| `row.rename` / `row.pin` / `row.unpin` / `row.move` / `row.export` / `row.archive` / `row.delete` | Rename / Pin / Unpin / Move to project / Export / Archive / Delete |
| `row.delete.confirm` | Delete "{title}"? This can't be undone. |
| `row.delete.cta` | Delete |
| `side.settings` | Settings |
| `net.offline` | Offline — everything still works |
| `net.offlineShort` | Offline |
| `net.onlineOn` | Online features on |
| `net.offlineOnly` | Offline only |
| `pill.download` | {pack} {percent}% |
| `pill.update` | Restart to update |
| `title.incognito` | Incognito |
| `badge.evil` | Evil |
| `a11y.evilChat` | Evil mode chat |
| `menu.file.newChat` / `.newEvilChat` / `.newIncognito` / `.export` | New Chat / New Evil Chat / New Incognito Chat / Export Chat… |
| `menu.view.sidebar` / `.panel` | Toggle Sidebar / Toggle Side Panel |
| `menu.help.whatsNew` / `.report` / `.shortcuts` | What's New / Report a Problem… / Keyboard Shortcuts |

## 3. Empty states and suggestions

| Key | String |
|---|---|
| `empty.headline` | What's on your mind? |
| `empty.evil.headline` | Ask anything. |
| `empty.evil.sub` | Evil chat · direct answers, no lectures |
| `empty.incognito.headline` | Incognito chat |
| `empty.incognito.sub` | Nothing from this chat is saved. It disappears when you close it. |
| `empty.project.headline` | No chats in {project} yet |
| `empty.offline.sub` | You're offline. Chat, voice, pictures and files still work. |
| `sugg.image` | Make a picture of… |
| `sugg.voice` | Talk to me |
| `sugg.pdf` | Summarise a PDF |
| `sugg.trip` | Plan a trip (uses the web) |
| `sugg.sheet` | Turn notes into a spreadsheet |
| `tour.title` | What can AntiChat do? |
| `tour.body` | Chat, talk, make pictures and clips, read your files and write new ones — all on this Mac. Just ask. |
| `tour.dismiss` | Got it |
| `library.empty` | Pictures, videos and files you make or attach will show up here. |
| `projects.empty` | Projects keep related chats, files and instructions together. |
| `search.empty` | No chats or settings match "{query}". |
| `search.askTab` | Tab to ask as a new chat |

## 4. Composer

| Key | String |
|---|---|
| `composer.placeholder` | Ask anything |
| `composer.placeholder.evil` | Ask anything — Evil chat |
| `composer.noModel` | Chat isn't installed yet. Open Settings → Capabilities. |
| `composer.queued` | Will send when the model is ready |
| `add.files` / `add.image` / `add.video` / `add.file` / `add.web` / `add.connections` / `add.skills` / `add.project` | Add photos & files / Create image / Create video / Create file / Web search / Connections / Skills / Use project |
| `add.file.pdf` / `.docx` / `.xlsx` / `.pptx` / `.chart` | PDF / Word document / Excel spreadsheet / Slides / Chart |
| `add.disabled.pack` | Install {pack} to use this |
| `add.disabled.offline` | Needs the internet |
| `tip.think` | Think harder |
| `tip.mic` | Dictate ({shortcut}) |
| `tip.voice` | Talk ({shortcut}) |
| `tip.send` / `tip.stop` | Send (Return) / Stop |
| `mode.normal` / `mode.evil` | Normal / Evil |
| `evil.locked` | Mode is set per chat. |
| `evil.continueEvil` / `evil.continueNormal` | Continue in a new Evil chat / Continue in a new Normal chat |
| `evil.downloading` | Evil ready in ~{minutes} min |
| `dictation.cancel` / `.stop` / `.send` | Cancel / Stop and review / Send now |
| `chip.remove` | Remove {tool} |

## 5. Messages, activity, status

| Key | String |
|---|---|
| `status.thinking` | Thinking… |
| `status.loadingModel` | Loading model… |
| `status.reading` | Reading {file} · {percent}% |
| `status.readingScan` | Reading scan · page {page} of {pages} |
| `status.searching` | Searching the web |
| `status.tool` | Using {tool} |
| `status.thought` | Thought for {seconds} s |
| `act.searched` | Searched the web · {count} sources |
| `act.created` | Created {filename} |
| `act.memory` | Memory updated |
| `act.memoryRead` | Used memory |
| `act.skill` | Using skill {name} |
| `act.connection` | Used {app} |
| `act.failed` | {action} didn't work. Retry |
| `msg.copy` / `msg.copied` / `msg.readAloud` / `msg.stopReading` / `msg.regenerate` / `msg.changePlaceholder` / `msg.like` / `msg.dislike` / `msg.more` / `msg.branch` / `msg.modelInfo` | Copy / Copied / Read aloud / Stop reading / Regenerate / Ask to change response / Good response / Bad response / More / Branch in new chat / Model info |
| `msg.dislike.tryAgain` / `.thinkHarder` / `.refused` / `.report` | Try again / Think harder / It refused / Report a problem |
| `msg.version` | {current} / {total} |
| `msg.edit.cancel` / `msg.edit.send` | Cancel / Send |
| `edit.keepsVersions` | Sending creates a new version. The old one stays available. |
| `msg.interrupted` | Response interrupted. |
| `msg.interrupted.edit` / `msg.retry` | Edit prompt / Retry |
| `starter.quick` | Quick model — full model downloading ({percent}%) |
| `starter.upgraded` | Chat upgraded to the full model |
| `scroll.bottom` | Jump to latest |
| `approve.title` | {action} |
| `approve.allowOnce` / `.always` / `.deny` | Allow once / Always allow / Deny |
| `approve.untrusted` | This request came while reading web or tool content. Check it before allowing. |
| `install.card` | {pack} isn't installed. Install it ({size}, ~{minutes} min) and I'll {verbPhrase}. |
| `install.cta` / `install.later` | Install / Not now |
| `install.unavailable` | {pack} doesn't run well on this Mac ({reason}). |
| `memory.propose` | Remember this? "{fact}" |
| `memory.save` / `memory.dismiss` / `memory.undo` | Save / Dismiss / Undo |

## 6. Photo and video

| Key | String |
|---|---|
| `img.creating` | Creating image |
| `img.waiting` | Waiting for the current job |
| `img.loading` | Getting the picture model ready |
| `img.progress` | {percent}% · {seconds} s |
| `img.cancel` / `img.cancelled` | Cancel / Cancelled |
| `img.save` / `img.copy` / `img.edit` / `img.variations` / `img.upscale` / `img.removeBg` / `img.open` | Save / Copy / Edit / Variations / Upscale / Remove background / Open |
| `img.lost` | This picture didn't finish. Retry |
| `media.imageBlocked` | This image can't be shown. |
| `media.videoBlocked` | This video can't be shown. |
| `video.plan` | About {minutes} min on this Mac · {resolution} · {seconds} s |
| `video.start` / `video.change` | Start / Change |
| `video.countdown` | Starting in {n}… |
| `video.battery` | You're on battery ({percent}%). Start anyway? |
| `video.paused.app` | Paused for another app |
| `video.paused.hot` | Paused — your Mac is hot. Resume |
| `video.notEligible` | Video needs {gb} GB memory. This Mac has {ram} GB. |
| `editor.markup` / `.erase` / `.removeBg` / `.sketch` / `.describe` | Markup / Erase / Remove background / Sketch / Describe the change |
| `safety.missing` | Safety check missing — repair ({size}) |
| `safety.missing.body` | Photo and Video are paused until the safety check is repaired. |

The blocked strings are deliberately bare (VISION §2.18). No lecture, no category name, no detail, no retry button.

## 7. Voice

| Key | String |
|---|---|
| `voice.connecting` | Getting voice ready… |
| `voice.listening` | Listening |
| `voice.muteMic` / `voice.unmuteMic` / `voice.muteSpeaker` / `voice.end` | Mute microphone / Unmute microphone / Mute speaker / End |
| `voice.noDevice` | No microphone found |
| `voice.permission` | AntiChat needs the microphone to hear you. Your voice stays on this Mac. |
| `voice.denied` | Microphone access is off. Open System Settings |

## 8. Errors and notices (`AntiChatError.code` → copy)

| Code | Where | String | Actions |
|---|---|---|---|
| `model.notEnoughMemory` | message / job card | Not enough free memory right now. Close some apps or pick a smaller size. | Retry |
| `model.usingLighter` (notice) | under the reply | Using a lighter model while memory is tight. | — |
| `model.lighterSetting` (notice) | job card | Using a lighter setting while memory is tight. | — |
| `model.missing` | message | The {pack} model isn't downloaded yet. | Download ({size}) |
| `model.corrupt` | message / pack row | This model file is damaged. | Re-download ({size}) |
| `model.revoked` | banner | {model} was withdrawn and has been replaced with {replacement}. | Details |
| `engine.restarted` | message | The AI engine restarted. | Retry |
| `engine.crashLoop` | banner | The AI engine keeps stopping. Your chats are safe. | Report a problem · Restart AntiChat |
| `download.offline` | pack row / pill | Paused — no internet. It will continue by itself. | — |
| `download.failed` | pack row | Download didn't finish. | Retry |
| `download.diskFull` | sheet | Needs {gb} GB more free space. | Open Storage |
| `download.verifyFailed` | pack row | A downloaded file didn't match. Downloading it again. | — |
| `network.offlineForSearch` | chip / activity | Web search needs the internet. Answered without it. | — |
| `network.blockedByOfflineOnly` | inline | Offline only is on. | Open Privacy & Data |
| `search.failed` | activity | Couldn't reach search engines. Answered without the web. | Retry search |
| `upload.failed` | tile + toast | Upload failed / Couldn't read {file}. | Remove · Retry |
| `upload.tooLarge` | tile | {file} is too large ({size}; limit {limit}). | Remove |
| `upload.unsupported` | tile | AntiChat can't read {ext} files yet. | Remove |
| `file.encrypted` | tile | This PDF is password-protected. | Enter password |
| `tool.denied` | activity | You denied {action}. | — |
| `tool.failed` | activity | {tool} didn't work: {reason}. | Retry |
| `tool.loopLimit` | message | Stopped after {n} steps to avoid going in circles. | Continue |
| `mcp.authExpired` | connection row / activity | {app} needs you to sign in again. | Sign in |
| `mcp.toolsChanged` | banner | {server} changed its tools. Review before using it again. | Review |
| `relay.notConfigured` | connections page | Connections aren't available yet. | — |
| `relay.rateLimited` | activity | Connections are busy. Try again in a minute. | Retry |
| `relay.overCapacity` / `relay.disabled` | activity | Connections are temporarily unavailable. | — |
| `relay.updateRequired` | banner | Update AntiChat to keep using connections. | Update |
| `sandbox.timeout` | activity | The code ran longer than 60 seconds and was stopped. | — |
| `sandbox.notInstalled` | install card | Running code needs File tools ({size}). | Install |
| `storage.newerVersion` | blocking window | This data was created by a newer AntiChat. | Update AntiChat |
| `storage.migrationFailed` | blocking window | AntiChat couldn't update your data. Nothing was lost — a backup was made first. | Restore backup · Report a problem |
| `update.failed` | settings row | The update didn't install. AntiChat will try again later. | Check now |
| `catalog.expired` | settings banner (warn only) | The model list is out of date. Installed models keep working. | Check now |
| `catalog.badSignature` | settings row | The model list couldn't be verified, so nothing new was installed. | Retry |
| `permission.notifications.off` | banner | Notifications are off. | Open System Settings |
| `permission.accessibility` | inline | The dictation hotkey needs Accessibility access. | Open System Settings |
| `thermal.serious` | job card | Running slower to keep your Mac cool. | — |
| `battery.ask` | plan card | You're on battery ({percent}%). Start anyway? | Start · Later |
| `crash.prompt.title` | at launch | AntiChat quit unexpectedly. | — |
| `crash.prompt.body` | | Send a report? It contains technical details only — no chats, files or audio. You can read it first. | Preview · Send · Don't send |

## 9. Settings (section titles and key labels; full list in `02-target/settings-map.md`)

| Key | String |
|---|---|
| `set.general` / `.appearance` / `.capabilities` / `.evil` / `.voice` / `.personalization` / `.tools` / `.skills` / `.privacy` / `.storage` / `.updates` / `.shortcuts` / `.about` | General / Appearance / Capabilities / Evil Mode / Voice / Personalization / Tools & Connections / Skills / Privacy & Data / Storage / Updates / Keyboard shortcuts / About & Help |
| `set.performance` | Performance: Auto / Maximum / Battery saver |
| `set.cap.advanced` | Advanced |
| `set.cap.override` | Model for {pack} ({mode}) |
| `set.cap.fit.fits` / `.tight` / `.tooLarge` | Fits / Tight / Too large |
| `set.cap.allowOver` | Allow loads above the memory budget |
| `set.cap.keepLoaded` | Keep models loaded: 5 min / 15 min / 30 min / Never unload |
| `set.cap.addHF` | Add a model by Hugging Face ID |
| `set.cap.addHF.gated` | This model needs a Hugging Face account, so AntiChat can't download it. |
| `set.evil.what` | Evil Mode uses uncensored versions of each model. No lectures, near-zero refusals, adult content allowed. One thing is blocked in every mode: sexual images or video involving minors. |
| `set.evil.disable` | Turn off Evil Mode |
| `set.evil.remove` | Remove Evil models — frees {size} |
| `set.evil.hide` | Hide Evil Mode |
| `set.evil.hide.note` | Removes the switch from the chat box, for shared Macs. |
| `set.evil.touchid` | Require Touch ID to open Evil chats |
| `set.evil.memory` | Use memory in Evil chats |
| `set.tools.web` | Web search |
| `set.tools.web.note` | Your search words go to public search engines. Never your chats or your name. |
| `set.tools.safeSearch` | Safe search results |
| `set.tools.location` | Use my approximate location for search |
| `set.tools.code` | Run code (File tools) |
| `set.tools.codeNet` | Allow network for code |
| `set.privacy.offlineOnly` | Offline only |
| `set.privacy.offlineOnly.note` | Nothing leaves this Mac. Web search, connections, updates and downloads pause. |
| `set.privacy.activity` | Network activity |
| `set.privacy.crash` | Send crash reports (you'll see each one first) |
| `set.privacy.deleteAll` | Delete all chats |
| `set.storage.removeEverything` | Remove everything |
| `set.storage.removeEverything.confirm` | This removes all models, chats, pictures, files, caches and settings from this Mac. Export first if you want to keep anything. |
| `set.storage.uninstall` | Uninstall AntiChat… |
| `uninstall.type` | Type UNINSTALL to confirm |
| `set.updates.auto` / `.models` / `.check` / `.notes` | Install app updates automatically / Update models automatically / Check now / Release notes |
| `set.about.report` | Report a problem |
| `set.about.licences` | Licences |
| `set.about.diagnostics` | Export diagnostics |
| `set.about.contentLogs` | Include content in logs (turns off after 24 hours) |

## 10. Connections and skills

| Key | String |
|---|---|
| `conn.title` | Connections |
| `conn.composio.intro` | Connect Gmail, Calendar, Slack and 1,000+ apps. AntiChat asks before anything is sent, changed or deleted. |
| `conn.composio.consent` | When you use a connection, the request and its result pass through AntiChat's connection service and Composio. Your other chats stay on this Mac. |
| `conn.connect` / `conn.disconnect` / `conn.reauth` | Connect / Disconnect / Sign in again |
| `conn.mcp.add` | Add an MCP server |
| `conn.mcp.consent` | {server} will be able to use these tools: {tools}. Writing, sending or deleting always asks first unless you choose otherwise. |
| `skills.add` | Add skill |
| `skills.scriptApproval` | This skill wants to run a script. Allow? |

## 11. Notifications, updates, help

| Key | String |
|---|---|
| `notif.answer` | {chatTitle}: reply ready |
| `notif.image` | Your picture is ready |
| `notif.video` | Your video is ready |
| `notif.download` | {pack} is ready |
| `notif.update` | AntiChat {version} is ready — restart to update |
| `update.restart` | Restart to update |
| `whatsnew.title` | What's new in AntiChat {version} |
| `report.title` | Report a problem |
| `report.body` | Describe what happened. We'll attach technical details you can review — no chats unless you add them. |
| `report.github` / `report.email` | Open on GitHub / Email instead |

## 12. Website-only lines (site/)
- **Hero:** "ChatGPT on your Mac, minus the cloud." **Sub:** "Free. No account. Runs on your Mac's own chip."
- **Requirements:** "Requires macOS 26 Tahoe or later and a Mac with Apple silicon."
- **Intel visitors:** "AntiChat needs a Mac with Apple silicon."
- **Evil page lead:** "Unfiltered. No lectures." plus the `onb.3.body` text and "Evil Mode is for adults. The terms forbid sexual imagery of real people without their consent and anything involving minors."
