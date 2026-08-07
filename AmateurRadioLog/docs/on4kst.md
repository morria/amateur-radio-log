# ON4KST Chat — Implementation Notes

## Current State

The app has a full ON4KST chat client on the Chat tab: room list, iMessage-style
transcript, directed ("/CQ") messages, arbitrary server commands, and the inline
DX-cluster feed. It speaks the **telnet** interface (`www.on4kst.org:23000`)
directly from the device, foreground-only.

There is no official specification and no vendor API for this service. Everything
here is reverse-engineered from an observed session capture, from `f4exb/colrdx`
(an ncurses client whose `src/dsplnkst.c` is the best available specification),
and from third-party write-ups. Sections below flag what is verified and what
still needs a live capture to confirm.

## Files

| File | Role |
|---|---|
| `Services/ON4KST/ON4KSTProtocol.swift` | Room table + live-menu parser, line classifier, login state machine. All pure — no I/O. |
| `Services/ON4KST/ON4KSTMessage.swift` | Transcript row and heard-station models. |
| `Services/ON4KST/ON4KSTClient.swift` | One `NWConnection` session: login, reconnect, sending. |
| `Services/ON4KST/ON4KSTSession.swift` | Main-actor state the UI renders from. |
| `Views/Chat/*` | Room list, transcript, composer, stations-heard, server log, sign-in. |
| `Services/Spots/ClusterLineParser.swift` | Shared with the Spots tab: `TelnetLineAssembler`, `resolveUTCTime`, DX-spot parsing. |

## Transport

Port 23000 is **not** an RFC 854 telnet service. It is a plain line-oriented
ASCII stream over TCP: no framing, no length prefix, no sequence numbers, no
acknowledgement, no typing. Message class is decided by pattern-matching each
line's text.

`TelnetLineAssembler` (shared with the DX cluster feed) handles byte-stream to
line assembly: it strips IAC sequences defensively, drops CR/NUL/control noise,
retains the incomplete tail across reads, caps the buffer at 64 KiB, and decodes
UTF-8 with an ISO-8859-1 fallback (colrdx maps CP437 bytes 128–159, so the server
may emit high-bit bytes that are not UTF-8; Latin-1 decoding cannot fail).

Outbound lines are terminated `\r\n`. colrdx sends a bare `\n` and works, so both
are presumably accepted; CRLF is what the service's own clients emit.

## Login

The three prompts — `Login:`, `Password:`, `Your choice           :` — are written
**without a trailing CR/LF**. A reader that only inspects completed lines blocks
forever. This is the single most common way an implementation of this protocol
hangs, so `ON4KSTLoginSequencer` is fed the assembler's *unterminated tail*, not
its finished lines. The buffer is cleared after each answer, so a prompt seen
twice really is the server asking twice.

The three answers must be sent separately, each after its own prompt arrives.
That is a **sequencing** constraint, not a timing one: there are no fixed sleeps
anywhere in this code.

```
awaitingLogin  --"login:"-------> send callsign
awaitingPassword --"password:"--> send password
awaitingMenu   --"your choice"--> send room number
awaitingWelcome --welcome/prompt line--> chat   (latched)
```

### Password safety

Anything written to an established connection is **posted publicly to the room**.
A state machine that believes it is still at `Password:` when it is not will
broadcast the operator's password to every station in the channel — a documented
real-world incident. Four independent guards:

1. The password is written from exactly one place, reachable only from the
   `.sendPassword` action.
2. `logged_in` is latched on the welcome banner or first own-prompt line; the
   sequencer is terminal from then on and offers no further sends
   (`testPasswordIsNeverOfferedAgainAfterLogin`).
3. Every reconnect rebuilds the assembler and sequencer from scratch — a
   half-open session is never reused.
4. `send()` refuses a line equal to the stored password, and any server line
   containing it is dropped rather than displayed (the server echoes the password
   back during login).

The password is stored in the Keychain under `ServiceType.on4kst`, never in
`AppSettings` — that record syncs through CloudKit, and this credential crosses
the network in cleartext. The sign-in screen says to use a password not reused
anywhere else.

### Failure handling

A re-prompt for `Login:`/`Password:` after we have answered is treated as a
credential rejection and is **not retried**: retrying bad credentials both
hammers a free, volunteer-run service and risks a lockout. A re-prompted menu is
treated as a room rejection. Three connections that never reach the chat prompt
also stop, rather than looping.

Transient drops reconnect with jittered exponential backoff, floor 5 s, ceiling
5 min.

## Line grammar

Classification order is: DX-cluster prefix, then the chat grammar, then system
text.

```
hhmmZ <FROMCALL> <FROMNAME>> <message>
hhmmZ <FROMCALL> <FROMNAME> to <TOCALL>> <message>
```

Three things the naive grammar gets wrong, all covered by tests:

- **The message body may contain `>`.** Matching greedily to the *last* `>`
  mis-splits grid-path text like `JM19<TR>JN01` or `IO64<>JN18` — a real bug in
  at least one existing client. Instead the search is bounded to the first 80
  characters and takes the **first** `>` whose header begins with a
  callsign-shaped token.
- **The operator name is free text and may contain spaces.** Nothing splits on a
  whitespace count; the header is anchored on the closing `>` and the trailing
  `to <CALL>`.
- **A callsign is not `[A-Z0-9]+`.** Portable and special calls carry `/`
  (`W2ASM/P`, `VK9/G0ABC`, `F/ON4KST/MM`). Matching is loose and never rejects.

Times are UTC `hhmm` with no date. `ClusterLineParser.resolveUTCTime` attaches the
receiving day and rolls back over midnight, so a `2359Z` line read just after
`0000Z` lands on yesterday.

The server's input prompt (`2251Z W2ASM Warc (30,17,12m) chat>`) matches the chat
grammar with an empty body. It is classified as `.prompt`, never rendered, and
doubles as the liveness signal — it is also where the room name the server itself
uses comes from.

### The directed-message disagreement

colrdx (working C source) places the recipient **inside** the header
(`... Bob to W2ASM> text`); a third-party write-up places it **after** the `>`
(`... Bob> (W2ASM) text`). This could not be resolved empirically — see below.
The colrdx form is parsed properly. The second form is honoured only when the
parenthesised token is *exactly the operator's own callsign*, which is what keeps
a message opening `(FT8) on 50.313` from being read as a recipient.

## Rooms

The room table in `ON4KSTRoom.telnetRooms` is the telnet namespace captured
2026-08-07. It is treated as a **fallback**: the client parses the live menu at
connect time and, when the server lists the chosen room under a different number,
the server wins.

The web front end uses a different, alphanumeric room-id namespace whose numbers
do not line up (EME is `5` there, 4 here). The two are never mapped onto each
other. There is no 20 m / 14 MHz room, and no UI implies one.

Membership is exclusive — one room per connection — and the service allows one
session per callsign, so opening another room tears the session down and logs in
again. No room-switch command is guessed at, because none is documented.

## Deliberate limitations

- **No user-list query.** The "Stations Heard" roster is built from traffic
  actually observed since connecting. No command is guessed at, so every entry is
  real; the cost is that a silent station does not appear.
- **No hardcoded command list.** The composer passes any `/`-prefixed line
  through verbatim and a "Send /HELP" action puts the server's own reply in the
  transcript and the Server Log. The full command set is undocumented and is not
  invented here.
- **Everything unclassified is kept.** Join/leave notices, error text and `/HELP`
  output have no documented grammar. Rather than dropping them, they are shown as
  centred notices and retained verbatim in the Server Log.
- **Foreground only.** iOS suspends the app shortly after backgrounding and the
  socket dies with it, so the session is closed on `scenePhase == .background` and
  reconnected on `.active`. Catching directed messages while the app is closed
  would need an always-on host holding the session and pushing to the device;
  that is out of scope here.
- **Self-limited sending.** One line per second minimum spacing, 400-character
  cap, CR/LF stripped from composer text so a pasted newline cannot post a
  second, unreviewed line.

## Still unverified

Outbound TCP to port 23000 is not reachable from the environment this was written
in, so the discovery capture could not be run. These remain open and should be
closed with a live session against a busy room (Low Band or 144/432 during a
European evening — the WARC room is too quiet to exercise the parser):

- The full `/HELP` command set.
- Whether a room-switch command exists.
- A user-list query and its response format.
- DX spot submission syntax for the inline ON4KST-2 CLX cluster.
- Idle timeout, and whether the prompt line is a real server heartbeat (the
  client currently presumes a dead link after 15 minutes of silence and relies on
  TCP keepalive otherwise).
- Concurrent-session policy per callsign.
- Exact server behaviour on bad password, unknown callsign and bad menu choice —
  the client's re-prompt heuristic is an inference.
- Which of the two directed-message formats the server actually emits.
- The character encoding used for non-ASCII operator names.

The parser is corpus-testable offline: `ON4KSTCorpusTests` replays a capture and
asserts that every line lands in a known bucket and that the unclassified bucket
stays small. Replaying a real capture through it is the fastest way to close the
list above — a large system bucket means the grammar is wrong.

## References

- `f4exb/colrdx` — <https://github.com/f4exb/colrdx> — `src/dsplnkst.c` for the
  line grammar, `src/colrdx.c` for connection handling. GPL. Best available spec.
- Tucnak (OK1ZIA) — <https://tucnak.nagano.cz/wiki/KST_chat> — login transcript,
  `/HELP` and `/CQ` usage.
- x8x.net, "Node-RED & IRC with ON4KST Chat" — the login sequencing constraint,
  the alternative message-format description, and the password-broadcast warning.
- Service entry point — <http://www.on4kst.org/chat/start.php>. The operator can
  be reached at `chat@on4kst.com`, which is the right route for asking whether
  automated clients are acceptable and what rate limits apply.
