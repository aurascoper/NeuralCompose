//
// BCIBridge.h — C-ABI shim for the BrainFlow C++ library.
//
// We expose only the surface Swift actually needs:
//   • create / destroy a session
//   • start / stop the stream
//   • drain newly-acquired EEG samples into a Swift-allocated buffer
//
// Two compile-time modes, controlled by SwiftPM cxxSettings:
//
//   BCI_BRIDGE_STUB             (default) — every entry point returns a clean
//                                "not available" status; no BrainFlow link.
//
//   BCI_BRAINFLOW_AVAILABLE     real BrainFlow headers + link, Swift gets
//                                actual EEG samples.
//
// The Swift side (BrainFlowService) checks `bci_bridge_is_available()` once
// at startup and falls back to SyntheticEEGStream if the bridge is stubbed.
//
// Important: this header is C-only (extern "C" wraps the .mm side). Do not
// reference any C++ types from here, or Swift's auto-generated module map
// will fail.
//

#ifndef BCIBRIDGE_H
#define BCIBRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Opaque handle to a single BrainFlow session.
typedef struct bci_session_t* bci_session_handle_t;

typedef enum bci_status_e {
    BCI_OK                       = 0,
    BCI_ERR_NOT_AVAILABLE        = -1,  ///< Bridge compiled in stub mode.
    BCI_ERR_INVALID_HANDLE       = -2,
    BCI_ERR_INVALID_ARGS         = -3,
    BCI_ERR_PREPARE_FAILED       = -4,  ///< prepare_session() failed.
    BCI_ERR_START_FAILED         = -5,
    BCI_ERR_STOP_FAILED          = -6,
    BCI_ERR_READ_FAILED          = -7,
    BCI_ERR_BUFFER_TOO_SMALL     = -8,
    BCI_ERR_UNKNOWN              = -99,
} bci_status_t;

/// Returns the BrainFlow C++ runtime version, or NULL when stubbed.
/// Lifetime: process-static; do not free.
const char* bci_bridge_runtime_version(void);

/// Returns true iff this build was compiled against BrainFlow headers
/// AND the runtime can be loaded.
bool bci_bridge_is_available(void);

/// Compiled `BoardIds` enum getters. These return the integer values from
/// the *installed* BrainFlow headers without opening any hardware session,
/// so they're safe to call when no Muse is connected and Bluetooth is off.
/// When the bridge is built in stub mode (no BrainFlow), they all return
/// `BCI_BRIDGE_BOARD_ID_UNAVAILABLE`.
///
/// Used by `BrainFlowService.verifyBoardIDsAgainstBridge()` to detect drift
/// between `MuseBoardProfile.brainFlowBoardID` and the BrainFlow C++ enum
/// after upgrades — much more reliable than the "try to prepare_session()"
/// strategy, which can fail for unrelated reasons.
#define BCI_BRIDGE_BOARD_ID_UNAVAILABLE  ((int32_t)0x7FFFFFFF)

int32_t bci_bridge_board_id_synthetic(void);
int32_t bci_bridge_board_id_muse_2(void);
int32_t bci_bridge_board_id_muse_2_bled(void);
int32_t bci_bridge_board_id_muse_s(void);
int32_t bci_bridge_board_id_muse_s_bled(void);
int32_t bci_bridge_board_id_muse_s_athena(void);

/// Allocate and prepare a session. `board_id` matches BrainFlow's enum.
/// `params_json` is a UTF-8 JSON blob mapping to BrainFlowInputParams
/// (serial_port, mac_address, etc.). May be NULL for defaults.
///
/// On success returns BCI_OK and writes a non-null handle to `*out_handle`.
bci_status_t bci_bridge_create_session(
    int32_t board_id,
    const char* params_json,
    bci_session_handle_t* out_handle
);

/// Returns the EEG channel count for this session, or -1 on error.
int32_t bci_bridge_eeg_channel_count(bci_session_handle_t handle);

/// Returns the BrainFlow-reported sample rate (Hz), or -1 on error.
double bci_bridge_sample_rate(bci_session_handle_t handle);

/// Begin streaming. `buffer_size_seconds` is the BrainFlow internal ring
/// length in seconds; recommend 30.
bci_status_t bci_bridge_start_stream(
    bci_session_handle_t handle,
    int32_t buffer_size_seconds
);

/// Pull all currently-available samples and write them into the Swift-side
/// row-major float32 buffer `out_samples`. Shape: [available_samples, channels].
///
/// `max_samples` is the maximum number of *samples* (not floats) the buffer
/// can hold; on entry it must equal `(buffer_capacity_floats / channels)`.
/// On success, `*out_count` is set to the actual sample count written, and
/// the function returns BCI_OK. If 0 samples are available, returns BCI_OK
/// with *out_count == 0.
///
/// `timestamps` may be NULL; if non-NULL, must point to at least
/// `max_samples` doubles and receives one wall-clock timestamp per sample.
bci_status_t bci_bridge_drain_samples(
    bci_session_handle_t handle,
    float* out_samples,
    double* timestamps,
    int32_t max_samples,
    int32_t* out_count
);

/// Stop streaming, but keep the session prepared for re-start.
bci_status_t bci_bridge_stop_stream(bci_session_handle_t handle);

/// Tear down the session and free the handle. After this call the handle
/// must not be used. Safe to call with a null handle.
void bci_bridge_destroy_session(bci_session_handle_t handle);

#if defined(__cplusplus)
} // extern "C"
#endif

#endif // BCIBRIDGE_H
