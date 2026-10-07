{
  coreutils,
  findutils,
  gawk,
  nix,
  procps,
  util-linux,
  writeShellApplication,
}:

writeShellApplication {
  name = "vm-boot-clean";
  runtimeInputs = [
    coreutils
    findutils
    gawk
    nix
    procps
    util-linux
  ];
  text = ''
    MIN_FREE_MIB="''${VM_BOOT_MIN_FREE_MIB:-120}"
    MIN_FREE_BYTES=$((MIN_FREE_MIB * 1024 * 1024))
    SYSTEM_PROFILE=/nix/var/nix/profiles/system

    usage() {
      cat <<EOF
    Usage: vm-boot-clean

    Safely free enough /boot space for vm-update. The target defaults to
    120 MiB and can be changed with VM_BOOT_MIN_FREE_MIB.
    EOF
    }

    case "''${1:-}" in
      "")
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        exit 2
        ;;
    esac

    if ! [[ "$MIN_FREE_MIB" =~ ^[0-9]+$ ]] || [ "$MIN_FREE_MIB" -lt 1 ]; then
      echo "ERROR: VM_BOOT_MIN_FREE_MIB must be a positive integer" >&2
      exit 2
    fi

    if ! mountpoint -q /boot; then
      echo "ERROR: /boot is not mounted" >&2
      exit 1
    fi

    if pgrep -f 'nixos-rebuild|switch-to-configuration|nixos-install-bootloader' >/dev/null; then
      echo "ERROR: a NixOS rebuild or bootloader update is already running" >&2
      exit 1
    fi

    available_bytes() {
      df --output=avail -B1 /boot | awk 'NR == 2 { print $1 }'
    }

    available_mib() {
      echo $(( $(available_bytes) / 1024 / 1024 ))
    }

    echo "==> /boot has $(available_mib) MiB free; target is $MIN_FREE_MIB MiB"

    # Interrupted bootloader installs can leave large kernel copies behind.
    # Only remove old temporary files when no installer process is running.
    while IFS= read -r -d "" temporary_file; do
      echo "    removing stale temporary file: $temporary_file"
      sudo rm -f -- "$temporary_file"
    done < <(sudo find /boot/kernels -maxdepth 1 -type f -name '*.tmp' -print0 2>/dev/null)

    if [ "$(available_bytes)" -ge "$MIN_FREE_BYTES" ]; then
      echo "==> /boot already has sufficient free space"
      exit 0
    fi

    current_generation="$(
      sudo nix-env -p "$SYSTEM_PROFILE" --list-generations |
        awk '/\(current\)/ { print $1; exit }'
    )"
    if [ -z "$current_generation" ]; then
      echo "ERROR: could not identify the current system generation" >&2
      exit 1
    fi

    running_system="$(readlink -f /run/current-system)"
    running_generation=""
    while IFS= read -r generation; do
      generation_path="$SYSTEM_PROFILE-$generation-link"
      if [ -L "$generation_path" ] &&
        [ "$(readlink -f "$generation_path")" = "$running_system" ]; then
        running_generation="$generation"
        break
      fi
    done < <(
      sudo nix-env -p "$SYSTEM_PROFILE" --list-generations |
        awk '$1 ~ /^[0-9]+$/ { print $1 }'
    )

    while IFS= read -r generation; do
      [ "$(available_bytes)" -ge "$MIN_FREE_BYTES" ] && break
      [ "$generation" = "$current_generation" ] && continue
      [ -n "$running_generation" ] && [ "$generation" = "$running_generation" ] && continue

      echo "    deleting obsolete system generation $generation"
      sudo nix-env -p "$SYSTEM_PROFILE" --delete-generations "$generation"
      sudo "$SYSTEM_PROFILE/bin/switch-to-configuration" boot
    done < <(
      sudo nix-env -p "$SYSTEM_PROFILE" --list-generations |
        awk '$1 ~ /^[0-9]+$/ { print $1 }'
    )

    free_mib="$(available_mib)"
    if [ "$(available_bytes)" -lt "$MIN_FREE_BYTES" ]; then
      echo "ERROR: /boot has only $free_mib MiB free after safe cleanup" >&2
      echo "       The current profile and running system were preserved." >&2
      exit 1
    fi

    echo "==> /boot cleanup complete: $free_mib MiB free"
  '';
}
