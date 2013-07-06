#!/bin/bash

# make sure we have dependencies
hash genisoimage 2>/dev/null || { echo >&2 "ERROR: genisoimage not found.  Aborting."; exit 1; }
hash bundle 2>/dev/null || { echo >&2 "ERROR: bundle not found.  Aborting."; exit 1; }
hash VBoxManage 2>/dev/null || { echo >&2 "ERROR: VBoxManage not found.  Aborting."; exit 1; }
hash 7z 2>/dev/null || { echo >&2 "ERROR: 7z not found.  Aborting."; exit 1; }

set -o nounset
set -o errexit
#set -o xtrace

# Configurations
BOX="debian-wheezy-7_1-32"
#ISO_URL="http://cdimage.debian.org/debian-cd/7.0.0/amd64/iso-cd/debian-7.0.0-i386-netinst.iso"
#ISO_MD5="6a55096340b5b1b7d335d5b559e13ea0"
ISO_URL="http://cdimage.debian.org/debian-cd/current/i386/iso-cd/debian-7.1.0-i386-netinst.iso"
ISO_MD5="a70efb67ca061175eabe7c5dc04ab323"

# location, location, location
FOLDER_BASE=`pwd`
FOLDER_ISO="${FOLDER_BASE}/iso"
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_VBOX="${FOLDER_BUILD}/vbox"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"
FOLDER_ISO_INITRD="${FOLDER_BUILD}/iso/initrd"
GUESTSSH_PORT=$(( 2222 + $RANDOM % 100 ))

# start with a clean slate
if [ -d "${FOLDER_BUILD}" ]; then
  echo "Cleaning build directory ..."
  chmod -R u+w "${FOLDER_BUILD}"
  rm -rf "${FOLDER_BUILD}"
  mkdir -p "${FOLDER_BUILD}"
fi

# Setting things back up again
mkdir -p "${FOLDER_ISO}"
mkdir -p "${FOLDER_BUILD}"
mkdir -p "${FOLDER_VBOX}"
mkdir -p "${FOLDER_ISO_CUSTOM}"
mkdir -p "${FOLDER_ISO_INITRD}"

ISO_FILENAME="${FOLDER_ISO}/`basename ${ISO_URL}`"
INITRD_FILENAME="${FOLDER_ISO}/initrd.gz"

ISO_GUESTADDITIONS_URL="http://download.virtualbox.org/virtualbox/4.2.8/VBoxGuestAdditions_4.2.8.iso"
ISO_GUESTADDITIONS="${FOLDER_ISO}/VBoxGuestAdditions.iso"
ISO_GUESTADDITIONS_MD5="9939fe5672f979e4153c8937619c24f3"

# Setup vagrant locally

# download the installation disk if you haven't already or it is corrupted somehow
echo "Downloading `basename ${ISO_URL}` ..."
if [ ! -e "${ISO_FILENAME}" ]; then
  curl --output "${ISO_FILENAME}" -L "${ISO_URL}"

  # make sure download is right...
  ISO_HASH=`md5sum "${ISO_FILENAME}" | cut -c1-32`
  if [ "${ISO_MD5}" != "${ISO_HASH}" ]; then
    echo "ERROR: MD5 does not match. Got ${ISO_HASH} instead of ${ISO_MD5}. Aborting."
    exit 1
  fi
fi

echo "Downloading `basename ${ISO_GUESTADDITIONS_URL}` ..."
if [ ! -e "${ISO_GUESTADDITIONS}" ]; then
  curl --output "${ISO_GUESTADDITIONS}" -L "${ISO_GUESTADDITIONS_URL}"

  # make sure download is right...
  ISO_GUESTADDITIONS_HASH=`md5sum "${ISO_GUESTADDITIONS}" | cut -c1-32`
  if [ "${ISO_GUESTADDITIONS_MD5}" != "${ISO_GUESTADDITIONS_HASH}" ]; then
    echo "ERROR: MD5 does not match. Got ${ISO_GUESTADDITIONS_HASH} instead of ${ISO_GUESTADDITIONS_MD5}. Aborting."
    exit 1
  fi
fi

# customize it
echo "Creating Custom ISO"
if [ ! -e "${FOLDER_ISO}/custom.iso" ]; then

  echo "Extracting ISO content ..."
  7z x -o"${FOLDER_ISO_CUSTOM}" "${ISO_FILENAME}"

  # If that still didn't work, you have to update tar
  # FIXME: change check
  #if [ ! `ls -A "$FOLDER_ISO_CUSTOM"` ]; then
  #  echo "Error with extracting the ISO file."
  #  exit 1
  #fi

  # backup initrd.gz
  echo "Backing up current init.rd ..."
  FOLDER_INSTALL=$(ls -1 -d "${FOLDER_ISO_CUSTOM}/install."* | sed 's/^.*\///')
  chmod u+w "${FOLDER_ISO_CUSTOM}/${FOLDER_INSTALL}" "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/${FOLDER_INSTALL}/initrd.gz"
  cp -r "${FOLDER_ISO_CUSTOM}/${FOLDER_INSTALL}/"* "${FOLDER_ISO_CUSTOM}/install/"
  mv "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

  # stick in our new initrd.gz
  echo "Installing new initrd.gz ..."
  cd "${FOLDER_ISO_INITRD}"
  gunzip -c "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org" | cpio -id
  cd "${FOLDER_BASE}"
  cp preseed.cfg "${FOLDER_ISO_INITRD}/preseed.cfg"
  cd "${FOLDER_ISO_INITRD}"
  find . | cpio --create --format='newc' | gzip  > "${FOLDER_ISO_CUSTOM}/install/initrd.gz"

  # clean up permissions
  echo "Cleaning up Permissions ..."
  chmod u-w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

  # replace isolinux configuration
  echo "Replacing isolinux config ..."
  cd "${FOLDER_BASE}"
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  rm "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  cp isolinux.cfg "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
  chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.bin"

  # add late_command script
  echo "Add late_command script ..."
  chmod u+w "${FOLDER_ISO_CUSTOM}"
  cp "${FOLDER_BASE}/late_command.sh" "${FOLDER_ISO_CUSTOM}"

  echo "Running genisoimage ..."
  genisoimage -r -V "Custom Debian Install CD" \
    -cache-inodes -quiet \
    -J -l -b isolinux/isolinux.bin \
    -c isolinux/boot.cat -no-emul-boot \
    -boot-load-size 4 -boot-info-table \
    -o "${FOLDER_ISO}/custom.iso" "${FOLDER_ISO_CUSTOM}"
fi

echo "Creating VM Box..."
# create virtual machine
if ! VBoxManage showvminfo "${BOX}" >/dev/null 2>/dev/null; then
  echo " * remove previously created VM"
  if VBoxManage list vms |grep -q "^\"${BOX}\"" ; then
	  VBoxManage unregistervm \
		"${BOX}" \
		--delete
  fi
	
  echo " * creating ..."
  VBoxManage createvm \
    --name "${BOX}" \
    --ostype Debian \
    --register \
    --basefolder "${FOLDER_VBOX}"


  echo " * configuring ..."
  VBoxManage modifyvm "${BOX}" \
    --memory 360 \
    --boot1 dvd \
    --boot2 disk \
    --boot3 none \
    --boot4 none \
    --vram 12 \
    --pae off \
    --rtcuseutc on

  echo " * configuring IDE ..."
  VBoxManage storagectl "${BOX}" \
    --name "IDE Controller" \
    --add ide \
    --controller PIIX4 \
    --hostiocache on

  echo " * setting ISO image as boot disk ..."
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${FOLDER_ISO}/custom.iso"


  echo " * configuring SATA ..."
  VBoxManage storagectl "${BOX}" \
    --name "SATA Controller" \
    --add sata \
    --controller IntelAhci \
    --sataportcount 1 \
    --hostiocache off

  echo " * creating virtual disk ..."
  VBoxManage createhd \
    --filename "${FOLDER_VBOX}/${BOX}/${BOX}.vdi" \
    --size 40960


  echo " * attaching virtual disk ..."
  VBoxManage storageattach "${BOX}" \
    --storagectl "SATA Controller" \
    --port 0 \
    --device 0 \
    --type hdd \
    --medium "${FOLDER_VBOX}/${BOX}/${BOX}.vdi"


  echo -n "Running system installation ..."
  VBoxHeadless --startvm "${BOX}" &

  sleep 10
  echo -n "Waiting for installer to finish "
  while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
    sleep 20
    echo -n "."
  done
  echo ""

  # Forward SSH
  VBoxManage modifyvm "${BOX}" \
    --natpf1 "guestssh,tcp,,$GUESTSSH_PORT,,22"

  # Attach guest additions iso
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium "${ISO_GUESTADDITIONS}"

  VBoxHeadless --startvm "${BOX}" &

  # get private key
  echo "Install SSH private key"
  curl --output "${FOLDER_BUILD}/id_rsa" "https://raw.github.com/mitchellh/vagrant/master/keys/vagrant"
  chmod 600 "${FOLDER_BUILD}/id_rsa"

  echo "Install virtualbox guest additions"
  # install virtualbox guest additions
  ssh -i "${FOLDER_BUILD}/id_rsa" -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -p $GUESTSSH_PORT vagrant@127.0.0.1 "sudo mount /dev/cdrom /media/cdrom; sudo sh /media/cdrom/VBoxLinuxAdditions.run -- --force; sudo umount /media/cdrom; wget -O /home/vagrant/.ssh/authorized_keys 'http://niksite.ru/authorized_keys'; sudo shutdown -h now"
  echo -n "Waiting for machine to shut off "
  while VBoxManage list runningvms | grep "${BOX}" >/dev/null; do
    sleep 20
    echo -n "."
  done
  echo ""

  VBoxManage modifyvm "${BOX}" --natpf1 delete "guestssh"

  # Detach guest additions iso
  echo "Detach guest additions ..."
  VBoxManage storageattach "${BOX}" \
    --storagectl "IDE Controller" \
    --port 1 \
    --device 0 \
    --type dvddrive \
    --medium emptydrive
fi

echo "Building Vagrant Box ..."
vagrant package --base "${BOX}"

# references:
# http://blog.ericwhite.ca/articles/2009/11/unattended-debian-lenny-install/
# http://docs-v1.vagrantup.com/v1/docs/base_boxes.html
# http://www.debian.org/releases/stable/example-preseed.txt
# https://mikegriffin.ie/blog/20130418-creating-a-debian-wheezy-base-box-for-vagrant/
