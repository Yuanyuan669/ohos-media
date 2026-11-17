#ifndef OHOS_MEDIA_MP4_HEVC_H
#define OHOS_MEDIA_MP4_HEVC_H

#include <cstdint>
#include <string>
#include <vector>

int hevc_probe(const char *path);
bool hevc_open(const char *path);
bool hevc_open_fd(int fd);
void hevc_close();
bool hevc_frame_at(int64_t ms, std::vector<uint8_t> &rgba, int &width, int &height);
std::string hevc_info_json();

#endif
