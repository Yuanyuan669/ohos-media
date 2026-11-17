#include "mp4_hevc.h"

#include <libde265/de265.h>

#include <algorithm>
#include <cstdio>
#include <unistd.h>
#include <cstring>

namespace {


struct VideoFile {
    FILE *fp = nullptr;
    int width = 0;
    int height = 0;
    int timescale = 0;
    int64_t durationMs = 0;
    double fps = 30.0;
    std::vector<uint64_t> offsets;
    std::vector<uint32_t> sizes;
    std::vector<int64_t> ptsMs;
    std::vector<std::vector<uint8_t>> params;
    de265_decoder_context *ctx = nullptr;
    size_t nextSample = 0;
    int64_t lastPts = -1;
    int64_t lastRequest = -1;
    std::vector<uint8_t> rgba;
    int outW = 0;
    int outH = 0;
    bool hasFrame = false;
};

VideoFile g;
std::string g_err;

uint32_t be32(const uint8_t *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) | ((uint32_t)p[2] << 8) | p[3];
}

uint64_t be64(const uint8_t *p) {
    return ((uint64_t)be32(p) << 32) | be32(p + 4);
}

bool readAt(FILE *f, uint64_t off, void *buf, size_t n) {
    if (f == nullptr || n == 0) {
        return false;
    }
    if (fseek(f, (long)off, SEEK_SET) != 0) {
        return false;
    }
    return fread(buf, 1, n, f) == n;
}

bool readU32(FILE *f, uint64_t off, uint32_t &v) {
    uint8_t b[4];
    if (!readAt(f, off, b, 4)) {
        return false;
    }
    v = be32(b);
    return true;
}

bool readU64(FILE *f, uint64_t off, uint64_t &v) {
    uint8_t b[8];
    if (!readAt(f, off, b, 8)) {
        return false;
    }
    v = be64(b);
    return true;
}

bool readU16(FILE *f, uint64_t off, uint16_t &v) {
    uint8_t b[2];
    if (!readAt(f, off, b, 2)) {
        return false;
    }
    v = (uint16_t)(((uint16_t)b[0] << 8) | b[1]);
    return true;
}

struct Box {
    uint64_t start = 0;
    uint64_t size = 0;
    uint32_t type = 0;
    uint64_t payload = 0;
};

bool readBox(FILE *f, uint64_t off, uint64_t end, Box &box) {
    uint8_t h[16];
    if (off + 8 > end || !readAt(f, off, h, 8)) {
        return false;
    }
    uint64_t size = be32(h);
    uint32_t type = be32(h + 4);
    uint64_t payload = off + 8;
    if (size == 1) {
        if (off + 16 > end || !readAt(f, off + 8, h + 8, 8)) {
            return false;
        }
        size = be64(h + 8);
        payload = off + 16;
    } else if (size == 0) {
        size = end - off;
    }
    if (size < 8 || off + size > end) {
        return false;
    }
    box.start = off;
    box.size = size;
    box.type = type;
    box.payload = payload;
    return true;
}

bool findChild(FILE *f, uint64_t start, uint64_t end, uint32_t type, Box &out) {
    uint64_t off = start;
    while (off + 8 <= end) {
        Box b;
        if (!readBox(f, off, end, b)) {
            return false;
        }
        if (b.type == type) {
            out = b;
            return true;
        }
        off = b.start + b.size;
    }
    return false;
}

int64_t fileSize(FILE *f) {
    if (fseek(f, 0, SEEK_END) != 0) {
        return 0;
    }
    long n = ftell(f);
    return n < 0 ? 0 : (int64_t)n;
}

bool parseHvcC(FILE *f, const Box &box, std::vector<std::vector<uint8_t>> &params) {
    uint8_t head[23];
    if (!readAt(f, box.payload, head, sizeof(head))) {
        return false;
    }
    if (head[0] != 1) {
        return false;
    }
    int numArrays = head[22];
    uint64_t off = box.payload + 23;
    uint64_t end = box.start + box.size;
    for (int a = 0; a < numArrays && off + 3 <= end; ++a) {
        uint8_t ah[3];
        if (!readAt(f, off, ah, 3)) {
            return false;
        }
        int numNalus = ((int)ah[1] << 8) | ah[2];
        off += 3;
        for (int n = 0; n < numNalus && off + 2 <= end; ++n) {
            uint8_t lb[2];
            if (!readAt(f, off, lb, 2)) {
                return false;
            }
            int len = ((int)lb[0] << 8) | lb[1];
            off += 2;
            if (len <= 0 || off + (uint64_t)len > end) {
                return false;
            }
            std::vector<uint8_t> nal((size_t)len);
            if (!readAt(f, off, nal.data(), (size_t)len)) {
                return false;
            }
            params.push_back(std::move(nal));
            off += (uint64_t)len;
        }
    }
    return !params.empty();
}

bool parseTrack(FILE *f, const Box &trak) {
    uint64_t trakEnd = trak.start + trak.size;
    Box mdia;
    if (!findChild(f, trak.payload, trakEnd, 'mdia', mdia)) {
        return false;
    }
    uint64_t mdiaEnd = mdia.start + mdia.size;
    Box hdlr;
    if (!findChild(f, mdia.payload, mdiaEnd, 'hdlr', hdlr)) {
        return false;
    }
    uint32_t handler = 0;
    if (!readU32(f, hdlr.payload + 8, handler) || handler != 'vide') {
        return false;
    }
    Box mdhd;
    if (!findChild(f, mdia.payload, mdiaEnd, 'mdhd', mdhd)) {
        return false;
    }
    uint8_t version = 0;
    if (!readAt(f, mdhd.payload, &version, 1)) {
        return false;
    }
    uint32_t timescale = 0;
    uint64_t mediaDuration = 0;
    if (version == 1) {
        readU32(f, mdhd.payload + 20, timescale);
        readU64(f, mdhd.payload + 24, mediaDuration);
    } else {
        readU32(f, mdhd.payload + 12, timescale);
        uint32_t d32 = 0;
        readU32(f, mdhd.payload + 16, d32);
        mediaDuration = d32;
    }
    if (timescale == 0) {
        return false;
    }
    Box minf;
    if (!findChild(f, mdia.payload, mdiaEnd, 'minf', minf)) {
        return false;
    }
    Box stbl;
    if (!findChild(f, minf.payload, minf.start + minf.size, 'stbl', stbl)) {
        return false;
    }
    uint64_t stblEnd = stbl.start + stbl.size;

    Box stsd;
    if (!findChild(f, stbl.payload, stblEnd, 'stsd', stsd)) {
        return false;
    }
    uint32_t entryCount = 0;
    readU32(f, stsd.payload + 4, entryCount);
    if (entryCount == 0) {
        return false;
    }
    Box entry;
    if (!readBox(f, stsd.payload + 8, stsd.start + stsd.size, entry)) {
        return false;
    }
    if (entry.type != 'hvc1' && entry.type != 'hev1') {
        return false;
    }
    uint16_t w = 0;
    uint16_t h = 0;
    readU16(f, entry.payload + 24, w);
    readU16(f, entry.payload + 26, h);
    if (w == 0 || h == 0) {
        return false;
    }
    Box hvcc;
    if (!findChild(f, entry.payload + 78, entry.start + entry.size, 'hvcC', hvcc)) {
        return false;
    }
    std::vector<std::vector<uint8_t>> params;
    if (!parseHvcC(f, hvcc, params)) {
        return false;
    }

    Box stts;
    if (!findChild(f, stbl.payload, stblEnd, 'stts', stts)) {
        return false;
    }
    uint32_t sttsCount = 0;
    readU32(f, stts.payload + 4, sttsCount);
    std::vector<int64_t> pts;
    int64_t t = 0;
    uint32_t firstDelta = 0;
    for (uint32_t i = 0; i < sttsCount; ++i) {
        uint32_t cnt = 0;
        uint32_t delta = 0;
        readU32(f, stts.payload + 8 + (uint64_t)i * 8, cnt);
        readU32(f, stts.payload + 12 + (uint64_t)i * 8, delta);
        if (firstDelta == 0) {
            firstDelta = delta;
        }
        for (uint32_t k = 0; k < cnt && pts.size() < 1000000; ++k) {
            pts.push_back((int64_t)(t * 1000 / timescale));
            t += delta;
        }
    }
    if (pts.empty()) {
        return false;
    }

    Box stsz;
    if (!findChild(f, stbl.payload, stblEnd, 'stsz', stsz)) {
        return false;
    }
    uint32_t uniform = 0;
    uint32_t sampleCount = 0;
    readU32(f, stsz.payload + 4, uniform);
    readU32(f, stsz.payload + 8, sampleCount);
    if (sampleCount == 0 || sampleCount > pts.size()) {
        return false;
    }
    std::vector<uint32_t> sizes(sampleCount, 0);
    for (uint32_t i = 0; i < sampleCount; ++i) {
        if (uniform != 0) {
            sizes[i] = uniform;
        } else {
            readU32(f, stsz.payload + 12 + (uint64_t)i * 4, sizes[i]);
        }
    }

    Box stco;
    bool co64 = false;
    if (!findChild(f, stbl.payload, stblEnd, 'stco', stco)) {
        if (!findChild(f, stbl.payload, stblEnd, 'co64', stco)) {
            return false;
        }
        co64 = true;
    }
    uint32_t chunkCount = 0;
    readU32(f, stco.payload + 4, chunkCount);
    if (chunkCount == 0) {
        return false;
    }
    std::vector<uint64_t> chunkOffsets(chunkCount, 0);
    for (uint32_t i = 0; i < chunkCount; ++i) {
        if (co64) {
            readU64(f, stco.payload + 8 + (uint64_t)i * 8, chunkOffsets[i]);
        } else {
            uint32_t v = 0;
            readU32(f, stco.payload + 8 + (uint64_t)i * 4, v);
            chunkOffsets[i] = v;
        }
    }

    Box stsc;
    if (!findChild(f, stbl.payload, stblEnd, 'stsc', stsc)) {
        return false;
    }
    uint32_t stscCount = 0;
    readU32(f, stsc.payload + 4, stscCount);
    struct StscEntry {
        uint32_t first;
        uint32_t spc;
    };
    std::vector<StscEntry> stscEntries;
    for (uint32_t i = 0; i < stscCount; ++i) {
        uint32_t first = 0;
        uint32_t spc = 0;
        readU32(f, stsc.payload + 8 + (uint64_t)i * 12, first);
        readU32(f, stsc.payload + 12 + (uint64_t)i * 12, spc);
        stscEntries.push_back({first, spc});
    }
    if (stscEntries.empty()) {
        return false;
    }

    std::vector<uint64_t> offsets(sampleCount, 0);
    uint32_t si = 0;
    size_t se = 0;
    for (uint32_t chunk = 1; chunk <= chunkCount && si < sampleCount; ++chunk) {
        while (se + 1 < stscEntries.size() && stscEntries[se + 1].first <= chunk) {
            ++se;
        }
        uint32_t spc = stscEntries[se].spc;
        uint64_t off = chunkOffsets[chunk - 1];
        for (uint32_t k = 0; k < spc && si < sampleCount; ++k) {
            offsets[si] = off;
            off += sizes[si];
            ++si;
        }
    }
    if (si == 0) {
        return false;
    }
    if (si < sampleCount) {
        sampleCount = si;
        sizes.resize(si);
        pts.resize(si);
        offsets.resize(si);
    }

    g.width = w;
    g.height = h;
    g.timescale = (int)timescale;
    g.fps = firstDelta == 0 ? 30.0 : (double)timescale / (double)firstDelta;
    g.durationMs = (int64_t)(mediaDuration * 1000 / timescale);
    g.offsets = std::move(offsets);
    g.sizes = std::move(sizes);
    g.ptsMs = std::move(pts);
    g.params = std::move(params);
    return true;
}

bool parseFile(FILE *f, uint64_t total) {
    uint64_t off = 0;
    while (off + 8 <= total) {
        Box b;
        if (!readBox(f, off, total, b)) {
            return false;
        }
        if (b.type == 'moov') {
            uint64_t o = b.payload;
            uint64_t end = b.start + b.size;
            while (o + 8 <= end) {
                Box c;
                if (!readBox(f, o, end, c)) {
                    break;
                }
                if (c.type == 'trak' && parseTrack(f, c)) {
                    return true;
                }
                o = c.start + c.size;
            }
            return false;
        }
        off = b.start + b.size;
    }
    return false;
}

void clampSet(uint8_t &dst, int v) {
    dst = (uint8_t)(v < 0 ? 0 : (v > 255 ? 255 : v));
}

void convertFrame(const de265_image *img) {
    int w = de265_get_image_width(img, 0);
    int h = de265_get_image_height(img, 0);
    if (w <= 0 || h <= 0) {
        return;
    }
    int strideY = 0;
    int strideU = 0;
    int strideV = 0;
    const uint8_t *py = de265_get_image_plane(img, 0, &strideY);
    const uint8_t *pu = de265_get_image_plane(img, 1, &strideU);
    const uint8_t *pv = de265_get_image_plane(img, 2, &strideV);
    if (py == nullptr || pu == nullptr || pv == nullptr) {
        return;
    }
    de265_chroma cf = de265_get_chroma_format(img);
    g.rgba.resize((size_t)w * (size_t)h * 4);
    for (int j = 0; j < h; ++j) {
        const uint8_t *rowY = py + (size_t)j * (size_t)strideY;
        int cj = (cf == de265_chroma_420) ? (j / 2) : j;
        const uint8_t *rowU = pu + (size_t)cj * (size_t)strideU;
        const uint8_t *rowV = pv + (size_t)cj * (size_t)strideV;
        for (int i = 0; i < w; ++i) {
            int ci = (cf == de265_chroma_420) ? (i / 2) : i;
            int c = (int)rowY[i] - 16;
            int d = (int)rowU[ci] - 128;
            int e = (int)rowV[ci] - 128;
            int r = (298 * c + 409 * e + 128) >> 8;
            int gg = (298 * c - 100 * d - 208 * e + 128) >> 8;
            int b = (298 * c + 516 * d + 128) >> 8;
            size_t o = ((size_t)j * (size_t)w + (size_t)i) * 4;
            clampSet(g.rgba[o], r);
            clampSet(g.rgba[o + 1], gg);
            clampSet(g.rgba[o + 2], b);
            g.rgba[o + 3] = 255;
        }
    }
    g.outW = w;
    g.outH = h;
    g.hasFrame = true;
}

void initDecoder() {
    if (g.ctx != nullptr) {
        de265_free_decoder(g.ctx);
        g.ctx = nullptr;
    }
    g.ctx = de265_new_decoder();
    if (g.ctx == nullptr) {
        return;
    }
    de265_start_worker_threads(g.ctx, 1);
    for (size_t i = 0; i < g.params.size(); ++i) {
        de265_push_NAL(g.ctx, g.params[i].data(), (int)g.params[i].size(), 0, nullptr);
    }
    de265_push_end_of_NAL(g.ctx);
    g.nextSample = 0;
    g.lastPts = -1;
    g.hasFrame = false;
}

bool pushSample(size_t idx) {
    if (idx >= g.sizes.size() || g.ctx == nullptr) {
        return false;
    }
    std::vector<uint8_t> buf(g.sizes[idx]);
    if (!readAt(g.fp, g.offsets[idx], buf.data(), buf.size())) {
        return false;
    }
    size_t p = 0;
    bool any = false;
    while (p + 4 <= buf.size()) {
        uint32_t n = be32(buf.data() + p);
        p += 4;
        if (n == 0 || p + n > buf.size()) {
            break;
        }
        de265_push_NAL(g.ctx, buf.data() + p, (int)n, (de265_PTS)g.ptsMs[idx], nullptr);
        p += n;
        any = true;
    }
    de265_push_end_of_NAL(g.ctx);
    return any;
}

void pump() {
    while (true) {
        int more = 0;
        de265_error err = de265_decode(g.ctx, &more);
        if (err == DE265_ERROR_WAITING_FOR_INPUT_DATA) {
            break;
        }
        while (true) {
            const de265_image *img = de265_get_next_picture(g.ctx);
            if (img == nullptr) {
                break;
            }
            int64_t pts = (int64_t)de265_get_image_PTS(img);
            if (pts >= g.lastPts) {
                g.lastPts = pts;
                convertFrame(img);
            }
            de265_release_next_picture(g.ctx);
        }
        if (more == 0) {
            break;
        }
    }
}

} // namespace

int hevc_probe(const char *path) {
    if (path == nullptr) {
        return 0;
    }
    FILE *f = fopen(path, "rb");
    if (f == nullptr) {
        return 0;
    }
    int64_t total = fileSize(f);
    bool ok = total > 0 && parseFile(f, (uint64_t)total);
    fclose(f);
    if (!ok) {
        return 0;
    }
    int w = g.width;
    g.offsets.clear();
    g.sizes.clear();
    g.ptsMs.clear();
    g.params.clear();
    return w;
}

bool hevc_open_fd(int fd) {
    hevc_close();
    g_err.clear();
    int d = dup(fd);
    if (d < 0) {
        g_err = "dup";
        return false;
    }
    g.fp = fdopen(d, "rb");
    if (g.fp == nullptr) {
        close(d);
        g_err = "fdopen";
        return false;
    }
    int64_t total = fileSize(g.fp);
    if (total <= 0 || !parseFile(g.fp, (uint64_t)total)) {
        g_err = "parse";
        hevc_close();
        return false;
    }
    initDecoder();
    if (g.ctx == nullptr) {
        g_err = "decoder";
        hevc_close();
        return false;
    }
    return true;
}

bool hevc_open(const char *path) {
    hevc_close();
    g_err.clear();
    if (path == nullptr) {
        return false;
    }
    g.fp = fopen(path, "rb");
    if (g.fp == nullptr) {
        g_err = "fopen";
        return false;
    }
    int64_t total = fileSize(g.fp);
    if (total <= 0 || !parseFile(g.fp, (uint64_t)total)) {
        g_err = "parse";
        hevc_close();
        return false;
    }
    initDecoder();
    if (g.ctx == nullptr) {
        g_err = "decoder";
        hevc_close();
        return false;
    }
    return true;
}

void hevc_close() {
    if (g.ctx != nullptr) {
        de265_free_decoder(g.ctx);
        g.ctx = nullptr;
    }
    if (g.fp != nullptr) {
        fclose(g.fp);
        g.fp = nullptr;
    }
    g.offsets.clear();
    g.sizes.clear();
    g.ptsMs.clear();
    g.params.clear();
    g.rgba.clear();
    g.hasFrame = false;
    g.nextSample = 0;
    g.lastPts = -1;
    g.lastRequest = -1;
    g.width = 0;
    g.height = 0;
}

bool hevc_frame_at(int64_t ms, std::vector<uint8_t> &rgba, int &width, int &height) {
    if (g.fp == nullptr || g.ctx == nullptr) {
        return false;
    }
    bool seek = ms < g.lastRequest - 150 || ms - g.lastRequest > 1500;
    if (seek) {
        initDecoder();
    }
    g.lastRequest = ms;
    int64_t target = ms < 0 ? 0 : ms;
    bool pushed = false;
    while (g.nextSample < g.sizes.size()) {
        if (g.hasFrame && g.ptsMs[g.nextSample] > target + 250) {
            break;
        }
        if (!pushSample(g.nextSample)) {
            break;
        }
        pushed = true;
        g.nextSample++;
        pump();
        if (g.lastPts >= target) {
            break;
        }
    }
    if (!pushed && g.hasFrame) {
        rgba = g.rgba;
        width = g.outW;
        height = g.outH;
        return true;
    }
    if (g.hasFrame) {
        rgba = g.rgba;
        width = g.outW;
        height = g.outH;
        return true;
    }
    return false;
}

std::string hevc_info_json() {
    if (!g_err.empty() && g.width == 0) {
        return std::string("{\"error\":\"") + g_err + "\"}";
    }
    char buf[256];
    snprintf(buf, sizeof(buf), "{\"width\":%d,\"height\":%d,\"fps\":%.2f,\"durationMs\":%lld,\"frames\":%d}",
             g.width, g.height, g.fps, (long long)g.durationMs, (int)g.sizes.size());
    return std::string(buf);
}
