# Accepted host OSes else fail.
OS := $(shell uname)
ifeq      ($(OS), Linux)
else ifeq ($(OS), FreeBSD)
else
$(error Host OS $(OS) is not supported.)
endif

# User variables
PREFIX = $(shell pwd)/root
# -- Image size in M.
IMGSIZE = 4096

# Add toolchain to PATH
PATH := $(shell pwd)/host/toolchain/cross-root/bin:$(PATH)

# Qword repo
QWORD_DIR  := $(shell pwd)/qword
QWORD_REPO := https://github.com/qword-os/qword.git

.PHONY: all clean hdd run run-nokvm

all: $(QWORD_DIR)
	$(MAKE) -C $(QWORD_DIR) install CC=x86_64-qword-gcc PREFIX=$(PREFIX)

clean: $(QWORD_DIR)
	$(MAKE) -C $(QWORD_DIR) clean

$(QWORD_DIR):
	git clone $(QWORD_REPO) $(QWORD_DIR)

ifeq ($(OS), Linux)
LOOP_DEVICE := $(shell losetup --find)
else ifeq ($(OS), FreeBSD)
LOOP_DEVICE := md9
endif

hdd: all
	sudo -v
	rm -rf qword.part
	dd if=/dev/zero bs=1M count=0 seek=$(IMGSIZE) of=qword.part
	echfs-utils ./qword.part quick-format 32768
	cp -v /etc/localtime root/etc/
	chmod 644 root/etc/localtime
	./copy-root-to-img.sh root qword.part
	rm -rf qword.hdd
	dd if=/dev/zero bs=1M count=0 seek=$$(( $(IMGSIZE) + 65 )) of=qword.hdd
ifeq ($(OS), Linux)
	sudo losetup -P $(LOOP_DEVICE) qword.hdd
	sudo parted $(LOOP_DEVICE) mklabel msdos
	sudo losetup -d $(LOOP_DEVICE)
else ifeq ($(OS), FreeBSD)
	sudo mdconfig -a -t vnode -f qword.hdd -u $(LOOP_DEVICE)
	sudo gpart create -s mbr $(LOOP_DEVICE)
	sudo mdconfig -d -u $(LOOP_DEVICE)
endif
	dd if=./syslinux/mbr.bin of=qword.hdd conv=notrunc
ifeq ($(OS), Linux)
	sudo losetup -P $(LOOP_DEVICE) qword.hdd
	sudo parted $(LOOP_DEVICE) -a none mkpart primary 40s 131111s
	sudo parted $(LOOP_DEVICE) -a none mkpart primary 131112s $$(( (($(IMGSIZE) * 1024 * 1024) / 512) + 131112 ))s
	sudo parted $(LOOP_DEVICE) set 1 boot on
	sudo mkfs.fat $(LOOP_DEVICE)p1
	sudo syslinux -f -i $(LOOP_DEVICE)p1
	sudo rm -rf ./mnt && sudo mkdir mnt
	sudo mount $(LOOP_DEVICE)p1 ./mnt
	sudo cp -r ./root/boot/* ./mnt/
	sync
	sudo umount $(LOOP_DEVICE)p1
	sudo rm -rf ./mnt
	sudo dd bs=4M if=qword.part of=$(LOOP_DEVICE)p2 status=progress
	sudo losetup -d $(LOOP_DEVICE)
	rm qword.part
else ifeq ($(OS), FreeBSD)
	sudo mdconfig -a -t vnode -f qword.hdd -u $(LOOP_DEVICE)
	sudo gpart add -a 4k -t '!14' -s 64M $(LOOP_DEVICE)
	sudo gpart add -a 4k -t '!14' $(LOOP_DEVICE)
	sudo gpart set -a active -i 1 $(LOOP_DEVICE)
	sudo newfs_msdos /dev/$(LOOP_DEVICE)s1
	sudo syslinux -f -i /dev/$(LOOP_DEVICE)s1
	sudo rm -rf ./mnt && sudo mkdir mnt
	sudo mount -t msdosfs /dev/$(LOOP_DEVICE)s1 ./mnt
	sudo cp -r ./root/boot/* ./mnt/
	sync
	sudo umount /dev/$(LOOP_DEVICE)s1
	sudo rm -rf ./mnt
	sudo dd bs=4M if=qword.part of=/dev/$(LOOP_DEVICE)s2 status=progress
	sudo mdconfig -d -u $(LOOP_DEVICE)
	rm qword.part
endif

# Emulation settings
QEMU_FLAGS := $(QEMU_FLAGS)                          \
	-m 2G                                            \
	-net none                                        \
	-debugcon stdio                                  \
	-d cpu_reset                                     \
	-device ahci,id=ahci                             \
	-drive if=none,id=disk,file=qword.hdd,format=raw \
	-device ide-drive,drive=disk,bus=ahci.0          \
	-smp sockets=1,cores=4,threads=1

run:
	qemu-system-x86_64 $(QEMU_FLAGS) -enable-kvm

run-nokvm:
	qemu-system-x86_64 $(QEMU_FLAGS)
