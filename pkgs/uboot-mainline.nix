{ pkgs, crossPkgs, axSign
, debugMilestones ? false
, dcacheOff ? false
, ... }:

# ===========================================================================
# Mainline U-Boot for the AX630C / NanoKVM-Pro (#89, epic #26).
#
# Upstream U-Boot 2026.07, unmodified, plus a five-patch AX630C port carried in
# pkgs/uboot-mainline/patches/ in upstream-submission shape. It replaces the
# vendor's U-Boot 2020.04 fork (pkgs/boot.nix), which is 325 files and
# +157 811 lines off upstream -- almost none of it load-bearing. What the port
# actually needs is 885 lines, because mainline already ships the two drivers
# the vendor forked (sdhci-cadence for the eMMC's Cadence SD4HC; ns16550 for
# the DesignWare UART), and because the first-stage loader hands BL33 a SoC
# whose clocks, muxes and pads are already set. docs/mainline-port.md 11.10.
#
# WHAT THIS PRODUCES
#   images/u-boot.bin                    raw, DT appended, links at 0x5C000400
#   images/u-boot.dtb                    the device tree that is inside it
#   images/u-boot_mainline_signed.bin    axgzip'd + 1 KiB signed header,
#                                        packaged exactly like the vendor's
#                                        u-boot_signed.bin, `dd`-able into the
#                                        `uboot` or `uboot_b` partition
#   src/part_cmdline.c                   the patched partition driver, so the
#                                        host-side parser test in
#                                        checks.uboot-mainline builds the
#                                        SHIPPED source rather than a copy
#
# ONE LAYOUT, NOT THREE. The blkdevparts= clause, the environment's offset and
# size, and the boot partition number are all injected below from
# nixos/emmc-partitions.nix, which parses them out of the `bootargs` line of
# dts/ax630c-nanokvm-pro.dts. The defconfig in the patch carries the same
# values as its upstream-visible default, and every substitution here is
# asserted, so the two can never silently disagree.
#
# NOT TESTED ON HARDWARE. Nothing in this file has run on the board; rung 0 of
# the #89 ladder is "it builds and the images fit".
# ===========================================================================

let
  inherit (pkgs) lib;

  layout = import ../nixos/emmc-partitions.nix { inherit lib; };

  version = "2026.07";

  # Current upstream release. Matches the tree docs/mainline-port.md 11.1
  # diffed the vendor fork against, and the version our nixpkgs pin builds
  # `ubootTools` from, so the toolchain expectations are already exercised.
  src = pkgs.fetchurl {
    url = "https://ftp.denx.de/pub/u-boot/u-boot-${version}.tar.bz2";
    sha256 = "0gi4y60y658lkls4qpcvfwvs08imas6ay7daandqyf7yhb1vzs3q";
  };

  defconfig = "ax630c_nanokvm_pro_defconfig";

  crossCC = crossPkgs.buildPackages.gcc;
  crossBinutils = crossPkgs.buildPackages.binutils;
  crossPrefix = crossPkgs.stdenv.cc.targetPrefix;

  patches = [
    ./uboot-mainline/patches/0001-arm-add-Axera-AX620E-AX630C-SoC-support.patch
    ./uboot-mainline/patches/0002-board-axera-add-the-Sipeed-NanoKVM-Pro.patch
    ./uboot-mainline/patches/0003-arm-dts-add-the-AX630C-and-the-Sipeed-NanoKVM-Pro.patch
    ./uboot-mainline/patches/0004-disk-add-a-blkdevparts-command-line-partition-driver.patch
    ./uboot-mainline/patches/0005-configs-add-ax630c_nanokvm_pro_defconfig.patch
  ];

  # The SPL enters BL33 here (docs/mainline-port.md 11.2). It is not
  # negotiable: the address is a compile-time constant in the first-stage
  # loader, and the 1 KiB image header carries no load address of its own.
  textBase = "0x5C000400";

  ubootPart = layout.byName.uboot;

  # -------------------------------------------------------------------------
  # Milestone instrumentation (#89 rung 2, debugMilestones = true).
  #
  # This board's console UART is on hidden pads, so a U-Boot that dies before
  # `preboot` says nothing the shipping image can read except whatever landed
  # in CONFIG_PRE_CONSOLE_BUFFER -- and that channel goes quiet the moment
  # `serial_initialize()` sets GD_FLG_SERIAL_READY, which is a third of the way
  # into board_init_r. These writes give the whole of board_init_r the same
  # channel #75 gave the kernel and rung 1 gave BL31: the spare high bits of
  # the A/B slot register 0x02390024, through its write-1-to-set alias at
  # +4, which survive a warm reboot, a watchdog reset and the SPL's fallback
  # to slot A.
  #
  # Bits, in execution order -- every one of them a hook U-Boot already calls,
  # so the instrumentation adds no new call site to upstream code:
  #
  #   12  dram_init            entered (pre-relocation, MMU off)
  #   13  dram_init_banksize   returned
  #   14  enable_caches        entered -- relocate_code() returned, so U-Boot
  #                            is running from the top of DRAM
  #   15  icache_enable        returned
  #   21  dcache_enable        returned -- the MMU is on with our mem_map
  #   16  board_init           driver model bound as well
  #   17  board_early_init_r   serial_initialize() and dm_announce() done, and
  #                            the last hook before initr_mmc (ARCH_EARLY_INIT_R
  #                            has no prompt on arm, so there is no hook between
  #                            this one and the eMMC)
  #   19  misc_init_r          eMMC, environment AND console_init_r all done
  #   20  board_late_init      interrupts up, one hook short of main_loop
  #   28  preboot              (the shipping milestone -- defconfig, not here)
  #
  # 12..20 are Linux's bits in the shipping assignment (docs/mainline-port.md
  # 11.10). That is fine and deliberate: a run that needs this build is a run
  # that never reaches Linux, and the register is cleared before each one.
  # -------------------------------------------------------------------------
  milestonePostPatch = ''
    substituteInPlace arch/arm/mach-axera/soc.c --replace-fail \
      '#include <asm/armv8/mmu.h>' \
      '#include <asm/armv8/mmu.h>
    #include <asm/io.h>

    /* #89 rung 2 boot-evidence channels -- see pkgs/uboot-mainline.nix. */
    #define AX630C_DBG_SLOT_SET	0x02390028UL
    #define AX630C_DBG_SCRATCH	0x480EC000UL

    void ax630c_milestone(unsigned int bit)
    {
    	writel(1U << bit, (void *)AX630C_DBG_SLOT_SET);
    }

    /*
     * A sixteen-word scratchpad in the spare tail of the pstore window, for
     * the values a single register bit cannot carry. writel() is a Device
     * store with the MMU off, so it reaches DRAM without a cache flush -- and
     * whether it reaches DRAM at all, from relocated code, is itself one of
     * the things being measured.
     */
    void ax630c_dbg_word(unsigned int idx, unsigned int val)
    {
    	writel(val, (void *)(AX630C_DBG_SCRATCH + 4 * idx));
    }'

    # Number every initcall. board_init_f() and board_init_r() are both an
    # ordered list of INITCALL(x), and the macro is one place -- so recording
    # __LINE__ before each call turns "it hung somewhere after relocation" into
    # a line number in common/board_[fr].c, for every stage, at the cost of one
    # store per initcall. The two files' line ranges do not overlap, so the
    # number alone says which phase as well as which call.
    substituteInPlace include/initcall.h --replace-fail \
      '#define INITCALL(_call) \
    	do { \
    		if (_call()) { \' \
      'void ax630c_dbg_word(unsigned int idx, unsigned int val);

    /*
     * The generic timer is running at 24 MHz before BL33 is entered (the
     * first-stage loader writes CNTFRQ_EL0), so CNTPCT_EL0 is a free
     * stopwatch. Recorded next to the line number, it separates the two
     * explanations for a boot that stops: a hang leaves a small elapsed
     * count, a timeout leaves one close to whatever period cut it off.
     * 32 bits of a 24 MHz counter wrap every 179 s.
     */

    #define AX630C_TICKS() ({ unsigned long __t; asm volatile("mrs %0, cntpct_el0" : "=r" (__t)); (unsigned int)__t; })

    #define INITCALL(_call) \
    	do { \
    		ax630c_dbg_word(12, __LINE__); \
    		ax630c_dbg_word(13, AX630C_TICKS()); \
    		if (_call()) { \'

    # Did relocate_code() return, and is the code that follows it running from
    # the relocated image? board_init_r() is the first C the relocated image
    # executes, and its own address settles the second question: `&board_init_r`
    # taken from inside it is PC-relative, so it IS the program counter.
    substituteInPlace common/board_r.c --replace-fail \
      '	gd->flags &= ~(GD_FLG_SERIAL_READY | GD_FLG_LOG_READY);' \
      '	ax630c_dbg_word(23, 0xB00DB00D);
    	ax630c_dbg_word(24, AX630C_TICKS());
    	ax630c_dbg_word(25, (unsigned int)(uintptr_t)new_gd);
    	ax630c_dbg_word(26, (unsigned int)dest_addr);
    	ax630c_dbg_word(27, (unsigned int)(uintptr_t)&board_init_r);
    	ax630c_dbg_word(28, (unsigned int)(uintptr_t)__builtin_return_address(0));

    	gd->flags &= ~(GD_FLG_SERIAL_READY | GD_FLG_LOG_READY);'

    # And name every device-tree node as driver model binds it: the first
    # eight characters of the node name, as two words, plus a running count.
    # `initr_dm` is one initcall but hundreds of binds, so the initcall line
    # number alone stops being enough once the hang is inside it.
    substituteInPlace drivers/core/lists.c --replace-fail \
      '	if (devp)
    		*devp = NULL;
    	name = ofnode_get_name(node);' \
      '	if (devp)
    		*devp = NULL;
    	name = ofnode_get_name(node);
    	{
    		extern void ax630c_dbg_word(unsigned int idx, unsigned int val);
    		static unsigned int ax630c_bind_count;
    		unsigned int w0 = 0, w1 = 0;
    		int ax_i;

    		for (ax_i = 0; ax_i < 4 && name[ax_i]; ax_i++)
    			w0 |= (unsigned int)name[ax_i] << (8 * ax_i);
    		for (; ax_i < 8 && name[ax_i]; ax_i++)
    			w1 |= (unsigned int)name[ax_i] << (8 * (ax_i - 4));
    		ax630c_dbg_word(14, w0);
    		ax630c_dbg_word(15, w1);
    		ax630c_dbg_word(16, ++ax630c_bind_count);
    	}'

    substituteInPlace arch/arm/mach-axera/soc.c --replace-fail \
      'int dram_init(void)
    {
    	int ret = fdtdec_setup_mem_size_base();' \
      'int dram_init(void)
    {
    	int ret;

    	ax630c_milestone(12);
    	ret = fdtdec_setup_mem_size_base();'

    substituteInPlace arch/arm/mach-axera/soc.c --replace-fail \
      'int dram_init_banksize(void)
    {
    	return fdtdec_setup_memory_banksize();
    }' \
      'int dram_init_banksize(void)
    {
    	int ret = fdtdec_setup_memory_banksize();

    	ax630c_milestone(13);
    	return ret;
    }'

    substituteInPlace board/axera/ax630c/ax630c.c --replace-fail \
      '#include <init.h>
    #include <stdio.h>' \
      '#include <init.h>
    #include <stdio.h>
    #include <cpu_func.h>
    #include <asm/io.h>
    #include <asm/cache.h>
    #include <asm/global_data.h>
    #include <asm/system.h>
    #include <asm/armv8/mmu.h>

    DECLARE_GLOBAL_DATA_PTR;'

    substituteInPlace board/axera/ax630c/ax630c.c --replace-fail \
      'int board_init(void)
    {
    	return 0;
    }' \
      'void ax630c_milestone(unsigned int bit);

    /*
     * Pre-relocation, and therefore printable: everything printf()s before
     * console_init_r() also lands in the pre-console buffer, which is the only
     * console this board has. This is where the relocation target comes from.
     */
    phys_addr_t board_get_usable_ram_top(phys_size_t total_size)
    {
    	printf("ram_base %llx size %llx top %llx mon_len %lx\n",
    	       (unsigned long long)gd->ram_base,
    	       (unsigned long long)gd->ram_size,
    	       (unsigned long long)gd->ram_top,
    	       (unsigned long)gd->mon_len);

    	return gd->ram_top;
    }

    /*
     * Post-relocation, and deliberately silent: gd->flags loses
     * GD_FLG_SERIAL_READY at the top of board_init_r, so a printf() here would
     * reach serial_putc() with a stale device pointer. Bits only.
     */
    void ax630c_dbg_word(unsigned int idx, unsigned int val);

    /*
     * Everything a milestone bit cannot say, dumped to the scratchpad the
     * moment board_init_r() hands control to a board hook. Word 0 is a magic
     * so a stale window cannot be mistaken for a fresh one; its presence also
     * answers, on its own, whether a plain DRAM store from relocated code
     * reaches DRAM at all.
     */
    static void ax630c_dump_gd(void)
    {
    	ax630c_dbg_word(1, (u32)gd->arch.tlb_addr);
    	ax630c_dbg_word(2, (u32)(gd->arch.tlb_addr >> 32));
    	ax630c_dbg_word(3, (u32)gd->arch.tlb_size);
    	ax630c_dbg_word(4, (u32)gd->relocaddr);
    	ax630c_dbg_word(5, (u32)gd->ram_top);
    	ax630c_dbg_word(6, (u32)gd->ram_size);
    	ax630c_dbg_word(7, (u32)gd->start_addr_sp);
    	ax630c_dbg_word(8, (u32)gd->reloc_off);
    	ax630c_dbg_word(9, (u32)(uintptr_t)gd);
    	ax630c_dbg_word(10, (u32)gd->flags);
    	ax630c_dbg_word(0, 0x55424D31);		/* "UBM1", written last */
    }

    /*
     * Does relocation work? Three answers, from relocated code:
     *   17  the address of a static -- PC-relative, so it needs no fixup and
     *       must land in the relocated image
     *   18  that static read back after a write -- proves BSS is where the
     *       code thinks it is, and was cleared
     *   19  the address of a function, likewise PC-relative
     *   20  `mem_map`, an initialised pointer in .data. THIS one needs an
     *       R_AARCH64_RELATIVE fixup, so it is the actual test: a value near
     *       0x5C0xxxxx means .rela.dyn was not applied and every absolute
     *       pointer in the image still points at the unrelocated copy.
     */
    static unsigned int ax630c_reloc_probe;

    static void ax630c_check_reloc(void)
    {
    	extern struct mm_region *mem_map;

    	ax630c_reloc_probe = 0xA5A5A5A5;
    	ax630c_dbg_word(17, (unsigned int)(uintptr_t)&ax630c_reloc_probe);
    	ax630c_dbg_word(18, ax630c_reloc_probe);
    	ax630c_dbg_word(19, (unsigned int)(uintptr_t)&ax630c_milestone);
    	ax630c_dbg_word(20, (unsigned int)(uintptr_t)mem_map);
    	ax630c_dbg_word(21, (unsigned int)(uintptr_t)&mem_map);
    }

    #ifndef AX630C_NO_MMU
    void mmu_enable(void);
    void setup_pgtables(void);
    u64 get_tcr(u64 *pips, u64 *pva_bits);
    u64 get_page_table_size(void);

    /*
     * mmu_setup() is __weak upstream, so the debug build replaces it with a
     * printf-instrumented copy. printf() works here only because
     * GD_FLG_HAVE_CONSOLE is cleared first: with the flag set, putc() calls
     * serial_putc() as well, and board_init_r() has already dropped
     * GD_FLG_SERIAL_READY, so gd->cur_serial_dev points at a pre-relocation
     * device. Cleared, every character goes to the pre-console buffer and
     * nowhere else -- which is a full printf channel on a board with no
     * console, for as long as the dcache is still off.
     */
    void mmu_setup(void)
    {
    	unsigned long flags = gd->flags;
    	u64 va_bits = 0;
    	u64 tcr;

    	ax630c_milestone(26);
    	gd->flags &= ~GD_FLG_HAVE_CONSOLE;

    	tcr = get_tcr(NULL, &va_bits);
    	ax630c_milestone(27);
    	printf("mmu: tlb %llx size %llx fill %llx el %d\n",
    	       (unsigned long long)gd->arch.tlb_addr,
    	       (unsigned long long)gd->arch.tlb_size,
    	       (unsigned long long)gd->arch.tlb_fillptr,
    	       current_el());
    	printf("mmu: tcr %llx va_bits %llu\n",
    	       (unsigned long long)tcr, (unsigned long long)va_bits);

    	if (!gd->arch.tlb_fillptr) {
    		gd->arch.tlb_fillptr = gd->arch.tlb_addr;
    		printf("mmu: setup_pgtables\n");
    		/*
    		 * printf() is dead post-relocation on this board (measured),
    		 * so publish the page-table address through the register
    		 * instead: clear bits 12..31, then set the bits of the address
    		 * itself. If
    		 * setup_pgtables() never returns, the slot register reads back
    		 * as the exact address it was writing to.
    		 */
    		writel(0xFFFFF000U, (void *)0x0239002CUL);
    		writel((u32)gd->arch.tlb_addr & 0xFFFFF000U,
    		       (void *)0x02390028UL);
    		setup_pgtables();
    		writel(0xFFFFF000U, (void *)0x0239002CUL);
    		ax630c_milestone(29);
    		printf("mmu: pgtables done, fill %llx\n",
    		       (unsigned long long)gd->arch.tlb_fillptr);
    	}

    	printf("mmu: set_ttbr_tcr_mair\n");
    	set_ttbr_tcr_mair(current_el(), gd->arch.tlb_addr, tcr,
    			  MEMORY_ATTRIBUTES);
    	ax630c_milestone(30);
    	printf("mmu: done\n");

    	gd->flags = flags;
    }

    void enable_caches(void)
    {
    	ax630c_milestone(14);
    	ax630c_dump_gd();
    	ax630c_check_reloc();
    	icache_enable();
    	ax630c_milestone(15);

    	/* dcache_enable(), unrolled, so each step of it is observable. */
    	__asm_invalidate_tlb_all();
    	ax630c_milestone(21);
    	mmu_setup();			/* page tables, TTBR0/TCR/MAIR */
    	ax630c_milestone(22);
    	mmu_enable();			/* SCTLR.M = 1 */
    	ax630c_milestone(23);
    	invalidate_dcache_all();
    	ax630c_milestone(24);
    	set_sctlr(get_sctlr() | CR_C);	/* SCTLR.C = 1 */
    	ax630c_milestone(25);
    }
    #else
    /*
     * AX630C_NO_MMU: never call dcache_enable(), so the MMU stays off and the
     * whole of board_init_r runs with data accesses as Device-nGnRnE. Slow,
     * and it decouples the rest of the boot from the page-table bug -- rung 2
     * can be finished without solving it. cleanup_before_linux() later calls
     * dcache_disable(), which returns immediately when SCTLR.C is clear.
     */
    void enable_caches(void)
    {
    	ax630c_milestone(14);
    	ax630c_dump_gd();
    	ax630c_check_reloc();
    	icache_enable();
    	ax630c_milestone(15);
    	ax630c_milestone(25);
    }
    #endif

    int board_init(void)
    {
    	ax630c_milestone(16);
    	return 0;
    }

    int board_early_init_r(void)
    {
    	ax630c_milestone(17);
    	return 0;
    }

    int misc_init_r(void)
    {
    	ax630c_milestone(19);
    	return 0;
    }

    int board_late_init(void)
    {
    	ax630c_milestone(20);
    	return 0;
    }'

    cat >> configs/${defconfig} <<'EOF'
    CONFIG_BOARD_EARLY_INIT_R=y
    CONFIG_MISC_INIT_R=y
    CONFIG_BOARD_LATE_INIT=y
    EOF
  '';

  # -------------------------------------------------------------------------
  # dcacheOff = true: never switch the MMU on.
  #
  # Rung 2 measured mainline U-Boot hanging inside mmu_setup(), the arm64
  # page-table build, before SCTLR.M is ever set. Everything the rung actually
  # exists to prove -- sdhci-cadence on this eMMC, part_cmdline, the
  # environment, bootcount, extlinux, booti -- is downstream of that, so this
  # variant decouples the two: board_init_r runs with data accesses as
  # Device-nGnRnE and the boot proceeds. Slow, and not what ships.
  #
  # NOT `CONFIG_SYS_DCACHE_OFF`. That looks like the right switch and does not
  # link on arm64 in 2026.07: `boot/bootm_os.c` and `cmd/elf.c` call
  # `dcache_enable()` / `dcache_disable()` unconditionally, and the stubs that
  # would satisfy them are inside the same `#if` the config turns off. Skipping
  # the call from our own `enable_caches()` is the same thing at runtime and
  # leaves every symbol defined. `cleanup_before_linux()`'s later
  # `dcache_disable()` returns immediately with SCTLR.C clear.
  #
  # Implies debugMilestones: the override it flips lives in that patch.
  # -------------------------------------------------------------------------
  dcacheOffPostPatch = ''
    substituteInPlace include/configs/ax630c.h --replace-fail \
      '#define CFG_SYS_SDRAM_BASE		0x40000000' \
      '#define AX630C_NO_MMU			1
    #define CFG_SYS_SDRAM_BASE		0x40000000'
  '';

  variant = assert lib.assertMsg (!dcacheOff || debugMilestones)
    "uboot-mainline: dcacheOff needs debugMilestones -- the enable_caches() it flips is in that patch";
    lib.optionalString debugMilestones "-debug"
    + lib.optionalString dcacheOff "-nommu";

  raw = pkgs.stdenv.mkDerivation {
    pname = "nanokvm-pro-uboot-mainline" + variant;
    inherit version src patches;

    # U-Boot manages its own flags; the cc-wrapper must not inject PIE,
    # fortify or stack-protector into a bare-metal image.
    hardeningDisable = [ "all" ];
    enableParallelBuilding = true;

    nativeBuildInputs = [ crossCC crossBinutils ] ++ (with pkgs; [
      gnumake bison flex bc dtc openssl ncurses python3 swig
      which gawk perl bash
    ]);

    # Everything the layout defines, in the two places U-Boot reads it.
    blkdevparts = layout.blkdevparts;
    envOffset = layout.hex layout.env.offset;
    envSize = layout.hex layout.env.size;
    bootPart = toString layout.bootfs.number;

    postPatch = ''
      patchShebangs tools scripts

      cfg=configs/${defconfig}
      hdr=include/configs/ax630c.h

      # --- the eMMC layout, from dts/ax630c-nanokvm-pro.dts ----------------
      # A mismatch here is not a build error on either side: U-Boot would
      # simply find a different `boot` partition than Linux does, at a
      # different offset, and the first symptom would be a board that stops
      # booting. So substitute, then assert.
      sed -i "s|^CONFIG_CMDLINE_PARTITION_DEFAULT=.*|CONFIG_CMDLINE_PARTITION_DEFAULT=\"$blkdevparts\"|" "$cfg"
      grep -qF "CONFIG_CMDLINE_PARTITION_DEFAULT=\"$blkdevparts\"" "$cfg" \
        || { echo "ERROR: could not set the blkdevparts clause in $cfg" >&2; exit 1; }

      sed -i "s|^CONFIG_ENV_OFFSET=.*|CONFIG_ENV_OFFSET=$envOffset|" "$cfg"
      sed -i "s|^CONFIG_ENV_SIZE=.*|CONFIG_ENV_SIZE=$envSize|" "$cfg"
      grep -qx "CONFIG_ENV_OFFSET=$envOffset" "$cfg" \
        || { echo "ERROR: could not set CONFIG_ENV_OFFSET in $cfg" >&2; exit 1; }
      grep -qx "CONFIG_ENV_SIZE=$envSize" "$cfg" \
        || { echo "ERROR: could not set CONFIG_ENV_SIZE in $cfg" >&2; exit 1; }

      grep -q "bootpart=[0-9][0-9]*" "$hdr" \
        || { echo "ERROR: no bootpart default in $hdr (did the port move it?)" >&2; exit 1; }
      sed -i "s|bootpart=[0-9][0-9]*|bootpart=$bootPart|" "$hdr"
      grep -qF "bootpart=$bootPart" "$hdr" \
        || { echo "ERROR: could not set bootpart in $hdr" >&2; exit 1; }

      echo "layout: $blkdevparts"
      echo "layout: env at $envOffset size $envSize, /boot is p$bootPart"
    '' + lib.optionalString debugMilestones milestonePostPatch
      + lib.optionalString dcacheOff dcacheOffPostPatch;

    makeFlags = [
      "ARCH=arm"
      "CROSS_COMPILE=${crossPrefix}"
      "HOSTCC=cc"
      "KBUILD_BUILD_TIMESTAMP=@0"
      "KBUILD_BUILD_USER=nix"
      "KBUILD_BUILD_HOST=nix"
    ];

    configurePhase = ''
      runHook preConfigure
      make $makeFlags ${defconfig}
      runHook postConfigure
    '';

    installPhase = ''
      runHook preInstall

      mkdir -p "$out/images" "$out/src" "$out/config"
      cp u-boot.bin "$out/images/u-boot.bin"
      cp u-boot.dtb "$out/images/u-boot.dtb"
      cp u-boot     "$out/images/u-boot.elf"
      cp .config    "$out/config/config"
      cp configs/${defconfig} "$out/config/${defconfig}"

      # The driver the host-side parser test compiles. Copied rather than
      # re-stated so the test can never test a stale copy.
      cp disk/part_cmdline.c "$out/src/part_cmdline.c"

      # The link address is a contract with the first-stage loader, so read it
      # back out of the ELF rather than trusting the defconfig.
      entry=$(${crossPrefix}readelf -h u-boot | ${pkgs.gawk}/bin/awk '/Entry point/ { print $NF }')
      echo "entry point: $entry"
      if [ "$entry" != "${textBase}" ] && [ "$entry" != "${lib.toLower textBase}" ]; then
        echo "ERROR: entry point $entry != ${textBase}; the SPL jumps to a fixed address" >&2
        exit 1
      fi

      ls -l "$out/images"
      runHook postInstall
    '';

    dontStrip = true;
    dontPatchELF = true;

    meta = {
      description = "Mainline U-Boot ${version} with an AX630C / NanoKVM-Pro board port (#89)";
      # The signed variant runs the prebuilt x86-64 ax_gzip; keep the whole
      # package on one platform so the two halves cannot diverge.
      platforms = [ "x86_64-linux" ];
      license = lib.licenses.gpl2Plus;
    };
  };

  signed = axSign.signImage {
    pname = "nanokvm-pro-uboot-mainline-signed" + variant;
    name = "u-boot_mainline_signed.bin";
    payload = "${raw}/images/u-boot.bin";
    maxSize = ubootPart.size;
  };
in

pkgs.runCommand "nanokvm-pro-uboot-mainline${variant}-${version}"
  {
    inherit version;
    passthru = {
      inherit raw signed layout;
      textBase = textBase;
      ubootPartSize = ubootPart.size;
      patchList = map baseNameOf patches;
    };
    meta = raw.meta;
  }
  ''
    mkdir -p "$out"
    cp -r ${raw}/images ${raw}/src ${raw}/config "$out/"
    chmod -R u+w "$out"
    cp ${signed}/u-boot_mainline_signed.bin "$out/images/"
    ls -l "$out/images"
  ''
