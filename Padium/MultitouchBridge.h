#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PadiumMultitouchContactState) {
    PadiumMultitouchContactStateNotTouching = 0,
    PadiumMultitouchContactStateStarting = 1,
    PadiumMultitouchContactStateHovering = 2,
    PadiumMultitouchContactStateMaking = 3,
    PadiumMultitouchContactStateTouching = 4,
    PadiumMultitouchContactStateBreaking = 5,
    PadiumMultitouchContactStateLingering = 6,
    PadiumMultitouchContactStateLeaving = 7,
};

@interface PadiumMultitouchContact : NSObject

@property (nonatomic, readonly) NSInteger identifier;
@property (nonatomic, readonly) float normalizedX;
@property (nonatomic, readonly) float normalizedY;
@property (nonatomic, readonly) float pressure;
@property (nonatomic, readonly) PadiumMultitouchContactState state;
@property (nonatomic, readonly) float total;
@property (nonatomic, readonly) float majorAxis;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithIdentifier:(NSInteger)identifier
                       normalizedX:(float)normalizedX
                       normalizedY:(float)normalizedY
                          pressure:(float)pressure
                             state:(PadiumMultitouchContactState)state
                             total:(float)total
                         majorAxis:(float)majorAxis NS_DESIGNATED_INITIALIZER;

@end

@interface PadiumMultitouchFrame : NSObject

@property (nonatomic, readonly) NSInteger deviceID;
@property (nonatomic, readonly) NSArray<PadiumMultitouchContact *> *contacts;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithDeviceID:(NSInteger)deviceID
                         contacts:(NSArray<PadiumMultitouchContact *> *)contacts NS_DESIGNATED_INITIALIZER;

@end

typedef void (^PadiumMultitouchFrameHandler)(PadiumMultitouchFrame *frame);

@interface PadiumMultitouchBridge : NSObject

- (instancetype)initWithFrameHandler:(PadiumMultitouchFrameHandler)frameHandler NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startListening;
- (void)stopListening;

@end

NS_ASSUME_NONNULL_END
