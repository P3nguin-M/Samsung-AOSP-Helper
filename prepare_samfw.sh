#!/usr/bin/env bash
set -euo pipefail

# Device codename and directories
CODENAME="e3q"
EXT4FUSE="/Users/kevinmbp/aosp_projects/compile_bin/ext4fuse"
UNPACKBOOT="/Users/kevinmbp/aosp_projects/compile_bin/unpackbootimg"
LPUNPACK="/Users/kevinmbp/aosp_projects/compile_bin/lpunpack.py"
PROPDIR="/Users/kevinmbp/aosp_projects/device/samsung/$CODENAME/proprietary"
OUTDIR="/Users/kevinmbp/aosp_projects/vendor/samsung/$CODENAME/proprietary"
TMPDIR="tmp_ap"
MNTDIR="mnt"

# Clean state
rm -rf "$MNTDIR"
mkdir -p "$OUTDIR" "$TMPDIR" "$MNTDIR"

if [[ "$(uname)" == "Darwin" ]]; then
echo ">> Install ext4fuse via Homebrew (brew install ext4fuse) for ext4 mounts."
fi

action_trim_and_mount() {
  local img="$1" mnt="$2"
  echo ">> Searching for EXT filesystem superblock in $img..."

  local hexoff offset blockstart orig_size new_size
  hexoff=$(hexdump -v -e '1/1 "%06_ax %02X
"' "$img" | awk '{ b[NR]=$2; o[NR]=$1; if(NR>3 && b[NR-3]=="53" && b[NR-2]=="EF" && b[NR-1]=="01" && b[NR]=="00"){print o[NR-3]; exit}}')
  if [ -z "$hexoff" ]; then
    echo ">> No ext4 superblock found; skipping mount"
    return 1
  fi

  offset=$((16#$hexoff))
  blockstart=$((offset - 1080))  # FS start = magic pos - (1024 + 0x38)
  if (( blockstart < 0 )); then
    echo ">> Error: computed FS start < 0 (offset=$offset); skipping"
    return 1
  fi

  echo ">> Shifting filesystem data in-place (dropping first $blockstart bytes)..."
  orig_size=$(stat -f %z "$img")
  tail -c +$((blockstart+1)) "$img" | dd of="$img" conv=notrunc status=none
  new_size=$((orig_size - blockstart))
  truncate -s "$new_size" "$img"

  echo ">> Zeroing first 1024 bytes to align superblock..."
  dd if=/dev/zero of="$img" bs=1024 count=1 conv=notrunc sta


  tus=none

  echo ">> Mounting trimmed image $img..."
  mkdir -p "$mnt"
  if [[ "$(uname)" == "Darwin" ]]; then
    "$EXT4FUSE" "$img" "$mnt" || { echo ">> ERROR: ext4fuse mount failed; skipping"; return 1; }
  else
    sudo mount -t ext4 -o loop "$img" "$mnt" || { echo ">> ERROR: mount failed; skipping"; return 1; }
  fi
}
# 1) Unpack Odin AP Unpack Odin AP
if [ -z "$(ls -A "$TMPDIR" 2>/dev/null)" ]; then
  TAR_AP=$(ls "$PROPDIR"/AP_*tar.md5 2>/dev/null || true)
  [ -z "$TAR_AP" ] && { echo "ERROR: No AP_*tar.md5 found in $PROPDIR"; exit 1; }
  echo ">> Found $TAR_AP; extracting to $TMPDIR"
  tar -xf "$TAR_AP" -C "$TMPDIR"
else
  echo ">> $TMPDIR already contains files; skipping AP extraction"
fi

# 2) Decompress .lz4
if compgen -G "$TMPDIR"/*.lz4 > /dev/null; then
  echo ">> Decompressing .lz4 images..."
  for f in "$TMPDIR"/*.lz4; do
    echo "   Decompressing $(basename "$f")"
    lz4 -d "$f" && rm "$f"
  done
else
  echo ">> No .lz4 files to decompress; skipping"
fi

# 3) Sync system and vendor
for img in "$TMPDIR"/system.img "$TMPDIR"/vendor.img; do
  [ -e "$img" ] || continue
  mnt="$MNTDIR/$(basename "${img%%.img}")"
  mkdir -p "$mnt"
  if action_trim_and_mount "$img" "$mnt"; then
    echo ">> Syncing $(basename "${img%%.img}") partition"
    if ! sudo rsync -a "$mnt/" "$OUTDIR/"; then
      echo ">> WARNING: rsync failed for $img; continuing"
    fi
    sudo umount "$mnt"
  else
    echo ">> Skipping sync for $(basename "${img%%.img}") due to mount failure"
  fi
done

# 4) Dynamic partitions
if [ -f "$TMPDIR/super.img" ]; then
  DYN_OUT="$TMPDIR/super_dyn"
  if [ -z "$(ls -A "$DYN_OUT" 2>/dev/null)" ]; then
    mkdir -p "$DYN_OUT"
    echo ">> Running python3 unpack on super.img"
    python3 "$LPUNPACK" "$TMPDIR/super.img" "$DYN_OUT"
  else
    echo ">> $DYN_OUT already contains partitions; skipping unpack"
  fi
  for part in "$DYN_OUT"/*.img; do
    [ -e "$part" ] || continue
    name=$(basename "$part" .img)
    mnt="$MNTDIR/super_$name"; mkdir -p "$mnt"
    if action_trim_and_mount "$part" "$mnt"; then
      echo ">> Syncing partition $name"
      if ! sudo rsync -a "$mnt/" "$OUTDIR/"; then
        echo ">> WARNING: rsync failed for partition $name; continuing"
      fi
      sudo umount "$mnt"
    else
      echo ">> Skipping sync for partition $name due to mount failure"
    fi
  done
else
  echo ">> No super.img found; skipping dynamic partitions"
fi

# 5) Ramdisk extraction
for img in "$TMPDIR"/boot*.img "$TMPDIR"/vendor_boot.img "$TMPDIR"/init_boot.img "$TMPDIR"/recovery.img; do
  [ -e "$img" ] && {
    out="$TMPDIR/$(basename "${img%%.img}")_ramdisk"
    if [ -d "$out" ]; then
      echo ">> $out exists; skipping ramdisk extraction"
    else
      echo ">> Extracting ramdisk from $(basename "$img")"
      mkdir -p "$out"
      "$UNPACKBOOT" --input "$img" --output "$out"
      if [ -f "$out/ramdisk.img" ]; then
        mkdir -p "$out/ramdisk"
        gzip -dc "$out/ramdisk.img" | cpio -idm -D "$out/ramdisk"
        rsync -a "$out/ramdisk/" "$OUTDIR/$(basename "${img%%.img}")_ramdisk/"
      else
        echo ">> No ramdisk found in $img"
      fi
    fi
  }
done

# 6) Firmware/HAL packages
echo ">> Extracting firmware/HAL packages..."
for pkg in "$PROPDIR"/*.tar.gz; do
  [ -e "$pkg" ] && { echo "   Unpacking $(basename "$pkg")"; tar -xzf "$pkg" -C "$OUTDIR"; }
done


echo "Done. Your proprietary blobs are staged in $OUTDIR"
