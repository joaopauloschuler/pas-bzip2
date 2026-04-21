/*
 * pasbzip2generatemtf.s — x86-64 assembly implementation of generateMTFValues
 *
 * Phase 11.7: replaces the Pascal generateMTFValues with a hand-written
 * assembly version that keeps all hot pointer variables in callee-saved
 * registers throughout the hot loop.
 *
 * FPC's register allocator assigns ptr/block/mtfv/unseqToSeq all to rax
 * and spills them to the stack, causing 4+ extra memory loads per iteration.
 * This assembly version eliminates those spills.
 *
 * The non-match branch (zPend flush + MTF rotation + emit) is inlined here
 * to avoid calling a Pascal helper with local (non-exported) visibility.
 *
 * Register assignment in hot loop:
 *   rbp = s  (EState*): gives unseqToSeq at 384(%rbp), mtfFreq at 672(%rbp)
 *   rbx = block   (= s->block)
 *   r12 = ptrCur  (walks from s->ptr to ptrEnd, step +4)
 *   r13 = ptrEnd  (= s->ptr + nblock*4, constant loop bound)
 *   r14 = mtfv    (= s->mtfv)
 *   r15b= yy0     (= yy[0] cached; updated after each non-match)
 *
 * Stack frame (rsp after 6 pushes + sub 272):
 *   [rsp+0   .. rsp+255] : yy[256]
 *   [rsp+256]            : wr    (Int32)
 *   [rsp+260]            : zPend (Int32)
 *   [rsp+264]            : EOB   (Int32)
 *
 * EState field offsets (verified):
 *   +56:  ptr,  +64: block,  +72: mtfv,  +108: nblock
 *   +124: nInUse,  +128: inUse[256],  +384: unseqToSeq[256]
 *   +668: nMTF,    +672: mtfFreq[BZ_MAX_ALPHA_SIZE]
 *
 * BZ_RUNA=0 → mtfFreq[0] at rbp+672
 * BZ_RUNB=1 → mtfFreq[1] at rbp+676
 */

	.section .text.n_pasbzip2compress_$$_generatemtfvalues$pestate
	.balign 16,0x90
	.type	PASBZIP2COMPRESS_$$_GENERATEMTFVALUES$PESTATE,@function
	.global	PASBZIP2COMPRESS_$$_GENERATEMTFVALUES$PESTATE
PASBZIP2COMPRESS_$$_GENERATEMTFVALUES$PESTATE:

	/* ---- Prologue: save callee-saved registers, allocate frame ---- */
	pushq	%rbp
	pushq	%rbx
	pushq	%r12
	pushq	%r13
	pushq	%r14
	pushq	%r15
	subq	$272, %rsp

	movq	%rdi, %rbp          /* rbp = s */

	/* ---- Zero yy[256] using 16-byte unaligned stores ---- */
	pxor	%xmm0, %xmm0
	movdqu	%xmm0,   0(%rsp)
	movdqu	%xmm0,  16(%rsp)
	movdqu	%xmm0,  32(%rsp)
	movdqu	%xmm0,  48(%rsp)
	movdqu	%xmm0,  64(%rsp)
	movdqu	%xmm0,  80(%rsp)
	movdqu	%xmm0,  96(%rsp)
	movdqu	%xmm0, 112(%rsp)
	movdqu	%xmm0, 128(%rsp)
	movdqu	%xmm0, 144(%rsp)
	movdqu	%xmm0, 160(%rsp)
	movdqu	%xmm0, 176(%rsp)
	movdqu	%xmm0, 192(%rsp)
	movdqu	%xmm0, 208(%rsp)
	movdqu	%xmm0, 224(%rsp)
	movdqu	%xmm0, 240(%rsp)

	/* ---- makeMaps_e(s) inlined ---- */
	movl	$0, 124(%rbp)       /* s->nInUse = 0 */
	xorl	%eax, %eax          /* i = 0 */
.Lmaps_loop:
	cmpb	$0, 128(%rbp,%rax,1)
	je	.Lmaps_skip
	movb	124(%rbp), %cl
	movb	%cl, 384(%rbp,%rax,1)   /* unseqToSeq[i] = nInUse */
	addl	$1, 124(%rbp)
.Lmaps_skip:
	addl	$1, %eax
	cmpl	$256, %eax
	jl	.Lmaps_loop

	/* ---- EOB = nInUse + 1 ---- */
	movl	124(%rbp), %eax
	addl	$1, %eax
	movl	%eax, 264(%rsp)         /* save EOB */

	/* ---- Zero mtfFreq[0..EOB] using rep stosl ---- */
	movl	264(%rsp), %ecx
	addl	$1, %ecx                /* count = EOB + 1 words */
	leaq	672(%rbp), %rdi
	xorl	%eax, %eax
	cld
	rep stosl

	/* ---- Initialize wr=0, zPend=0 ---- */
	movl	$0, 256(%rsp)
	movl	$0, 260(%rsp)

	/* ---- Initialize yy[0..nInUse-1] = 0, 1, ..., nInUse-1 ---- */
	movl	124(%rbp), %ecx
	testl	%ecx, %ecx
	jle	.Linit_yy_done
	xorl	%eax, %eax
.Linit_yy_loop:
	movb	%al, (%rsp,%rax,1)
	addl	$1, %eax
	subl	$1, %ecx
	jnz	.Linit_yy_loop
.Linit_yy_done:

	/* ---- Set up callee-saved hot-loop registers ---- */
	movq	64(%rbp), %rbx          /* rbx = block */
	movq	56(%rbp), %r12          /* r12 = ptrCur */
	movq	72(%rbp), %r14          /* r14 = mtfv */
	movl	108(%rbp), %eax         /* nblock */
	leaq	(%r12,%rax,4), %r13     /* r13 = ptrEnd = ptr + nblock*4 */
	movb	(%rsp), %r15b           /* r15b = yy[0] cache */

	/* ---- Empty block check ---- */
	cmpq	%r13, %r12
	jae	.Lmain_loop_done

	/* ================================================================
	 * Main hot loop
	 * ================================================================ */
	.balign 16, 0x90
.Lmain_loop:
	/* j = (Int32)(*ptrCur) - 1 */
	movl	(%r12), %eax
	subl	$1, %eax
	jns	.Lno_wrap
	addl	108(%rbp), %eax         /* j += nblock */
.Lno_wrap:
	/* ll_i = unseqToSeq[block[j]] */
	movslq	%eax, %rax
	movzbl	(%rbx,%rax,1), %edx     /* block[j] */
	movzbl	384(%rbp,%rdx,1), %edx  /* ll_i */

	/* if ll_i == yy[0]: zPend++ and continue */
	cmpb	%r15b, %dl
	jne	.Lnon_match

	addl	$1, 260(%rsp)           /* zPend++ */
	addq	$4, %r12
	cmpq	%r13, %r12
	jb	.Lmain_loop
	jmp	.Lmain_loop_done

	/* ---- Non-match: flush zPend, rotate, emit ---- */
.Lnon_match:
	/* ll_i is in dl; save it in r10b while we handle zPend */
	movb	%dl, %r10b

	/* --- Flush zPend (emit RUNA/RUNB run-length codes) --- */
	cmpl	$0, 260(%rsp)
	jle	.Lno_zpend

	subl	$1, 260(%rsp)           /* zPend-- */
.Lzpend_inner:
	movl	260(%rsp), %eax
	andl	$1, %eax
	je	.Lzpend_runa

	/* RUNB: mtfv[wr]=1, wr++, mtfFreq[1]++ */
	movslq	256(%rsp), %rax
	movw	$1, (%r14,%rax,2)
	addl	$1, 256(%rsp)
	addl	$1, 676(%rbp)
	jmp	.Lzpend_cnt

.Lzpend_runa:
	/* RUNA: mtfv[wr]=0, wr++, mtfFreq[0]++ */
	movslq	256(%rsp), %rax
	movw	$0, (%r14,%rax,2)
	addl	$1, 256(%rsp)
	addl	$1, 672(%rbp)

.Lzpend_cnt:
	cmpl	$2, 260(%rsp)
	jl	.Lzpend_zero
	movslq	260(%rsp), %rax
	subq	$2, %rax
	movq	%rax, %rcx
	shrq	$63, %rcx
	addq	%rcx, %rax
	sarq	$1, %rax
	movl	%eax, 260(%rsp)
	jmp	.Lzpend_inner

.Lzpend_zero:
	movl	$0, 260(%rsp)

.Lno_zpend:
	/* --- MTF rotation: bubble ll_i (r10b) to yy[0] --- */
	movb	1(%rsp), %cl            /* rtmp = yy[1] */
	movb	(%rsp), %al
	movb	%al, 1(%rsp)            /* yy[1] = yy[0] */
	leaq	1(%rsp), %rax           /* ryy_j = &yy[1] */
	cmpb	%r10b, %cl              /* already found at position 1? */
	je	.Lrotate_done

	.balign 8, 0x90
.Lrotate_loop:
	incq	%rax                    /* ryy_j++ */
	movb	%cl, %r11b              /* rtmp2 = rtmp */
	movb	(%rax), %cl             /* rtmp = *ryy_j */
	movb	%r11b, (%rax)           /* *ryy_j = rtmp2 (shift previous into current slot) */
	cmpb	%r10b, %cl
	jne	.Lrotate_loop

.Lrotate_done:
	movb	%cl, (%rsp)             /* yy[0] = rtmp (= ll_i) */
	movb	%cl, %r15b              /* update yy[0] cache */

	/* j = ryy_j - &yy[0]; emit mtfv[wr] = j+1, mtfFreq[j+1]++ */
	subq	%rsp, %rax              /* j = rax - rsp (byte offset in yy) */
	movslq	256(%rsp), %rcx        /* wr */
	leal	1(%eax), %esi           /* j+1 (fits in 16 bits: 1..256) */
	movw	%si, (%r14,%rcx,2)      /* mtfv[wr] = j+1 */
	addl	$1, 256(%rsp)           /* wr++ */
	/* mtfFreq[j+1]++ : base 672, index (j+1), stride 4
	   = 672 + (j+1)*4 = 676 + j*4 = 676(%rbp,%rax,4) */
	addl	$1, 676(%rbp,%rax,4)

	addq	$4, %r12                /* ptrCur += 4 */
	cmpq	%r13, %r12
	jb	.Lmain_loop

.Lmain_loop_done:

	/* ---- Flush remaining zPend ---- */
	cmpl	$0, 260(%rsp)
	jle	.Lzfinal_done
	subl	$1, 260(%rsp)

.Lzfinal_loop:
	movl	260(%rsp), %eax
	andl	$1, %eax
	je	.Lzfinal_runa

	movslq	256(%rsp), %rax
	movw	$1, (%r14,%rax,2)
	addl	$1, 256(%rsp)
	addl	$1, 676(%rbp)
	jmp	.Lzfinal_cnt

.Lzfinal_runa:
	movslq	256(%rsp), %rax
	movw	$0, (%r14,%rax,2)
	addl	$1, 256(%rsp)
	addl	$1, 672(%rbp)

.Lzfinal_cnt:
	cmpl	$2, 260(%rsp)
	jl	.Lzfinal_done
	movslq	260(%rsp), %rax
	subq	$2, %rax
	movq	%rax, %rcx
	shrq	$63, %rcx
	addq	%rcx, %rax
	sarq	$1, %rax
	movl	%eax, 260(%rsp)
	jmp	.Lzfinal_loop

.Lzfinal_done:

	/* ---- Emit EOB ---- */
	movl	264(%rsp), %eax         /* EOB */
	movslq	256(%rsp), %rcx        /* wr */
	movw	%ax, (%r14,%rcx,2)      /* mtfv[wr] = EOB */
	addl	$1, 256(%rsp)           /* wr++ */
	movslq	264(%rsp), %rcx        /* EOB as index */
	addl	$1, 672(%rbp,%rcx,4)    /* mtfFreq[EOB]++ */

	/* ---- s->nMTF = wr ---- */
	movl	256(%rsp), %eax
	movl	%eax, 668(%rbp)

	/* ---- Epilogue ---- */
	addq	$272, %rsp
	popq	%r15
	popq	%r14
	popq	%r13
	popq	%r12
	popq	%rbx
	popq	%rbp
	ret

	.size	PASBZIP2COMPRESS_$$_GENERATEMTFVALUES$PESTATE, . - PASBZIP2COMPRESS_$$_GENERATEMTFVALUES$PESTATE

/* Mark stack as non-executable */
	.section .note.GNU-stack,"",@progbits
