# Week 1 — Shell speed: filesystem, streams, text

> **By the end:** you compose pipelines at conversational speed and stop thinking about syntax.

**Time:** ≈5 h across 3 sessions · **Where:** Rocky box (not the Mac — BSD userland differs)
**Prereq:** week 0 checkpoint

---

## What this is, and why it matters

This week is **recall, not acquisition.** You knew all of this. The goal is speed: getting from
"I need the top ten IPs in this log" to a working pipeline without a pause, because every
later week assumes this is free.

The one idea worth re-articulating is the one that makes Unix cohere:

**Text is the API.** Every tool reads a stream of lines on stdin and writes a stream of lines
on stdout. No tool knows about any other tool. The composition operator is the pipe, and it
means you assemble one-off programs out of parts that were never designed for each other.
Nothing else in computing has stayed this useful for this long — you can still pipe a 2026
`journalctl` into an `awk` invocation you'd have written in 1995.

The corollary matters as much: **stderr is a separate channel from stdout** precisely so that
errors don't corrupt the data stream. `2>&1` merges them, and knowing when *not* to is half
of writing robust pipelines.

### The mental model

```
            ┌──────────┐        ┌──────────┐        ┌──────────┐
  stdin ───▶│  grep    │───────▶│   sort   │───────▶│   uniq   │───▶ stdout
            └────┬─────┘        └────┬─────┘        └────┬─────┘
                 │                   │                   │
               stderr              stderr              stderr  ──▶ your terminal
```

Three file descriptors, always: `0` stdin, `1` stdout, `2` stderr. Redirection is just
pointing a descriptor somewhere else. `2>&1` means "make descriptor 2 point wherever
descriptor 1 currently points" — which is why `cmd 2>&1 > file` and `cmd > file 2>&1` do
different things, and why the second is what you almost always want.

---

## Session 1 — Filesystem and search (≈1.5 h)

### Concepts to re-seat

**The hierarchy.** `/etc` configuration, `/var` variable state (logs, spool, databases),
`/usr` read-only program data, `/opt` self-contained third-party software, `/srv` data served
by this machine, `/proc` and `/sys` kernel interfaces pretending to be files, `/run` runtime
state cleared on boot. When you're hunting for something, this narrows the search enormously.

**Globbing is not regex.** `*.txt` is expanded by the *shell* before your command ever runs.
`grep '.*\.txt'` is a regex evaluated by grep. Confusing them produces bugs that look like
magic. Quoting is what decides which one you get.

**Links.** A hard link is another name for the same inode — indistinguishable from the
"original", and the data lives until the last name is removed. A symlink is a small file
containing a path, which can dangle. This distinction becomes load-bearing in week 10 when a
deleted-but-open file fills your disk.

### Do this

```bash
# read the hierarchy from the system's own documentation
man hier

# inodes and links, concretely
cd /tmp && mkdir linkdemo && cd linkdemo
echo hello > original
ln original hardlink
ln -s original symlink
ls -li                       # note: original and hardlink share an inode number
rm original
cat hardlink                 # still works — the data has another name
cat symlink                  # broken — it pointed at a name, not the data

# find is the workhorse; learn the predicate style
find /var -type f -size +10M -mtime -7 2>/dev/null
find /etc -name '*.conf' -newer /etc/hostname
find . -type f -print0 | xargs -0 grep -l TODO     # -print0/-0 survives spaces in names
```

Note `2>/dev/null` above — `find /var` as a non-root user generates permission errors on
stderr. Discarding *only* stderr keeps the data stream clean. That's the separation earning
its keep.

### Prove it

Find every file over 10 MB under `/var` modified in the last seven days, sorted by size.

<details>
<summary>One answer</summary>

```bash
sudo find /var -type f -size +10M -mtime -7 -printf '%s\t%p\n' | sort -rn
```
</details>

---

## Session 2 — Streams and the text toolkit (≈1.5 h)

### Which tool, when

This is the actual skill. The tools overlap heavily and picking well is most of your speed.

| Reach for | When |
|---|---|
| `grep` | Select lines matching a pattern. `-c` count, `-v` invert, `-o` only match, `-E` extended regex |
| `cut` | Split on a fixed delimiter, take fields. Fast, brittle — breaks on runs of spaces |
| `awk` | Field-aware processing with logic. Whitespace-splits by default, which `cut` can't |
| `sed` | Stream editing — substitution, deletion, line ranges |
| `sort` / `uniq` | `uniq` only collapses *adjacent* duplicates, so `sort` almost always precedes it |
| `tr` | Character-level translation or deletion |
| `xargs` | Turn a stream of lines into arguments for another command |
| `jq` | Anything JSON. Do not parse JSON with grep |

The rule of thumb: if you're chaining three or more of `grep`/`cut`/`sed` together, one `awk`
usually replaces the lot and reads better.

### Exit codes and short-circuiting

```bash
grep -q ERROR app.log && echo "found"       # && runs on success (exit 0)
grep -q ERROR app.log || echo "clean"       # || runs on failure (non-zero)
echo $?                                      # exit code of the last command
```

Exit codes are how scripts make decisions. `grep -q` is the idiomatic test — quiet, exits early.

### jq, because everything is JSON now

This is genuinely new since your era and you'll use it constantly.

```bash
curl -s https://api.github.com/repos/torvalds/linux | jq '.stargazers_count'
curl -s https://api.github.com/repos/torvalds/linux/issues | jq -r '.[] | .title'
journalctl -u sshd -o json -n 5 | jq -r '.MESSAGE'
echo '{"a":{"b":[1,2,3]}}' | jq '.a.b[1]'
```

`-r` gives raw output (no quotes), `.[]` iterates an array, `|` pipes *inside* jq.

### Do this

Get a real log to work on. If nginx isn't installed yet, journald will do:

```bash
sudo journalctl --since "1 day ago" -o short-iso > ~/sample.log
wc -l ~/sample.log
```

Now build these one at a time, checking the output at each stage of the pipe:

```bash
# count lines by hour
awk '{print substr($1,1,13)}' ~/sample.log | sort | uniq -c

# which units are noisiest
sudo journalctl --since "1 day ago" -o json | jq -r '._SYSTEMD_UNIT // "none"' | sort | uniq -c | sort -rn | head
```

**Build pipelines incrementally.** Write the first stage, look at the output, add the next.
Debugging a six-stage pipeline you wrote blind is miserable; building it up is trivial.

### Prove it

Explain why `grep x file | wc -l` is worse than `grep -c x file`, and why
`sort | uniq -c | sort -rn` is such a common idiom.

<details>
<summary>Answers</summary>

`grep -c` counts internally — one process instead of two, no data copied through a pipe.
It also returns the count directly rather than counting lines that happen to contain matches
(with `-o`, one line can hold several matches, and the two disagree).

`sort | uniq -c | sort -rn` is the universal frequency histogram: sort to make duplicates
adjacent, `uniq -c` to collapse and count, `sort -rn` to rank by that count descending.
</details>

---

## Session 3 — Weekend block: speed drills and a real analysis (≈2 h)

### Part 1 — OverTheWire Bandit, levels 0–20

```bash
ssh bandit0@bandit.labs.overthewire.org -p 2220     # password: bandit0
```

It's calibrated for beginners, so **treat the clock as the exercise.** Twenty levels should
feel like a warm-up, not a puzzle. If a level stalls you for more than five minutes, that's a
gap worth noting in `notes.md` — that's the actual signal you're here for.

### Part 2 — A real log analysis

Install nginx on the Rocky box so you have genuine access logs (you'll want it in week 5 anyway):

```bash
sudo dnf install -y nginx
sudo systemctl enable --now nginx
sudo firewall-cmd --add-service=http --permanent && sudo firewall-cmd --reload
curl -s localhost > /dev/null      # generate a few entries
```

Now produce each of these as a **single pipeline**, no scripts:

1. Top ten client IPs by request count
2. Requests per hour
3. The 5xx rate as a percentage of all requests
4. The ten most-requested paths

<details>
<summary>Reference answers — try first</summary>

```bash
L=/var/log/nginx/access.log

# 1. top ten IPs
sudo awk '{print $1}' $L | sort | uniq -c | sort -rn | head -10

# 2. requests per hour  (log time field looks like [10/Aug/2026:14:22:01 +0000])
sudo awk '{print substr($4,2,14)}' $L | sort | uniq -c

# 3. 5xx rate
sudo awk '{t++; if ($9 ~ /^5/) e++} END {printf "%.2f%% (%d/%d)\n", e*100/t, e, t}' $L

# 4. top paths
sudo awk '{print $7}' $L | sort | uniq -c | sort -rn | head -10
```

Note how #3 is a single `awk` doing what would otherwise be three passes and a shell
arithmetic expansion. That's the "reach for awk" instinct.
</details>

### Part 3 — Modern replacements

Know these exist; stay fluent in the classics, because the classics are on every server and
these are on none of them by default.

| Modern | Replaces | Worth it because |
|---|---|---|
| `rg` (ripgrep) | `grep -r` | Much faster, respects `.gitignore`, sane defaults |
| `fd` | `find` | Simpler syntax for the 90% case |
| `bat` | `cat` | Syntax highlighting, line numbers |
| `dust` / `ncdu` | `du` | Actually readable disk usage |

Install them on your Mac and OrbStack machines. Do **not** rely on them on servers.

---

## Command reference

```
find PATH -type f -size +10M -mtime -7      files over 10MB modified in last 7 days
find . -print0 | xargs -0 CMD               null-delimited: survives spaces in filenames
grep -c / -v / -o / -E / -q                 count / invert / only-match / ERE / quiet
awk '{print $1}'                            first whitespace-separated field
awk -F: '{print $1}'                        custom delimiter
awk '$9 ~ /^5/ {n++} END {print n}'         conditional counting
sed 's/old/new/g'                           substitute globally on each line
sed -n '10,20p'                             print a line range
sort -rn / sort -u / sort -k2               reverse numeric / unique / by field 2
uniq -c                                     count adjacent duplicates (sort first!)
tr -d '\r' / tr 'a-z' 'A-Z'                 delete or translate characters
cmd 2>/dev/null                             discard stderr only
cmd > out 2>&1                              both streams to a file (order matters)
cmd |& less                                 shorthand for 2>&1 |
jq -r '.[] | .field'                        iterate array, raw output
```

---

## Traps

- **`uniq` without `sort`** silently under-counts — it only collapses *adjacent* duplicates.
- **`cmd 2>&1 > file`** sends stdout to the file and stderr to the terminal. You wanted
  `cmd > file 2>&1`. Redirections are evaluated left to right.
- **Unquoted variables** break on spaces. `"$var"`, always.
- **`for f in $(ls)`** is wrong in every case. Use `for f in *` or `find -print0 | xargs -0`.
- **Parsing JSON with grep** works until it doesn't, usually in production. Use `jq`.

---

## Checkpoint

Both from memory, no searching:

1. Write the top-ten-IPs pipeline in **under sixty seconds**.
2. Extract a nested field from a JSON API response with `jq` without looking up the syntax.

---

## If you want more

- `man 7 glob`, `man 7 regex` — the distinction, from the source
- [explainshell.com](https://explainshell.com) — paste a command, get every flag explained
- *The Linux Command Line* (Shotts, free PDF) — chapters 1–20 map onto this week
