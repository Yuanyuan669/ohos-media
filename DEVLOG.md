# ohos-media DEVLOG

> 目的：记录设计决策、踩坑与当前状态，上下文压缩后仍能续接。
> 相关：`D:\ohos-device\docs\APP-ROADMAP.md`、`docs/research/VERIFY-MEDIA-M0.md`

## 2026-11-17 M0：可行性验证

- 工程：`com.local.media`，test-CA 普通应用，零三方依赖。
- 验证：AVPlayer + `fdSrc` 播放沙箱媒体；视频用 `XComponent(type:'surface')` + `surfaceId`。
- 格式矩阵 10/10：FLAC/M4A/MP3/OGG(Vorbis)/OPUS/WAV/MKV(H264)/MP4(H264)/TS(H264)/**HEVC 320x240**。
- 后台：AVSession + `backgroundTaskManager(AUDIO_PLAYBACK)`，切后台 98 s 进度持续、进程存活。
- picker：可打开，但测试机 Documents/Download 0 项（外部拷入不索引），picker→fd 待人工验证。
- 结论：HEVC 小分辨率可用；风险在 4K/10bit/大码率。

## 2026-11-17 M2：音频播放器

- 设计：音频列表（后改为包含视频，视频走 surface）；播放/暂停/seek/上下曲；播完自动下一首；后台保持。
- 踩坑 1：`fdSrc` 赋值到 `initialized` 是**异步**的，立即 `prepare()` 报 `5400102 ... unsupport prepare operation`。
  → 修法：`waitInitialized()` 轮询状态（50 ms，5 s 超时）。
- 踩坑 2：在 `initialized` 状态写 `p.loop = false` 报 `5400102 ... unsupport loop operation`。
  → 修法：不要设 loop；默认就是 false；如要设，必须在 prepared/playing 之后。
- 踩坑 3：后台任务在 `play()` 成功前启动，UI 会误显示“后台播放中”。
  → 修法：顺序改为 prepare → ensureSession → play → ensureBackground。
- 踩坑 4：视频被误点后无 surface，状态停在 initialized。
  → 修法：列表先分类型；视频等 M3 接 surface。
- 安装 `hdc install -r` 会把默认输入法重置为 Kika，测试后需恢复 `com.local.homeime`。

## 2026-11-17 M3：视频播放（部分）

- 已实现：列表同时显示音视频；视频选中后渲染 `XComponent(type:'surface')`，在 `initialized` 后取 `surfaceId` 并赋给 AVPlayer，再 `prepare/play`；视频播完停在 completed（音频才自动下一首）。
- 全屏：竖向沉浸式（隐藏头部/列表/控制区，`setWindowLayoutFullScreen(true)`，surface 铺满）；退出恢复。
- 实测：
  - H264 MP4：正常出画（纯蓝测试帧）。
  - MKV / TS：可播放（M0 已验证解码，本轮未逐一截图）。
  - **HEVC 320x240：进度/状态正常但画面全黑**。根因已确认：设备 `codec_caps.xml` 无 HEVC 解码器（仅 h264/h263/mpeg2/mpeg4），且无 HEVC 解码库；**本机不支持 HEVC**，应用层无法修复。M0 的“HEVC pass”是误判。
  - 全屏横屏：`setPreferredOrientation(LANDSCAPE)` 在 LHT16 上窗口不跟随旋转，变成左上角半屏（右侧露出桌面），已放弃强制横屏；横屏需用户旋转设备或另做窗口方案。

## 踩坑（M3）

1. **切换视频后列表整体下移 232px**：视频区域插入到列表上方，自动化点击必须每次重新 `dumpLayout` 取坐标；否则会点到相邻行（表现为“点 HEVC 却播了 OGG/M4A”）。
2. **全屏按钮不能放在状态栏区域**：`layoutFullScreen` 下状态栏仍占顶部约 32vp，按钮在 y<80px 点击无效；给全屏态按钮 `margin.top=52`。
3. **视频自动下一首会跳到音频**：完成回调统一 `next()` 导致全屏时已切走；改为仅 `isAudioOnly(selected)` 时自动下一首。
4. `setPreferredOrientation` 不要与 `setWindowLayoutFullScreen` 混用做伪横屏；本机行为不可靠。

## 当前状态（M3 收尾）

- M2 已推送 `fca73b1`；M3 代码与本文档待提交。
- HEVC 结论：系统镜像无解码器，不再投入；UI 文案改为“支持音频与 H264 视频”。
- 下一步：真机旋转横屏验证；手势（双击暂停、亮度/音量）；音频焦点与耳机切换。


## 设计约定

- 所有媒体复制进应用沙箱 `filesDir/media`，不依赖 picker URI 持久化（`FILE_ACCESS_PERSIST` 为 system_basic）。
- 后台播放必须 AVSession + `audioPlayback`，否则约 1.1 s 被系统暂停。
- 不引入 ohpm 三方库；测试素材用 ffmpeg 生成放 `samples/`。


### HEVC 不支持属于哪一层？

- **不是 API 层**：API 11 的 AVCodec/AVPlayer 本身支持 HEVC，运行时按 codec 能力发现解码器。
- **不是“纯硬件”**：SoC 是否具备 HEVC 硬解无法从系统内确认；关键证据是系统镜像没把解码器暴露出来。
- **是系统镜像 + 闭源 vendor 组件缺失**：
  - `/system/etc/codec/codec_caps.xml`（OH 软件/注册解码器清单）只有 h264/h263/mpeg2/mpeg4，无 HEVC；
  - `/vendor/lib64` 只有 `libomx_avcdec_hw_sprd`、`libomx_avcenc_hw_sprd` 等 H264 OMX，没有任何 HEVC OMX/codec2/解码 .so；
  - 结果：AVPlayer 找不到 HEVC 解码器，只播音轨/推进时间轴，surface 保持黑屏。
- 修复路径：由 ROM/vendor 提供 HEVC 解码组件并在 codec_caps 注册（或移植软解到 media engine），应用层无解。


## 2026-11-17 HEVC 应用内软解（原型可用）

- 方案：libde265 静态库 + 自带 MP4 解复用（hvcC/stts/stsz/stco/stsc）→ YUV420→RGBA；ArkTS 用 PixelMap+Image 显示，AVPlayer 只播音频并提供时钟。
- 实测 320x240 25fps：解析 125 帧；出画正常；渲染约 12.8fps。
- 关键坑：原生 fopen 打不开 ArkTS filesDir 虚拟路径 → 传 fd（dup+fdopen）；沙箱文件/目录权限（目录要 770）；SDK 10→11 需卸载重装。
- 详见 docs/HEVC-SOFTDECODE.md。
