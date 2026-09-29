{
  config,
  lib,
  pkgs,
  modulesPath,
  ...
}:

{
  imports = [ (modulesPath + "/profiles/qemu-guest.nix") ];

  # --- Lima integration -----------------------------------------------------
  # Provides lima-init.service and lima-guestagent.service. Removing this makes
  # the VM unreachable through limactl.
  services.lima.enable = true;

  # lima-init creates the login user imperatively at boot, so the user database
  # must stay mutable or SSH login breaks.
  users.mutableUsers = true;

  # --- Boot -----------------------------------------------------------------
  # This image boots via GRUB (EFI, installed as removable). It is NOT
  # systemd-boot; /boot contains /boot/grub and EFI/BOOT/BOOTAA64.EFI.
  boot.loader.grub = {
    device = "nodev";
    efiSupport = true;
    efiInstallAsRemovable = true;
    # /boot is only ~249 MiB, so cap how many generations keep kernels there.
    configurationLimit = 10;
  };
  boot.loader.efi.canTouchEfiVariables = false;

  boot.initrd.availableKernelModules = [
    "virtio_pci"
    "xhci_pci"
    "usbhid"
  ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
    autoResize = true;
    # discard lets the guest return freed blocks to the sparse host image.
    options = [
      "noatime"
      "nodiratime"
      "discard"
    ];
  };

  fileSystems."/boot" = {
    device = "/dev/vda1";
    fsType = "vfat";
    options = [
      "fmask=0022"
      "dmask=0022"
    ];
  };

  # Host shares. lima-init appends these to /etc/fstab at every boot, but a
  # live `nixos-rebuild switch` regenerates /etc/fstab without them, and
  # systemd then unmounts the shares out from under you. Declaring them here
  # makes them survive activation. Tags come from `mount | grep virtiofs`;
  # `nofail` guarantees a stale tag can never block boot, and lima-init still
  # re-adds the authoritative entries on the next start.
  fileSystems."/Users/mfrw" = {
    device = "lima-2fd63231cbd3b44a";
    fsType = "virtiofs";
    options = [
      "ro"
      "nofail"
    ];
  };

  fileSystems."/tmp/lima" = {
    device = "lima-1fd4cbcaa36d359d";
    fsType = "virtiofs";
    options = [
      "rw"
      "nofail"
    ];
  };

  nixpkgs.hostPlatform = "aarch64-linux";

  # --- Networking -----------------------------------------------------------
  networking.hostName = "nixos";
  # Networking is handled by dhcpcd (the NixOS default). Do not enable
  # NetworkManager here: it is not what this image runs.

  services.openssh.enable = true;
  security.sudo.wheelNeedsPassword = false;

  # --- x86_64-linux builds via Rosetta --------------------------------------
  # Lima (vz driver) exposes Rosetta as a virtiofs share tagged "vz-rosetta".
  # This gives near-native x86_64-linux builds, which matters because most
  # nixpkgs PRs and CI rebuild labels target x86_64-linux.
  virtualisation.rosetta = {
    enable = true;
    mountTag = "vz-rosetta";
  };

  time.timeZone = "Asia/Kolkata";

  # --- Nix ------------------------------------------------------------------
  nix.settings = {
    experimental-features = [
      "nix-command"
      "flakes"
    ];
    trusted-users = [
      "root"
      "@wheel"
    ];

    max-jobs = "auto";
    cores = 0;

    # Build x86_64-linux derivations locally through Rosetta.
    extra-platforms = [ "x86_64-linux" ];

    # Keep build-time deps of built outputs around; makes repeated
    # nixpkgs-review runs on related PRs much cheaper.
    keep-outputs = true;
    keep-derivations = true;

    substituters = [
      "https://cache.nixos.org/"
      "https://nix-community.cachix.org"
    ];
    trusted-public-keys = [
      "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
    ];

    # Self-limiting store: when free space drops below min-free, the daemon
    # garbage collects until max-free is available. This is what stops the
    # disk filling up during a heavy review session.
    min-free = 10 * 1024 * 1024 * 1024;
    max-free = 50 * 1024 * 1024 * 1024;
  };

  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };

  nix.optimise.automatic = true;

  # --- Review toolchain -----------------------------------------------------
  # Declared here rather than installed ad hoc with `nix profile install`, so
  # the whole toolchain upgrades atomically with the system.
  programs.direnv.enable = true;

  # --- Update routine -------------------------------------------------------
  # `vm-update` performs the whole recurring maintenance cycle. It stages the
  # new system for the next boot by default (safest, and a kernel change needs
  # a reboot anyway); pass --switch to activate live instead.
  environment.systemPackages = [
    (pkgs.writeShellApplication {
      name = "vm-update";
      runtimeInputs = with pkgs; [
        git
        nix
        util-linux
      ];
      text = ''
        CONFIG="''${NIXOS_CONFIG_DIR:-$HOME/nixos-config}"
        MODE="boot"
        if [ "''${1:-}" = "--switch" ]; then MODE="switch"; fi

        echo "==> [1/6] updating flake inputs in $CONFIG"
        cd "$CONFIG"
        nix flake update
        # Flakes only see git-tracked files, so stage the new lock before building.
        if [ -d .git ]; then git add -A; fi

        echo "==> [2/6] building system ($MODE)"
        sudo nixos-rebuild "$MODE" --flake ".#nixos"

        echo "==> [3/6] updating nixpkgs checkout"
        # Non-fatal: a flaky fetch of a 3.6 GB repo must not abort maintenance.
        update_nixpkgs() {
          [ -d "$HOME/nixpkgs/.git" ] || return 0
          git -C "$HOME/nixpkgs" fetch upstream --prune --quiet || return 1
          local branch
          branch="$(git -C "$HOME/nixpkgs" rev-parse --abbrev-ref HEAD)"
          if [ "$branch" = "master" ] && [ -z "$(git -C "$HOME/nixpkgs" status --porcelain --untracked-files=no)" ]; then
            git -C "$HOME/nixpkgs" merge --ff-only upstream/master
          else
            echo "    skipped fast-forward (on '$branch', or tree is dirty)"
          fi
        }
        if ! update_nixpkgs; then
          echo "    WARNING: nixpkgs fetch failed (network?); retry later with:"
          echo "      git -C ~/nixpkgs fetch upstream --prune"
        fi

        echo "==> [4/6] collecting garbage (keeping 30 days)"
        sudo nix-collect-garbage --delete-older-than 30d
        nix-collect-garbage --delete-older-than 30d

        echo "==> [5/6] optimising store"
        sudo nix store optimise

        echo "==> [6/6] returning freed blocks to the host image"
        sudo fstrim -av

        df -h /
        if [ "$MODE" = "boot" ]; then
          echo
          echo "Staged for next boot. Activate from the macOS host with:"
          echo "    limactl stop nix && limactl start nix"
        fi
      '';
    })
  ]
  ++ (with pkgs; [
    nixpkgs-review
    nix-init
    nurl
    nix-update
    nixd
    nixfmt
    statix
    deadnix

    gh
    git
    delta
    helix
    direnv
    starship
    ripgrep
    fd
    jq
    tmux
    tailcat
    htop

    # --- neovim build toolchain ---------------------------------------------
    # The dotfiles config compiles things at plugin-install time:
    # telescope-fzf-native (build = "make"), nvim-treesitter's parsers, and
    # LuaSnip's jsregexp. Without a compiler those silently stay broken.
    gcc
    gnumake
    tree-sitter

    # --- language servers, from nixpkgs rather than mason -------------------
    # mason ships prebuilt binaries linked against FHS paths that do not exist
    # on NixOS, and upstream clangd publishes no aarch64-linux build at all, so
    # mason can never satisfy this list here. nixpkgs has correct aarch64
    # builds of all of them, and vim.lsp.enable() resolves servers off PATH.
    go
    gopls
    rust-analyzer
    # rust-analyzer refuses to load a workspace without cargo and rustc on
    # PATH; without them every Rust buffer gets "cargo not found", not an LSP.
    cargo
    rustc
    clang-tools
    zls
    stylua
  ]);

  # Lets dynamically linked, non-Nix binaries run (mason downloads, anything
  # fetched by `go install`). Not required now that the servers come from
  # nixpkgs, but it removes a whole category of "works everywhere except here".
  programs.nix-ld.enable = true;
  programs.neovim = {
    enable = true;
    viAlias = true;
    vimAlias = true;
    defaultEditor = true;
  };

  # Do not change: this records the NixOS release this machine was first
  # installed with, not the release it tracks.
  system.stateVersion = "25.11";
}
