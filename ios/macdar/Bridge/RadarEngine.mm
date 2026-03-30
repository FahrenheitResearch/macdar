#import "RadarEngine.h"

#include "app.h"
#include "nexrad/products.h"
#include "nexrad/stations.h"

#include <memory>

// ── RadarStationInfo (ObjC wrapper) ────────────────────────────────

@implementation RadarStationInfo
@end

// ── RadarEngine ───────────────────────────────────────────────

@implementation RadarEngine {
    std::unique_ptr<App> _app;
    BOOL _initialized;
    BOOL _mosaicMode;
    int  _maxActiveStations;
}

#pragma mark - Lifecycle

- (instancetype)init {
    self = [super init];
    if (self) {
        _initialized = NO;
        _mosaicMode = NO;
        _maxActiveStations = 1;
    }
    return self;
}

- (BOOL)initializeWithDevice:(id<MTLDevice>)device width:(int)w height:(int)h {
    @synchronized (self) {
        if (_initialized) {
            NSLog(@"RadarEngine: already initialized, shutting down first");
            [self shutdown];
        }

        NSLog(@"RadarEngine: creating App %dx%d", w, h);
        _app = std::make_unique<App>();
        NSLog(@"RadarEngine: calling init...");
        if (!_app->init(w, h, device)) {
            NSLog(@"RadarEngine: App::init failed");
            _app.reset();
            return NO;
        }

        _initialized = YES;
        NSLog(@"RadarEngine: initialized %dx%d", w, h);
        return YES;
    }
}

- (void)shutdown {
    @synchronized (self) {
        _app.reset();
        _initialized = NO;
    }
}

- (void)dealloc {
    [self shutdown];
}

#pragma mark - Per-frame

- (void)updateWithDeltaTime:(float)dt {
    @synchronized (self) {
        if (!_initialized) return;
        _app->update(dt);
    }
}

- (void)render {
    @synchronized (self) {
        if (!_initialized) return;
        _app->render();
    }
}

#pragma mark - Output

- (id<MTLBuffer>)outputBuffer {
    @synchronized (self) {
        if (!_initialized) return nil;
        return _app->getOutputBuffer();
    }
}

- (int)viewportWidth {
    @synchronized (self) {
        if (!_initialized) return 0;
        return _app->viewport().width;
    }
}

- (int)viewportHeight {
    @synchronized (self) {
        if (!_initialized) return 0;
        return _app->viewport().height;
    }
}

#pragma mark - Viewport Gestures

- (void)panByDx:(double)dx dy:(double)dy {
    @synchronized (self) {
        if (!_initialized) return;
        _app->onMouseDrag(dx, dy);
    }
}

- (void)zoomAtLat:(double)lat lon:(double)lon magnification:(double)mag {
    @synchronized (self) {
        if (!_initialized) return;
        // Move cursor to the lat/lon position, then magnify
        Viewport& vp = _app->viewport();
        int px, py;
        vp.latLonToPixel(lat, lon, px, py);
        _app->onMouseMove((double)px, (double)py);
        _app->onMagnify(mag);
    }
}

- (void)zoomByMagnification:(double)mag {
    @synchronized (self) {
        if (!_initialized) return;
        _app->onMagnify(mag);
    }
}

- (void)tapAtScreenX:(double)x y:(double)y {
    @synchronized (self) {
        if (!_initialized) return;
        _app->onMouseMove(x, y);

        // Convert screen coords to lat/lon using viewport math
        Viewport& vp = _app->viewport();
        double lon = vp.center_lon + (x - vp.width * 0.5) / vp.zoom;
        double lat = vp.center_lat - (y - vp.height * 0.5) / vp.zoom;

        // Find nearest NEXRAD station, but only if within tap radius
        int bestIdx = -1;
        float bestScreenDist2 = 1e9f;
        std::vector<StationUiState> stationList = _app->stations();
        for (const auto& st : stationList) {
            // Compute screen-space distance (in pixels)
            double sx = (st.lon - vp.center_lon) * vp.zoom + vp.width * 0.5;
            double sy = (vp.center_lat - st.lat) * vp.zoom + vp.height * 0.5;
            double dx = sx - x;
            double dy = sy - y;
            float dist2 = (float)(dx * dx + dy * dy);
            if (dist2 < bestScreenDist2) {
                bestScreenDist2 = dist2;
                bestIdx = st.index;
            }
        }

        // Only select if tap is within 44pt * scale = ~132px on 3x display
        float maxDist = 132.0f; // pixels
        if (bestIdx >= 0 && bestScreenDist2 < maxDist * maxDist &&
            bestIdx != _app->activeStation()) {
            _app->selectStation(bestIdx, true);
        }
    }
}

- (void)resizeWidth:(int)w height:(int)h {
    @synchronized (self) {
        if (!_initialized) return;
        _app->onResize(w, h);
    }
}

#pragma mark - Product & Tilt

- (int)activeProduct {
    @synchronized (self) {
        if (!_initialized) return 0;
        return _app->activeProduct();
    }
}

- (int)activeTilt {
    @synchronized (self) {
        if (!_initialized) return 0;
        return _app->activeTilt();
    }
}

- (int)maxTilts {
    @synchronized (self) {
        if (!_initialized) return 1;
        return _app->maxTilts();
    }
}

- (float)activeTiltAngle {
    @synchronized (self) {
        if (!_initialized) return 0.5f;
        return _app->activeTiltAngle();
    }
}

- (NSString *)activeProductName {
    @synchronized (self) {
        if (!_initialized) return @"";
        int p = _app->activeProduct();
        if (p >= 0 && p < (int)Product::COUNT) {
            return [NSString stringWithUTF8String:PRODUCT_INFO[p].name];
        }
        return @"Unknown";
    }
}

- (void)setProduct:(int)product {
    @synchronized (self) {
        if (!_initialized) return;
        _app->setProduct(product);
    }
}

- (void)setTilt:(int)tilt {
    @synchronized (self) {
        if (!_initialized) return;
        _app->setTilt(tilt);
    }
}

- (void)nextProduct {
    @synchronized (self) {
        if (!_initialized) return;
        _app->nextProduct();
    }
}

- (void)prevProduct {
    @synchronized (self) {
        if (!_initialized) return;
        _app->prevProduct();
    }
}

- (void)nextTilt {
    @synchronized (self) {
        if (!_initialized) return;
        _app->nextTilt();
    }
}

- (void)prevTilt {
    @synchronized (self) {
        if (!_initialized) return;
        _app->prevTilt();
    }
}

- (int)productCount {
    return (int)Product::COUNT;
}

- (NSString *)productNameForIndex:(int)idx {
    if (idx >= 0 && idx < (int)Product::COUNT) {
        return [NSString stringWithUTF8String:PRODUCT_INFO[idx].name];
    }
    return @"Unknown";
}

#pragma mark - Station

- (int)activeStationIndex {
    @synchronized (self) {
        if (!_initialized) return -1;
        return _app->activeStation();
    }
}

- (NSString *)activeStationName {
    @synchronized (self) {
        if (!_initialized) return @"";
        std::string name = _app->activeStationName();
        return [NSString stringWithUTF8String:name.c_str()];
    }
}

- (int)stationsLoaded {
    @synchronized (self) {
        if (!_initialized) return 0;
        return _app->stationsLoaded();
    }
}

- (int)stationsTotal {
    @synchronized (self) {
        if (!_initialized) return 0;
        return _app->stationsTotal();
    }
}

- (void)selectStation:(int)idx centerView:(BOOL)center {
    @synchronized (self) {
        if (!_initialized) return;
        _app->selectStation(idx, (bool)center);
    }
}

- (NSArray<RadarStationInfo *> *)stationList {
    @synchronized (self) {
        if (!_initialized) return @[];

        std::vector<StationUiState> stations = _app->stations();
        NSMutableArray<RadarStationInfo *> *result = [NSMutableArray arrayWithCapacity:stations.size()];

        for (const auto& st : stations) {
            RadarStationInfo *info = [[RadarStationInfo alloc] init];
            info.icao = [NSString stringWithUTF8String:st.icao.c_str()];
            info.lat = st.lat;
            info.lon = st.lon;
            info.loaded = st.parsed && st.uploaded;
            info.downloading = st.downloading;
            info.index = st.index;
            info.scanTime = [NSString stringWithUTF8String:st.latest_scan_utc.c_str()];
            [result addObject:info];
        }

        return [result copy];
    }
}

#pragma mark - Multi-radar mode

- (BOOL)mosaicMode {
    return _mosaicMode;
}

- (void)setMosaicMode:(BOOL)mosaicMode {
    @synchronized (self) {
        _mosaicMode = mosaicMode;
        if (_initialized) {
            if (mosaicMode && !_app->showAll()) {
                _app->toggleShowAll();
            } else if (!mosaicMode && _app->showAll()) {
                _app->toggleShowAll();
            }
        }
    }
}

- (int)maxActiveStations {
    return _maxActiveStations;
}

- (void)setMaxActiveStations:(int)maxActiveStations {
    _maxActiveStations = MIN(MAX(maxActiveStations, 1), 10);
}

#pragma mark - Boundary compositing

- (void)compositeBoundaries {
    @synchronized (self) {
        if (!_initialized) return;
        _app->compositeBoundaries();
    }
}

- (void)waitForGpu {
    @synchronized (self) {
        if (!_initialized) return;
        _app->waitForGpu();
    }
}

#pragma mark - Data

- (void)refreshData {
    @synchronized (self) {
        if (!_initialized) return;
        _app->refreshData();
    }
}

#pragma mark - Viewport state

- (double)centerLat {
    @synchronized (self) {
        if (!_initialized) return 39.0;
        return _app->viewport().center_lat;
    }
}

- (double)centerLon {
    @synchronized (self) {
        if (!_initialized) return -98.0;
        return _app->viewport().center_lon;
    }
}

- (double)zoom {
    @synchronized (self) {
        if (!_initialized) return 28.0;
        return _app->viewport().zoom;
    }
}

- (void)setViewportCenter:(double)lat lon:(double)lon zoom:(double)zoom {
    @synchronized (self) {
        if (!_initialized) return;
        Viewport& vp = _app->viewport();
        vp.center_lat = lat;
        vp.center_lon = lon;
        vp.zoom = zoom;
    }
}

- (float)cursorLat {
    @synchronized (self) {
        if (!_initialized) return 0.0f;
        return _app->cursorLat();
    }
}

- (float)cursorLon {
    @synchronized (self) {
        if (!_initialized) return 0.0f;
        return _app->cursorLon();
    }
}

#pragma mark - SRV

- (BOOL)srvMode {
    @synchronized (self) {
        if (!_initialized) return NO;
        return _app->srvMode() ? YES : NO;
    }
}

- (void)setSrvMode:(BOOL)srvMode {
    @synchronized (self) {
        if (!_initialized) return;
        if ((bool)srvMode != _app->srvMode()) {
            _app->toggleSRV();
        }
    }
}

- (float)stormSpeed {
    @synchronized (self) {
        if (!_initialized) return 15.0f;
        return _app->stormSpeed();
    }
}

- (void)setStormSpeed:(float)stormSpeed {
    @synchronized (self) {
        if (!_initialized) return;
        _app->setStormMotion(stormSpeed, _app->stormDir());
    }
}

- (float)stormDir {
    @synchronized (self) {
        if (!_initialized) return 225.0f;
        return _app->stormDir();
    }
}

- (void)setStormDir:(float)stormDir {
    @synchronized (self) {
        if (!_initialized) return;
        _app->setStormMotion(_app->stormSpeed(), stormDir);
    }
}

#pragma mark - Threshold

- (float)dbzThreshold {
    @synchronized (self) {
        if (!_initialized) return 5.0f;
        return _app->dbzMinThreshold();
    }
}

- (void)setDbzThreshold:(float)dbzThreshold {
    @synchronized (self) {
        if (!_initialized) return;
        _app->setDbzMinThreshold(dbzThreshold);
    }
}

@end
