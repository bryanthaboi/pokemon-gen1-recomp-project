#ifndef FPU_CTRL_H
#define FPU_CTRL_H

class FPUCtl {
#if defined(HAVE_SSE_INTRINSICS) || (defined(__GNUC__) && defined(HAVE_SSE))
    unsigned int sse_state{};
#endif
    bool in_mode{};

public:
    FPUCtl();
    /* HACK: 32-bit targets for GCC seem to have a problem here with certain
     * noexcept methods (which destructors are) causing an internal compiler
     * error. No idea why it's these methods specifically, but this is needed
     * to get it to compile.
     */
    ~FPUCtl() noexcept(false) { leave(); }

    FPUCtl(const FPUCtl&) = delete;
    FPUCtl& operator=(const FPUCtl&) = delete;

    void leave();
};

#endif /* FPU_CTRL_H */
