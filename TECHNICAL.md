# Pager — Technical Reference

> Secure VoIP calling and messaging without a SIM carrier.

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Infrastructure](#infrastructure)
4. [Backend](#backend)
5. [Mobile Client](#mobile-client)
6. [Security & Encryption](#security--encryption)
7. [Real-Time Communication](#real-time-communication)
8. [VoIP & WebRTC](#voip--webrtc)
9. [Media & Attachments](#media--attachments)
10. [Voice Notes](#voice-notes)
11. [Push Notifications](#push-notifications)
12. [Local Persistence](#local-persistence)
13. [State Management](#state-management)
14. [Feature Matrix](#feature-matrix)
15. [API Reference](#api-reference)
16. [Technical Propositions](#technical-propositions)

---

## Overview

Pager is an Android VoIP and messaging application that operates over the internet using virtual IDs (e.g. `PGR-XXXX-XXXX`) instead of phone numbers. All messages are end-to-end encrypted. Calls are peer-to-peer via WebRTC. The app requires no SIM card or carrier.

---

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                        Android Client                         │
│                      (Flutter / Dart)                         │
│                                                               │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐  │
│  │  Auth    │  │ Messages │  │  Calls   │  │  Contacts   │  │
│  │ Provider │  │ Provider │  │ Provider │  │  Provider   │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └──────┬──────┘  │
│       │              │              │                │         │
│  ┌────▼──────────────▼──────────────▼────────────────▼─────┐  │
│  │                    Service Layer                          │  │
│  │  AuthService │ MessagingService │ WebRTCService │ Media  │  │
│  │  SyncService │ SignalingService │ Notification  │ mDNS   │  │
│  └────┬───────────────┬────────────────┬───────────────────┘  │
│       │               │                │                       │
│  ┌────▼──────┐  ┌──────▼──────┐  ┌────▼──────────────────┐   │
│  │  Secure   │  │   SQLite    │  │   CryptoUtils         │   │
│  │  Storage  │  │  (sqflite)  │  │  X25519 + AES-256-GCM │   │
│  └───────────┘  └─────────────┘  └───────────────────────┘   │
└──────────────────────┬───────────────────────┬────────────────┘
                       │ HTTPS / REST           │ WebSocket (Socket.io)
                       │ WebRTC (P2P)           │
┌──────────────────────▼───────────────────────▼────────────────┐
│                     Backend Server                              │
│              Node.js / Express + Socket.io                      │
│                                                                 │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
│  │  /auth   │  │  /users  │  │/messages │  │   /media     │   │
│  │  /turn-  │  │/contacts │  │signaling │  │  (multer)    │   │
│  │credentials│  │          │  │          │  │              │   │
│  └──────────┘  └──────────┘  └──────────┘  └──────────────┘   │
│                         │                                       │
│                  ┌──────▼──────┐                               │
│                  │ PostgreSQL  │                               │
│                  │  Database   │                               │
│                  └─────────────┘                               │
└────────────────────────────────────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │  Firebase FCM   │
                    │ (push notifs)   │
                    └─────────────────┘
```

---

## Infrastructure

| Component | Technology | Details |
|---|---|---|
| Server | DigitalOcean Droplet | IP `137.184.168.242` |
| Runtime | Docker container | Container: `ipager_app` |
| Backend runtime | Node.js | Express 4.x |
| Database | PostgreSQL | Managed inside container |
| Media storage | Local filesystem | `/app/uploads` inside container |
| Push notifications | Firebase Cloud Messaging | `firebase-admin` SDK |
| STUN | Google STUN | `stun.l.google.com:19302` |
| TURN | coturn (self-hosted) | REST API credential spec, 12 h TTL |
| CI/CD | Manual | `scp` + `docker cp` + `docker restart` |

### Deployment Flow

```bash
# Deploy a single backend file
scp <file> root@137.184.168.242:/tmp/<file>
ssh root@137.184.168.242 "docker cp /tmp/<file> ipager_app:/app/src/<file> && docker restart ipager_app"

# Build & install APK
flutter build apk --release
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## Backend

### Stack

| Layer | Technology |
|---|---|
| HTTP framework | Express.js |
| Real-time | Socket.io (WebSocket + polling fallback) |
| Auth | JWT (`jsonwebtoken`, 30-day expiry) |
| Password hashing | bcryptjs (cost 12) |
| File uploads | multer (100 MB limit, UUID-named files) |
| Push | firebase-admin |
| DB client | pg (node-postgres) |

### Database Schema (PostgreSQL)

```sql
users (
  id             UUID PRIMARY KEY,
  virtual_id     TEXT UNIQUE,          -- PGR-XXXX-XXXX
  username       TEXT,
  password_hash  TEXT,
  public_key     TEXT,                 -- X25519 public key (base64)
  avatar_url     TEXT,
  fcm_token      TEXT,
  last_seen      TIMESTAMPTZ
)

messages (
  id                UUID PRIMARY KEY,
  sender_id         UUID REFERENCES users,
  recipient_id      UUID REFERENCES users,
  encrypted_content TEXT,              -- AES-256-GCM ciphertext (base64)
  nonce             TEXT,              -- GCM nonce (base64)
  status            TEXT,             -- 'sent' | 'delivered' | 'read'
  reply_to_id       UUID,
  edited_at         TIMESTAMPTZ,
  is_deleted        BOOLEAN,
  reactions         JSONB,            -- { "emoji": ["userId", ...] }
  attachment_url    TEXT,
  attachment_type   TEXT,             -- 'image' | 'gif' | 'video' | 'audio' | 'file'
  attachment_name   TEXT,             -- filename; voice notes encode effect: "note.m4a#deep"
  attachment_size   INTEGER,
  created_at        TIMESTAMPTZ
)

contacts (
  id           UUID PRIMARY KEY,
  user_id      UUID REFERENCES users,
  contact_id   UUID REFERENCES users
)

call_records (
  id           UUID PRIMARY KEY,
  caller_id    UUID REFERENCES users,
  callee_id    UUID REFERENCES users,
  started_at   TIMESTAMPTZ,
  ended_at     TIMESTAMPTZ,
  status       TEXT                   -- 'answered' | 'missed' | 'rejected'
)

chat_clears (
  user_id      UUID REFERENCES users,
  contact_id   UUID REFERENCES users,
  cleared_at   TIMESTAMPTZ,
  PRIMARY KEY (user_id, contact_id)
)
```

### REST API Routes

| Method | Path | Auth | Description |
|---|---|---|---|
| POST | `/auth/register` | — | Create account, returns JWT + user |
| POST | `/auth/login` | — | Login, returns JWT + user (incl. `avatar_url`) |
| POST | `/auth/update-profile` | ✓ | Update username / avatar URL |
| POST | `/auth/change-password` | ✓ | Change password (requires current) |
| PUT | `/auth/fcm-token` | ✓ | Register FCM push token |
| GET | `/users/me` | ✓ | Own profile (avatar, username, last_seen) |
| GET | `/users/:virtualId` | ✓ | Look up user by virtual ID |
| PUT | `/users/public-key` | ✓ | Update X25519 public key |
| GET | `/contacts` | ✓ | List contacts with last message + unread count |
| POST | `/contacts` | ✓ | Add contact by virtual ID |
| DELETE | `/contacts/:contactId` | ✓ | Remove contact |
| GET | `/messages/:contactId` | ✓ | Paginated message history |
| POST | `/messages/clear` | ✓ | Server-side chat clear |
| POST | `/media/upload` | ✓ | Multipart file upload, returns URL + type |
| GET | `/uploads/:filename` | — | Static media serving |
| GET | `/turn-credentials` | ✓ | Short-lived TURN credentials (coturn REST spec) |
| GET | `/health` | — | Health check |

---

## Mobile Client

### Stack

| Layer | Technology |
|---|---|
| Framework | Flutter 3.x (Dart 3.10) |
| Target platform | Android (minSdk 21) |
| State management | Provider (`ChangeNotifier`) |
| HTTP | `http` package |
| WebSocket | `socket_io_client` |
| WebRTC | `flutter_webrtc` |
| Local DB | `sqflite` (SQLite, schema v6) |
| Secure storage | `flutter_secure_storage` (EncryptedSharedPreferences on Android) |
| Preferences | `shared_preferences` (mirrored token for native code) |
| Crypto | `cryptography` (X25519 + AES-256-GCM) |
| Push | `firebase_messaging` + `flutter_local_notifications` |
| Media recording | `record` 5.0.5 (AAC-LC, `.m4a`) |
| Audio playback | `just_audio` |
| Image picking | `image_picker` |
| File picking | `file_picker` |
| Video playback | `video_player` |
| Video thumbnails | `video_thumbnail` |
| Network images | `cached_network_image` |
| File opening | `open_file` |
| LAN discovery | `multicast_dns` |
| Permissions | `permission_handler` |
| IDs | `uuid` v4 |
| Date formatting | `intl` |

### Module Structure

```
lib/
├── main.dart                    # App entry point, provider setup
├── app.dart                     # MaterialApp, routing
├── core/
│   ├── constants.dart           # Server URL, storage keys, DB name
│   ├── theme.dart               # Dark Telegram-inspired color palette
│   └── crypto_utils.dart        # X25519 + AES-256-GCM helpers
├── data/
│   ├── local/
│   │   ├── database.dart        # SQLite schema + CRUD (v6)
│   │   └── secure_storage.dart  # FlutterSecureStorage wrapper
│   └── models/
│       ├── message.dart
│       ├── contact.dart
│       ├── call_record.dart
│       └── user.dart
├── providers/
│   ├── auth_provider.dart       # Auth state, profile updates
│   ├── messages_provider.dart   # Message list, pagination
│   ├── contacts_provider.dart   # Contact list, presence
│   └── call_provider.dart       # Active call state
├── services/
│   ├── auth_service.dart        # Register, login, session persistence
│   ├── messaging_service.dart   # Socket send/receive, encryption wrapper
│   ├── webrtc_service.dart      # PeerConnection, ICE, call lifecycle
│   ├── signaling_service.dart   # Socket.io signaling events
│   ├── notification_service.dart# FCM + local notification handling
│   ├── sync_service.dart        # Background message sync on reconnect
│   ├── media_service.dart       # Upload/download, thumbnails, GIF picking
│   └── mdns_service.dart        # LAN peer discovery via mDNS
└── ui/
    ├── screens/
    │   ├── splash_screen.dart
    │   ├── auth/
    │   │   ├── login_screen.dart
    │   │   └── register_screen.dart
    │   ├── home/
    │   │   └── home_screen.dart  # 3-tab nav: Chats, Calls, Settings
    │   ├── chat/
    │   │   └── chat_screen.dart  # Full chat UI, input bar, voice notes
    │   ├── call/
    │   │   ├── active_call_screen.dart
    │   │   ├── incoming_call_screen.dart
    │   │   └── outgoing_call_screen.dart
    │   ├── contacts/
    │   │   ├── contacts_screen.dart
    │   │   └── add_contact_screen.dart
    │   ├── settings/
    │   │   ├── settings_screen.dart       # Telegram-style collapsing header
    │   │   └── profile_edit_screen.dart   # Avatar, username, password
    │   └── media/
    │       ├── photo_view_screen.dart
    │       └── video_player_screen.dart
    └── widgets/
        ├── message_bubble.dart      # Full bubble rendering, reactions overlay
        ├── voice_note_player.dart   # Waveform player + voice effects
        ├── user_avatar.dart
        └── contact_tile.dart
```

---

## Security & Encryption

### Key Exchange

- Each user generates an **X25519 keypair** on registration
- The **public key** is stored on the server and shared with contacts
- The **private key** never leaves the device (stored in `EncryptedSharedPreferences`)
- On login from a new device where the private key is lost, a new keypair is generated and the server's public key record is updated

### Message Encryption

```
Sender private key + Recipient public key
         │
         ▼ X25519 ECDH
    Shared Secret (32 bytes)
         │
         ▼ AES-256-GCM
  Encrypted message + nonce (base64)
         │
         ▼ Transmitted over Socket.io / stored in DB
```

1. Sender derives shared secret from their private key + recipient's public key
2. AES-256-GCM encrypts the plaintext with a random 12-byte nonce
3. Ciphertext + 16-byte GCM MAC are concatenated and base64-encoded
4. Only the encrypted payload and nonce are stored on the server or in transit
5. Recipient derives the same shared secret using their private key + sender's public key to decrypt

The server **never** sees plaintext message content.

### Transport Security

- All REST API calls use HTTPS
- Socket.io uses WSS
- JWT tokens expire after 30 days
- Passwords hashed with bcrypt (cost factor 12)

---

## Real-Time Communication

Socket.io is used for all real-time events. The server maintains an in-memory `Map<userId, socketId>` for online presence.

### Socket Events

| Direction | Event | Purpose |
|---|---|---|
| Client → Server | `send-message` | Send encrypted message |
| Client → Server | `typing` | Typing indicator |
| Client → Server | `read-receipt` | Mark messages as read |
| Client → Server | `edit-message` | Edit sent message |
| Client → Server | `delete-message` | Soft-delete message |
| Client → Server | `add-reaction` | Toggle emoji reaction |
| Client → Server | `call-offer` | Initiate WebRTC call |
| Client → Server | `call-answer` | Accept call |
| Client → Server | `call-reject` | Decline call |
| Client → Server | `call-end` | End active call |
| Client → Server | `ice-candidate` | Relay ICE candidate |
| Server → Client | `new-message` | Incoming message |
| Server → Client | `message-ack` | Delivery confirmation |
| Server → Client | `message-edited` | Peer edited a message |
| Server → Client | `message-deleted` | Peer deleted a message |
| Server → Client | `reaction-added` | Reaction state update |
| Server → Client | `user-typing` | Typing indicator from peer |
| Server → Client | `messages-read` | Read receipt from peer |
| Server → Client | `incoming-call` | Incoming call notification |
| Server → Client | `call-answered` | Call accepted |
| Server → Client | `call-rejected` | Call declined |
| Server → Client | `call-ended` | Call terminated |
| Server → Client | `ice-candidate` | ICE candidate relay |
| Server → Client | `presence-update` | Online/offline status |
| Server → Client | `contacts-presence` | Bulk presence on connect |

### Offline Message Delivery

Messages sent while a recipient is offline are stored with `status = 'sent'`. On reconnect, the server queries all pending messages and delivers them in order before any real-time events.

---

## VoIP & WebRTC

### Call Flow

```
Caller                    Server                   Callee
  │                          │                        │
  │── call-offer (SDP) ─────►│                        │
  │◄─ call-offer-ack ────────│                        │
  │                          │── incoming-call ───────►│
  │                          │   (SDP forwarded)       │
  │                          │◄─ call-answer ──────────│
  │◄─ call-answered (SDP) ───│                        │
  │                          │                        │
  │◄══════ ICE candidates relayed both ways ══════════►│
  │                                                    │
  │◄══════════ P2P WebRTC audio stream ═══════════════►│
  │                          │                        │
  │── call-end ─────────────►│── call-ended ──────────►│
```

### ICE / TURN

- Primary: Google STUN (`stun.l.google.com:19302`)
- Fallback: Self-hosted coturn TURN server (UDP + TCP)
- TURN credentials are generated server-side using the coturn REST API spec (HMAC-SHA1, 12-hour TTL)

### Call Records

Answered, missed, and rejected calls are stored locally in SQLite and surfaced in the Calls tab.

---

## Media & Attachments

### Upload Flow

1. Client uploads file via `POST /media/upload` (multipart, max 100 MB)
2. Server stores file with a UUID filename in `/app/uploads`
3. Server auto-detects type from extension + MIME: `image` | `gif` | `video` | `file`
4. Server returns `{ url, type, name, size }`
5. Client sends the URL as part of the message payload over Socket.io

### Supported Types

| Type | Extensions |
|---|---|
| Image | `.jpg` `.jpeg` `.png` `.webp` `.heic` `.bmp` |
| GIF | `.gif` |
| Video | `.mp4` `.mov` `.avi` `.mkv` `.webm` `.3gp` |
| Audio (voice notes) | `.m4a` |
| File | Any other |

### In-App Handling

| Type | Rendering |
|---|---|
| Image | `CachedNetworkImage` with full-screen photo viewer |
| GIF | `CachedNetworkImage` (animated) |
| Video | Thumbnail in bubble → full-screen `video_player` |
| Audio | `VoiceNotePlayer` widget (waveform + playback) |
| File | Download + open with `open_file` |

### GIF Keyboard

`ContentInsertionConfiguration` on the text field enables the system GIF keyboard on Android. Inserted GIFs are uploaded through the standard media upload endpoint.

---

## Voice Notes

### Recording

- Package: `record` 5.0.5
- Codec: AAC-LC (`.m4a`)
- Sample rate: 44,100 Hz, 128 kbps
- Activation: Long-press mic button (replaces send button when text field is empty)
- Cancel: Slide finger left > 80 px while holding
- On release: preview sheet shown with recorded audio

### Voice Effect System

Effects are applied at **playback time only** — no audio re-encoding. The effect ID is encoded in the `attachment_name` field using a `#` separator:

```
voice_note.m4a#deep
```

The `VoiceNotePlayer` widget decodes the suffix and applies pitch + speed via `just_audio`:

| Effect | Pitch | Speed |
|---|---|---|
| Normal | 1.00 | 1.00 |
| Deep | 0.65 | 0.92 |
| Chipmunk | 1.75 | 1.10 |
| Robot | 0.82 | 1.00 |
| Alien | 1.35 | 1.15 |

Both sender and receiver apply the same effect from the same effect ID — no server-side audio processing required.

### Preview Sheet

Before sending, the user sees:
- A `VoiceNotePlayer` preview with the selected effect applied
- A horizontal scroller to pick from 5 voice effect presets
- **Discard** / **Dub Voice** (picks effect) / **Send** actions

---

## Push Notifications

| Scenario | Notification type |
|---|---|
| New message (offline) | FCM data message with sender name and truncated encrypted preview |
| Incoming call (online target) | FCM high-priority, triggers in-app call screen |
| Incoming call (offline target) | FCM high-priority "missed call" notification |

- FCM tokens are stored per user in the `users` table (`fcm_token` column)
- Updated via `PUT /auth/fcm-token` on each app launch
- Firebase Admin SDK is initialized from either `serviceAccountKey.json` or environment variables (`FIREBASE_PROJECT_ID`, `FIREBASE_PRIVATE_KEY`, `FIREBASE_CLIENT_EMAIL`)

---

## Local Persistence

### Secure Storage (`flutter_secure_storage`)

Stores per-session secrets in Android `EncryptedSharedPreferences`:

| Key | Value |
|---|---|
| `auth_token` | JWT |
| `user_id` | UUID |
| `virtual_id` | PGR-XXXX-XXXX |
| `username` | Display name |
| `avatar_url` | Absolute URL |
| `private_key` | X25519 private key (base64) |
| `public_key` | X25519 public key (base64) |
| `avatar_url` | Profile photo URL |

Token and server URL are additionally mirrored to `SharedPreferences` so native Android background isolates (e.g. `QuickReplyReceiver`) can access them without the secure enclave.

### SQLite (`sqflite`, schema v6)

Tables: `contacts`, `messages`, `pending_messages`, `call_records`

Key columns:
- `messages.reactions` — JSONB-compatible TEXT blob `{ "emoji": ["userId"] }`
- `messages.attachment_name` — encodes voice effect: `filename.m4a#effectId`
- `contacts.avatar_url` — cached avatar for contact display

---

## State Management

| Provider | Responsibility |
|---|---|
| `AuthProvider` | Authentication state, profile (username, avatar), JWT lifecycle |
| `MessagesProvider` | Per-conversation message list, pagination, decryption cache |
| `ContactsProvider` | Contact list, unread counts, online presence |
| `CallProvider` | Active call state, duration timer, mute/speaker |

All providers extend `ChangeNotifier`. The widget tree consumes them via `Provider.of` / `context.watch`.

---

## Feature Matrix

| Feature | Status | Notes |
|---|---|---|
| Virtual ID registration (no phone number) | ✓ | PGR-XXXX-XXXX format |
| End-to-end encrypted messaging | ✓ | X25519 + AES-256-GCM |
| VoIP calls (audio) | ✓ | WebRTC P2P |
| Contact management | ✓ | Add by virtual ID |
| Online presence / last seen | ✓ | Socket.io broadcast |
| Typing indicators | ✓ | |
| Message delivery receipts | ✓ | sent → delivered → read |
| Message reactions (emoji) | ✓ | Overlap bubble bottom (Telegram style) |
| Message editing | ✓ | With `edited` label |
| Message deletion | ✓ | Soft-delete, shows placeholder |
| Reply to message | ✓ | Thread preview in bubble |
| Message forwarding | ✓ | Via long-press menu → contact picker |
| Chat clear | ✓ | Server-side via `chat_clears` table |
| Image sharing | ✓ | Camera + gallery, in-app viewer |
| GIF sharing | ✓ | System GIF keyboard + `ContentInsertionConfiguration` |
| Video sharing | ✓ | Record or pick from gallery |
| File sharing | ✓ | Any file, in-app opener |
| Video thumbnails in chat | ✓ | `video_thumbnail` |
| Voice notes | ✓ | Long-press mic, AAC-LC `.m4a` |
| Voice effects | ✓ | 5 presets, playback-side only |
| Push notifications | ✓ | FCM, high-priority for calls |
| Profile photo | ✓ | Upload via media endpoint |
| Username change | ✓ | |
| Password change | ✓ | Requires current password |
| Settings screen | ✓ | Telegram-style collapsing SliverAppBar |
| LAN peer discovery | ✓ | mDNS (`multicast_dns`) |
| TURN relay fallback | ✓ | Self-hosted coturn, REST credential spec |

---

## API Reference

### Authentication Headers

All authenticated endpoints require:
```
Authorization: Bearer <jwt_token>
```

### Virtual ID Format

```
PGR-[A-Z2-9]{4}-[A-Z2-9]{4}
```
Characters exclude `I`, `O`, `0`, `1` to avoid visual ambiguity.

### Voice Effect Encoding

Voice note `attachment_name` format:
```
<filename>#<effectId>
```
Where `effectId` ∈ `{ normal, deep, chipmunk, robot, alien }`. Absent suffix = normal.

---

## Technical Propositions

### Near-Term

#### 1. Video Calls
Extend WebRTC to add a video track. The signaling flow is identical; add camera permission, a `RTCVideoRenderer` widget, and a toggle UI. Consider using `flutter_webrtc`'s `getUserMedia` with `video: true`.

#### 2. Message Search
Add a full-text search bar over local SQLite with `LIKE` queries. For server-side, PostgreSQL `tsvector`/`tsquery` on the plaintext is not possible (E2E encrypted), so search must remain local-only.

#### 3. Group Chats
Requires a key distribution change: a group symmetric key (AES-256) encrypted separately for each member and stored server-side. Backend needs `groups`, `group_members`, and `group_messages` tables. Signaling needs a fan-out broadcast to all online members.

#### 4. Disappearing Messages
Add a `expires_at` column to `messages`. Server-side cron deletes expired rows. Client respects the TTL from a per-conversation setting. Options: 1 h / 24 h / 7 days.

#### 5. Message Status Persistence
Currently delivery/read status is only real-time. Persist `message-ack` and `messages-read` events to the local SQLite `messages` table so status survives app restarts.

### Medium-Term

#### 6. Multi-Device Support
Current design ties one private key to one device. Multi-device requires either:
- **Key sync**: Encrypted key export/import via QR code or passphrase
- **Signal-style multi-key**: Each device registers its own keypair; senders encrypt separately for each device

#### 7. Media Encryption
Attachments are currently uploaded unencrypted (protected only by UUID-based obscurity). Encrypt files with a per-message symmetric key before upload; store the key encrypted alongside the message.

#### 8. Object Storage (S3 / R2)
Replace local `/app/uploads` with S3-compatible object storage (Cloudflare R2 is cost-effective). Benefits: independent scaling, CDN delivery, no Docker volume management.

#### 9. Horizontal Scaling / Redis Presence
The current in-memory `onlineUsers` Map does not survive restarts or multi-instance deploys. Replace with Redis Pub/Sub for presence and Socket.io adapter (`@socket.io/redis-adapter`) for multi-node fan-out.

#### 10. Read Receipts for Attachments
Track when a recipient actually downloads/views a media file, not just when the message arrives.

### Long-Term

#### 11. iOS Support
The core Flutter codebase is cross-platform. Blockers to address:
- Replace `flutter_secure_storage` Android-specific options with iOS Keychain equivalent (already handled by the package)
- Add `NSMicrophoneUsageDescription` and media permissions to `Info.plist`
- APNS integration alongside FCM
- `flutter_webrtc` is already cross-platform

#### 12. Sealed-Sender / Metadata Privacy
Hide the sender's identity from the server at the network level. This requires a sealed-sender envelope scheme (as used in Signal Protocol) so the server cannot observe who is messaging whom.

#### 13. Desktop Clients (macOS / Windows)
Flutter supports desktop. The `record_linux` compatibility shim (`packages/record_linux_patched`) already exists. Main work: OS-specific notification integrations and window management.

#### 14. Backup & Restore
Encrypted local database export (using a user-supplied passphrase to derive a KDF key), enabling chat history migration to new devices.
