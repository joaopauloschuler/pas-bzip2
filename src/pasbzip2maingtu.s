/*
 * pasbzip2maingtu.s — x86-64 assembly implementation of mainGtU
 *
 * Phase 11.16: hand-written assembly for mainGtU to eliminate the double-compare
 * FPC code-generation bug.
 *
 * FPC generates this pattern for `if c1 <> c2 then begin result := c1 > c2; exit; end`:
 *   cmpb %r10b,%al    ; compare c1 vs c2 (sets flags)
 *   je   .equal
 *   cmpb %r10b,%al    ; REDUNDANT second compare (flags unchanged!)
 *   setbb %al         ; set result
 *   jmp  .exit
 * The second cmpb is wasted because flags are still set from the first cmpb.
 * With 12 unrolled comparisons + an 8-per-iteration loop, this bug fires many
 * times per mainGtU call (which itself is called millions of times per sort).
 *
 * This assembly version uses a single cmpb + jne + seta/setb per comparison:
 *   movzbl (%rdx,%rdi), %r10d  ; c1 = block[i1]
 *   movzbl (%rdx,%rsi), %eax   ; c2 = block[i2]
 *   cmpb   %r10b, %al           ; al - r10b → sets CF if al < r10b (c2 < c1)
 *   jne    .ret_char             ; if c1 != c2, go to result
 *   ...
 * .ret_char:
 *   seta   %al                   ; al = 1 if c1 > c2 (al > r10b, unsigned above)
 *   ret
 *
 * Register assignment:
 *   rdi = i1  (mutated during loop)
 *   rsi = i2  (mutated during loop)
 *   rdx = block (constant)
 *   rcx = quadrant (constant)
 *   r8d = nblock (constant)
 *   r9  = budget (pointer, decremented each repeat-loop iteration)
 *   r10 = scratch (c1/s1)
 *   r11 = k (repeat-loop counter)
 *   al  = return value (Bool)
 *
 * Callee-saved registers used: none (r10, r11 are volatile scratch)
 * So no push/pop needed — this is a leaf function with no calls.
 *
 * Pascal calling convention = SysV x86-64 ABI for non-variadic functions.
 * FPC-mangled name: PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE
 */

        .text
        .balign 16, 0x90
        .globl PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE
        .type  PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE, @function

PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE:
        /* AssertD(i1 != i2) is a no-op in release builds — skip it */

        /* --- 12 unrolled char-only comparisons --- */
        /* Each step: load c1=block[i1], c2=block[i2]; if c1!=c2 return c1>c2 */

        /* Step 1 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al          /* al - r10b; CF=1 if al < r10b */
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 2 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 3 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 4 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 5 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 6 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 7 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 8 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 9 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 10 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 11 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* Step 12 */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        incl    %edi
        incl    %esi

        /* --- repeat loop (k = nblock + 8; until k < 0) --- */
        /* k counts down by 8 each iteration; starts at nblock+8 */
        leal    8(%r8d), %r11d      /* k = nblock + 8 */

        .balign 16, 0x90
.Lloop:
        /* 8 unrolled (char + quadrant) comparisons */

        /* Step A: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step B: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step C: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step D: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step E: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step F: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step G: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* Step H: char */
        movzbl  (%rdx,%rdi), %r10d
        movzbl  (%rdx,%rsi), %eax
        cmpb    %r10b, %al
        jne     .Lret_char
        /* quadrant */
        movzwl  (%rcx,%rdi,2), %r10d
        movzwl  (%rcx,%rsi,2), %eax
        cmpw    %r10w, %ax
        jne     .Lret_quad
        incl    %edi
        incl    %esi

        /* wrap indices around nblock */
        cmpl    %r8d, %edi
        jb      .Lno_wrap_i1
        subl    %r8d, %edi
.Lno_wrap_i1:
        cmpl    %r8d, %esi
        jb      .Lno_wrap_i2
        subl    %r8d, %esi
.Lno_wrap_i2:

        /* Dec(budget^); Dec(k, 8); until k < 0 */
        subl    $1, (%r9)
        subl    $8, %r11d
        jns     .Lloop              /* loop while k >= 0 */

        /* fell through all comparisons → return false (0) */
        xorl    %eax, %eax
        ret

        /* --- return paths --- */
        .balign 8, 0x90
.Lret_char:
        /* flags set by cmpb %r10b,%al  (al - r10b) */
        /* return 1 if al > r10b (unsigned above, i.e. c2 > c1 → c1 < c2 → false)
           wait: we return Bool(c1 > c2), and c1=r10b, c2=al
           cmpb %r10b,%al computes al - r10b
           "above" (seta) means al > r10b (unsigned), i.e. c2 > c1 → return 0
           "below" (setb) means al < r10b (unsigned), i.e. c2 < c1 → return 1
           So we want: return c1 > c2 → c1 > c2 → r10b > al → al < r10b → setb */
        setb    %al
        ret

        .balign 8, 0x90
.Lret_quad:
        /* flags set by cmpw %r10w,%ax  (ax - r10w) */
        /* s1 = r10w (quadrant[i1]), s2 = ax (quadrant[i2])
           return s1 > s2 → r10w > ax → ax < r10w → setb */
        setb    %al
        ret

        .size PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE, . - PASBZIP2BLOCKSORT_$$_MAINGTU$LONGWORD$LONGWORD$PUCHAR$PWORD$LONGWORD$PLONGINT$$BYTE

/* Mark stack as non-executable (required by Linux security policy) */
        .section .note.GNU-stack,"",@progbits
