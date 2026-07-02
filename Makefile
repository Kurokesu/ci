# SPDX-License-Identifier: GPL-2.0-only
# Copyright (c) 2026, UAB Kurokesu. All rights reserved.

obj-m += selftest.o

KDIR ?= /lib/modules/$(shell uname -r)/build

.PHONY: module clean

module:
	$(MAKE) -C $(KDIR) M=$(CURDIR) modules

# No kernel tree involved, so packaging clean works in a container
# without headers. dpkg-buildpackage runs clean before every build.
clean:
	rm -f *.o *.ko *.mod *.mod.c *.mod.o .*.cmd Module.symvers modules.order
