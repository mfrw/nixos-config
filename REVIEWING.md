# nixpkgs review rig — operating manual

This VM (`lima` instance `nix`) is a NixOS review box on an Apple Silicon Mac.
It builds **both** `aarch64-linux` (native) and `x86_64-linux` (Rosetta).

The Mac host has no Nix installed, by choice. That means `aarch64-darwin`
reviews are out of scope for now — see "Level-up path" for why that is worth
revisiting.

---

## 1. Operating the machine

### The one command

```sh
vm-update            # stage the update for next boot (default, recommended)
vm-update --switch   # activate live instead
```

It does six things: update flake inputs → build the system → fast-forward
`~/nixpkgs` → garbage-collect (keeping 30 days) → optimise the store →
`fstrim` so freed blocks shrink the sparse image on the Mac.

After the default (`boot`) mode, activate from the **macOS host**:

```sh
limactl stop nix && limactl start nix
```

Prefer `boot` + restart over `--switch`: `nixos-unstable` ships new kernels
constantly, and a live switch keeps running the old one.

### Cadence

Weekly is a good rhythm — it keeps the closure close to what CI is testing
without churning daily.

Deliberately **not** automated with a timer: an unattended `nixos-unstable`
jump on the machine you review with can break your tooling at the worst
moment. Store hygiene *is* automated (`nix.gc` weekly + `nix.optimise`), and
`min-free`/`max-free` mean the disk cannot silently fill again.

### Rollback

The config lives in a git repo at `~/nixos-config`, so both the config and
`flake.lock` are revertable. Two recovery paths, in order of preference:

```sh
# 1. Flake-aware (needs a working flake)
cd ~/nixos-config
sudo nixos-rebuild switch --rollback --flake .#nixos

# 2. Pure profile switch — evaluates nothing, always works
sudo nix-env -p /nix/var/nix/profiles/system --list-generations
sudo nix-env -p /nix/var/nix/profiles/system --switch-generation N
sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
```

Method 2 is the one to remember. `nixos-rebuild --rollback` **without**
`--flake` fails on this machine (it falls back to `<nixpkgs/nixos>`, which
does not exist here).

To undo a bad flake bump specifically:

```sh
cd ~/nixos-config && git checkout HEAD~1 -- flake.lock && sudo nixos-rebuild boot --flake .#nixos
```

Generation 1 is the pristine image from 2025-08-28 and is kept as a floor.

### Three landmines baked into this config

Do not "clean these up" — each one is load-bearing.

1. **`services.lima.enable` is not in nixpkgs.** It comes from the
   out-of-tree `nixos-lima` flake input. Drop it and the VM boots but lima
   cannot reach it: no SSH, no port forwarding, no mounts.
2. **This image boots GRUB, not systemd-boot**, even though the original
   `/etc/nixos/configuration.nix` claimed otherwise. `/boot` is only ~249 MiB,
   hence `configurationLimit = 10`.
3. **The host shares are declared here on purpose.** lima-init appends them to
   `/etc/fstab` at boot, but a live `nixos-rebuild switch` regenerates
   `/etc/fstab` and systemd then unmounts `/Users/mfrw` and `/tmp/lima` out
   from under you. They carry `nofail` so a stale virtiofs tag can never block
   boot.

Also: `users.mutableUsers = true` is mandatory (lima-init creates the login
user imperatively), and `system.stateVersion = "25.11"` is not a version to
bump.

---

## 2. Finding PRs to review

Best dashboard: <https://nixpkgs-prs.fliegendewurst.eu/> — has New, Needs
Reviewer, Needs Merger and Awaiting Changes queues, with temporary
reservation so two people don't duplicate work.

(`https://nixpk.gs/pr-tracker.html` is *not* a review queue — it tracks an
already-merged PR's propagation through staging/Hydra/channels.)

```sh
# Green, nobody has formally reviewed it
gh pr list -R NixOS/nixpkgs --limit 100 \
  --search 'is:open review:none status:success no:assignee' \
  --json number,title,url,labels

# Explicitly asking for a reviewer
gh pr list -R NixOS/nixpkgs --search 'is:open label:"9.needs: reviewer"' --limit 100

# Already has one approval — your second one often unblocks the merge
gh pr list -R NixOS/nixpkgs --search 'is:open label:"12.approvals: 1"' --limit 100

# Maintainer-approved and green: usually just needs a committer's attention
gh pr list -R NixOS/nixpkgs \
  --search 'is:open label:"12.approved-by: package-maintainer" status:success' --limit 100

# Automated bumps needing review
gh pr list -R NixOS/nixpkgs \
  --search 'is:open author:r-ryantm label:"9.needs: reviewer"' --limit 100
```

Useful label vocabulary (these are the real names; `awaiting_reviewer` and
`needs reviewer` do **not** exist):

```
9.needs: reviewer            9.needs: maintainer          9.needs: help on darwin
12.approvals: 1 / 2 / 3+     12.approved-by: package-maintainer
6.topic: darwin              2.status: merge-bot eligible
10.rebuild-linux: 0 | 1 | 1-10 | 11-100 | 101-500 | 501-1000 | 1001-2500 | 2501-5000 | 5001+
```

Filter by `10.rebuild-linux: 1-10` to keep build times sane on this box.
Anything `501+` is better left to Hydra and people with build farms.

Start where you already have standing: the ~10 packages you maintain, the
Rust/Go CLI niche you mostly ship in, and `r-ryantm` bumps.

`r-ryantm` PRs are good volume work but are **not** rubber stamps — still
check upstream release notes, source authenticity, license changes, whether
patches still apply, that the binary runs, and reverse dependencies.

### Where reviewers coordinate

| Purpose | Where |
|---|---|
| General review requests | `#review-requests:nixos.org` |
| `nixpkgs-review` tool talk | `#nixpkgs-review:matrix.org` |
| macOS/Darwin | `#macos:nixos.org` |
| PRs ready for review | <https://discourse.nixos.org/t/prs-ready-for-review/3032> |
| Already reviewed, needs merger | <https://discourse.nixos.org/t/prs-already-reviewed/2617> |

Etiquette: wait about a week of inactivity before promoting a PR in those
channels.

---

## 3. Running a review

```sh
cd ~/nixpkgs

nixpkgs-review pr 12345 --systems linux      # both linux systems, drops into a shell
nixpkgs-review pr 12345 --systems linux --no-shell --print-result
nixpkgs-review pr 12345 --systems linux --post-result   # posts the report as a comment
```

`--systems linux` is the current alias for `--systems 'aarch64-linux x86_64-linux'`.

Other forms worth knowing:

```sh
nixpkgs-review wip                 # your unstaged working-tree changes
nixpkgs-review wip --staged
nixpkgs-review rev HEAD            # a local commit
nixpkgs-review pr 12345 --run 'myprog --version'   # run a command instead of a shell
nixpkgs-review pr 12345 --approve-pr               # approve only if the report succeeded
```

Spelling traps (v4.0): it is `--systems` not `--system`, `--build-args` not
`--build-arg`, `approve` is a subcommand while `--approve-pr` is an option,
and `--run`/`--no-shell` are mutually exclusive. In 4.0 the review shell is a
plain `$SHELL` with the built `bin/` dirs prepended, not a `nix-shell`.

**Always actually run the binaries.** The single most valuable thing a
reviewer adds over CI is "I ran it and it works", because CI only proves it
compiled.

Asking CI for more, one command per line, no trailing prose:

```
@ofborg build hello
@ofborg test installer
```

The lint gate is `nixpkgs-vet` (formerly `nixpkgs-check-by-name`) — it polices
`pkgs/by-name` layout and evaluation.

Cache lives in `~/.cache/nixpkgs-review`; it grows fast (it was 2.2 GB / 54 PRs
when this box was revived). `vm-update` does not prune it, so occasionally:

```sh
rm -rf ~/.cache/nixpkgs-review/pr-*
```

---

## 4. Review checklists

From the Nixpkgs manual, *Reviewing contributions*.

**Package update**
- Version and commit-message conventions (`pkg: old -> new`).
- Source is the authentic upstream artefact.
- `license` and the rest of `meta` still accurate.
- Maintainers were notified.
- Patches, pins, substitutions, disabled checks and unusual flags are justified.
- It builds; relevant reverse dependencies build.
- Every shipped executable actually runs.
- Patches link upstream or explain why they aren't upstreamed.

**New package** — all of the above, plus
- Correct `pkgs/by-name` path and name.
- Appropriate fetcher.
- Correct `description`, `license`, `platforms`, `maintainers`, `mainProgram`.
- Build-only deps in `nativeBuildInputs`, not `buildInputs`.
- Phases and hooks follow convention.

**Module change**
- Module maintainers notified; existing NixOS tests pass.
- Option types, defaults, descriptions and examples correct.
- Backward compatibility preserved; renames use the compat helpers;
  removals use `mkRemovedOptionModule`.
- Breaking changes have release notes; docs updated.

**Tone** (this is what gets you taken seriously)
- Keep the review scoped to the proposed change.
- Separate blockers from optional follow-ups explicitly.
- State exactly what you inspected and what you tested, on which systems.
- Reserve GitHub's **Request changes** for genuine blockers.
- Drive toward a conclusion rather than leaving it hanging.

---

## 5. Level-up path

**Anyone may review and approve a nixpkgs PR** — you do not need any status.
A non-committer approval counts toward the `12.approvals: N` labels, adds
`12.approved-by: package-maintainer` when you maintain an affected package,
and is real evidence for whoever eventually merges.

You are already in `maintainers/maintainer-list.nix`, so you can also use the
narrow merge bot on eligible small `pkgs/by-name` changes — a standalone
comment:

```
@NixOS/nixpkgs-merge-bot merge
```

**Committer nomination** (`NixOS/nixpkgs-committers`): check open nominations,
add an empty `members/mfrw` file, open a PR making the case. Self-nomination is
allowed. There is no numeric threshold; the community looks for sustained
participation across multiple release cycles, substantive reviews, sound
cross-tree judgement and good communication. Note the process moved: after the
core team disbanded (2026-08-02), the Steering Committee delegated
committer-process authority to the Nixpkgs CI team.

Given 221 PRs / 188 merged / 215 reviews already, the gap is not volume — it is
*visible, sustained, recent* review work of other people's changes. This rig
existing again is the point.

**The Darwin opportunity.** At the time of writing there were ~202 open PRs
labelled `6.topic: darwin`, ~170 with no review at all, and an open recruitment
issue (`NixOS/nixpkgs#323144`) for Darwin reviewers — joining
`@NixOS/darwin-maintainers` is deliberately lightweight, needing only a public
record of useful participation. Doing that requires Nix on the Mac itself,
which was explicitly out of scope here. It remains the highest-leverage thing
available, precisely because Apple Silicon hardware is what most reviewers
lack.
