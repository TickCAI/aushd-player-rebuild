#ifndef RUNNER_WINDOW_METRICS_H_
#define RUNNER_WINDOW_METRICS_H_

#include <atomic>

// Counters for the window layer, read back through the read-only "diag" method
// on zerk/window. They exist so a cloud soak can assert *rates* (one resize per
// toggle, not four) instead of only the end state, and so a support log can say
// which path churned without a debugger.
namespace window_metrics {

// Every WM_SIZE the top-level window received.
inline std::atomic<int> wm_size_count{0};

// WM_SIZE rounds that asked for a zero-width or zero-height client area.
inline std::atomic<int> minimized_resize_count{0};

// Times the video host actually moved a window (it coalesces the rest).
inline std::atomic<int> move_window_count{0};

// Resize requests folded into a single coalesced resize.
inline std::atomic<int> coalesced_resize_count{0};

// Fullscreen enters where the resulting window rect did not cover the monitor.
inline std::atomic<int> fullscreen_rect_mismatch{0};

// SetWindowPos failures during a fullscreen transition.
inline std::atomic<int> set_window_pos_failure_count{0};

}  // namespace window_metrics

#endif  // RUNNER_WINDOW_METRICS_H_
