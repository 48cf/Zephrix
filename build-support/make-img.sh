#!/bin/bash

set -e

script_dir="$(dirname "$0")"
test -z "${script_dir}" && script_dir="."

source_dir="$(cd ${script_dir}/.. && pwd -P)"
build_dir="$(pwd -P)"

# Let the user pass their own $SUDO (or doas).
: "${SUDO:=sudo}"

if [ -f .jinx-parameters ]; then
    # If already initialized, get ARCH from .jinx-parameters file.
    ARCH="$(. ./.jinx-parameters && echo "${JINX_ARCH}")"
else
    # Get ARCH based on the build directory name.
    case "$(basename "${build_dir}")" in
        build-x86_64) ARCH=x86_64 ;;
        *)
            echo "error: The build directory must be called 'build-<architecture>'." 1>&2
            exit 1
            ;;
    esac

    "${source_dir}"/jinx init "${source_dir}" ARCH="${ARCH}"
fi

# Build the sysroot with jinx.
set -f

$SUDO rm -rf sysroot

"${source_dir}"/jinx update base $PKGS_TO_INSTALL

$SUDO --preserve-env "${source_dir}"/jinx install "sysroot" base $PKGS_TO_INSTALL

set +f

# Create and enable the first boot services.
cat <<'EOF' | $SUDO tee sysroot/usr/bin/first-boot-wizard >/dev/null
#!/bin/bash

set -e

echo "=== First boot setup wizard ==="
echo ""
echo -n "Enter your desired hostname (default: zephrix): "
read -r hostname_input

if [ -z "$hostname_input" ]; then
    hostname_input="zephrix"
fi

echo "$hostname_input" >/etc/hostname
echo "# Hostname fallback if /etc/hostname does not exist" >/etc/conf.d/hostname
echo "hostname=\"$hostname_input\"" >>/etc/conf.d/hostname
echo "Hostname set to: $hostname_input"

rc-service hostname restart &>/dev/null

echo ""
pwconv
passwd root

echo ""
echo "Setup complete! Press any key to continue..."
read -r -n 1 -s
EOF

cat <<'EOF' | $SUDO tee sysroot/etc/init.d/first-boot-xbps-reconfigure >/dev/null
#!/usr/bin/openrc-run

description="First boot (xbps-reconfigure)"

depend() {
    need localmount
    after bootmisc
}

start() {
    xbps-reconfigure -fa

    # Disable this service after first run
    rc-update del first-boot-xbps-reconfigure boot

    rm /etc/init.d/first-boot-xbps-reconfigure

    eend $?
}
EOF

cat <<'EOF' | $SUDO tee sysroot/etc/init.d/first-boot-wizard >/dev/null
#!/usr/bin/openrc-run

description="First boot setup wizard"

depend() {
    need localmount
    after bootmisc logger
}

start() {
    # Save current VT
    current_vt=$(fgconsole)

    # Run first-boot-wizard on VT9
    openvt -c 9 -s -w -- /usr/bin/first-boot-wizard

    # Switch back to original VT
    chvt "${current_vt}"

    # Disable this service after first run
    rc-update del first-boot-wizard default

    rm /usr/bin/first-boot-wizard
    rm /etc/init.d/first-boot-wizard

    eend $?
}
EOF

$SUDO chmod +x sysroot/usr/bin/first-boot-wizard
$SUDO chmod +x sysroot/etc/init.d/first-boot-xbps-reconfigure
$SUDO chmod +x sysroot/etc/init.d/first-boot-wizard

$SUDO ln -s ../../init.d/first-boot-xbps-reconfigure sysroot/etc/runlevels/boot/
$SUDO ln -s ../../init.d/first-boot-wizard sysroot/etc/runlevels/default/

if ! [ -d host-pkgs/limine ]; then
    "${source_dir}"/jinx host-build limine
fi

# Prepare the iso and boot directories.
rm -rf mount_dir

# Allocate the image. If a size is passed, we just use that size, else, we try
# to guesstimate calculate a rough size.
# Try to not use fractional sizes (3.X for example) since certain Linux distros
# like debian struggle to use it.
if [ -z "$IMAGE_SIZE" ]; then
    IMAGE_SIZE=8G
fi

rm -f jinix.img
fallocate -l "${IMAGE_SIZE}" jinix.img

# Format and mount the image.
PATH=$PATH:/usr/sbin:/sbin parted -s jinix.img mklabel gpt
PATH=$PATH:/usr/sbin:/sbin parted -s jinix.img mkpart ESP fat32 2048s 64MiB
PATH=$PATH:/usr/sbin:/sbin parted -s jinix.img set 1 esp on
PATH=$PATH:/usr/sbin:/sbin parted -s jinix.img mkpart bios_boot 64MiB 65MiB
PATH=$PATH:/usr/sbin:/sbin parted -s jinix.img set 2 bios_grub on
PATH=$PATH:/usr/sbin:/sbin parted -s jinix.img mkpart jinix_root ext4 5% 100%
LOOPBACK_DEV=$($SUDO losetup -Pf --show jinix.img)
$SUDO mkfs.fat ${LOOPBACK_DEV}p1
$SUDO mkfs.ext4 -U 0e0e97f9-5c96-4826-972f-118e2316e55c ${LOOPBACK_DEV}p3
mkdir -p mount_dir
$SUDO mount ${LOOPBACK_DEV}p3 mount_dir

# Copy the system root to the initramfs filesystem.
$SUDO cp -rp sysroot/* mount_dir/
$SUDO rm -rf mount_dir/boot
$SUDO mkdir -p mount_dir/boot
$SUDO mount ${LOOPBACK_DEV}p1 mount_dir/boot

$SUDO cp sysroot/usr/share/linux/vmlinuz mount_dir/boot/
$SUDO cp sysroot/usr/share/linux/initramfs mount_dir/boot/

$SUDO mkdir -p mount_dir/boot/limine
$SUDO cp host-pkgs/limine/usr/local/share/limine/limine-bios.sys mount_dir/boot/limine/
$SUDO mkdir -p mount_dir/boot/EFI/BOOT
$SUDO cp host-pkgs/limine/usr/local/share/limine/BOOTX64.EFI mount_dir/boot/EFI/BOOT/
$SUDO cp host-pkgs/limine/usr/local/share/limine/BOOTIA32.EFI mount_dir/boot/EFI/BOOT/

$SUDO sudo cp "${source_dir}/build-support/limine.conf" mount_dir/boot/

sync
$SUDO umount mount_dir/boot
$SUDO umount mount_dir
$SUDO rm -rf mount_dir
$SUDO losetup -d ${LOOPBACK_DEV}

# Arch-specific image triggers.
if [ "$ARCH" = x86_64 ]; then
    host-pkgs/limine/usr/local/bin/limine bios-install jinix.img
fi

sync
