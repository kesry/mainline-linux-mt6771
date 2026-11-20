obj-m += trim_acl_shim.o

KDIR ?= /opt/oppoa3/kernel-src
KOUT ?= /opt/oppoa3/qdiag
ARCH ?= arm64
CROSS ?= aarch64-linux-gnu-

all:
	$(MAKE) -C $(KDIR) O=$(KOUT) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) M=$(PWD) modules

clean:
	$(MAKE) -C $(KDIR) O=$(KOUT) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS) M=$(PWD) clean
