// SPDX-License-Identifier: GPL-2.0
/*
 * Does a write to Apple's VM_TMR_FIQ_ENA_EL2 take effect on this SoC?
 *
 * The AIC driver masks a guest's timer FIQ by clearing bits in this register.
 * KVM relies on that mask to stop a pending guest timer from refiring. If the
 * write is ignored, the guest timer FIQ storms and VMs hang.
 *
 * For each CPU named in the cpus= parameter, with interrupts off: read the
 * register, write it with both bits set, read, write it with both clear, read,
 * restore the original value, read. Logs the values and refuses to stay loaded
 * (init returns -ENODEV), so nothing remains after the run.
 *
 * Only meaningful when the kernel runs at EL2 (VHE), as it does on Omarchy.
 */
#include <linux/module.h>
#include <linux/smp.h>
#include <linux/cpumask.h>
#include <asm/sysreg.h>
#include <asm/virt.h>
#include <asm/cputype.h>

#define SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2 sys_reg(3, 5, 15, 1, 3)
#define VM_TMR_BITS (BIT(0) | BIT(1))

static char *cpus = "0-13";
module_param(cpus, charp, 0444);

struct probe_result {
	u64 orig, after_set, after_clear, after_restore;
	u32 midr;
};

static void probe_cpu(void *data)
{
	struct probe_result *r = data;
	unsigned long flags;

	local_irq_save(flags);
	r->midr = read_cpuid_id();
	r->orig = read_sysreg_s(SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	write_sysreg_s(r->orig | VM_TMR_BITS, SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	isb();
	r->after_set = read_sysreg_s(SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	write_sysreg_s(r->orig & ~VM_TMR_BITS, SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	isb();
	r->after_clear = read_sysreg_s(SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	write_sysreg_s(r->orig, SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	isb();
	r->after_restore = read_sysreg_s(SYS_IMP_APL_VM_TMR_FIQ_ENA_EL2);
	local_irq_restore(flags);
}

static int __init vm_timer_probe_init(void)
{
	cpumask_var_t mask;
	int cpu, err;

	if (!is_kernel_in_hyp_mode()) {
		pr_err("vm_timer_probe: kernel not at EL2, nothing to test\n");
		return -ENODEV;
	}
	if (!zalloc_cpumask_var(&mask, GFP_KERNEL))
		return -ENOMEM;
	err = cpulist_parse(cpus, mask);
	if (err)
		goto out;

	for_each_cpu_and(cpu, mask, cpu_online_mask) {
		struct probe_result r = {};

		err = smp_call_function_single(cpu, probe_cpu, &r, 1);
		if (err) {
			pr_err("vm_timer_probe: cpu%d: call failed %d\n", cpu, err);
			continue;
		}
		pr_info("vm_timer_probe: cpu%d midr=%08x orig=%#llx set->%#llx clear->%#llx restore->%#llx %s\n",
			cpu, r.midr,
			r.orig, r.after_set, r.after_clear, r.after_restore,
			((r.after_set & VM_TMR_BITS) == VM_TMR_BITS &&
			 !(r.after_clear & VM_TMR_BITS)) ? "WRITES TAKE" :
			"WRITES IGNORED");
	}
	err = -ENODEV; /* never stay loaded */
out:
	free_cpumask_var(mask);
	return err;
}

module_init(vm_timer_probe_init);
MODULE_DESCRIPTION("Probe whether VM_TMR_FIQ_ENA_EL2 writes take effect");
MODULE_LICENSE("GPL");
