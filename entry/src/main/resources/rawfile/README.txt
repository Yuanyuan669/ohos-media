媒体 M0 验证 App 的 rawfile 说明
=================================

这里不放音视频，所有测试素材走应用沙箱 filesDir/media/。

导入方式（二选一）：
1. App 内「导入文件」按钮 -> @ohos.file.picker DocumentViewPicker 多选。
2. hdc 推送：
   hdc file send samples\tone.wav /data/local/tmp/media-samples/
   hdc shell cp /data/local/tmp/media-samples/* /data/app/el2/100/base/com.local.media/haps/entry/files/media/
   hdc shell chown $(stat -c %u <media-dir>):$(stat -c %g <media-dir>) <files>
   hdc shell chmod 660 <files>

「格式矩阵测试」会逐个 createAVPlayer + fdSrc + prepare + play(2s)，
结果写 hilog（DOMAIN 0x0FFF, TAG MediaM0）。
