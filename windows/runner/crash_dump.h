#ifndef AUSHD_CRASH_DUMP_H_
#define AUSHD_CRASH_DUMP_H_

namespace aushd {

// Installs a process-wide unhandled exception filter. On a native crash it
// writes a minidump plus a short text summary into the app log directory,
// then delegates to the previous filter (Flutter/Chrome crashpad) so normal
// crash reporting still works. Call once at startup, before any window.
void InstallCrashDumpHandler();

// Writes a one-shot snapshot of GPUs, monitors, DPI, Vulkan layers and the
// AUSHD_* diagnostic switches into the app log directory. This is the
// evidence base for the "clean environment vs crash" comparison.
void WriteEnvironmentSnapshot();

}  // namespace aushd

#endif  // AUSHD_CRASH_DUMP_H_
