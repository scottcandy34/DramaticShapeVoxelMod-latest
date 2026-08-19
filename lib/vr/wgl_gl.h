typedef void (__stdcall *PROC)();

void* wglGetCurrentDC(void);
void* wglGetCurrentContext(void);
PROC wglGetProcAddress(const char*);

unsigned int glGetError(void);
void glGetIntegerv(unsigned int pname, int* params);
void glReadBuffer(unsigned int mode);
void glFlush(void);

void glCopyTexSubImage2D(unsigned int target, int level, int xoffset,
                         int yoffset, int x, int y, int width, int height);
void glBindTexture(unsigned int target, unsigned int texture);

typedef void (__stdcall *pfn_glBindFramebuffer)(unsigned int, unsigned int);
typedef void (__stdcall *pfn_glGenFramebuffers)(int, unsigned int*);
typedef void (__stdcall *pfn_glDeleteFramebuffers)(int, const unsigned int*);
typedef void (__stdcall *pfn_glFramebufferTexture2D)(unsigned int,
                                                     unsigned int,
                                                     unsigned int,
                                                     unsigned int,
                                                     int);
typedef void (__stdcall *pfn_glBlitFramebuffer)(int, int, int, int,
                                                int, int, int, int,
                                                unsigned int, unsigned int);