#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

NS_ASSUME_NONNULL_BEGIN

@interface StationInfo : NSObject
@property (nonatomic, copy) NSString *icao;
@property (nonatomic) float lat, lon;
@property (nonatomic) BOOL loaded;
@property (nonatomic) BOOL downloading;
@property (nonatomic) int index;
@property (nonatomic, copy) NSString *scanTime;
@end

@interface RadarEngine : NSObject

// Lifecycle
- (BOOL)initializeWithDevice:(id<MTLDevice>)device width:(int)w height:(int)h;
- (void)shutdown;

// Per-frame
- (void)updateWithDeltaTime:(float)dt;
- (void)render;

// Output
- (id<MTLBuffer> _Nullable)outputBuffer;
- (int)viewportWidth;
- (int)viewportHeight;

// Viewport gestures
- (void)panByDx:(double)dx dy:(double)dy;
- (void)zoomAtLat:(double)lat lon:(double)lon magnification:(double)mag;
- (void)zoomByMagnification:(double)mag;
- (void)tapAtScreenX:(double)x y:(double)y;
- (void)resizeWidth:(int)w height:(int)h;

// Product & tilt
@property (nonatomic, readonly) int activeProduct;
@property (nonatomic, readonly) int activeTilt;
@property (nonatomic, readonly) int maxTilts;
@property (nonatomic, readonly) float activeTiltAngle;
@property (nonatomic, readonly) NSString *activeProductName;
- (void)setProduct:(int)product;
- (void)setTilt:(int)tilt;
- (void)nextProduct;
- (void)prevProduct;
- (void)nextTilt;
- (void)prevTilt;
- (int)productCount;
- (NSString *)productNameForIndex:(int)idx;

// Station
@property (nonatomic, readonly) int activeStationIndex;
@property (nonatomic, readonly) NSString *activeStationName;
@property (nonatomic, readonly) int stationsLoaded;
@property (nonatomic, readonly) int stationsTotal;
- (void)selectStation:(int)idx centerView:(BOOL)center;
- (NSArray<StationInfo *> *)stationList;

// Multi-radar mode
@property (nonatomic) BOOL mosaicMode;
@property (nonatomic) int maxActiveStations;

// Data
- (void)refreshData;

// Viewport state
@property (nonatomic, readonly) double centerLat;
@property (nonatomic, readonly) double centerLon;
@property (nonatomic, readonly) double zoom;
@property (nonatomic, readonly) float cursorLat;
@property (nonatomic, readonly) float cursorLon;

// SRV
@property (nonatomic) BOOL srvMode;
@property (nonatomic) float stormSpeed;
@property (nonatomic) float stormDir;

// Threshold
@property (nonatomic) float dbzThreshold;

@end

NS_ASSUME_NONNULL_END
