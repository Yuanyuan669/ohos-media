# HEVC 应用内软解（实验）

## 为什么做
LHT16 的系统镜像没有 HEVC 解码器：`/system/etc/codec/codec_caps.xml` 只注册
`avdec_h264 / h263 / mpeg2video / mpeg4`，`/vendor/lib64` 也只有 H264 OMX。
AVPlayer 播 HEVC 时只走音轨/时间轴，surface 保持黑屏。

## 方案
- **视频**：应用自带 libde265（静态库）软解，自己解析 MP4（hvcC + stts/stsz/stco/stsc），
  解出 YUV420 转 RGBA，交给 ArkTS 用 `PixelMap + Image` 显示。
- **音频/时钟**：仍由 AVPlayer 播放 AAC 音轨并提供 `currentTime`；软解按时间取帧（`frameAt(ms)`）。
- 检测：选中视频时用 `hevcdec.openFd(fd)` 探测；能解析出 HEVC 视频轨则进入软解模式，否则走原来的 AVPlayer + XComponent。
- 播完/切换/退出会停止解码并释放 PixelMap。

## 当前实测（320x240，25fps，5s 测试片）
- 解析：`{"width":320,"height":240,"fps":25,"durationMs":5000,"frames":125}`
- 出画正常（测试片为纯红帧），音频时间轴正常。
- ArkTS `PixelMap + Image` 路径渲染约 **12~13 fps**（80ms 定时 + 异步 PixelMap 创建）。
  仅适合作为原型；要流畅需改成原生 `XComponent` surface + EGL/GLES 直接渲染。

## 复现/构建
```bash
# 1) 交叉编译 libde265（OHOS SDK 11 native）
cmake -S libde265 -B build-ohos -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<sdk>/11/native/build/cmake/ohos.toolchain.cmake \
  -DOHOS_ARCH=arm64-v8a -DOHOS_STL=c++_shared \
  -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF -DENABLE_SDL=OFF
cmake --build build-ohos --target de265
# 产物：build-ohos/libde265/libde265.a
```
- 把 `libde265.a` 放到 `entry/src/main/cpp/libde265/`，头文件放 `include/libde265/`。
- `entry/build-profile.json5` 打开 `externalNativeOptions`，CMake 链接 `libde265.a`、`ace_napi.z`、`hilog_ndk.z`。
- SDK 从 10 升到 11 会导致 `hdc install -r` 报 `9568282 releaseType target not same`，需卸载重装（沙箱文件会丢）。

## 踩坑
1. **原生 `fopen` 打不开 ArkTS 的 `filesDir` 虚拟路径**（`/data/storage/el2/base/...`）。
   → 由 ArkTS `fs.openSync` 拿 fd，NAPI 传 fd，原生 `dup + fdopen`。
2. 用 root 往沙箱拷文件后：`chown` 成应用 uid，目录要 `770`（660 会去掉 x 导致无法遍历），文件 `660`。
3. `media.createPixelMapSync` 在该 SDK 不存在；用异步 `createPixelMap`，并加 `softBusy` 防重入。
4. ArkTS 不允许 `any`：NAPI 返回值要显式 `as string` / `as ArrayBuffer | null`。
5. libde265 头文件按 `<libde265/de265.h>` 布局，否则找不到 `de265-version.h`。
6. 重装/重启后输入法会重置，需要恢复 homeime。

## 许可
libde265 为 LGPLv3；当前仅本机原型内置静态库，未分发。若要发布需满足 LGPL（提供源码/可替换链接）并注意 HEVC 专利授权。
