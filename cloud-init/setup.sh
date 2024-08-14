#!/bin/bash
set -e

RELEASE=24.04
CODENAME=noble
# see https://launchpad.net/ubuntu/+cdmirrors
MIRROR=https://releases.ubuntu.com

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
mkdir -p $SCRIPT_DIR/data
cd $SCRIPT_DIR/data

if [ -e SHA256SUMS ]; then
    rm -rf SHA256SUMS
fi
wget "$MIRROR/$RELEASE/SHA256SUMS"
if [ -e SHA256SUMS.gpg ]; then
    rm -rf SHA256SUMS.gpg
fi
wget -q "$MIRROR/$RELEASE/SHA256SUMS.gpg"
gpg --keyid-format long --keyserver hkp://keyserver.ubuntu.com --recv-keys 0x843938DF228D22F7B3742BC0D94AA3F0EFE21092
gpg --keyid-format long --verify SHA256SUMS.gpg SHA256SUMS

if [ -e tftp ]; then
    rm -rf tftp
fi
mkdir tftp
cd tftp
wget "$MIRROR/$CODENAME/ubuntu-$RELEASE-netboot-amd64.tar.gz"
sha256sum --check --ignore-missing ../SHA256SUMS
tar xf "ubuntu-$RELEASE-netboot-amd64.tar.gz" ./amd64/ --strip-components=2 
rm "ubuntu-$RELEASE-netboot-amd64.tar.gz"
# instantly boot installer without timeout or human interaction
sed -i '1 i\set timeout=0' grub/grub.cfg
sed -i '/DEFAULT install/a PROMPT 0' pxelinux.cfg/default
# increase ramdisk size to fit entire image
sed -i 's|---|root=/dev/ram0 ramdisk_size=3000000 ---|g' grub/grub.cfg
sed -i -E 's|ramdisk_size=([0-9]+)|ramdisk_size=3000000|g' pxelinux.cfg/default
# pull image from local source instead of the default public mirror
sed -i "s|https://releases.ubuntu.com/$RELEASE|ftp://192.168.1.2|g" grub/grub.cfg 
sed -i "s|https://releases.ubuntu.com/$RELEASE|ftp://192.168.1.2|g" pxelinux.cfg/default
# auto-install using cloud-init, point to the locally hosted CIDATA
sed -i 's|---|autoinstall ds=nocloud-net\\;s=http://192.168.1.2:8080/configs/ ---|g' grub/grub.cfg # grub treats an unescaped semicolon as beginning of a comment
sed -i 's|---|autoinstall ds=nocloud-net;s=http://192.168.1.2:8080/configs/ ---|g' pxelinux.cfg/default
cd ..

if [ -e ftp ]; then
    rm -rf ftp
fi
mkdir ftp
cd ftp
wget "$MIRROR/$RELEASE/ubuntu-$RELEASE-live-server-amd64.iso"
sha256sum --check --ignore-missing ../SHA256SUMS
cd ..

if [ -e http ]; then
    rm -rf http
fi
mkdir -p http/configs
cd http/configs
touch meta-data
cp $SCRIPT_DIR/user-data .

cd $SCRIPT_DIR/data
rm -rf SHA256SUMS SHA256SUMS.gpg
