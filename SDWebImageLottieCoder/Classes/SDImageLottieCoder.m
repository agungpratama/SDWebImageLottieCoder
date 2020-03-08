/*
* This file is part of the SDWebImage package.
* (c) DreamPiggy <lizhuoli1126@126.com>
*
* For the full copyright and license information, please view the LICENSE
* file that was distributed with this source code.
*/

#import "SDImageLottieCoder.h"
#if __has_include(<rlottie/rlottie_capi.h>)
#import <rlottie/rlottie_capi.h>
#elif __has_include(<librlottie/librlottie.h>)
#import <librlottie/librlottie.h>
#else
@import librlottie;
#endif

#define SD_FOUR_CC(c1,c2,c3,c4) ((uint32_t)(((c4) << 24) | ((c3) << 16) | ((c2) << 8) | (c1)))

@implementation SDImageLottieCoder {
    CGFloat _scale;
    Lottie_Animation * _animation;
    CGContextRef _canvas;
    NSData *_imageData;
    size_t _width, _height;
    NSUInteger _loopCount;
    NSUInteger _frameCount;
    NSTimeInterval _totalDuration;
}

+ (SDImageLottieCoder *)sharedCoder {
    static dispatch_once_t onceToken;
    static SDImageLottieCoder *coder;
    dispatch_once(&onceToken, ^{
        coder = [[SDImageLottieCoder alloc] init];
    });
    return coder;
}

- (void)dealloc {
    if (_animation) {
        lottie_animation_destroy(_animation);
        _animation = NULL;
    }
    if (_canvas) {
        CGContextRelease(_canvas);
        _canvas = NULL;
    }
}

#pragma mark - Decoding

- (BOOL)canDecodeFromData:(NSData *)data {
    return [self.class isJSONFormatForData:data];
}

- (UIImage *)decodedImageWithData:(NSData *)data options:(SDImageCoderOptions *)options {
    CGFloat scale = 1;
    NSNumber *scaleFactor = options[SDImageCoderDecodeScaleFactor];
    if (scaleFactor != nil) {
        scale = [scaleFactor doubleValue];
        if (scale < 1) {
            scale = 1;
        }
    }
    
    Lottie_Animation *animation = lottie_animation_from_data(data.bytes, "", "");
    if (!animation) {
        return nil;
    }
    size_t width = 0;
    size_t height = 0;
    lottie_animation_get_size(animation, &width, &height);
    if (width == 0 || height == 0) {
        lottie_animation_destroy(animation);
        return nil;
    }
    size_t frameCount = lottie_animation_get_totalframe(animation);
    if (frameCount < 1) {
        lottie_animation_destroy(animation);
        return nil;
    }
    NSTimeInterval totalDuration = lottie_animation_get_duration(animation);
    // Lottie surface use ARGB8888 Premultiplied
    CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
    bitmapInfo |= kCGImageAlphaPremultipliedFirst;
    CGContextRef canvas = CGBitmapContextCreate(NULL, width, height, 8, 0, SDImageCoderHelper.colorSpaceGetDeviceRGB, bitmapInfo);
    if (!canvas) {
        lottie_animation_destroy(animation);
        return nil;
    }
    // Decode each frame
    void *buffer = CGBitmapContextGetData(canvas);
    size_t bytesPerRow = CGBitmapContextGetBytesPerRow(canvas);
    NSMutableArray<SDImageFrame *> *frames = [NSMutableArray array];
    for (size_t i = 0; i < frameCount; i++) {
        lottie_animation_render(animation, i, buffer, width, height, bytesPerRow);
        CGImageRef imageRef = CGBitmapContextCreateImage(canvas);
        if (!imageRef) {
            continue;
        }

#if SD_UIKIT || SD_WATCH
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:UIImageOrientationUp];
#else
        UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:scale orientation:kCGImagePropertyOrientationUp];
#endif
        CGImageRelease(imageRef);
        NSTimeInterval duration = totalDuration / frameCount;
        SDImageFrame *frame = [SDImageFrame frameWithImage:image duration:duration];
        [frames addObject:frame];
    }
    
    lottie_animation_destroy(animation);
    CGContextRelease(canvas);
    
    UIImage *animatedImage = [SDImageCoderHelper animatedImageWithFrames:frames];
    animatedImage.sd_imageLoopCount = 0;
    animatedImage.sd_imageFormat = SDImageFormatWebP;
    
    return animatedImage;
}
#pragma mark - Encoding

- (BOOL)canEncodeToFormat:(SDImageFormat)format {
    // Does not support Lottie encoding
    return NO;
}

- (NSData *)encodedDataWithImage:(UIImage *)image format:(SDImageFormat)format options:(SDImageCoderOptions *)options {
    return nil;
}

#pragma mark - SDAnimatedCoder

- (instancetype)initWithAnimatedImageData:(NSData *)data options:(SDImageCoderOptions *)options {
    self = [super init];
    if (self) {
        Lottie_Animation *animation = lottie_animation_from_data(data.bytes, "", "");
        if (!animation) {
            return nil;
        }
        size_t width, height;
        lottie_animation_get_size(animation, &width, &height);
        if (width == 0 || height == 0) {
            return nil;
        }
        size_t frameCount = lottie_animation_get_totalframe(animation);
        if (frameCount < 1) {
            return nil;
        }
        NSTimeInterval totalDuration = lottie_animation_get_duration(animation);
        CGFloat scale = 1;
        NSNumber *scaleFactor = options[SDImageCoderDecodeScaleFactor];
        if (scaleFactor != nil) {
            scale = MAX([scaleFactor doubleValue], 1);
        }
        _scale = scale;
        _width = width;
        _height = height;
        _frameCount = frameCount;
        _loopCount = 0; // Lottie animation does not have loop count information
        _totalDuration = totalDuration;
        _animation = animation;
        _imageData = data;
        
    }
    return self;
}

- (NSData *)animatedImageData {
    return _imageData;
}

- (NSUInteger)animatedImageFrameCount {
    return _frameCount;
}

- (NSUInteger)animatedImageLoopCount {
    return _loopCount;
}

- (NSTimeInterval)animatedImageDurationAtIndex:(NSUInteger)index {
    if (_frameCount > 0) {
        return _totalDuration / _frameCount;
    }
    return 0;
}

- (UIImage *)animatedImageFrameAtIndex:(NSUInteger)index {
    if (!_canvas) {
        // Lottie surface use ARGB8888 Premultiplied
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
        bitmapInfo |= kCGImageAlphaPremultipliedFirst;
        _canvas = CGBitmapContextCreate(NULL, _width, _height, 8, 0, SDImageCoderHelper.colorSpaceGetDeviceRGB, bitmapInfo);
        if (!_canvas) {
            return nil;
        }
    }
    uint32_t *buffer = CGBitmapContextGetData(_canvas);
    size_t bytesPerRow = CGBitmapContextGetBytesPerRow(_canvas);
    lottie_animation_render(_animation, index, buffer, _width, _height, bytesPerRow);
    
    CGImageRef imageRef = CGBitmapContextCreateImage(_canvas);
    if (!imageRef) {
        return nil;
    }
    
#if SD_UIKIT
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:_scale orientation:UIImageOrientationUp];
#else
    UIImage *image = [[UIImage alloc] initWithCGImage:imageRef scale:_scale orientation:kCGImagePropertyOrientationUp];
#endif
    CGImageRelease(imageRef);
    
    return image;
}

#pragma mark - Helper
+ (BOOL)isJSONFormatForData:(NSData *)data {
    if (!data) {
        return NO;
    }
    uint32_t magic4;
    [data getBytes:&magic4 length:4]; // 4 Bytes Magic Code for most file format.
    switch (magic4) {
        case SD_FOUR_CC('{', '"', 'v', '"'): { // {"v"
            return YES;
        }
        default: {
            return NO;
        }
    }
}

@end
