//
// BCIBridge.mm — implementation of the C ABI declared in BCIBridge.h.
//
// Compile-time gating:
//   - default build: BCI_BRIDGE_STUB defined → every entry point returns
//     BCI_ERR_NOT_AVAILABLE. The package builds and the Swift side
//     transparently falls back to SyntheticEEGStream.
//
//   - real build:    BCI_BRAINFLOW_AVAILABLE defined → wraps BrainFlow's
//     `BoardShim` C++ class. You must also pass -lBrainflow at link time
//     and `-I` BrainFlow's headers at compile time (see Scripts/build.sh).
//
// The two modes share *no* runtime state; if both flags are set at once,
// BCI_BRAINFLOW_AVAILABLE wins.
//

#import "BCIBridge.h"

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

#if defined(BCI_BRAINFLOW_AVAILABLE)
  // Real BrainFlow headers. Make sure -I<brainflow-include> is on the path.
  #include "board_shim.h"
  #include "data_filter.h"
  #include "brainflow_input_params.h"
  #include "brainflow_exception.h"
#endif

struct bci_session_t {
#if defined(BCI_BRAINFLOW_AVAILABLE)
    std::unique_ptr<BoardShim> shim;
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
    try {
        BrainFlowInputParams params;
        // params_json is parsed only minimally — BrainFlow doesn't expose a
        // JSON helper, so we accept a tiny subset relevant to Muse over BT.
        // For the full set, modify BrainFlowService.swift before calling here.
        if (params_json != NULL) {
            std::string s(params_json);
            auto extract = [&s](const char* key, std::string& out) {
                std::string needle = std::string("\"") + key + "\":\"";
                auto pos = s.find(needle);
                if (pos == std::string::npos) return false;
                pos += needle.size();
                auto end = s.find("\"", pos);
                if (end == std::string::npos) return false;
                out = s.substr(pos, end - pos);
                return true;
            };
            extract("serial_port",  params.serial_port);
            extract("mac_address",  params.mac_address);
            extract("ip_address",   params.ip_address);
            extract("other_info",   params.other_info);
        }
        auto* session = new bci_session_t();
        session->boardId = board_id;
        session->shim    = std::make_unique<BoardShim>(board_id, params);
        session->shim->prepare_session();

        session->eegChannels  = BoardShim::get_eeg_channels(board_id);
        session->channelCount = static_cast<int32_t>(session->eegChannels.size());
        session->sampleRate   = BoardShim::get_sampling_rate(board_id);
        *out_handle = session;
        return BCI_OK;
    } catch (const BrainFlowException& e) {
        return BCI_ERR_PREPARE_FAILED;
    } catch (const std::exception& e) {
        return BCI_ERR_UNKNOWN;
    } catch (...) {
        return BCI_ERR_UNKNOWN;
    }
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
    try {
        // BrainFlow's start_stream takes (buffer_size_samples, streamer_params).
        // Convert seconds to samples conservatively.
        int32_t bufSamples = (buffer_size_seconds > 0)
            ? static_cast<int32_t>(buffer_size_seconds * (handle->sampleRate > 0 ? handle->sampleRate : 256))
            : 7680;
        handle->shim->start_stream(bufSamples, "");
        handle->streaming = true;
        return BCI_OK;
    } catch (const BrainFlowException&) {
        return BCI_ERR_START_FAILED;
    } catch (...) {
        return BCI_ERR_UNKNOWN;
    }
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
    try {
        // get_current_board_data returns BrainFlowArray<double, 2>:
        // [n_channels_total, n_data_points]. We extract only EEG rows.
        auto board_data = handle->shim->get_current_board_data(max_samples);
        const int nChan   = handle->channelCount;
        const int nPoints = static_cast<int>(board_data.get_size(1));
        if (nPoints == 0) return BCI_OK;
        if (nPoints > max_samples) return BCI_ERR_BUFFER_TOO_SMALL;

        // Optional timestamps row.
        int tsRow = -1;
        try { tsRow = BoardShim::get_timestamp_channel(handle->boardId); } catch (...) {}

        // Pack row-major [points, channels] float32 for Swift.
        for (int p = 0; p < nPoints; ++p) {
            for (int c = 0; c < nChan; ++c) {
                int row = handle->eegChannels[static_cast<size_t>(c)];
                double v = board_data(row, p);
                out_samples[p * nChan + c] = static_cast<float>(v);
            }
            if (timestamps != NULL) {
                timestamps[p] = (tsRow >= 0) ? board_data(tsRow, p)
                                             : static_cast<double>(p) / handle->sampleRate;
            }
        }
        *out_count = nPoints;
        return BCI_OK;
    } catch (const BrainFlowException&) {
        return BCI_ERR_READ_FAILED;
    } catch (...) {
        return BCI_ERR_UNKNOWN;
    }
#else
    (void)out_samples; (void)timestamps; (void)max_samples;
    return BCI_ERR_NOT_AVAILABLE;
#endif
}

bci_status_t bci_bridge_stop_stream(bci_session_handle_t handle) {
    if (handle == NULL) return BCI_ERR_INVALID_HANDLE;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    try {
        if (handle->streaming) {
            handle->shim->stop_stream();
            handle->streaming = false;
        }
        return BCI_OK;
    } catch (const BrainFlowException&) {
        return BCI_ERR_STOP_FAILED;
    } catch (...) {
        return BCI_ERR_UNKNOWN;
    }
#else
    return BCI_ERR_NOT_AVAILABLE;
#endif
}

void bci_bridge_destroy_session(bci_session_handle_t handle) {
    if (handle == NULL) return;
#if defined(BCI_BRAINFLOW_AVAILABLE)
    try {
        if (handle->streaming) { handle->shim->stop_stream(); handle->streaming = false; }
        if (handle->shim) handle->shim->release_session();
    } catch (...) {
        // We're destroying — swallow everything.
    }
#endif
    delete handle;
}

} // extern "C"
