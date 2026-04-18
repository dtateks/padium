#import "MultitouchBridge.h"

#import <dlfcn.h>
#import <os/lock.h>
#import <os/log.h>

typedef struct {
    float x;
    float y;
} MTPoint;

typedef struct {
    MTPoint position;
    MTPoint velocity;
} MTVector;

typedef int MTTouchState;

typedef struct {
    int frame;
    double timestamp;
    int identifier;
    MTTouchState state;
    int fingerId;
    int handId;
    MTVector normalizedPosition;
    float total;
    float pressure;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolutePosition;
    int field14;
    int field15;
    float density;
} MTTouch;

typedef void *MTDeviceRef;
typedef void (*MTFrameCallbackFunction)(MTDeviceRef device, MTTouch touches[], int numTouches, double timestamp, int frame);

typedef bool (*MTDeviceIsAvailableFn)(void);
typedef CFMutableArrayRef _Nullable (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterContactFrameCallbackFn)(MTDeviceRef, MTFrameCallbackFunction);
typedef void (*MTUnregisterContactFrameCallbackFn)(MTDeviceRef, MTFrameCallbackFunction);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int);
typedef void (*MTDeviceStopFn)(MTDeviceRef);
typedef void (*MTDeviceReleaseFn)(MTDeviceRef);
typedef int32_t (*MTDeviceGetDeviceIDFn)(MTDeviceRef, uint64_t *);

typedef struct {
    MTDeviceIsAvailableFn deviceIsAvailable;
    MTDeviceCreateListFn deviceCreateList;
    MTRegisterContactFrameCallbackFn registerContactFrameCallback;
    MTUnregisterContactFrameCallbackFn unregisterContactFrameCallback;
    MTDeviceStartFn deviceStart;
    MTDeviceStopFn deviceStop;
    MTDeviceReleaseFn deviceRelease;
    MTDeviceGetDeviceIDFn deviceGetDeviceID;
} PadiumMultitouchSymbols;

static const char *PadiumMultitouchLibraryPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";

static os_log_t PadiumGestureLog(void) {
    static os_log_t log;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        log = os_log_create("com.padium", "gesture");
    });
    return log;
}

@interface PadiumMultitouchContact ()
@property (nonatomic, readwrite) NSInteger identifier;
@property (nonatomic, readwrite) float normalizedX;
@property (nonatomic, readwrite) float normalizedY;
@property (nonatomic, readwrite) float pressure;
@property (nonatomic, readwrite) PadiumMultitouchContactState state;
@property (nonatomic, readwrite) float total;
@property (nonatomic, readwrite) float majorAxis;
@end

@implementation PadiumMultitouchContact

- (instancetype)initWithIdentifier:(NSInteger)identifier
                       normalizedX:(float)normalizedX
                       normalizedY:(float)normalizedY
                          pressure:(float)pressure
                             state:(PadiumMultitouchContactState)state
                             total:(float)total
                         majorAxis:(float)majorAxis {
    self = [super init];
    if (!self) { return nil; }
    _identifier = identifier;
    _normalizedX = normalizedX;
    _normalizedY = normalizedY;
    _pressure = pressure;
    _state = state;
    _total = total;
    _majorAxis = majorAxis;
    return self;
}

@end

@interface PadiumMultitouchFrame ()
@property (nonatomic, readwrite) NSInteger deviceID;
@property (nonatomic, readwrite) NSArray<PadiumMultitouchContact *> *contacts;
@end

@implementation PadiumMultitouchFrame

- (instancetype)initWithDeviceID:(NSInteger)deviceID contacts:(NSArray<PadiumMultitouchContact *> *)contacts {
    self = [super init];
    if (!self) { return nil; }
    _deviceID = deviceID;
    _contacts = contacts;
    return self;
}

@end

@interface PadiumMultitouchBridge ()
@property (nonatomic, copy) PadiumMultitouchFrameHandler frameHandler;
@property (nonatomic, strong) NSArray *activeDevices;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@end

@implementation PadiumMultitouchBridge

static os_unfair_lock sActiveBridgeLock = OS_UNFAIR_LOCK_INIT;
static __weak PadiumMultitouchBridge *sActiveBridge = nil;

static void *PadiumResolveMultitouchSymbol(const char *name) {
    static void *libraryHandle = NULL;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        libraryHandle = dlopen(PadiumMultitouchLibraryPath, RTLD_NOW);
    });
    return libraryHandle == NULL ? NULL : dlsym(libraryHandle, name);
}

static PadiumMultitouchSymbols PadiumLoadedSymbols(void) {
    static PadiumMultitouchSymbols symbols;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        symbols.deviceIsAvailable = (MTDeviceIsAvailableFn)PadiumResolveMultitouchSymbol("MTDeviceIsAvailable");
        symbols.deviceCreateList = (MTDeviceCreateListFn)PadiumResolveMultitouchSymbol("MTDeviceCreateList");
        symbols.registerContactFrameCallback = (MTRegisterContactFrameCallbackFn)PadiumResolveMultitouchSymbol("MTRegisterContactFrameCallback");
        symbols.unregisterContactFrameCallback = (MTUnregisterContactFrameCallbackFn)PadiumResolveMultitouchSymbol("MTUnregisterContactFrameCallback");
        symbols.deviceStart = (MTDeviceStartFn)PadiumResolveMultitouchSymbol("MTDeviceStart");
        symbols.deviceStop = (MTDeviceStopFn)PadiumResolveMultitouchSymbol("MTDeviceStop");
        symbols.deviceRelease = (MTDeviceReleaseFn)PadiumResolveMultitouchSymbol("MTDeviceRelease");
        symbols.deviceGetDeviceID = (MTDeviceGetDeviceIDFn)PadiumResolveMultitouchSymbol("MTDeviceGetDeviceID");
    });
    return symbols;
}

static void PadiumMultitouchContactFrameCallback(MTDeviceRef device, MTTouch touches[], int numTouches, double timestamp, int frameID) {
    (void)timestamp;
    (void)frameID;
    os_unfair_lock_lock(&sActiveBridgeLock);
    PadiumMultitouchBridge *bridge = sActiveBridge;
    os_unfair_lock_unlock(&sActiveBridgeLock);
    [bridge handleFrameFromDevice:device touches:touches touchCount:numTouches];
}

- (instancetype)initWithFrameHandler:(PadiumMultitouchFrameHandler)frameHandler {
    self = [super init];
    if (!self) { return nil; }
    _frameHandler = [frameHandler copy];
    _activeDevices = @[];
    _callbackQueue = dispatch_queue_create("com.padium.multitouch.bridge", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (BOOL)startListening {
    if (self.isRunning) { return NO; }
    PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
    if (symbols.deviceIsAvailable == NULL || symbols.deviceCreateList == NULL || symbols.registerContactFrameCallback == NULL || symbols.deviceStart == NULL) {
        return NO;
    }
    if (!symbols.deviceIsAvailable()) { return NO; }

    NSArray *devices = CFBridgingRelease(symbols.deviceCreateList());
    if (devices.count == 0) { return NO; }

    os_unfair_lock_lock(&sActiveBridgeLock);
    sActiveBridge = self;
    os_unfair_lock_unlock(&sActiveBridgeLock);

    NSMutableArray *activeDevices = [NSMutableArray arrayWithCapacity:devices.count];
    for (id device in devices) {
        MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
        @try {
            symbols.registerContactFrameCallback(mtDevice, PadiumMultitouchContactFrameCallback);
            symbols.deviceStart(mtDevice, 0);
            [activeDevices addObject:device];
        } @catch (NSException *exception) {
            os_log_error(PadiumGestureLog(), "Failed to start multitouch device: %{public}@ (%{public}@)", exception.name, exception.reason ?: @"");
        }
    }

    if (activeDevices.count == 0) {
        os_unfair_lock_lock(&sActiveBridgeLock);
        sActiveBridge = nil;
        os_unfair_lock_unlock(&sActiveBridgeLock);
        return NO;
    }

    self.activeDevices = activeDevices;
    self.isRunning = YES;
    return YES;
}

- (void)stopListening {
    if (!self.isRunning) { return; }
    PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
    for (id device in self.activeDevices.reverseObjectEnumerator) {
        MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
        @try {
            if (symbols.unregisterContactFrameCallback != NULL) {
                symbols.unregisterContactFrameCallback(mtDevice, PadiumMultitouchContactFrameCallback);
            }
            if (symbols.deviceStop != NULL) {
                symbols.deviceStop(mtDevice);
            }
            if (symbols.deviceRelease != NULL) {
                symbols.deviceRelease(mtDevice);
            }
        } @catch (NSException *exception) {
            os_log_error(PadiumGestureLog(), "Failed to stop multitouch device: %{public}@ (%{public}@)", exception.name, exception.reason ?: @"");
        }
    }

    os_unfair_lock_lock(&sActiveBridgeLock);
    if (sActiveBridge == self) {
        sActiveBridge = nil;
    }
    os_unfair_lock_unlock(&sActiveBridgeLock);

    self.activeDevices = @[];
    self.isRunning = NO;
}

- (void)handleFrameFromDevice:(MTDeviceRef)device touches:(MTTouch *)touches touchCount:(int)touchCount {
    PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
    NSInteger deviceID = (NSInteger)(uintptr_t)device;
    if (symbols.deviceGetDeviceID != NULL) {
        uint64_t resolvedDeviceID = 0;
        if (symbols.deviceGetDeviceID(device, &resolvedDeviceID) == 0) {
            deviceID = (NSInteger)resolvedDeviceID;
        }
    }

    NSMutableArray<PadiumMultitouchContact *> *contacts = [NSMutableArray arrayWithCapacity:MAX(0, touchCount)];
    for (int index = 0; index < touchCount; index += 1) {
        MTTouch touch = touches[index];
        PadiumMultitouchContact *contact = [[PadiumMultitouchContact alloc]
                                            initWithIdentifier:touch.identifier
                                            normalizedX:touch.normalizedPosition.position.x
                                            normalizedY:touch.normalizedPosition.position.y
                                            pressure:touch.pressure
                                            state:(PadiumMultitouchContactState)touch.state
                                            total:touch.total
                                            majorAxis:touch.majorAxis];
        [contacts addObject:contact];
    }

    PadiumMultitouchFrame *frame = [[PadiumMultitouchFrame alloc] initWithDeviceID:deviceID contacts:contacts];
    dispatch_async(self.callbackQueue, ^{
        self.frameHandler(frame);
    });
}

@end
