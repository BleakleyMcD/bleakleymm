# rsync_queue — Setup

> **Scope of this document**
>
> This doc is the setup runbook for getting `rsync_queue` working on a new
> Mac that will be used to drive transfers between the TrueNAS hosts.
>
> **For now it covers SSH setup only** — the part most likely to bite you
> the first time you run the tool on a fresh machine. Over time this
> document should grow to cover the whole `rsync_queue` workflow:
> day-to-day usage, the queue/log layout on `.220`, server-side
> `rsync_run.sh`, troubleshooting beyond auth, and so on. If you find
> yourself learning something the hard way that isn't in here yet, add it.

## Architecture

```
  Mac running rsync_queue
        │   ssh + scp (5 connections per launch_queue call)
        ▼
  TrueNAS .220  (192.168.3.220, root)
    └── runs the rsync transfer in a tmux session via /root/rsync_run.sh
        │   ssh (when a source is on .225)
        ▼
  TrueNAS .225  (192.168.3.225, medialab)
    └── source filesystem for some transfers
```

Two SSH legs need to work without password prompts:

1. **Mac → `root@.220`** — set up per Mac that runs `rsync_queue`.
2. **`root@.220` → `medialab@.225`** — one-time server-side setup; only
   needs redoing if the key is lost or the `medialab` user is recreated.

If either leg falls back to password auth, `rsync_queue` will either
prompt you many times (Mac → .220) or fail mid-batch with `exit code 12`
when an interactive prompt times out (.220 → .225).

## Prerequisites

- Mac has the relevant SMB shares mounted in Finder. `rsync_queue` reads
  the active SMB mount table to translate `/Volumes/<share>/...` paths to
  the matching server-side `/mnt/...` paths.
- Network reachability to both `.220` and `.225`.
- A clone of the repo with `tools/rsync_queue` available locally.

## Per-Mac setup (the common case)

This is what you do every time a new Mac (or a new user account on a Mac)
will run `rsync_queue`.

### 1. Make sure you have an SSH key

```bash
ls ~/.ssh/id_*
```

If you see at least one of `id_ed25519` / `id_ed25519.pub` (or `id_rsa` /
`id_rsa.pub`), skip to step 2.

If you don't, generate one:

```bash
ssh-keygen -t ed25519 -C "$(whoami)@$(hostname -s)"
```

Accept the default location. A passphrase is recommended (we'll cache it
in macOS Keychain so you only type it once, ever).

### 2. Install your public key on `.220`

```bash
ssh-copy-id root@192.168.3.220
```

You'll be prompted for `root@.220`'s password **once**. After this, your
public key is in `/root/.ssh/authorized_keys` on `.220` and key auth
works.

Verify:

```bash
ssh root@192.168.3.220 'echo ok'
```

You may be prompted for the **passphrase** of your local key (this is
expected — it's the local key's passphrase, not the remote password).
Once it prints `ok`, key auth is working. Move to step 3 to stop the
passphrase prompts.

### 3. Cache the key passphrase in macOS Keychain

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

Type your passphrase one time. macOS Keychain stores it. From now on,
ssh-agent serves the unlocked key to every `ssh`/`scp` call without
prompting — and this persists across reboots and logins.

To make this fully automatic on future macOS sessions, add to
`~/.ssh/config`:

```
Host *
    UseKeychain yes
    AddKeysToAgent yes
```

(Or scope it to `Host 192.168.3.220` if you'd rather not apply globally.)

### 4. Verify zero prompts

```bash
ssh-add -l                              # should list your key
ssh root@192.168.3.220 'echo ok'        # should print 'ok' with no prompts at all
```

If both work silently, your Mac is ready.

## Server-side setup (one-time — already done in current lab)

This section documents the `.220` ↔ `.225` SSH setup so it can be
recreated if the lab is ever rebuilt. **You should not need to do this
when adding a new Mac.**

### 1. Generate a key for `root@.220`

On `.220`:

```bash
ssh-keygen -t ed25519 -f /root/.ssh/id_medialab -N "" -C "root@truenas-220"
```

`-N ""` makes it passphrase-less (necessary for unattended use by
`rsync_run.sh`).

`rsync_run.sh` references this key path explicitly via:

```bash
MEDIALAB_KEY="/root/.ssh/id_medialab"
... -e "ssh -i $MEDIALAB_KEY"
```

### 2. Make `medialab` on `.225` have a real home directory

By default, the `medialab` user on `.225` has `Home Directory =
/nonexistent`, which prevents TrueNAS from writing
`~/.ssh/authorized_keys`.

> **TODO (Bleakley): grab screenshots of the relevant TrueNAS UI fields**
> and drop them into `tools/rsync_queue.SETUP.assets/`, then wire them
> in here. Specifically:
> - The Local Users → `medialab` → Edit form, with Home Directory
>   highlighted.
> - The same form with the SSH Public Key field highlighted.
> - The TrueNAS Shell page (where the `mkdir`/`chown` for the home dir
>   gets run), so people know which left-nav item to click.
> The text below should be enough to follow without screenshots, but
> screenshots make a TrueNAS UI walkthrough roughly 3× faster to follow.

In the TrueNAS UI on `.225` → **Credentials → Local Users → medialab →
Edit**:

1. Change **Home Directory** to a real, dedicated path. The UI uses a
   tree picker, not a text field, so the path must already exist.
2. If no suitable directory exists yet, open **Shell** in the TrueNAS UI
   and create one:

   ```bash
   mkdir -p /mnt/medialab/medialab_home
   chown medialab:medialab /mnt/medialab/medialab_home
   chmod 700 /mnt/medialab/medialab_home
   ```

   Then go back to the user form, navigate the picker to
   `/mnt/medialab/medialab_home`, and select it.
3. Save.

### 3. Install `.220`'s public key on `medialab@.225`

Get the public key:

```bash
ssh root@192.168.3.220 'cat /root/.ssh/id_medialab.pub'
```

Copy the entire line (`ssh-ed25519 <data> <comment>`).

In the TrueNAS UI on `.225`, edit the `medialab` user again. Paste the
key into the **SSH Public Key** field. Save.

> **Two-save quirk**: TrueNAS will reject the SSH key with *"home
> directory is not writeable"* if the home directory was just changed in
> the same form. Save the home-directory change first, then re-edit the
> user and paste the SSH key in a second save.

### 4. Verify .220 → .225 key auth

From your Mac:

```bash
ssh root@192.168.3.220 \
    'ssh -i /root/.ssh/id_medialab -o BatchMode=yes medialab@192.168.3.225 echo ok'
```

`BatchMode=yes` means "fail rather than prompt" — so this either prints
`ok` silently (key works) or errors out cleanly (key doesn't work).

## First run

Once both SSH legs are silent, run `rsync_queue` and build a tiny test
queue (one transfer, small folder, dry-run mode). Expected outcomes:

- No password or passphrase prompts at any point.
- Auto-attaches to a `tmux` session named `rsync` on `.220`.
- Dry run completes; `Press Enter to close this session.` appears.
- After Enter, the script offers to re-run the same queue in live mode
  without rebuilding it.

If you see prompts or errors, jump to **Troubleshooting** below.

## Troubleshooting

### `Permission denied (publickey,password)` from `.220` → `.225`

The `medialab@.225` SSH key isn't installed correctly. Common causes:

- The public key wasn't pasted into the TrueNAS UI for `medialab`.
- It was pasted but `medialab` still has `Home Directory = /nonexistent`,
  so TrueNAS silently failed to write `authorized_keys`.
- The key on `.220` doesn't exist at `/root/.ssh/id_medialab` (it was
  moved or never generated).

Re-run server-side setup steps 2–4. The verify command in step 4 should
return `ok` silently when it's right.

### Many passphrase prompts during a single `rsync_queue` run

The Mac side is using key auth (good) but the agent isn't caching the
unlocked key. Re-run:

```bash
ssh-add --apple-use-keychain ~/.ssh/id_ed25519
```

If the prompts persist after a new shell session, your `~/.ssh/config`
isn't enabling Keychain integration — add the `UseKeychain yes` /
`AddKeysToAgent yes` block from per-Mac step 3.

### `rsync error: ... (code 12)` mid-queue

Specifically: `Connection closed by 192.168.3.225 port 22` followed by
`rsync: connection unexpectedly closed`.

The remote `ssh` from `.220` to `.225` fell back to a password prompt
that timed out. Root cause is the same as the `Permission denied` case
above — the `.220` → `.225` key isn't working, so `ssh` waits for a
password that nobody types. Fix the key and re-run.

### `rsync error: ... (code 23)` on a queue

Code 23 means "partial transfer due to error." rsync moved most of what
it could see but at least one path failed. `rsync_run.sh` pipes rsync's
stdout+stderr through `tee -a "$LOG"`, so the actual error line is in
the `.log` file — open the log and search for `rsync:` or `failed:`
near the end (just before the summary stats).

Common causes:

- A typo in the source path (e.g. a stray `y` or other character entered
  along with the path during the interactive prompt). The `Source:` line
  near the top of the log will show exactly what was sent to rsync.
- A source file or directory that `medialab` can't read on `.225`.
- A broken symlink or special file rsync can't handle.

> Note: because `rsync_run.sh` both `tee`s rsync's terminal output to
> `$LOG` *and* uses `--log-file=$LOG`, you'll see some content twice in
> the log (stats blocks especially). That's expected and harmless —
> rsync's `--log-file` format and its stdout format overlap but aren't
> identical, and having both means errors are captured no matter which
> stream rsync sends them to.

### `rsync_queue` reports `Path is not on a known SMB mount`

The path you dragged in is on a share that isn't mounted on this Mac, or
isn't in `SHARE_MAP` inside the script. Mount it in Finder first; if
it's a brand-new share, add a line to `SHARE_MAP` in
`tools/rsync_queue` and commit.

### `A tmux session named 'rsync' already exists on 192.168.3.220`

A previous run is still attached or never cleaned up. Either reattach to
finish what's there:

```bash
ssh root@192.168.3.220 'tmux attach -t rsync'
```

…or kill it if it's truly stale:

```bash
ssh root@192.168.3.220 'tmux kill-session -t rsync'
```

Then re-run `rsync_queue`.
