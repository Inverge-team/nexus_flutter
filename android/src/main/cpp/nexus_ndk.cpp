// Native (NDK) crash capture for Android. Installs signal handlers on an
// alternate stack, unwinds the crashing thread, and writes the backtrace to a
// file using only async-signal-safe calls. The Java layer reads it on the next
// launch; the backend symbolicates the addresses with the .so's build-id
// (ndk-stack / addr2line).

#include <jni.h>
#include <signal.h>
#include <unwind.h>
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <stdint.h>

#define MAX_FRAMES 64
#define NEXUS_NSIG 32

static char g_crash_path[1024] = {0};
static char g_alt_stack[64 * 1024];
static struct sigaction g_old[NEXUS_NSIG];
static const int g_signals[] = {SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP};

struct BacktraceState {
  void** current;
  void** end;
};

static _Unwind_Reason_Code unwind_cb(struct _Unwind_Context* ctx, void* arg) {
  BacktraceState* state = static_cast<BacktraceState*>(arg);
  uintptr_t pc = _Unwind_GetIP(ctx);
  if (pc) {
    if (state->current == state->end) return _URC_END_OF_STACK;
    *state->current++ = reinterpret_cast<void*>(pc);
  }
  return _URC_NO_REASON;
}

static size_t capture_backtrace(void** buffer, size_t max) {
  BacktraceState state = {buffer, buffer + max};
  _Unwind_Backtrace(unwind_cb, &state);
  return static_cast<size_t>(state.current - buffer);
}

// --- async-signal-safe write helpers (no malloc / stdio) ---

static void write_str(int fd, const char* s) { write(fd, s, strlen(s)); }

static void write_int(int fd, long v) {
  char buf[24];
  int i = sizeof(buf);
  if (v == 0) { char z = '0'; write(fd, &z, 1); return; }
  bool neg = v < 0;
  unsigned long u = neg ? (unsigned long)(-v) : (unsigned long)v;
  while (u) { buf[--i] = static_cast<char>('0' + (u % 10)); u /= 10; }
  if (neg) buf[--i] = '-';
  write(fd, buf + i, sizeof(buf) - i);
}

static void write_hex(int fd, uintptr_t v) {
  static const char* hex = "0123456789abcdef";
  char buf[2 + sizeof(uintptr_t) * 2];
  int i = sizeof(buf);
  do { buf[--i] = hex[v & 0xf]; v >>= 4; } while (v);
  buf[--i] = 'x';
  buf[--i] = '0';
  write(fd, buf + i, sizeof(buf) - i);
}

static void handler(int sig, siginfo_t* info, void* ucontext) {
  int fd = open(g_crash_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (fd >= 0) {
    write_str(fd, "signal=");
    write_int(fd, sig);
    write_str(fd, "\n");
    if (info) {
      write_str(fd, "fault=");
      write_hex(fd, reinterpret_cast<uintptr_t>(info->si_addr));
      write_str(fd, "\n");
    }
    void* frames[MAX_FRAMES];
    size_t count = capture_backtrace(frames, MAX_FRAMES);
    for (size_t i = 0; i < count; i++) {
      write_str(fd, "frame=");
      write_hex(fd, reinterpret_cast<uintptr_t>(frames[i]));
      write_str(fd, "\n");
    }
    close(fd);
  }
  // Restore the previous handler and re-raise so the OS records the crash too.
  if (sig < NEXUS_NSIG) sigaction(sig, &g_old[sig], nullptr);
  raise(sig);
}

extern "C" JNIEXPORT void JNICALL
Java_net_inverge_nexus_core_NexusNdk_nativeInstall(JNIEnv* env, jclass, jstring path) {
  const char* p = env->GetStringUTFChars(path, nullptr);
  strncpy(g_crash_path, p, sizeof(g_crash_path) - 1);
  env->ReleaseStringUTFChars(path, p);

  stack_t ss;
  ss.ss_sp = g_alt_stack;
  ss.ss_size = sizeof(g_alt_stack);
  ss.ss_flags = 0;
  sigaltstack(&ss, nullptr);

  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = handler;
  sa.sa_flags = SA_ONSTACK | SA_SIGINFO;
  sigemptyset(&sa.sa_mask);
  for (int s : g_signals) sigaction(s, &sa, &g_old[s]);
}

// Copy /proc/self/maps → destination (loaded libs + base addresses + build-ids)
// for offline symbolication. Called at install time (safe — not in a handler).
extern "C" JNIEXPORT void JNICALL
Java_net_inverge_nexus_core_NexusNdk_nativeDumpMaps(JNIEnv* env, jclass, jstring dest) {
  const char* d = env->GetStringUTFChars(dest, nullptr);
  int in = open("/proc/self/maps", O_RDONLY);
  int out = open(d, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (in >= 0 && out >= 0) {
    char buf[4096];
    ssize_t n;
    while ((n = read(in, buf, sizeof(buf))) > 0) write(out, buf, n);
  }
  if (in >= 0) close(in);
  if (out >= 0) close(out);
  env->ReleaseStringUTFChars(dest, d);
}
