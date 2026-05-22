//
// BCIBridge.mm — implementation of the C ABI declared in BCIBridge.h.
//
// Compile-time gating:
//   - default build: BCI_BRIDGE_STUB defined → every entry point returns
//     BCI_ERR_NOT_AVAILABLE. The package builds and the Swift side
//     transparently falls back to SyntheticEEGStream.
//
//   - real build:    BCI_BRAINFLOW_AVAILABLE defined → wraps BrainFlow's
//     C board-controller API. You must also pass -lBoardController at link time
//     and `-I` BrainFlow's headers at compile time (see Scripts/build.sh).
//
// The two modes share *no* runtime state; if both flags are set at once,
// BCI_BRAINFLOW_AVAILABLE wins.
//

#import "BCIBridge.h"

#include <cstdlib>
#include <cstring>
#include <new>
#include <vector>

#if defined(BCI_BRAINFLOW_AVAILABLE)
  // BrainFlow C API headers. Make sure -I<brainflow-include> is on the path.
  #include "board_controller.h"
  #include "board_info_getter.h"
  #include "brainflow_constants.h"
#endif

struct bci_session_t {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    int32_t boardId{-1};
    int32_t channelCount{0};
    double sampleRate{0.0};
    std::vector<int32_t> eegChannels;
    bool streaming{false};
#else
    int dummy{0};
#endif
};

extern "C" {

const char* bci_bridge_runtime_version(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    // BrainFlow doesn't have a single version C-API; report something stable.
    return "brainflow-linked";
#else
    return NULL;
#endif
}

bool bci_bridge_is_available(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return true;
#else
    return false;
#endif
}

// ── Compiled BoardIds enum getters (no hardware session needed) ──────────

int32_t bci_bridge_board_id_synthetic(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return static_cast<int32_t>(BoardIds::SYNTHETIC_BOARD);
#else
    return BCI_BRIDGE_BOARD_ID_UNAVAILABLE;
#endif
}
int32_t bci_bridge_board_id_muse_2(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return static_cast<int32_t>(BoardIds::MUSE_2_BOARD);
#else
    return BCI_BRIDGE_BOARD_ID_UNAVAILABLE;
#endif
}
int32_t bci_bridge_board_id_muse_2_bled(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return static_cast<int32_t>(BoardIds::MUSE_2_BLED_BOARD);
#else
    return BCI_BRIDGE_BOARD_ID_UNAVAILABLE;
#endif
}
int32_t bci_bridge_board_id_muse_s(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return static_cast<int32_t>(BoardIds::MUSE_S_BOARD);
#else
    return BCI_BRIDGE_BOARD_ID_UNAVAILABLE;
#endif
}
int32_t bci_bridge_board_id_muse_s_bled(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return static_cast<int32_t>(BoardIds::MUSE_S_BLED_BOARD);
#else
    return BCI_BRIDGE_BOARD_ID_UNAVAILABLE;
#endif
}
int32_t bci_bridge_board_id_muse_s_athena(void) {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return static_cast<int32_t>(BoardIds::MUSE_S_ATHENA_BOARD);
#else
    return BCI_BRIDGE_BOARD_ID_UNAVAILABLE;
#endif
}

bci_status_t bci_bridge_create_session(
    int32_t board_id,
    const char* params_json,
    bci_session_handle_t* out_handle
) {
    if (out_handle == NULL) return BCI_ERR_INVALID_ARGS;
    *out_handle = NULL;

#if defined(BCI_BRAINFLOW_AVAILABLE)
    auto* session = new bci_session_t();
    session->boardId = board_id;

    // Call prepare_session with the C API.
    int status = prepare_session(board_id, params_json != NULL ? params_json : "{}");
    if (status != 0) {
        delete session;
        return BCI_ERR_PREPARE_FAILED;
    }

    // Get sampling rate using C API (preset = 0 for default).
    int sampling_rate = 0;
    status = get_sampling_rate(board_id, 0, &sampling_rate);
    if (status != 0) {
        release_session(board_id, params_json != NULL ? params_json : "{}");
        delete session;
        return BCI_ERR_PREPARE_FAILED;
    }
    session->sampleRate = static_cast<double>(sampling_rate);

    // Get EEG channels using C API.
    int max_channels = 256;
    int* channels_buf = static_cast<int*>(malloc(max_channels * sizeof(int)));
    int channels_len = 0;
    status = get_eeg_channels(board_id, 0, channels_buf, &channels_len);
    if (status != 0 || channels_len <= 0) {
        free(channels_buf);
        release_session(board_id, params_json != NULL ? params_json : "{}");
        delete session;
        return BCI_ERR_PREPARE_FAILED;
    }

    session->eegChannels.assign(channels_buf, channels_buf + channels_len);
    session->channelCount = static_cast<int32_t>(channels_len);
    free(channels_buf);

    *out_handle = session;
    return BCI_OK;
#else
    (void)board_id;
    (void)params_json;
    return BCI_ERR_NOT_AVAILABLE;
#endif
}

int32_t bci_bridge_eeg_channel_count(bci_session_handle_t handle) {
    if (handle == NULL) return -1;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return handle->channelCount;
#else
    return -1;
#endif
}

double bci_bridge_sample_rate(bci_session_handle_t handle) {
    if (handle == NULL) return -1;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    return handle->sampleRate;
#else
    return -1;
#endif
}

bci_status_t bci_bridge_start_stream(
    bci_session_handle_t handle,
    int32_t buffer_size_seconds
) {
    if (handle == NULL) return BCI_ERR_INVALID_HANDLE;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    // Convert seconds to samples.
    int32_t bufSamples = (buffer_size_seconds > 0)
        ? static_cast<int32_t>(buffer_size_seconds * (handle->sampleRate > 0 ? handle->sampleRate : 256))
        : 7680;
    // Call start_stream with the C API.
    int status = start_stream(bufSamples, "", handle->boardId, "{}");
    if (status != 0) {
        return BCI_ERR_START_FAILED;
    }
    handle->streaming = true;
    return BCI_OK;
#else
    (void)buffer_size_seconds;
    return BCI_ERR_NOT_AVAILABLE;
#endif
}

bci_status_t bci_bridge_drain_samples(
    bci_session_handle_t handle,
    float* out_samples,
    double* timestamps,
    int32_t max_samples,
    int32_t* out_count
) {
    if (handle == NULL) return BCI_ERR_INVALID_HANDLE;
    if (out_samples == NULL || out_count == NULL || max_samples <= 0)
        return BCI_ERR_INVALID_ARGS;
    *out_count = 0;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    // Allocate buffer for board data: [total_rows * max_samples]
    double* board_data = static_cast<double*>(malloc(256 * max_samples * sizeof(double)));
    if (board_data == NULL) return BCI_ERR_UNKNOWN;

    int returned_samples = 0;
    int status = get_current_board_data(max_samples, 0, board_data, &returned_samples,
                                        handle->boardId, "{}");
    if (status != 0) {
        free(board_data);
        return BCI_ERR_READ_FAILED;
    }

    if (returned_samples == 0) {
        free(board_data);
        return BCI_OK;
    }
    if (returned_samples > max_samples) {
        free(board_data);
        return BCI_ERR_BUFFER_TOO_SMALL;
    }

    // Get the number of total rows to interpret the flat buffer layout.
    int num_rows = 0;
    status = get_num_rows(handle->boardId, 0, &num_rows);
    if (status != 0) {
        free(board_data);
        return BCI_ERR_READ_FAILED;
    }

    // Get timestamp channel (optional).
    int ts_channel = -1;
    get_timestamp_channel(handle->boardId, 0, &ts_channel);

    const int nChan   = handle->channelCount;
    const int nPoints = returned_samples;

    // Extract EEG channels and pack as row-major [points, channels] float32 for Swift.
    // Buffer layout: board_data[row * nPoints + point]
    for (int p = 0; p < nPoints; ++p) {
        for (int c = 0; c < nChan; ++c) {
            int row = handle->eegChannels[static_cast<size_t>(c)];
            double v = board_data[row * nPoints + p];
            out_samples[p * nChan + c] = static_cast<float>(v);
        }
        if (timestamps != NULL) {
            if (ts_channel >= 0) {
                timestamps[p] = board_data[ts_channel * nPoints + p];
            } else {
                timestamps[p] = static_cast<double>(p) / handle->sampleRate;
            }
        }
    }
    *out_count = nPoints;
    free(board_data);
    return BCI_OK;
#else
    (void)out_samples; (void)timestamps; (void)max_samples;
    return BCI_ERR_NOT_AVAILABLE;
#endif
}

bci_status_t bci_bridge_stop_stream(bci_session_handle_t handle) {
    if (handle == NULL) return BCI_ERR_INVALID_HANDLE;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    if (handle->streaming) {
        int status = stop_stream(handle->boardId, "{}");
        if (status != 0) {
            return BCI_ERR_STOP_FAILED;
        }
        handle->streaming = false;
    }
    return BCI_OK;
#else
    return BCI_ERR_NOT_AVAILABLE;
#endif
}

void bci_bridge_destroy_session(bci_session_handle_t handle) {
    if (handle == NULL) return;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    if (handle->streaming) {
        stop_stream(handle->boardId, "{}");
        handle->streaming = false;
    }
    release_session(handle->boardId, "{}");
#endif
    delete handle;
}

} // extern "C"
