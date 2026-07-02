// SPDX-License-Identifier: GPL-2.0-only
// Copyright (c) 2026, UAB Kurokesu. All rights reserved.
/* Dummy module for the Kurokesu CI selftest fixture. DKMS builds it on
 * target at install time, so packaging selftests never compile it.
 */

#include <linux/init.h>
#include <linux/module.h>

static int __init selftest_init(void)
{
	return 0;
}

static void __exit selftest_exit(void)
{
}

module_init(selftest_init);
module_exit(selftest_exit);

MODULE_AUTHOR("Danius Kalvaitis <danius@kurokesu.com>");
MODULE_DESCRIPTION("Kurokesu CI selftest fixture module");
MODULE_LICENSE("GPL");
