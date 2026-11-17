#include <cstring>
#include <string>
#include <vector>

#include "napi/native_api.h"
#include <libde265/de265.h>
#include "mp4_hevc.h"

static napi_value Version(napi_env env, napi_callback_info info) {
    (void) info;
    const char *v = de265_get_version();
    napi_value out = nullptr;
    napi_create_string_utf8(env, v == nullptr ? "unknown" : v, NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value Probe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[1024] = {0};
    size_t len = 0;
    if (argc < 1 || napi_get_value_string_utf8(env, args[0], path, sizeof(path), &len) != napi_ok) {
        napi_value zero = nullptr;
        napi_create_int32(env, 0, &zero);
        return zero;
    }
    napi_value out = nullptr;
    napi_create_int32(env, hevc_probe(path), &out);
    return out;
}

static napi_value Open(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char path[1024] = {0};
    size_t len = 0;
    napi_value out = nullptr;
    if (argc < 1 || napi_get_value_string_utf8(env, args[0], path, sizeof(path), &len) != napi_ok) {
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &out);
        return out;
    }
    if (!hevc_open(path)) {
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &out);
        return out;
    }
    std::string json = hevc_info_json();
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value OpenFd(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int32_t fd = -1;
    if (argc >= 1) {
        napi_get_value_int32(env, args[0], &fd);
    }
    napi_value out = nullptr;
    if (fd < 0 || !hevc_open_fd(fd)) {
        napi_create_string_utf8(env, "", NAPI_AUTO_LENGTH, &out);
        return out;
    }
    std::string json = hevc_info_json();
    napi_create_string_utf8(env, json.c_str(), NAPI_AUTO_LENGTH, &out);
    return out;
}

static napi_value FrameAt(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value args[1] = {nullptr};
    napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    int64_t ms = 0;
    if (argc >= 1) {
        napi_get_value_int64(env, args[0], &ms);
    }
    std::vector<uint8_t> rgba;
    int w = 0;
    int h = 0;
    if (!hevc_frame_at(ms, rgba, w, h) || rgba.empty()) {
        napi_value nullValue = nullptr;
        napi_get_null(env, &nullValue);
        return nullValue;
    }
    void *data = nullptr;
    napi_value ab = nullptr;
    napi_create_arraybuffer(env, rgba.size(), &data, &ab);
    if (data != nullptr) {
        memcpy(data, rgba.data(), rgba.size());
    }
    return ab;
}

static napi_value Close(napi_env env, napi_callback_info info) {
    (void) info;
    hevc_close();
    napi_value undef = nullptr;
    napi_get_undefined(env, &undef);
    return undef;
}

static napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"version", nullptr, Version, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"probe", nullptr, Probe, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"open", nullptr, Open, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"openFd", nullptr, OpenFd, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"frameAt", nullptr, FrameAt, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"close", nullptr, Close, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

static napi_module hevcModule = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "hevcdec",
    .nm_priv = nullptr,
    .reserved = {0},
};

extern "C" __attribute__((constructor)) void RegisterHevcModule(void) {
    napi_module_register(&hevcModule);
}
