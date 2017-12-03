//
//  iTermCharacterSource.m
//  iTerm2SharedARC
//
//  Created by George Nachman on 11/26/17.
//

#import <Cocoa/Cocoa.h>

#import "DebugLogging.h"
#import "iTermCharacterSource.h"
#import "iTermTextureMap.h"
#import "NSStringITerm.h"

extern void CGContextSetFontSmoothingStyle(CGContextRef, int);
extern int CGContextGetFontSmoothingStyle(CGContextRef);

@implementation iTermCharacterSource {
    NSString *_string;
    NSFont *_font;
    CGSize _size;
    CGFloat _baselineOffset;
    CGFloat _scale;
    BOOL _useThinStrokes;
    BOOL _fakeBold;
    BOOL _fakeItalic;

    CGSize _partSize;
    CTLineRef _lineRef;
    CGContextRef _cgContext;

    NSAttributedString *_attributedString;
    NSImage *_image;
    NSMutableData *_glyphsData;
    NSMutableData *_positionsBuffer;
    BOOL _haveDrawn;
    CGImageRef _imageRef;
    NSArray<NSNumber *> *_parts;
}

+ (CGColorSpaceRef)colorSpace {
    static dispatch_once_t onceToken;
    static CGColorSpaceRef colorSpace;
    dispatch_once(&onceToken, ^{
        colorSpace = CGColorSpaceCreateDeviceRGB();
    });
    return colorSpace;
}

+ (CGContextRef)newBitmapContextOfSize:(CGSize)size {
    return CGBitmapContextCreate(NULL,
                                 size.width,
                                 size.height,
                                 8,
                                 size.width * 4,
                                 [iTermCharacterSource colorSpace],
                                 kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Host);
}

+ (CGContextRef)onePixelContext {
    static dispatch_once_t onceToken;
    static CGContextRef context;
    dispatch_once(&onceToken, ^{
        context = [self newBitmapContextOfSize:CGSizeMake(1, 1)];
    });
    return context;
}

- (instancetype)initWithCharacter:(NSString *)string
                             font:(NSFont *)font
                             size:(CGSize)size
                   baselineOffset:(CGFloat)baselineOffset
                            scale:(CGFloat)scale
                   useThinStrokes:(BOOL)useThinStrokes
                         fakeBold:(BOOL)fakeBold
                       fakeItalic:(BOOL)fakeItalic {
    ITDebugAssert(font);
    ITDebugAssert(size.width > 0 && size.height > 0);
    ITDebugAssert(scale > 0);

    if (string.length == 0 || [string isEqualToString:@" "]) {
        return nil;
    }

    self = [super init];
    if (self) {
        _string = [string copy];
        _font = font;
        _partSize = size;
        _size = CGSizeMake(size.width * iTermTextureMapMaxCharacterParts,
                           size.height * iTermTextureMapMaxCharacterParts);
        _baselineOffset = baselineOffset;
        _scale = scale;
        _useThinStrokes = useThinStrokes;
        _fakeBold = fakeBold;
        _fakeItalic = fakeItalic;

        _attributedString = [[NSAttributedString alloc] initWithString:string attributes:self.attributes];
        _lineRef = CTLineCreateWithAttributedString((CFAttributedStringRef)_attributedString);
        _cgContext = [iTermCharacterSource newBitmapContextOfSize:_size];
        _emoji = [string startsWithEmoji];
    }
    return self;
}

- (void)dealloc {
    if (_lineRef) {
        CFRelease(_lineRef);
    }
    if (_cgContext) {
        CGContextRelease(_cgContext);
    }
    if (_imageRef) {
        CGImageRelease(_imageRef);
    }
}

#pragma mark - APIs

- (NSImage *)imageAtPart:(int)part {
    [self drawIfNeeded];
    const int radius = iTermTextureMapMaxCharacterParts / 2;
    int dx = ImagePartDX(part) + radius;
    int dy = ImagePartDY(part) + radius;
    return [self newImageWithOffset:CGPointMake(dx * _partSize.width,
                                                dy * _partSize.height)];
}

- (NSArray<NSNumber *> *)parts {
    if (!_parts) {
        _parts = [self newParts];
    }
    return _parts;
}

#pragma mark - Private

#pragma mark Lazy Computations

- (NSArray<NSNumber *> *)newParts {
    CGRect boundingBox = self.frame;
    const int radius = iTermTextureMapMaxCharacterParts / 2;
    NSMutableArray<NSNumber *> *result = [NSMutableArray array];
    for (int y = 0; y < iTermTextureMapMaxCharacterParts; y++) {
        for (int x = 0; x < iTermTextureMapMaxCharacterParts; x++) {
            CGRect partRect = CGRectMake(x * _partSize.width,
                                         y * _partSize.height,
                                         _partSize.width,
                                         _partSize.height);
            if (CGRectIntersectsRect(partRect, boundingBox)) {
                [result addObject:@(ImagePartFromDeltas(x - radius, y - radius))];
            }
        }
    }
    return [result copy];
}

- (NSImage *)newImageWithOffset:(CGPoint)offset {
    if (!_imageRef) {
        _imageRef = CGBitmapContextCreateImage(_cgContext);
    }
    CGImageRef part = CGImageCreateWithImageInRect(_imageRef,
                                                   CGRectMake(offset.x,
                                                              offset.y,
                                                              _partSize.width,
                                                              _partSize.height));
    NSImage *image = [[NSImage alloc] initWithCGImage:part size:_partSize];
    CGImageRelease(part);
    return image;
}

- (void)drawIfNeeded {
    if (!_haveDrawn) {
        const int radius = iTermTextureMapMaxCharacterParts / 2;
        [self drawWithOffset:CGPointMake(_partSize.width * radius,
                                         _partSize.height * radius)];
    }
}

- (CGRect)frame {
    if (_string.length == 0) {
        return CGRectZero;
    }
    CGContextRef cgContext = [iTermCharacterSource onePixelContext];
    CGRect frame = CTLineGetImageBounds(_lineRef, cgContext);
    const int radius = iTermTextureMapMaxCharacterParts / 2;
    frame.origin.y -= _baselineOffset;
    frame.origin.x *= _scale;
    frame.origin.y *= _scale;
    frame.size.width *= _scale;
    frame.size.height *= _scale;
    frame.origin.x += radius * _partSize.width;
    frame.origin.y += radius * _partSize.height;
    frame.origin.y = _size.height - frame.origin.y - frame.size.height;

    // This is set to cut off subpixels that spill into neighbors as an optimization.
    CGPoint min = CGPointMake(ceil(CGRectGetMinX(frame)),
                              ceil(CGRectGetMinY(frame)));
    CGPoint max = CGPointMake(floor(CGRectGetMaxX(frame)),
                              floor(CGRectGetMaxY(frame)));
    frame = CGRectMake(min.x, min.y, max.x - min.x, max.y - min.y);

    return frame;
}

#pragma mark Drawing

- (void)drawWithOffset:(CGPoint)offset {
    [self fillBackground];

    CFArrayRef runs = CTLineGetGlyphRuns(_lineRef);
    CGContextSetShouldAntialias(_cgContext, YES);
    CGContextSetFillColorWithColor(_cgContext, [[NSColor blackColor] CGColor]);
    CGContextSetStrokeColorWithColor(_cgContext, [[NSColor blackColor] CGColor]);

    const CGFloat skew = _fakeItalic ? 0.2 : 0;

    if (_useThinStrokes) {
        CGContextSetShouldSmoothFonts(_cgContext, YES);
        // This seems to be available at least on 10.8 and later. The only reference to it is in
        // WebKit. This causes text to render just a little lighter, which looks nicer.
        CGContextSetFontSmoothingStyle(_cgContext, 16);
    }

    const CGFloat ty = offset.y - _baselineOffset * _scale;

    [self drawRuns:runs atOffset:CGPointMake(offset.x, ty) skew:skew];
}

- (void)fillBackground {
    if (self.emoji) {
        CGContextSetRGBFillColor(_cgContext, 1, 1, 1, 0);
    } else {
        CGContextSetRGBFillColor(_cgContext, 1, 1, 1, 1);
    }
    CGContextFillRect(_cgContext, CGRectMake(0, 0, _size.width, _size.height));
}

- (void)drawRuns:(CFArrayRef)runs atOffset:(CGPoint)offset skew:(CGFloat)skew {
    [self initializeTextMatrixWithSkew:skew offset:offset];

    for (CFIndex j = 0; j < CFArrayGetCount(runs); j++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, j);
        const size_t length = CTRunGetGlyphCount(run);
        const CGGlyph *buffer = [self glyphsInRun:run length:length];
        CGPoint *positions = [self positionsInRun:run length:length];
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);

        if (_emoji) {
            [self drawEmojiWithFont:runFont offset:offset buffer:buffer positions:positions length:length];
        } else {
            CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, _cgContext);
        }
    }
}

- (void)drawEmojiWithFont:(CTFontRef)runFont
                   offset:(CGPoint)offset
                   buffer:(const CGGlyph *)buffer
                positions:(CGPoint *)positions
                   length:(size_t)length {
    CGContextSaveGState(_cgContext);
    // You have to use the CTM with emoji. CGContextSetTextMatrix doesn't work.
    [self initializeCTMWithFont:runFont offset:offset];

    CTFontDrawGlyphs(runFont, buffer, (NSPoint *)positions, length, _cgContext);

    CGContextRestoreGState(_cgContext);
}

#pragma mark Core Text Helpers

- (const CGGlyph *)glyphsInRun:(CTRunRef)run length:(size_t)length {
    const CGGlyph *buffer = CTRunGetGlyphsPtr(run);
    if (buffer) {
        return buffer;
    }

    _glyphsData = [[NSMutableData alloc] initWithLength:sizeof(CGGlyph) * length];
    CTRunGetGlyphs(run, CFRangeMake(0, length), (CGGlyph *)_glyphsData.mutableBytes);
    return (const CGGlyph *)_glyphsData.mutableBytes;
}

- (CGPoint *)positionsInRun:(CTRunRef)run length:(size_t)length {
    _positionsBuffer = [[NSMutableData alloc] initWithLength:sizeof(CGPoint) * length];
    CTRunGetPositions(run, CFRangeMake(0, length), (CGPoint *)_positionsBuffer.mutableBytes);
    return (CGPoint *)_positionsBuffer.mutableBytes;

}

- (void)initializeTextMatrixWithSkew:(CGFloat)skew offset:(CGPoint)offset {
    if (!_emoji) {
        // Can't use this with emoji.
        CGAffineTransform textMatrix = CGAffineTransformMake(_scale, 0.0,
                                                             skew, _scale,
                                                             offset.x, offset.y);
        CGContextSetTextMatrix(_cgContext, textMatrix);
    }
}

- (void)initializeCTMWithFont:(CTFontRef)runFont offset:(CGPoint)offset {
    CGContextConcatCTM(_cgContext, CTFontGetMatrix(runFont));
    CGContextTranslateCTM(_cgContext, offset.x, offset.y);
    CGContextScaleCTM(_cgContext, _scale, _scale);
}

- (NSDictionary *)attributes {
    static NSMutableParagraphStyle *paragraphStyle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        paragraphStyle.lineBreakMode = NSLineBreakByClipping;
        paragraphStyle.tabStops = @[];
        paragraphStyle.baseWritingDirection = NSWritingDirectionLeftToRight;
    });
    return @{ (NSString *)kCTLigatureAttributeName: @0,
              (NSString *)kCTForegroundColorAttributeName: (id)[[NSColor blackColor] CGColor],
              NSFontAttributeName: _font,
              NSParagraphStyleAttributeName: paragraphStyle };
}

@end