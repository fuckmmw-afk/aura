// A crash leaves its trace in Aura's own log (Documents/Aura/aura.log, shared from Diagnostics): the signal or the
// exception and the stack, with Aura's frames named (the dylib keeps its symbols). The app's own crash reporters
// still get it afterwards.
#import "AUCore.h"
#import <execinfo.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>

static char sPath[1024];
static struct sigaction sPrevious[32];
static NSUncaughtExceptionHandler *sPreviousException;

static void writeText(int fd, const char *text) {
    write(fd, text, strlen(text));
}

static void onSignal(int signal, siginfo_t *info, void *context) {
    int fd = open(sPath, O_WRONLY | O_APPEND | O_CREAT, 0644);
    if (fd >= 0) {
        char line[160];
        snprintf(line, sizeof(line), "\n*** crash: signal %d at %p (Aura %s)\n", signal, info ? info->si_addr : NULL, AURA_VERSION);
        writeText(fd, line);
        void *frames[64];
        int count = backtrace(frames, 64);
        backtrace_symbols_fd(frames, count, fd);
        close(fd);
    }
    // The previous handler (the app's reporter), else the default: the crash goes on as it would have.
    struct sigaction previous = sPrevious[signal];
    sigaction(signal, &previous, NULL);
    if ((previous.sa_flags & SA_SIGINFO) && previous.sa_sigaction) {
        previous.sa_sigaction(signal, info, context);
    } else if (previous.sa_handler && previous.sa_handler != SIG_DFL && previous.sa_handler != SIG_IGN) {
        previous.sa_handler(signal);
    }
    raise(signal);
}

static void onException(NSException *exception) {
    AULog(@"*** crash: %@: %@\n%@", exception.name, exception.reason, [exception.callStackSymbols componentsJoinedByString:@"\n"]);
    if (sPreviousException) sPreviousException(exception);
}

void AUCrashLogInstall(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        strlcpy(sPath, AULogURL().fileSystemRepresentation, sizeof(sPath));
        sPreviousException = NSGetUncaughtExceptionHandler();
        NSSetUncaughtExceptionHandler(onException);
        int signals[] = {SIGSEGV, SIGBUS, SIGABRT, SIGILL, SIGTRAP, SIGFPE};
        for (size_t i = 0; i < sizeof(signals) / sizeof(*signals); i++) {
            struct sigaction action = {0};
            action.sa_sigaction = onSignal;
            action.sa_flags = SA_SIGINFO;
            sigemptyset(&action.sa_mask);
            sigaction(signals[i], &action, &sPrevious[signals[i]]);
        }
    });
}
