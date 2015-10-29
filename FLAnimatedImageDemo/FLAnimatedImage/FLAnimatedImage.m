//
//  FLAnimatedImage.m
//  Flipboard
//
//  Created by Raphael Schaad on 7/8/13.
//  Copyright (c) 2013-2015 Flipboard. All rights reserved.
//


#import "FLAnimatedImage.h"
#import <ImageIO/ImageIO.h>
#import <MobileCoreServices/MobileCoreServices.h>


// From vm_param.h, define for iOS 8.0 or higher to build on device.
#ifndef BYTE_SIZE
    #define BYTE_SIZE 8 // byte size in bits
#endif

#define MEGABYTE (1024 * 1024)

#if FLLumberjackIntegrationEnabled && defined(FLLumberjackAvailable)
    #if DEBUG
        #if defined(LOG_LEVEL_DEBUG) // CocoaLumberjack 1.x
            int flAnimatedImageLogLevel = LOG_LEVEL_DEBUG;
        #else // CocoaLumberjack 2.x
            int flAnimatedImageLogLevel = DDLogFlagDebug;
        #endif
    #else
        #if defined(LOG_LEVEL_WARN) // CocoaLumberjack 1.x
            int flAnimatedImageLogLevel = LOG_LEVEL_WARN;
        #else // CocoaLumberjack 2.x
            int flAnimatedImageLogLevel = DDLogFlagWarning;
        #endif
    #endif
#endif


// An animated image's data size (dimensions * frameCount) category; its value is the max allowed memory (in MB).
// E.g.: A 100x200px GIF with 30 frames is ~2.3MB in our pixel format and would fall into the `FLAnimatedImageDataSizeCategoryAll` category.
typedef NS_ENUM(NSUInteger, FLAnimatedImageDataSizeCategory) {
    FLAnimatedImageDataSizeCategoryAll = 10,       // All frames permanently in memory (be nice to the CPU)
    FLAnimatedImageDataSizeCategoryDefault = 75,   // A frame cache of default size in memory (usually real-time performance and keeping low memory profile)
    FLAnimatedImageDataSizeCategoryOnDemand = 250, // Only keep one frame at the time in memory (easier on memory, slowest performance)
    FLAnimatedImageDataSizeCategoryUnsupported     // Even for one frame too large, computer says no.
};

typedef NS_ENUM(NSUInteger, FLAnimatedImageFrameCacheSize) {
    FLAnimatedImageFrameCacheSizeNoLimit = 0,                // 0 means no specific limit
    FLAnimatedImageFrameCacheSizeLowMemory = 1,              // The minimum frame cache size; this will produce frames on-demand.
    FLAnimatedImageFrameCacheSizeGrowAfterMemoryWarning = 2, // If we can produce the frames faster than we consume, one frame ahead will already result in a stutter-free playback.
    FLAnimatedImageFrameCacheSizeDefault = 5                 // Build up a comfy buffer window to cope with CPU hiccups etc.
};


@interface FLAnimatedImage ()

@property (nonatomic, assign, readonly) NSUInteger frameCacheSizeOptimal; // The optimal number of frames to cache based on image size & number of frames; never changes
@property (nonatomic, assign) NSUInteger frameCacheSizeMaxInternal; // Allow to cap the cache size e.g. when memory warnings occur; 0 means no specific limit (default)
@property (nonatomic, assign) NSUInteger requestedFrameIndex; // Most recently requested frame index
@property (nonatomic, strong, readonly) NSMutableArray *cachedFrames; // Uncached frame indexes hold `NSNull`
@property (nonatomic, strong, readonly) NSMutableIndexSet *cachedFrameIndexes; // Indexes of cached frames
@property (nonatomic, strong, readonly) NSMutableIndexSet *requestedFrameIndexes; // Indexes of frames that are currently produced in the background
@property (nonatomic, strong, readonly) NSIndexSet *allFramesIndexSet; // Default index set with the full range of indexes; never changes
@property (nonatomic, assign) NSUInteger memoryWarningCount;
@property (nonatomic, strong, readonly) dispatch_queue_t serialQueue;
@property (nonatomic, strong, readonly) __attribute__((NSObject)) CGImageSourceRef imageSource;

// The weak proxy is used to break retain cycles with delayed actions from memory warnings.
// We are lying about the actual type here to gain static type checking and eliminate casts.
// The actual type of the object is `FLWeakProxy`.
@property (nonatomic, strong, readonly) FLAnimatedImage *weakProxy;

@end


// For custom dispatching of memory warnings to avoid deallocation races since NSNotificationCenter doesn't retain objects it is notifying.
static NSHashTable *allAnimatedImagesWeak;

@implementation FLAnimatedImage

#pragma mark - Accessors
#pragma mark Public

// This is the definite value the frame cache needs to size itself to.
- (NSUInteger)frameCacheSizeCurrent
{
    NSUInteger frameCacheSizeCurrent = self.frameCacheSizeOptimal;
    
    // If set, respect the caps.
    if (self.frameCacheSizeMax > FLAnimatedImageFrameCacheSizeNoLimit) {
        frameCacheSizeCurrent = MIN(frameCacheSizeCurrent, self.frameCacheSizeMax);
    }
    
    if (self.frameCacheSizeMaxInternal > FLAnimatedImageFrameCacheSizeNoLimit) {
        frameCacheSizeCurrent = MIN(frameCacheSizeCurrent, self.frameCacheSizeMaxInternal);
    }
    
    return frameCacheSizeCurrent;
}


- (void)setFrameCacheSizeMax:(NSUInteger)frameCacheSizeMax
{
    if (_frameCacheSizeMax != frameCacheSizeMax) {
        
        // Remember whether the new cap will cause the current cache size to shrink; then we'll make sure to purge from the cache if needed.
        BOOL willFrameCacheSizeShrink = (frameCacheSizeMax < self.frameCacheSizeCurrent);
        
        // Update the value
        _frameCacheSizeMax = frameCacheSizeMax;
        
        if (willFrameCacheSizeShrink) {
            [self purgeFrameCacheIfNeeded];
        }
    }
}


#pragma mark Private

- (void)setFrameCacheSizeMaxInternal:(NSUInteger)frameCacheSizeMaxInternal
{
    if (_frameCacheSizeMaxInternal != frameCacheSizeMaxInternal) {
        
        // Remember whether the new cap will cause the current cache size to shrink; then we'll make sure to purge from the cache if needed.
        BOOL willFrameCacheSizeShrink = (frameCacheSizeMaxInternal < self.frameCacheSizeCurrent);
        
        // Update the value
        _frameCacheSizeMaxInternal = frameCacheSizeMaxInternal;
        
        if (willFrameCacheSizeShrink) {
            [self purgeFrameCacheIfNeeded];
        }
    }
}


#pragma mark - Life Cycle

+ (void)initialize
{
    if (self == [FLAnimatedImage class]) {
        // UIKit memory warning notification handler shared by all of the instances
        allAnimatedImagesWeak = [NSHashTable weakObjectsHashTable];
        
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(NSNotification *note) {
            // UIKit notifications are posted on the main thread. didReceiveMemoryWarning: is expecting the main run loop, and we don't lock on allAnimatedImagesWeak
            NSAssert([NSThread isMainThread], @"Received memory warning on non-main thread");
            // Get a strong reference to all of the images. If an instance is returned in this array, it is still live and has not entered dealloc.
            // Note that FLAnimatedImages can be created on any thread, so the hash table must be locked.
            NSArray *images = nil;
            @synchronized(allAnimatedImagesWeak) {
                images = [[allAnimatedImagesWeak allObjects] copy];
            }
            // Now issue notifications to all of the images while holding a strong reference to them
            [images makeObjectsPerformSelector:@selector(didReceiveMemoryWarning:) withObject:note];
        }];
    }
}


- (instancetype)initWithImageData:(NSData *)data
{
    return [self initWithImageData:data mode:FLAnimatedImageInitModeDefault];
}


- (instancetype)initWithImageData:(NSData *)data mode:(FLAnimatedImageInitMode)mode
{
    return [self initWithImageData:data mode:mode scale:1.0];
}


- (instancetype)initWithImageData:(NSData *)data scale:(CGFloat)scale
{
    return [self initWithImageData:data mode:FLAnimatedImageInitModeDefault scale:scale];
}


- (instancetype)initWithImageData:(NSData *)data mode:(FLAnimatedImageInitMode)mode scale:(CGFloat)scale
{
    self = [super initWithData:data scale:scale];
    if (self) {
        [self prepareAnimatedImageWithData:data mode:mode];
    }
    return self;
}


+ (instancetype)imageWithData:(NSData *)data mode:(FLAnimatedImageInitMode)mode
{
    return [self imageWithData:data mode:mode scale:1.0];
}


+ (instancetype)imageWithData:(NSData *)data mode:(FLAnimatedImageInitMode)mode scale:(CGFloat)scale
{
    return [[FLAnimatedImage alloc] initWithImageData:data mode:mode scale:scale];
}


#pragma mark Adopting UIImage Convenience Factory Methods

+ (instancetype)imageNamed:(NSString *)name
{
    return [self imageNamed:name inBundle:[NSBundle mainBundle] compatibleWithTraitCollection:nil];
}


+ (instancetype)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traitCollection
{
    return [self imageNamed:name inBundle:bundle compatibleWithTraitCollection:traitCollection mode:FLAnimatedImageInitModeDefault];
}


+ (instancetype)imageWithContentsOfFile:(NSString *)path
{
    return [[FLAnimatedImage alloc] initWithContentsOfFile:path];
}


+ (instancetype)imageWithData:(NSData *)data
{
    return [self imageWithData:data scale:1.0];
}


+ (instancetype)imageWithData:(NSData *)data scale:(CGFloat)scale
{
    return [[FLAnimatedImage alloc] initWithImageData:data mode:FLAnimatedImageInitModeDefault scale:scale];
}


#pragma mark Init Helpers

// This worker method including `mode` remains unexposed to keep the header cleaner.
+ (instancetype)imageNamed:(NSString *)name inBundle:(NSBundle *)bundle compatibleWithTraitCollection:(UITraitCollection *)traitCollection mode:(FLAnimatedImageInitMode)mode
{
    FLAnimatedImage *animatedImage = nil;
    
    // By going through super we preserve the lookup and caching behavior.
    UIImage *image = nil;
    if([UIImage respondsToSelector:@selector(imageNamed:inBundle:compatibleWithTraitCollection:)]){
        image = [super imageNamed:name inBundle:bundle compatibleWithTraitCollection:traitCollection];
    }
    else{
        image = [self imageNamed:name
                        inBundle:bundle];
    }

    if (image) {
        animatedImage = [[self alloc] initWithCGImage:image.CGImage scale:image.scale orientation:image.imageOrientation];
        NSString *path = [bundle pathForResource:name ofType:nil];
        NSData *data = [NSData dataWithContentsOfFile:path];
        [animatedImage prepareAnimatedImageWithData:data mode:mode];
    }
    
    return animatedImage;
}

+ (UIImage *)imageNamed:(NSString *)imageName
               inBundle:(NSBundle *)bundle{
    NSBundle *mainBundle = [NSBundle mainBundle];
    // The path to take the image from must be related to the main bundle because that's how native imageNamed method works. So we remove the main bundle's path from the given bundle's path.
    
    NSString *imagePath = nil;
    if ([bundle.bundlePath isEqualToString:mainBundle.bundlePath] == YES) {
        // Is main bundle
        imagePath = [NSString stringWithFormat:@"%@", imageName];
    } else {
        NSString *bundleName = [[bundle.bundlePath componentsSeparatedByString:@"/"] lastObject];
        imagePath = [NSString stringWithFormat:@"%@/%@", bundleName, imageName];
    }
    
    UIImage *image = [UIImage imageNamed:imagePath];
    return image;
}

- (void)prepareAnimatedImageWithData:(NSData *)data mode:(FLAnimatedImageInitMode)mode
{
    // Do one-time initializations of `readonly` properties directly to ivar to prevent implicit actions and avoid need for private `readwrite` property overrides.
    
    // Keep a strong reference to `data` and expose it read-only publicly.
    // However, we will use the `_imageSource` as handler to the image data throughout our life cycle.
//    _data = data;
    
    _mode = mode;
    
    // Note: We could leverage `CGImageSourceCreateWithURL` too to add additional initializers
    _imageSource = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!_imageSource) {
        FLLogInfo(@"Won't animate: Failed to `CGImageSourceCreateWithData` for data %@", data);
        return; // Early return on failure!
    }
    
    size_t imageCount = CGImageSourceGetCount(_imageSource);
    if (imageCount <= 0) {
        FLLogInfo(@"Won't animate: No frames in data %@", data);
        CFRelease(_imageSource);
        _imageSource = nil;
        return; // Early return when we don't have any frames!
    }
    if (imageCount == 1) {
        FLLogInfo(@"Won't animate: Single frame in data %@", data);
        CFRelease(_imageSource);
        _imageSource = nil;
        return; // Early return when we only have a single frame!
    }
    
    CFStringRef imageSourceContainerType = CGImageSourceGetType(_imageSource);
    BOOL isGIFData = UTTypeConformsTo(imageSourceContainerType, kUTTypeGIF);
    if (!isGIFData) {
        FLLogInfo(@"Won't animate: Supplied data is of type %@ and doesn't seem to be GIF data %@", imageSourceContainerType, data);
        CFRelease(_imageSource);
        _imageSource = nil;
        return; // Early return if not GIF!
    }
    
    if (mode == FLAnimatedImageInitModeDefault) {
        
    } else if (mode == FLAnimatedImageInitModeLazy) {
#warning Implement
    } else if (mode == FLAnimatedImageInitModeFull) {
#warning Implement
    } else {
        FLLogError(@"Unsupported `FLAnimatedImageInitMode`");
    }
    
    // Initialize internal data structures
    // We'll fill in the initial `NSNull` values below, when we loop through all frames.
    _cachedFrames = [[NSMutableArray alloc] init];
    _cachedFrameIndexes = [[NSMutableIndexSet alloc] init];
    _requestedFrameIndexes = [[NSMutableIndexSet alloc] init];
    
    
    // Get `LoopCount`
    // Note: 0 means repeating the animation indefinitely.
    // Image properties example:
    // {
    //     FileSize = 314446;
    //     "{GIF}" = {
    //         HasGlobalColorMap = 1;
    //         LoopCount = 0;
    //     };
    // }
    NSDictionary *imageProperties = (__bridge_transfer NSDictionary *)CGImageSourceCopyProperties(_imageSource, NULL);
    _loopCount = [[[imageProperties objectForKey:(id)kCGImagePropertyGIFDictionary] objectForKey:(id)kCGImagePropertyGIFLoopCount] unsignedIntegerValue];
    
    // Iterate through frame images
    NSMutableArray *delayTimesMutable = [NSMutableArray arrayWithCapacity:imageCount];
    for (size_t i = 0; i < imageCount; i++) {
        CGImageRef frameImageRef = CGImageSourceCreateImageAtIndex(_imageSource, i, NULL);
        if (frameImageRef) {
            UIImage *frameImage = [UIImage imageWithCGImage:frameImageRef scale:self.scale orientation:self.imageOrientation];
            // Check for valid `frameImage` before parsing its properties as frames can be corrupted (and `frameImage` even `nil` when `frameImageRef` was valid).
            if (frameImage) {
                // Placeholder indicates that we don't have a cached frame.
                // We use an array instead of a dictionary for slightly faster access.
                self.cachedFrames[i] = [NSNull null];
                
                // Get `DelayTime`
                // Note: It's not in (1/100) of a second like still falsely described in the documentation as per iOS 8 (rdar://19507384) but in seconds stored as `kCFNumberFloat32Type`.
                // Frame properties example:
                // {
                //     ColorModel = RGB;
                //     Depth = 8;
                //     PixelHeight = 960;
                //     PixelWidth = 640;
                //     "{GIF}" = {
                //         DelayTime = "0.4";
                //         UnclampedDelayTime = "0.4";
                //     };
                // }
                
                NSDictionary *frameProperties = (__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(_imageSource, i, NULL);
                NSDictionary *framePropertiesGIF = [frameProperties objectForKey:(id)kCGImagePropertyGIFDictionary];
                
                // Try to use the unclamped delay time; fall back to the normal delay time.
                NSNumber *delayTime = [framePropertiesGIF objectForKey:(id)kCGImagePropertyGIFUnclampedDelayTime];
                if (!delayTime) {
                    delayTime = [framePropertiesGIF objectForKey:(id)kCGImagePropertyGIFDelayTime];
                }
                // If we don't get a delay time from the properties, fall back to `kDelayTimeIntervalDefault` or carry over the preceding frame's value.
                const NSTimeInterval kDelayTimeIntervalDefault = 0.1;
                if (!delayTime) {
                    if (i == 0) {
                        FLLogInfo(@"Falling back to default delay time for first frame %@ because none found in GIF properties %@", frameImage, frameProperties);
                        delayTime = @(kDelayTimeIntervalDefault);
                    } else {
                        FLLogInfo(@"Falling back to preceding delay time for frame %zu %@ because none found in GIF properties %@", i, frameImage, frameProperties);
                        delayTime = delayTimesMutable[i - 1];
                    }
                }
                // Support frame delays as low as `kDelayTimeIntervalMinimum`, with anything below being rounded up to `kDelayTimeIntervalDefault` for legacy compatibility.
                // This is how the fastest browsers do it as per 2012: http://nullsleep.tumblr.com/post/16524517190/animated-gif-minimum-frame-delay-browser-compatibility
                const NSTimeInterval kDelayTimeIntervalMinimum = 0.02;
                // To support the minimum even when rounding errors occur, use an epsilon when comparing. We downcast to float because that's what we get for delayTime from ImageIO.
                if ([delayTime floatValue] < ((float)kDelayTimeIntervalMinimum - FLT_EPSILON)) {
                    FLLogInfo(@"Rounding frame %zu's `delayTime` from %f up to default %f (minimum supported: %f).", i, [delayTime floatValue], kDelayTimeIntervalDefault, kDelayTimeIntervalMinimum);
                    delayTime = @(kDelayTimeIntervalDefault);
                }
                delayTimesMutable[i] = delayTime;
            } else {
                FLLogInfo(@"Dropping frame %zu because valid `CGImageRef` %@ did result in `nil`-`UIImage`.", i, frameImageRef);
            }
            CFRelease(frameImageRef);
        } else {
            FLLogInfo(@"Dropping frame %zu because failed to `CGImageSourceCreateImageAtIndex` with image source %@", i, _imageSource);
        }
    }
    _delayTimes = [delayTimesMutable copy];
    _frameCount = [_delayTimes count];
    
    // Calculate the optimal frame cache size: try choosing a larger buffer window depending on the predicted image size.
    // It's only dependent on the image size & number of frames and never changes.
    CGFloat animatedImageDataSize = CGImageGetBytesPerRow(self.CGImage) * self.size.height * self.scale * self.frameCount / MEGABYTE;
    if (animatedImageDataSize <= FLAnimatedImageDataSizeCategoryAll) {
        _frameCacheSizeOptimal = self.frameCount;
    } else if (animatedImageDataSize <= FLAnimatedImageDataSizeCategoryDefault) {
        // This value doesn't depend on device memory much because if we're not keeping all frames in memory we will always be decoding 1 frame up ahead per 1 frame that gets played and at this point we might as well just keep a small buffer just large enough to keep from running out of frames.
        _frameCacheSizeOptimal = FLAnimatedImageFrameCacheSizeDefault;
    } else {
        // The predicted size exceeds the limits to build up a cache and we go into low memory mode from the beginning.
        _frameCacheSizeOptimal = FLAnimatedImageFrameCacheSizeLowMemory;
    }
    // In any case, cap the optimal cache size at the frame count.
    _frameCacheSizeOptimal = MIN(_frameCacheSizeOptimal, self.frameCount);
    
    // Convenience/minor performance optimization; keep an index set handy with the full range to return in `-frameIndexesToCache`.
    _allFramesIndexSet = [[NSIndexSet alloc] initWithIndexesInRange:NSMakeRange(0, self.frameCount)];
    
    // See the property declarations for descriptions.
    _weakProxy = (id)[FLWeakProxy weakProxyForObject:self];
    
    // Register this instance in the weak table for memory notifications. The NSHashTable will clean up after itself when we're gone.
    // Note that FLAnimatedImages can be created on any thread, so the hash table must be locked.
    @synchronized(allAnimatedImagesWeak) {
        [allAnimatedImagesWeak addObject:self];
    }
}


#pragma mark Teardown

- (void)dealloc
{
    if (_weakProxy) {
        [NSObject cancelPreviousPerformRequestsWithTarget:_weakProxy];
    }
    
    if (_imageSource) {
        CFRelease(_imageSource);
        _imageSource = nil;
    }
}


#pragma mark - UIImage Animation Properties Overrides

- (NSArray *)images
{
    return [self valueForKey:@"frames"];
}


- (NSTimeInterval)duration
{
#warning What if this hasn't been initialized yet?
#warning Cache this calculation?
    return [[self.delayTimes valueForKeyPath:@"@sum.self"] doubleValue];
}


#pragma mark - KVC Collection Proxy

- (NSUInteger)countOfFrames
{
#warning What if this hasn't been initialized yet?
    return self.frameCount;
}


#warning Should repeat images multiple times that have a longer frame delay.
- (id)objectInFramesAtIndex:(NSUInteger)index
{
    UIImage *image = nil;
    id tryImage = self.cachedFrames[index];
    if ([tryImage isKindOfClass:[UIImage class]]) {
        image = tryImage;
    } else {
#warning Do we waste a lot of resources when we predraw images to then only access `-images` (e.g. for watch)?
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(_imageSource, index, NULL);
        image = [UIImage imageWithCGImage:imageRef];
        CFRelease(imageRef);
    }
    return image;
}

#warning Implement -framesAtIndexes: for performance?


#pragma mark - Public Methods

// See header for more details.
// Note: both consumer and producer are throttled: consumer by frame timings and producer by the available memory (max buffer window size).
- (UIImage *)imageLazilyCachedAtIndex:(NSUInteger)index
{
    // Early return if the requested index is beyond bounds.
    // Note: We're comparing an index with a count and need to bail on greater than or equal to.
    if (index >= self.frameCount) {
        FLLogWarn(@"Skipping requested frame %lu beyond bounds (total frame count: %lu) for animated image: %@", (unsigned long)index, (unsigned long)self.frameCount, self);
        return nil;
    }
    
    // Remember requested frame index, this influences what we should cache next.
    self.requestedFrameIndex = index;
#if defined(DEBUG) && DEBUG
    if ([self.debug_delegate respondsToSelector:@selector(debug_animatedImage:didRequestCachedFrame:)]) {
        [self.debug_delegate debug_animatedImage:self didRequestCachedFrame:index];
    }
#endif
    
    // Quick check to avoid doing any work if we already have all possible frames cached, a common case.
    if ([self.cachedFrameIndexes count] < self.frameCount) {
        // If we have frames that should be cached but aren't and aren't requested yet, request them.
        // Exclude existing cached frames and frames already requested.
        NSMutableIndexSet *frameIndexesToAddToCacheMutable = [[self frameIndexesToCache] mutableCopy];
        [frameIndexesToAddToCacheMutable removeIndexes:self.cachedFrameIndexes];
        [frameIndexesToAddToCacheMutable removeIndexes:self.requestedFrameIndexes];
        NSIndexSet *frameIndexesToAddToCache = [frameIndexesToAddToCacheMutable copy];
        
        // Asynchronously add frames to our cache.
        if ([frameIndexesToAddToCache count] > 0) {
            [self addFrameIndexesToCache:frameIndexesToAddToCache];
        }
    }
    
    // Get the specified image. Watch out for `NSNull` placeholders.
    UIImage *image = nil;
    id tryImage = self.cachedFrames[index];
    if ([tryImage isKindOfClass:[UIImage class]]) {
        image = tryImage;
    }
    
    // Purge if needed based on the current playhead position.
    [self purgeFrameCacheIfNeeded];
    
    return image;
}


// Only called once from `-imageLazilyCachedAtIndex` but factored into its own method for logical grouping.
- (void)addFrameIndexesToCache:(NSIndexSet *)frameIndexesToAddToCache
{
    // Order matters. First, iterate over the indexes starting from the requested frame index.
    // Then, if there are any indexes before the requested frame index, do those.
    NSRange firstRange = NSMakeRange(self.requestedFrameIndex, self.frameCount - self.requestedFrameIndex);
    NSRange secondRange = NSMakeRange(0, self.requestedFrameIndex);
    if (firstRange.length + secondRange.length != self.frameCount) {
        FLLogWarn(@"Two-part frame cache range doesn't equal full range.");
    }
    
    // Add to the requested list before we actually kick them off, so they don't get into the queue twice.
    [self.requestedFrameIndexes addIndexes:frameIndexesToAddToCache];
    
    // Lazily create dedicated isolation queue.
    if (!self.serialQueue) {
        _serialQueue = dispatch_queue_create("com.flipboard.framecachingqueue", DISPATCH_QUEUE_SERIAL);
    }
    
    // Start streaming requested frames in the background into the cache.
    // Avoid capturing self in the block as there's no reason to keep doing work if the animated image went away.
    __block FLAnimatedImage *blockSelf = self;
    dispatch_async(self.serialQueue, ^{
        // Produce and cache next needed frame.
        void (^frameRangeBlock)(NSRange, BOOL *) = ^(NSRange range, BOOL *stop) {
            // Iterate through contiguous indexes; can be faster than `enumerateIndexesInRange:options:usingBlock:`.
            for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
#if defined(DEBUG) && DEBUG
                CFTimeInterval predrawBeginTime = CACurrentMediaTime();
#endif
                UIImage *image = [blockSelf predrawnImageAtIndex:i];
#if defined(DEBUG) && DEBUG
                CFTimeInterval predrawDuration = CACurrentMediaTime() - predrawBeginTime;
                CFTimeInterval slowdownDuration = 0.0;
                if ([blockSelf.debug_delegate respondsToSelector:@selector(debug_animatedImagePredrawingSlowdownFactor:)]) {
                    CGFloat predrawingSlowdownFactor = [blockSelf.debug_delegate debug_animatedImagePredrawingSlowdownFactor:blockSelf];
                    slowdownDuration = predrawDuration * predrawingSlowdownFactor - predrawDuration;
                    [NSThread sleepForTimeInterval:slowdownDuration];
                }
                FLLogVerbose(@"Predrew frame %lu in %f ms for animated image: %@", (unsigned long)i, (predrawDuration + slowdownDuration) * 1000, blockSelf);
#endif
                // The results get returned one by one as soon as they're ready (and not in batch).
                // The benefits of having the first frames as quick as possible outweigh building up a buffer to cope with potential hiccups when the CPU suddenly gets busy.
                if (image && blockSelf) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        blockSelf.cachedFrames[i] = image;
                        [blockSelf.cachedFrameIndexes addIndex:i];
                        [blockSelf.requestedFrameIndexes removeIndex:i];
#if defined(DEBUG) && DEBUG
                        if ([blockSelf.debug_delegate respondsToSelector:@selector(debug_animatedImage:didUpdateCachedFrames:)]) {
                            [blockSelf.debug_delegate debug_animatedImage:blockSelf didUpdateCachedFrames:blockSelf.cachedFrameIndexes];
                        }
#endif
                    });
                }
            }
        };
        
        [frameIndexesToAddToCache enumerateRangesInRange:firstRange options:0 usingBlock:frameRangeBlock];
        [frameIndexesToAddToCache enumerateRangesInRange:secondRange options:0 usingBlock:frameRangeBlock];
    });
}


#pragma mark - Private Methods
#pragma mark Frame Loading

- (UIImage *)predrawnImageAtIndex:(NSUInteger)index
{
    // It's very important to use the cached `_imageSource` since the random access to a frame with `CGImageSourceCreateImageAtIndex` turns from an O(1) into an O(n) operation when re-initializing the image source every time.
    CGImageRef imageRef = CGImageSourceCreateImageAtIndex(_imageSource, index, NULL);
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:self.scale orientation:self.imageOrientation];
    CFRelease(imageRef);
    
    // Loading in the image object is only half the work, the displaying image view would still have to synchronosly wait and decode the image, so we go ahead and do that here on the background thread.
    image = [[self class] predrawnImageFromImage:image];
    
    return image;
}


#pragma mark Frame Caching

- (NSIndexSet *)frameIndexesToCache
{
    NSIndexSet *indexesToCache = nil;
    // Quick check to avoid building the index set if the number of frames to cache equals the total frame count.
    if (self.frameCacheSizeCurrent == self.frameCount) {
        indexesToCache = self.allFramesIndexSet;
    } else {
        NSMutableIndexSet *indexesToCacheMutable = [[NSMutableIndexSet alloc] init];
        
        // Add indexes to the set in two separate blocks- the first starting from the requested frame index, up to the limit or the end.
        // The second, if needed, the remaining number of frames beginning at index zero.
        NSUInteger firstLength = MIN(self.frameCacheSizeCurrent, self.frameCount - self.requestedFrameIndex);
        NSRange firstRange = NSMakeRange(self.requestedFrameIndex, firstLength);
        [indexesToCacheMutable addIndexesInRange:firstRange];
        NSUInteger secondLength = self.frameCacheSizeCurrent - firstLength;
        if (secondLength > 0) {
            NSRange secondRange = NSMakeRange(0, secondLength);
            [indexesToCacheMutable addIndexesInRange:secondRange];
        }
        // Double check our math.
        if ([indexesToCacheMutable count] != self.frameCacheSizeCurrent) {
            FLLogWarn(@"Number of frames to cache doesn't equal expected cache size.");
        }
        
        indexesToCache = [indexesToCacheMutable copy];
    }
    
    return indexesToCache;
}


- (void)purgeFrameCacheIfNeeded
{
    __block FLAnimatedImage *blockSelf = self;
    
    // Purge frames that are currently cached but don't need to be.
    // But not if we're still under the number of frames to cache.
    // This way, if all frames are allowed to be cached (the common case), we can skip all the `NSIndexSet` math below.
    if ([self.cachedFrameIndexes count] > self.frameCacheSizeCurrent) {
        NSMutableIndexSet *indexesToPurge = [self.cachedFrameIndexes mutableCopy];
        [indexesToPurge removeIndexes:[self frameIndexesToCache]];
        [indexesToPurge enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
            // Iterate through contiguous indexes; can be faster than `enumerateIndexesInRange:options:usingBlock:`.
            for (NSUInteger i = range.location; i < NSMaxRange(range); i++) {
                [blockSelf.cachedFrameIndexes removeIndex:i];
                blockSelf.cachedFrames[i] = [NSNull null];
                // Note: Don't `CGImageSourceRemoveCacheAtIndex` on the image source for frames that we don't want cached any longer to maintain O(1) time access.
#if defined(DEBUG) && DEBUG
                if ([blockSelf.debug_delegate respondsToSelector:@selector(debug_animatedImage:didUpdateCachedFrames:)]) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [blockSelf.debug_delegate debug_animatedImage:blockSelf didUpdateCachedFrames:blockSelf.cachedFrameIndexes];
                    });
                }
#endif
            }
        }];
    }
}


- (void)growFrameCacheSizeAfterMemoryWarning:(NSNumber *)frameCacheSize
{
    self.frameCacheSizeMaxInternal = [frameCacheSize unsignedIntegerValue];
    FLLogDebug(@"Grew frame cache size max to %lu after memory warning for animated image: %@", (unsigned long)self.frameCacheSizeMaxInternal, self);
    
    // Schedule resetting the frame cache size max completely after a while.
    const NSTimeInterval kResetDelay = 3.0;
    [self.weakProxy performSelector:@selector(resetFrameCacheSizeMaxInternal) withObject:nil afterDelay:kResetDelay];
}


- (void)resetFrameCacheSizeMaxInternal
{
    self.frameCacheSizeMaxInternal = FLAnimatedImageFrameCacheSizeNoLimit;
    FLLogDebug(@"Reset frame cache size max (current frame cache size: %lu) for animated image: %@", (unsigned long)self.frameCacheSizeCurrent, self);
}


#pragma mark System Memory Warnings Notification Handler

- (void)didReceiveMemoryWarning:(NSNotification *)notification
{
    self.memoryWarningCount++;
    
    // If we were about to grow larger, but got rapped on our knuckles by the system again, cancel.
    [NSObject cancelPreviousPerformRequestsWithTarget:self.weakProxy selector:@selector(growFrameCacheSizeAfterMemoryWarning:) object:@(FLAnimatedImageFrameCacheSizeGrowAfterMemoryWarning)];
    [NSObject cancelPreviousPerformRequestsWithTarget:self.weakProxy selector:@selector(resetFrameCacheSizeMaxInternal) object:nil];
    
    // Go down to the minimum and by that implicitly immediately purge from the cache if needed to not get jettisoned by the system and start producing frames on-demand.
    FLLogDebug(@"Attempt setting frame cache size max to %lu (previous was %lu) after memory warning #%lu for animated image: %@", (unsigned long)FLAnimatedImageFrameCacheSizeLowMemory, (unsigned long)self.frameCacheSizeMaxInternal, (unsigned long)self.memoryWarningCount, self);
    self.frameCacheSizeMaxInternal = FLAnimatedImageFrameCacheSizeLowMemory;
    
    // Schedule growing larger again after a while, but cap our attempts to prevent a periodic sawtooth wave (ramps upward and then sharply drops) of memory usage.
    //
    // [mem]^     (2)   (5)  (6)        1) Loading frames for the first time
    //   (*)|      ,     ,    ,         2) Mem warning #1; purge cache
    //      |     /| (4)/|   /|         3) Grow cache size a bit after a while, if no mem warning occurs
    //      |    / |  _/ | _/ |         4) Try to grow cache size back to optimum after a while, if no mem warning occurs
    //      |(1)/  |_/   |/   |__(7)    5) Mem warning #2; purge cache
    //      |__/   (3)                  6) After repetition of (3) and (4), mem warning #3; purge cache
    //      +---------------------->    7) After 3 mem warnings, stay at minimum cache size
    //                            [t]
    //                                  *) The mem high water mark before we get warned might change for every cycle.
    //
    const NSUInteger kGrowAttemptsMax = 2;
    const NSTimeInterval kGrowDelay = 2.0;
    if ((self.memoryWarningCount - 1) <= kGrowAttemptsMax) {
        [self.weakProxy performSelector:@selector(growFrameCacheSizeAfterMemoryWarning:) withObject:@(FLAnimatedImageFrameCacheSizeGrowAfterMemoryWarning) afterDelay:kGrowDelay];
    }
    
    // Note: It's not possible to get the level of a memory warning with a public API: http://stackoverflow.com/questions/2915247/iphone-os-memory-warnings-what-do-the-different-levels-mean/2915477#2915477
}


#pragma mark Image Decoding

// Decodes the image's data and draws it off-screen fully in memory; it's thread-safe and hence can be called on a background thread.
// On success, the returned object is a new `UIImage` instance with the same content as the one passed in.
// On failure, the returned object is the unchanged passed in one; the data will not be predrawn in memory though and an error will be logged.
// First inspired by & good Karma to: https://gist.github.com/steipete/1144242
+ (UIImage *)predrawnImageFromImage:(UIImage *)imageToPredraw
{
    // Always use a device RGB color space for simplicity and predictability what will be going on.
    CGColorSpaceRef colorSpaceDeviceRGBRef = CGColorSpaceCreateDeviceRGB();
    // Early return on failure!
    if (!colorSpaceDeviceRGBRef) {
        FLLogError(@"Failed to `CGColorSpaceCreateDeviceRGB` for image %@", imageToPredraw);
        return imageToPredraw;
    }
    
    // Even when the image doesn't have transparency, we have to add the extra channel because Quartz doesn't support other pixel formats than 32 bpp/8 bpc for RGB:
    // kCGImageAlphaNoneSkipFirst, kCGImageAlphaNoneSkipLast, kCGImageAlphaPremultipliedFirst, kCGImageAlphaPremultipliedLast
    // (source: docs "Quartz 2D Programming Guide > Graphics Contexts > Table 2-1 Pixel formats supported for bitmap graphics contexts")
    size_t numberOfComponents = CGColorSpaceGetNumberOfComponents(colorSpaceDeviceRGBRef) + 1; // 4: RGB + A
    
    // "In iOS 4.0 and later, and OS X v10.6 and later, you can pass NULL if you want Quartz to allocate memory for the bitmap." (source: docs)
    void *data = NULL;
    size_t width = imageToPredraw.size.width * imageToPredraw.scale;
    size_t height = imageToPredraw.size.height * imageToPredraw.scale;
    size_t bitsPerComponent = CHAR_BIT;
    
    size_t bitsPerPixel = (bitsPerComponent * numberOfComponents);
    size_t bytesPerPixel = (bitsPerPixel / BYTE_SIZE);
    size_t bytesPerRow = (bytesPerPixel * width);
    
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrderDefault;
    
    CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(imageToPredraw.CGImage);
    // If the alpha info doesn't match to one of the supported formats (see above), pick a reasonable supported one.
    // "For bitmaps created in iOS 3.2 and later, the drawing environment uses the premultiplied ARGB format to store the bitmap data." (source: docs)
    if (alphaInfo == kCGImageAlphaNone || alphaInfo == kCGImageAlphaOnly) {
        alphaInfo = kCGImageAlphaNoneSkipFirst;
    } else if (alphaInfo == kCGImageAlphaFirst) {
        alphaInfo = kCGImageAlphaPremultipliedFirst;
    } else if (alphaInfo == kCGImageAlphaLast) {
        alphaInfo = kCGImageAlphaPremultipliedLast;
    }
    // "The constants for specifying the alpha channel information are declared with the `CGImageAlphaInfo` type but can be passed to this parameter safely." (source: docs)
    bitmapInfo |= alphaInfo;
    
    // Create our own graphics context to draw to; `UIGraphicsGetCurrentContext`/`UIGraphicsBeginImageContextWithOptions` doesn't create a new context but returns the current one which isn't thread-safe (e.g. main thread could use it at the same time).
    // Note: It's not worth caching the bitmap context for multiple frames ("unique key" would be `width`, `height` and `hasAlpha`), it's ~50% slower. Time spent in libRIP's `CGSBlendBGRA8888toARGB8888` suddenly shoots up -- not sure why.
    CGContextRef bitmapContextRef = CGBitmapContextCreate(data, width, height, bitsPerComponent, bytesPerRow, colorSpaceDeviceRGBRef, bitmapInfo);
    CGColorSpaceRelease(colorSpaceDeviceRGBRef);
    // Early return on failure!
    if (!bitmapContextRef) {
        FLLogError(@"Failed to `CGBitmapContextCreate` with color space %@ and parameters (width: %zu height: %zu bitsPerComponent: %zu bytesPerRow: %zu) for image %@", colorSpaceDeviceRGBRef, width, height, bitsPerComponent, bytesPerRow, imageToPredraw);
        return imageToPredraw;
    }
    
    // Draw image in bitmap context and create image by preserving receiver's properties.
    CGContextDrawImage(bitmapContextRef, CGRectMake(0.0, 0.0, width, height), imageToPredraw.CGImage);
    CGImageRef predrawnImageRef = CGBitmapContextCreateImage(bitmapContextRef);
    UIImage *predrawnImage = [UIImage imageWithCGImage:predrawnImageRef scale:imageToPredraw.scale orientation:imageToPredraw.imageOrientation];
    CGImageRelease(predrawnImageRef);
    CGContextRelease(bitmapContextRef);
    
    // Early return on failure!
    if (!predrawnImage) {
        FLLogError(@"Failed to `imageWithCGImage:scale:orientation:` with image ref %@ created with color space %@ and bitmap context %@ and properties and properties (scale: %f orientation: %ld) for image %@", predrawnImageRef, colorSpaceDeviceRGBRef, bitmapContextRef, imageToPredraw.scale, (long)imageToPredraw.imageOrientation, imageToPredraw);
        return imageToPredraw;
    }
    
    return predrawnImage;
}


#pragma mark - Description

- (NSString *)description
{
    NSString *description = [super description];
    
#warning add more properties?
    description = [description stringByAppendingFormat:@" size=%@", NSStringFromCGSize(self.size)];
    description = [description stringByAppendingFormat:@" frameCount=%lu", (unsigned long)self.frameCount];
    
    return description;
}


@end


#pragma mark - UIImage FLAnimatedImage Category

@implementation UIImage (FLAnimatedImage)

+ (UIImage *)animatedImageNamed:(NSString *)name
{
    UIImage *retVal = nil;
    FLAnimatedImage *image = [FLAnimatedImage imageNamed:name
                                                inBundle:[NSBundle mainBundle]
                           compatibleWithTraitCollection:nil
                                                    mode:FLAnimatedImageInitModeFull];
    if (image) {
        retVal = [self animatedImageWithFLAnimatedImage:image
                                                options:FLAnimatedImageOptionVariableDelays];
    }
    return retVal;
}


+ (UIImage *)animatedImageWithData:(NSData *)data options:(FLAnimatedImageOptions)options
{
    FLAnimatedImage *image = [FLAnimatedImage imageWithData:data mode:FLAnimatedImageInitModeFull];
    return [self animatedImageWithFLAnimatedImage:image options:options];
}


#pragma mark - Helper

+ (UIImage *)animatedImageWithFLAnimatedImage:(FLAnimatedImage *)image options:(FLAnimatedImageOptions)options
{
    NSArray *images = image.images;
    
    if (options & FLAnimatedImageOptionVariableDelays) {
        // Use a high, constant frame rate and slot in images with longer delays multiple times in a row.
        
        // Convert seconds to integer centiseconds to find out the GCD ( http://en.wikipedia.org/wiki/Greatest_common_divisor ) of the delays.
        NSMutableArray *delayTimesCentisecondsMutable = [NSMutableArray arrayWithCapacity:image.frameCount];
        for (NSNumber *delayTime in image.delayTimes) {
            NSUInteger delayTimeCentiseconds = lrint([delayTime doubleValue] * 100);
            [delayTimesCentisecondsMutable addObject:@(delayTimeCentiseconds)];
        }
        NSArray *delayTimesCentiseconds = [delayTimesCentisecondsMutable copy];
        NSUInteger durationCentiseconds = lrint(image.duration * 100);
        
        // Example of an image with three frames (delay in seconds): A (3s), B (9s), and C (15s).
        // Divide each by the GCD (3) and add each frame the resulting number of times.
        // Thus, `images` = [ A ][ B ][ B ][ B ][ C ][ C ][ C ][ C ][ C ] and `duration`= (3+9+15)/100 = 0.27s.
        // Note: B and C will fortunately not duplicate their memory usage.
        NSUInteger delayTimesCentisecondsGCD = gcdArray(delayTimesCentiseconds);
        NSUInteger frameCount = durationCentiseconds / delayTimesCentisecondsGCD;
        
        NSMutableArray *framesMutable = [NSMutableArray arrayWithCapacity:frameCount];
        for (NSUInteger i = 0, frameNumber = 0; i < [images count]; i++) {
            for (NSUInteger j = [delayTimesCentiseconds[i] unsignedIntegerValue] / delayTimesCentisecondsGCD; j > 0; j--) {
                framesMutable[frameNumber++] = images[i];
            }
        }
        
        images = [framesMutable copy];
    }
    
    return [self animatedImageWithImages:images duration:image.duration];
}


static NSUInteger gcdArray(NSArray *values)
{
    NSUInteger gcd = 0;
    
    NSUInteger count = [values count];
    if (count > 0) {
        gcd = [values[0] unsignedIntegerValue];
        for (NSUInteger i = 1; i < count; i++) {
            // After processing the first few elements `gcd` will likely be smaller than any remaining element.
            // By passing the smaller value as second argument to `gcdPair(,)` we avoid the sawp.
            gcd = gcdPair([values[i] unsignedIntegerValue], gcd);
        }
    }
    
    return gcd;
}


static NSUInteger gcdPair(NSUInteger a, NSUInteger b)
{
    if (a < b) {
        return gcdPair(b, a);
    }
    
    while (true) {
        NSUInteger r = a % b;
        if (r == 0) {
            return b;
        }
        a = b;
        b = r;
    }
}


@end


#pragma mark - FLWeakProxy

@interface FLWeakProxy ()

@property (nonatomic, weak) id target;

@end


@implementation FLWeakProxy

#pragma mark Life Cycle

// This is the designated creation method of an `FLWeakProxy` and
// as a subclass of `NSProxy` it doesn't respond to or need `-init`.
+ (instancetype)weakProxyForObject:(id)targetObject
{
    FLWeakProxy *weakProxy = [FLWeakProxy alloc];
    weakProxy.target = targetObject;
    return weakProxy;
}


#pragma mark Forwarding Messages

- (id)forwardingTargetForSelector:(SEL)selector
{
    // Keep it lightweight: access the ivar directly
    return _target;
}


#pragma mark - NSWeakProxy Method Overrides
#pragma mark Handling Unimplemented Methods

- (void)forwardInvocation:(NSInvocation *)invocation
{
    // Fallback for when target is nil. Don't do anything, just return 0/NULL/nil.
    // The method signature we've received to get here is just a dummy to keep `doesNotRecognizeSelector:` from firing.
    // We can't really handle struct return types here because we don't know the length.
    void *nullPointer = NULL;
    [invocation setReturnValue:&nullPointer];
}


- (NSMethodSignature *)methodSignatureForSelector:(SEL)selector
{
    // We only get here if `forwardingTargetForSelector:` returns nil.
    // In that case, our weak target has been reclaimed. Return a dummy method signature to keep `doesNotRecognizeSelector:` from firing.
    // We'll emulate the Obj-c messaging nil behavior by setting the return value to nil in `forwardInvocation:`, but we'll assume that the return value is `sizeof(void *)`.
    // Other libraries handle this situation by making use of a global method signature cache, but that seems heavier than necessary and has issues as well.
    // See https://www.mikeash.com/pyblog/friday-qa-2010-02-26-futures.html and https://github.com/steipete/PSTDelegateProxy/issues/1 for examples of using a method signature cache.
    return [NSObject instanceMethodSignatureForSelector:@selector(init)];
}


@end
