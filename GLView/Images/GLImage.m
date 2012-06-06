//
//  GLImage.m
//
//  GLView Project
//  Version 1.3
//
//  Created by Nick Lockwood on 10/07/2011.
//  Copyright 2011 Charcoal Design
//
//  Distributed under the permissive zlib License
//  Get the latest version from either of these locations:
//
//  http://charcoaldesign.co.uk/source/cocoa#glview
//  https://github.com/nicklockwood/GLView
//
//  This software is provided 'as-is', without any express or implied
//  warranty.  In no event will the authors be held liable for any damages
//  arising from the use of this software.
//
//  Permission is granted to anyone to use this software for any purpose,
//  including commercial applications, and to alter it and redistribute it
//  freely, subject to the following restrictions:
//
//  1. The origin of this software must not be misrepresented; you must not
//  claim that you wrote the original software. If you use this software
//  in a product, an acknowledgment in the product documentation would be
//  appreciated but is not required.
//
//  2. Altered source versions must be plainly marked as such, and must not be
//  misrepresented as being the original software.
//
//  3. This notice may not be removed or altered from any source distribution.
//

#import "GLImage.h"
#import "GLView.h"


typedef struct
{
    GLuint headerSize;
    GLuint height;
    GLuint width;
    GLuint mipmapCount;
    GLuint pixelFormatFlags;
    GLuint textureDataSize;
    GLuint bitCount; 
    GLuint redBitMask;
    GLuint greenBitMask;
    GLuint blueBitMask;
    GLuint alphaBitMask;
    GLuint magicNumber;
    GLuint surfaceCount;
}
PVRTextureHeader;


typedef enum
{
    OGL_RGBA_4444 = 0x10,
    OGL_RGBA_5551,
    OGL_RGBA_8888,
    OGL_RGB_565,
    OGL_RGB_555,
    OGL_RGB_888,
    OGL_I_8,
    OGL_AI_88,
    OGL_PVRTC2,
    OGL_PVRTC4
}
PVRPixelType;


@interface GLView (Private)

+ (EAGLContext *)sharedContext;

@end


@interface GLImage ()

@property (nonatomic, assign) CGSize size;
@property (nonatomic, assign) CGFloat scale;
@property (nonatomic, assign) GLuint texture;
@property (nonatomic, assign) CGSize textureSize;
@property (nonatomic, assign) GLfloat *textureCoords;
@property (nonatomic, assign) CGRect clipRect;
@property (nonatomic, getter = isRotated) BOOL rotated;
@property (nonatomic, assign) BOOL premultipliedAlpha;
@property (nonatomic, strong) GLImage *superimage;

@end


@implementation GLImage

@synthesize size = _size;
@synthesize scale = _scale;
@synthesize texture = _texture;
@synthesize textureSize = _textureSize;
@synthesize textureCoords = _textureCoords;
@synthesize clipRect = _clipRect;
@synthesize rotated = _rotated;
@synthesize premultipliedAlpha = _premultipliedAlpha;
@synthesize superimage = _superimage;


#pragma mark -
#pragma mark Caching

static NSCache *imageCache = nil;

+ (void)initialize
{
    imageCache = [[NSCache alloc] init];
}

+ (GLImage *)imageNamed:(NSString *)nameOrPath
{
    NSString *path = [nameOrPath absolutePathWithDefaultExtensions:@"png", nil];
    GLImage *image = nil;
    if (path)
    {
        image = [imageCache objectForKey:path];
        if (!image)
        {
            image = [self imageWithContentsOfFile:path];
            if (image)
            {
                [imageCache setObject:image forKey:path];
            }
        }
    }
    return image;
}


#pragma mark -
#pragma mark Loading

+ (GLImage *)imageWithContentsOfFile:(NSString *)nameOrPath
{
    return AH_AUTORELEASE([[self alloc] initWithContentsOfFile:nameOrPath]);
}

+ (GLImage *)imageWithUIImage:(UIImage *)image
{
    return AH_AUTORELEASE([[self alloc] initWithUIImage:image]);
}

+ (GLImage *)imageWithSize:(CGSize)size scale:(CGFloat)scale drawingBlock:(GLImageDrawingBlock)drawingBlock
{
    return AH_AUTORELEASE([[self alloc] initWithSize:size scale:scale drawingBlock:drawingBlock]);
}

+ (GLImage *)imageWithData:(NSData *)data scale:(CGFloat)scale
{
    return AH_AUTORELEASE([[self alloc] initWithData:data scale:scale]);
}

- (GLImage *)initWithContentsOfFile:(NSString *)nameOrPath
{
    //normalise path
    NSString *path = [nameOrPath absolutePathWithDefaultExtensions:@"png", nil];
    
    //get scale factor
    CGFloat scale = [path imageScaleValue];
    
    //load data
    NSData *data = [NSData dataWithContentsOfFile:path];
    return [self initWithData:data scale:scale];
}

- (GLImage *)initWithUIImage:(UIImage *)image
{
    if (image)
    {
        return [self initWithSize:image.size scale:image.scale drawingBlock:^(CGContextRef context)
        {
            [image drawAtPoint:CGPointZero];
        }];
    }
    
    //no image supplied
    AH_RELEASE(self);
    return nil;
}

- (GLImage *)initWithSize:(CGSize)size scale:(CGFloat)scale drawingBlock:(GLImageDrawingBlock)drawingBlock
{
    if ((self = [super init]))
    {
        //dimensions and scale
        self.scale = scale;
        self.size = size;
        self.textureSize = CGSizeMake(powf(2.0f, ceilf(log2f(size.width * scale))),
                                      powf(2.0f, ceilf(log2f(size.height * scale))));
        
        
        //clip rect
        self.clipRect = CGRectMake(0.0f, 0.0f, size.width * scale, size.height * scale);
        
        //alpha
        self.premultipliedAlpha = YES;
        
        //create cg context
        GLint width = self.textureSize.width;
        GLint height = self.textureSize.height;
        void *imageData = calloc(height * width, 4);
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        CGContextRef context = CGBitmapContextCreate(imageData, width, height, 8, 4 * width, colorSpace,
                                                     kCGBitmapByteOrder32Big | kCGImageAlphaPremultipliedLast);
        CGColorSpaceRelease(colorSpace);
        
        //perform drawing
        CGContextTranslateCTM(context, 0, self.textureSize.height);
        CGContextScaleCTM(context, self.scale, -self.scale);
        UIGraphicsPushContext(context);
        if (drawingBlock) drawingBlock(context);
        UIGraphicsPopContext();
        
        //bind gl context
        if (![EAGLContext currentContext])
        {
            [EAGLContext setCurrentContext:[GLView sharedContext]];
        }
        
        //create texture
        glGenTextures(1, &_texture);
        glBindTexture(GL_TEXTURE_2D, self.texture);
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR); 
        glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
        glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA, GL_UNSIGNED_BYTE, imageData);
        
        //free cg context
        CGContextRelease(context);
        free(imageData);
    }
    return self;
}

- (GLImage *)initWithData:(NSData *)data scale:(CGFloat)scale
{
    //attempt to load as PVR first
    if ([data length] >= sizeof(PVRTextureHeader))
    {
        //parse header
        PVRTextureHeader *header = (PVRTextureHeader *)[data bytes];
        
        //check magic number
        if (CFSwapInt32HostToBig(header->magicNumber) == 'PVR!')
        {
            //initalize
            if ((self = [super init]))
            {
                //dimensions
                GLint width = header->width;
                GLint height = header->height;
                self.scale = scale;
                self.size = CGSizeMake((float)width/self.scale, (float)height/self.scale);
                self.textureSize = CGSizeMake(width, height);
                self.clipRect = CGRectMake(0.0f, 0.0f, width, height);
                
                //format
                BOOL compressed;
                NSInteger bitsPerPixel;
                GLuint type;
                GLuint format;
                self.premultipliedAlpha = NO;
                BOOL hasAlpha = header->alphaBitMask;
                switch (header->pixelFormatFlags & 0xff)
                {
                    case OGL_RGBA_4444:
                    {
                        compressed = NO;
                        bitsPerPixel = 16;
                        format = GL_RGBA;
                        type = GL_UNSIGNED_SHORT_4_4_4_4;
                        break;
                    }
                    case OGL_RGBA_5551:
                    {
                        compressed = NO;
                        bitsPerPixel = 16;
                        format = GL_RGBA;
                        type = GL_UNSIGNED_SHORT_5_5_5_1;
                        break;
                    }
                    case OGL_RGBA_8888:
                    {
                        compressed = NO;
                        bitsPerPixel = 32;
                        format = GL_RGBA;
                        type = GL_UNSIGNED_BYTE;
                        break;
                    }
                    case OGL_RGB_565:
                    {
                        compressed = NO;
                        bitsPerPixel = 16;
                        format = GL_RGB;
                        type = GL_UNSIGNED_SHORT_5_6_5;
                        break;
                    }
                    case OGL_RGB_555:
                    {
                        NSLog(@"RGB 555 PVR format is not currently supported");
                        AH_RELEASE(self);
                        return nil;
                    }
                    case OGL_RGB_888:
                    {
                        compressed = NO;
                        bitsPerPixel = 24;
                        format = GL_RGB;
                        type = GL_UNSIGNED_BYTE;
                        break;
                    }
                    case OGL_I_8:
                    {
                        NSLog(@"I8 PVR format is not currently supported");
                        AH_RELEASE(self);
                        return nil;
                    }
                    case OGL_AI_88:
                    {
                        NSLog(@"AI88 PVR format is not currently supported");
                        AH_RELEASE(self);
                        return nil;
                    }
                    case OGL_PVRTC2:
                    {
                        compressed = YES;
                        bitsPerPixel = 2;
                        format = hasAlpha? GL_COMPRESSED_RGBA_PVRTC_2BPPV1_IMG: GL_COMPRESSED_RGB_PVRTC_2BPPV1_IMG;
                        type = 0;
                        break;
                    }
                    case OGL_PVRTC4:
                    {
                        compressed = YES;
                        bitsPerPixel = 4;
                        format = hasAlpha? GL_COMPRESSED_RGBA_PVRTC_4BPPV1_IMG: GL_COMPRESSED_RGB_PVRTC_4BPPV1_IMG;
                        type = 0;
                        break;
                    }
                    default:
                    {
                        NSLog(@"Unrecognised PVR image format: %i", header->pixelFormatFlags & 0xff);
                        AH_RELEASE(self);
                        return nil;
                    }
                }
                
                //bind context
                [EAGLContext setCurrentContext:[GLView performSelector:@selector(sharedContext)]];
                
                //create texture
                glGenTextures(1, &_texture);
                glBindTexture(GL_TEXTURE_2D, self.texture);
                glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MIN_FILTER,GL_LINEAR);
                glTexParameteri(GL_TEXTURE_2D,GL_TEXTURE_MAG_FILTER,GL_LINEAR);
                if (compressed)
                {
                    glCompressedTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0,
                                           MAX(32, width * height * bitsPerPixel / 8),
                                           [data bytes] + header->headerSize);
                }
                else
                {
                    glTexImage2D(GL_TEXTURE_2D, 0, format, width, height, 0, format, type,
                                 [data bytes] + header->headerSize);
                }
            }
            return self;
        }
    }

    //attempt to load as regular image
    UIImage *image = [UIImage imageWithData:data];
    image = [UIImage imageWithCGImage:image.CGImage scale:scale orientation:UIImageOrientationUp];
    return [self initWithUIImage:image];
}

- (void)dealloc
{
    if (!_superimage) glDeleteTextures(1, &_texture);
    if (_textureCoords) free(_textureCoords);
    AH_RELEASE(_superimage);
    AH_SUPER_DEALLOC;
}


#pragma mark -
#pragma mark Copying

- (id)copyWithZone:(NSZone *)zone
{
    GLImage *copy = [[[self class] allocWithZone:zone] init];
    copy.superimage = self.superimage ?: self;
    copy.texture = self.texture;
    copy.premultipliedAlpha = self.premultipliedAlpha;
    copy.scale = self.scale;
    copy.size = self.size;
    copy.textureSize = self.textureSize;
    copy.clipRect = self.clipRect;
    return copy;
}

- (GLImage *)imageWithPremultipliedAlpha:(BOOL)premultipliedAlpha
{
    GLImage *copy = AH_AUTORELEASE([self copy]);
    copy.premultipliedAlpha = premultipliedAlpha;
    return copy;
}

- (GLImage *)imageWithClipRect:(CGRect)clipRect
{
    GLImage *copy = AH_AUTORELEASE([self copy]);
    copy.clipRect = clipRect;
    copy.size = CGSizeMake(clipRect.size.width / copy.scale, clipRect.size.height / copy.scale);
    return copy;
}

- (GLImage *)imageWithScale:(CGFloat)scale
{
    CGFloat deltaScale = scale / self.scale;
    GLImage *copy = AH_AUTORELEASE([self copy]);
    copy.scale = scale;
    copy.size = CGSizeMake(copy.size.width * deltaScale, copy.size.height * deltaScale);
    return copy;
}

- (GLImage *)imageWithSize:(CGSize)size
{
    GLImage *copy = AH_AUTORELEASE([self copy]);
    copy.size = size;
    return copy;
}


#pragma mark -
#pragma mark Drawing

- (void)bindTexture
{
    glEnable(GL_TEXTURE_2D);
    glEnable(GL_BLEND);
    glBlendFunc(self.premultipliedAlpha? GL_ONE: GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    glBindTexture(GL_TEXTURE_2D, self.texture);
}

- (void)drawAtPoint:(CGPoint)point
{
    [self drawInRect:CGRectMake(point.x, point.y, self.size.width, self.size.height)];
}

- (GLfloat *)textureCoords
{
    if (_textureCoords == NULL)
    {
        //normalise coordinates
        CGRect clipRect = self.clipRect;
        clipRect.origin.x /= self.textureSize.width;
        clipRect.origin.y /= self.textureSize.height;
        clipRect.size.width /= self.textureSize.width;
        clipRect.size.height /= self.textureSize.height;
        
        //set non-rotated coordinates
        _textureCoords = malloc(8 * sizeof(GLfloat));
        _textureCoords[0] = clipRect.origin.x;
        _textureCoords[1] = clipRect.origin.y;
        _textureCoords[2] = clipRect.origin.x + clipRect.size.width;
        _textureCoords[3] = clipRect.origin.y;
        _textureCoords[4] = clipRect.origin.x + clipRect.size.width;
        _textureCoords[5] = clipRect.origin.y + clipRect.size.height;
        _textureCoords[6] = clipRect.origin.x;
        _textureCoords[7] = clipRect.origin.y + clipRect.size.height;
        
        if (self.rotated)
        {
            //rotate coordinates 90 degrees anticlockwise
            GLfloat u = _textureCoords[0];
            GLfloat v = _textureCoords[1];
            _textureCoords[0] = _textureCoords[2];
            _textureCoords[1] = _textureCoords[3];
            _textureCoords[2] = _textureCoords[4];
            _textureCoords[3] = _textureCoords[5];
            _textureCoords[4] = _textureCoords[6];
            _textureCoords[5] = _textureCoords[7];
            _textureCoords[6] = u;
            _textureCoords[7] = v;
        }
    }
    return _textureCoords;
}

- (void)drawInRect:(CGRect)rect
{    
    GLfloat vertices[] =
    {
        rect.origin.x, rect.origin.y,
        rect.origin.x + rect.size.width, rect.origin.y,
        rect.origin.x + rect.size.width, rect.origin.y + rect.size.height,
        rect.origin.x, rect.origin.y + rect.size.height
    };

    [self bindTexture];
    
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisableClientState(GL_NORMAL_ARRAY);
    
    glVertexPointer(2, GL_FLOAT, 0, vertices);
    glTexCoordPointer(2, GL_FLOAT, 0, self.textureCoords);
    glDrawArrays(GL_TRIANGLE_FAN, 0, 4);
}

@end
