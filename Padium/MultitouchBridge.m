#import "MultitouchBridge.h"

#import <dlfcn.h>
#import <IOKit/IOKitLib.h>
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
typedef int32_t (*MTDeviceGetDeviceIDFn)(MTDeviceRef, uint64_t *);
typedef io_service_t (*MTDeviceGetServiceFn)(MTDeviceRef);

typedef struct {
    MTDeviceIsAvailableFn deviceIsAvailable;
    MTDeviceCreateListFn deviceCreateList;
    MTRegisterContactFrameCallbackFn registerContactFrameCallback;
    MTUnregisterContactFrameCallbackFn unregisterContactFrameCallback;
    MTDeviceStartFn deviceStart;
    MTDeviceStopFn deviceStop;
    MTDeviceGetDeviceIDFn deviceGetDeviceID;
    MTDeviceGetServiceFn deviceGetService;
} PadiumMultitouchSymbols;

static const char *PadiumMultitouchLibraryPath = "/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport";
static const char *PadiumMultitouchServiceName = "AppleMultitouchDevice";
static const int64_t PadiumDeviceRefreshIntervalNanoseconds = NSEC_PER_SEC;
static const int64_t PadiumDeviceRefreshLeewayNanoseconds = NSEC_PER_SEC / 5;
static char PadiumMultitouchBridgeCallbackQueueKey;

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
@property (nonatomic, copy, nullable) PadiumMultitouchDeviceResetHandler deviceResetHandler;
@property (nonatomic, strong) NSArray *activeDevices;
@property (nonatomic, assign) BOOL isRunning;
@property (nonatomic, strong) dispatch_queue_t callbackQueue;
@property (nonatomic, strong, nullable) dispatch_source_t deviceRefreshTimer;
@property (nonatomic, assign) IONotificationPortRef deviceNotificationPort;
@property (nonatomic, assign) io_iterator_t deviceMatchedIterator;
@property (nonatomic, assign) io_iterator_t deviceTerminatedIterator;

- (void)handleDeviceTopologyNotification:(io_iterator_t)iterator;
- (nullable NSString *)registrationIdentityForDevice:(MTDeviceRef)device symbols:(PadiumMultitouchSymbols)symbols;
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
        symbols.deviceGetDeviceID = (MTDeviceGetDeviceIDFn)PadiumResolveMultitouchSymbol("MTDeviceGetDeviceID");
        symbols.deviceGetService = (MTDeviceGetServiceFn)PadiumResolveMultitouchSymbol("MTDeviceGetService");
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

static void PadiumMultitouchDeviceNotification(void *refcon, io_iterator_t iterator) {
    PadiumMultitouchBridge *bridge = (__bridge PadiumMultitouchBridge *)refcon;
    [bridge handleDeviceTopologyNotification:iterator];
}

- (instancetype)initWithFrameHandler:(PadiumMultitouchFrameHandler)frameHandler {
    return [self initWithFrameHandler:frameHandler deviceResetHandler:nil];
}

- (instancetype)initWithFrameHandler:(PadiumMultitouchFrameHandler)frameHandler
                  deviceResetHandler:(PadiumMultitouchDeviceResetHandler)deviceResetHandler {
    self = [super init];
    if (!self) { return nil; }
    _frameHandler = [frameHandler copy];
    _deviceResetHandler = [deviceResetHandler copy];
    _activeDevices = @[];
    _callbackQueue = dispatch_queue_create("com.padium.multitouch.bridge", DISPATCH_QUEUE_SERIAL);
    dispatch_queue_set_specific(_callbackQueue,
                                &PadiumMultitouchBridgeCallbackQueueKey,
                                &PadiumMultitouchBridgeCallbackQueueKey,
                                NULL);
    return self;
}

- (BOOL)startListening {
    __block BOOL started = NO;
    [self performOnCallbackQueueAndWait:^{
        started = [self startListeningOnCallbackQueue];
    }];
    return started;
}

- (void)stopListening {
    [self performOnCallbackQueueAndWait:^{
        [self stopListeningOnCallbackQueue];
    }];
}

- (void)performOnCallbackQueueAndWait:(dispatch_block_t)block {
    if (dispatch_get_specific(&PadiumMultitouchBridgeCallbackQueueKey) != NULL) {
        block();
        return;
    }

    dispatch_sync(self.callbackQueue, block);
}

- (BOOL)startListeningOnCallbackQueue {
    if (self.isRunning) { return NO; }

    PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
    if (![self hasRequiredSymbols:symbols]) {
        return NO;
    }

    self.isRunning = YES;
    [self setActiveBridgeToSelf];
    [self startDeviceNotificationsOnCallbackQueue];
    [self startDeviceRefreshTimerOnCallbackQueue];
    [self refreshDeviceRegistrationsOnCallbackQueueWithSymbols:symbols force:YES];
    return YES;
}

- (void)stopListeningOnCallbackQueue {
    if (!self.isRunning) { return; }

    [self stopDeviceRefreshTimerOnCallbackQueue];
    [self stopDeviceNotificationsOnCallbackQueue];

    PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
    [self stopActiveDevicesOnCallbackQueueWithSymbols:symbols];
    self.activeDevices = @[];
    self.isRunning = NO;
    [self clearActiveBridgeIfNeeded];
}

- (BOOL)hasRequiredSymbols:(PadiumMultitouchSymbols)symbols {
    return symbols.deviceIsAvailable != NULL
        && symbols.deviceCreateList != NULL
        && symbols.registerContactFrameCallback != NULL
        && symbols.deviceStart != NULL;
}

- (void)startDeviceRefreshTimerOnCallbackQueue {
    if (self.deviceRefreshTimer != nil) { return; }

    // MultitouchSupport exposes frame callbacks for known devices, but public
    // reverse-engineered consumers handle hotplug by re-enumerating devices.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.callbackQueue);
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, PadiumDeviceRefreshIntervalNanoseconds),
                              PadiumDeviceRefreshIntervalNanoseconds,
                              PadiumDeviceRefreshLeewayNanoseconds);

    __weak PadiumMultitouchBridge *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        PadiumMultitouchBridge *strongSelf = weakSelf;
        if (strongSelf == nil || !strongSelf.isRunning) { return; }

        PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
        [strongSelf refreshDeviceRegistrationsOnCallbackQueueWithSymbols:symbols force:NO];
    });

    self.deviceRefreshTimer = timer;
    dispatch_resume(timer);
}

- (void)stopDeviceRefreshTimerOnCallbackQueue {
    if (self.deviceRefreshTimer == nil) { return; }
    dispatch_source_cancel(self.deviceRefreshTimer);
    self.deviceRefreshTimer = nil;
}

- (void)startDeviceNotificationsOnCallbackQueue {
    if (self.deviceNotificationPort != NULL) { return; }

    IONotificationPortRef notificationPort = IONotificationPortCreate(kIOMainPortDefault);
    if (notificationPort == NULL) {
        os_log_error(PadiumGestureLog(), "Failed to create multitouch device notification port");
        return;
    }

    IONotificationPortSetDispatchQueue(notificationPort, self.callbackQueue);
    self.deviceNotificationPort = notificationPort;

    kern_return_t matchedResult = IOServiceAddMatchingNotification(
        notificationPort,
        kIOMatchedNotification,
        IOServiceMatching(PadiumMultitouchServiceName),
        PadiumMultitouchDeviceNotification,
        (__bridge void *)self,
        &_deviceMatchedIterator
    );
    if (matchedResult != KERN_SUCCESS) {
        os_log_error(PadiumGestureLog(), "Failed to observe multitouch device matches: %{public}d", matchedResult);
        [self stopDeviceNotificationsOnCallbackQueue];
        return;
    }
    [self drainDeviceIteratorOnCallbackQueue:self.deviceMatchedIterator];

    kern_return_t terminatedResult = IOServiceAddMatchingNotification(
        notificationPort,
        kIOTerminatedNotification,
        IOServiceMatching(PadiumMultitouchServiceName),
        PadiumMultitouchDeviceNotification,
        (__bridge void *)self,
        &_deviceTerminatedIterator
    );
    if (terminatedResult != KERN_SUCCESS) {
        os_log_error(PadiumGestureLog(), "Failed to observe multitouch device terminations: %{public}d", terminatedResult);
        [self stopDeviceNotificationsOnCallbackQueue];
        return;
    }
    [self drainDeviceIteratorOnCallbackQueue:self.deviceTerminatedIterator];
}

- (void)stopDeviceNotificationsOnCallbackQueue {
    if (self.deviceMatchedIterator != IO_OBJECT_NULL) {
        IOObjectRelease(self.deviceMatchedIterator);
        self.deviceMatchedIterator = IO_OBJECT_NULL;
    }
    if (self.deviceTerminatedIterator != IO_OBJECT_NULL) {
        IOObjectRelease(self.deviceTerminatedIterator);
        self.deviceTerminatedIterator = IO_OBJECT_NULL;
    }
    if (self.deviceNotificationPort != NULL) {
        IONotificationPortDestroy(self.deviceNotificationPort);
        self.deviceNotificationPort = NULL;
    }
}

- (void)handleDeviceTopologyNotification:(io_iterator_t)iterator {
    BOOL didObserveDeviceChange = [self drainDeviceIteratorOnCallbackQueue:iterator];
    if (!didObserveDeviceChange || !self.isRunning) { return; }

    PadiumMultitouchSymbols symbols = PadiumLoadedSymbols();
    [self refreshDeviceRegistrationsOnCallbackQueueWithSymbols:symbols force:YES];
}

- (BOOL)drainDeviceIteratorOnCallbackQueue:(io_iterator_t)iterator {
    BOOL didObserveDevice = NO;
    io_object_t service = IO_OBJECT_NULL;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        didObserveDevice = YES;
        IOObjectRelease(service);
    }
    return didObserveDevice;
}

- (void)refreshDeviceRegistrationsOnCallbackQueueWithSymbols:(PadiumMultitouchSymbols)symbols force:(BOOL)force {
    if (![self hasRequiredSymbols:symbols]) { return; }

    NSArray *devices = @[];
    if (symbols.deviceIsAvailable()) {
        devices = CFBridgingRelease(symbols.deviceCreateList()) ?: @[];
    }

    if (!force && [self activeDevicesMatchDevices:devices symbols:symbols]) {
        return;
    }

    os_log_info(PadiumGestureLog(),
                "Refreshing multitouch devices: %{public}lu -> %{public}lu",
                (unsigned long)self.activeDevices.count,
                (unsigned long)devices.count);

    [self notifyDeviceResetOnCallbackQueue];
    [self stopActiveDevicesOnCallbackQueueWithSymbols:symbols];
    self.activeDevices = [self startDevicesOnCallbackQueue:devices symbols:symbols];
    [self setActiveBridgeToSelf];
}

- (BOOL)activeDevicesMatchDevices:(NSArray *)devices symbols:(PadiumMultitouchSymbols)symbols {
    NSArray<NSString *> *activeSignature = [self deviceRegistrationSignatureForDevices:self.activeDevices symbols:symbols];
    NSArray<NSString *> *newSignature = [self deviceRegistrationSignatureForDevices:devices symbols:symbols];
    if (activeSignature != nil && newSignature != nil) {
        return [activeSignature isEqualToArray:newSignature];
    }

    return self.activeDevices.count == devices.count;
}

- (NSArray<NSString *> *)deviceRegistrationSignatureForDevices:(NSArray *)devices symbols:(PadiumMultitouchSymbols)symbols {
    NSMutableArray<NSString *> *deviceSignatures = [NSMutableArray arrayWithCapacity:devices.count];
    for (id device in devices) {
        MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
        NSString *deviceSignature = [self registrationIdentityForDevice:mtDevice symbols:symbols];
        if (deviceSignature == nil) {
            return nil;
        }
        [deviceSignatures addObject:deviceSignature];
    }

    return [deviceSignatures sortedArrayUsingSelector:@selector(compare:)];
}

- (nullable NSString *)registrationIdentityForDevice:(MTDeviceRef)device symbols:(PadiumMultitouchSymbols)symbols {
    if (symbols.deviceGetService != NULL) {
        io_service_t service = symbols.deviceGetService(device);
        uint64_t registryEntryID = 0;
        if (service != IO_OBJECT_NULL && IORegistryEntryGetRegistryEntryID(service, &registryEntryID) == KERN_SUCCESS) {
            return [NSString stringWithFormat:@"service:%llu", (unsigned long long)registryEntryID];
        }
    }

    if (symbols.deviceGetDeviceID != NULL) {
        uint64_t resolvedDeviceID = 0;
        if (symbols.deviceGetDeviceID(device, &resolvedDeviceID) == 0) {
            return [NSString stringWithFormat:@"device:%llu", (unsigned long long)resolvedDeviceID];
        }
    }

    return nil;
}

- (NSArray *)startDevicesOnCallbackQueue:(NSArray *)devices symbols:(PadiumMultitouchSymbols)symbols {
    NSMutableArray *activeDevices = [NSMutableArray arrayWithCapacity:devices.count];
    for (id device in devices) {
        MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
        @try {
            symbols.registerContactFrameCallback(mtDevice, PadiumMultitouchContactFrameCallback);
            symbols.deviceStart(mtDevice, 0);
            [activeDevices addObject:device];
        } @catch (NSException *exception) {
            os_log_error(PadiumGestureLog(),
                         "Failed to start multitouch device: %{public}@ (%{public}@)",
                         exception.name,
                         exception.reason ?: @"");
        }
    }

    return activeDevices;
}

- (void)stopActiveDevicesOnCallbackQueueWithSymbols:(PadiumMultitouchSymbols)symbols {
    for (id device in self.activeDevices.reverseObjectEnumerator) {
        MTDeviceRef mtDevice = (__bridge MTDeviceRef)device;
        @try {
            if (symbols.unregisterContactFrameCallback != NULL) {
                symbols.unregisterContactFrameCallback(mtDevice, PadiumMultitouchContactFrameCallback);
            }
            if (symbols.deviceStop != NULL) {
                symbols.deviceStop(mtDevice);
            }
        } @catch (NSException *exception) {
            os_log_error(PadiumGestureLog(),
                         "Failed to stop multitouch device: %{public}@ (%{public}@)",
                         exception.name,
                         exception.reason ?: @"");
        }
    }
}

- (void)notifyDeviceResetOnCallbackQueue {
    if (self.deviceResetHandler != nil) {
        self.deviceResetHandler();
    }
}

- (void)setActiveBridgeToSelf {
    os_unfair_lock_lock(&sActiveBridgeLock);
    sActiveBridge = self;
    os_unfair_lock_unlock(&sActiveBridgeLock);
}

- (void)clearActiveBridgeIfNeeded {
    os_unfair_lock_lock(&sActiveBridgeLock);
    if (sActiveBridge == self) {
        sActiveBridge = nil;
    }
    os_unfair_lock_unlock(&sActiveBridgeLock);
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
