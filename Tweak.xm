// 动态岛 — ios16dao 功能复刻（纯净自研版）
// 与 Axs《动态岛 ios16.0~17.0 2025》功能一一对应，但不含：
//   设备指纹 / 激活码校验 / 联网代码 / 混淆字符串。
// 全部素材来自用户目录 /var/mobile/ios16dao，插件本体只含逻辑。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <notify.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <math.h>
#import <stdio.h>

static NSString *const DAOVersion  = @"1.0.0";
static const char *const DAONotify = "com.minis.ios16dao/changed";
static NSString *const DAORoot     = @"/var/mobile/ios16dao";
static NSString *const DAOLogPath  = @"/var/mobile/ios16dao.log";
static CFStringRef const kDAODomain = CFSTR("com.minis.ios16dao");
static NSString *const DAOFrameDir  = @"帧率素材";

#pragma mark - 日志

static void DAOLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSString *line = [NSString stringWithFormat:@"[%.1f] %@\n", CFAbsoluteTimeGetCurrent(), msg];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        FILE *fp = fopen(DAOLogPath.UTF8String, "a");
        if (fp) { fputs(line.UTF8String, fp); fclose(fp); }
    });
}

#pragma mark - 设置读取

static NSMutableDictionary<NSString *, NSNumber *> *gNumCache;
static NSTimeInterval gNumAt = -1e9;

static id DAOPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kDAODomain));
}

static NSNumber *DAONum(NSString *key, double fallback) {
    NSTimeInterval now = CACurrentMediaTime();
    if (!gNumCache || now - gNumAt > 0.5) { gNumCache = [NSMutableDictionary dictionary]; gNumAt = now; }
    NSNumber *c = gNumCache[key];
    if (c) return c;
    id v = DAOPref(key);
    NSNumber *r = @(v ? [v doubleValue] : fallback);
    if ([v isKindOfClass:[NSNumber class]]) r = v;
    gNumCache[key] = r;
    return r;
}

static BOOL DAOBool(NSString *key, BOOL fallback) { return DAONum(key, fallback).boolValue; }
static double DAODouble(NSString *key, double fallback, double lo, double hi) {
    return MAX(lo, MIN(hi, DAONum(key, fallback).doubleValue));
}

static NSString *DAOString(NSString *key) {
    id v = DAOPref(key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSArray *DAOArray(NSString *key) {
    id v = DAOPref(key);
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

static void DAOFlush(void) {
    gNumCache = nil; gNumAt = -1e9;
}

// 总开关：展开态 / 小岛态
static BOOL DAOExpandedOn(void) { return DAOBool(@"islandgv_enabled", NO); }
static BOOL DAOPillOn(void)     { return DAOBool(@"islandgv_island_enabled", NO); }
static BOOL DAOAnyOn(void)      { return DAOExpandedOn() || DAOPillOn(); }

static NSString *DAORootDir(void) {
    NSString *v = DAOString(@"islandgv_root");
    return [(v.length ? v : DAORoot) stringByStandardizingPath];
}

static BOOL DAOPowerSaving(void) { return DAOBool(@"islandgv_power_saving", NO); }

#pragma mark - 素材（逐帧 PNG / GIF / MP4）

static NSString *DAOSelectedFolder(void) { return DAOString(@"islandgv_folder"); }

static NSString *DAOFramesDir(NSInteger kind) {   // 0 = dance / 右侧, 1 = eye / 左侧
    NSString *sub = kind == 0 ? @"dance" : @"eye";
    return [[[DAORootDir() stringByAppendingPathComponent:DAOFrameDir] stringByAppendingPathComponent:sub]
            stringByStandardizingPath];
}

static NSString *DAOMaskPath(void) {
    return [[[DAORootDir() stringByAppendingPathComponent:DAOFrameDir] stringByAppendingPathComponent:@"mask"]
            stringByAppendingPathComponent:@"Mask.png"];
}

static BOOL DAOIsDir(NSString *path) {
    BOOL d = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&d] && d;
}

static NSInteger DAONumberInName(NSString *name) {
    NSMutableString *digits = [NSMutableString string];
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c >= '0' && c <= '9') [digits appendFormat:@"%C", c];
        else if (digits.length) break;
    }
    return digits.length ? digits.integerValue : 0;
}

static NSArray<NSString *> *DAOMediaFilesIn(NSString *dir) {
    if (!dir.length || !DAOIsDir(dir)) return @[];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    NSMutableArray<NSString *> *videos = [NSMutableArray array];
    NSMutableArray<NSString *> *gifs = [NSMutableArray array];
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:NULL]) {
        if ([n hasPrefix:@"."]) continue;
        NSString *ext = n.pathExtension.lowercaseString;
        if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"]) [videos addObject:n];
        else if ([ext isEqualToString:@"gif"]) [gifs addObject:n];
        else if ([ext isEqualToString:@"png"] || [ext isEqualToString:@"jpg"] ||
                 [ext isEqualToString:@"jpeg"] || [ext isEqualToString:@"webp"]) [images addObject:n];
    }
    NSArray *ordered = videos.count ? videos : (gifs.count ? gifs : images);
    NSMutableArray *replay = [NSMutableArray array];
    for (NSString *n in ordered) if ([n.lowercaseString hasPrefix:@"replay"]) [replay addObject:n];
    NSArray *use = replay.count ? replay : ordered;
    return [use sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger na = DAONumberInName(a), nb = DAONumberInName(b);
        if (na != nb) return na < nb ? NSOrderedAscending : NSOrderedDescending;
        return [a compare:b];
    }];
}

// 按「素材的清晰度」把图缩到指定最长边，避免几十张 4K PNG 常驻内存
static UIImage *DAODecodeImage(NSString *path) {
    CGFloat maxEdge = DAODouble(@"islandgv_active_decode_max_edge", 220.0, 160.0, 320.0);
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return [UIImage imageWithContentsOfFile:path];
    UIImage *out = nil;
    NSDictionary *opts = @{ (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                            (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxEdge * 3.0),
                            (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES };
    CGImageRef thumb = CGImageSourceCreateThumbnailAtIndex(src, 0, (__bridge CFDictionaryRef)opts);
    if (thumb) {
        out = [UIImage imageWithCGImage:thumb scale:3.0 orientation:UIImageOrientationUp];
        CGImageRelease(thumb);
    }
    CFRelease(src);
    return out ?: [UIImage imageWithContentsOfFile:path];
}

static NSArray<UIImage *> *gLeftFrames, *gRightFrames;
static NSString *gLeftKey, *gRightKey;

static NSArray<UIImage *> *DAOLoadFrames(NSInteger kind) {
    NSString *dir = DAOFramesDir(kind);
    if (!DAOIsDir(dir)) return nil;
    NSString *key = [NSString stringWithFormat:@"%@|%.0f", dir, DAODouble(@"islandgv_active_decode_max_edge", 220, 160, 320)];
    NSArray<UIImage *> *cached = kind == 0 ? gRightFrames : gLeftFrames;
    NSString *cachedKey = kind == 0 ? gRightKey : gLeftKey;
    if (cached && [cachedKey isEqualToString:key]) return cached;

    NSMutableArray<UIImage *> *images = [NSMutableArray array];
    NSInteger cap = (NSInteger)DAODouble(@"islandgv_active_frame_cap", 999.0, 1.0, 999.0);
    for (NSString *n in DAOMediaFilesIn(dir)) {
        NSString *ext = n.pathExtension.lowercaseString;
        if (![ext isEqualToString:@"png"] && ![ext isEqualToString:@"jpg"] && ![ext isEqualToString:@"jpeg"]) continue;
        UIImage *img = DAODecodeImage([dir stringByAppendingPathComponent:n]);
        if (img) [images addObject:img];
        if ((NSInteger)images.count >= cap) break;
    }
    NSArray<UIImage *> *result = images.count ? images : nil;
    if (kind == 0) { gRightFrames = result; gRightKey = result ? key : nil; }
    else           { gLeftFrames = result;  gLeftKey = result ? key : nil; }
    DAOLog(@"frames %@ count=%lu", kind == 0 ? @"dance" : @"eye", (unsigned long)images.count);
    return result;
}

static UIImage *gMaskImage; static NSString *gMaskKey;
static UIImage *DAOMaskImage(void) {
    if (!DAOBool(@"islandgv_active_enable_mask", YES)) return nil;
    NSString *path = DAOMaskPath();
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return nil;
    if (gMaskImage && [gMaskKey isEqualToString:path]) return gMaskImage;
    gMaskImage = [UIImage imageWithContentsOfFile:path] ?: DAODecodeImage(path);
    gMaskKey = path;
    return gMaskImage;
}

static void DAOClearMediaCache(void) {
    gLeftFrames = nil; gRightFrames = nil; gLeftKey = nil; gRightKey = nil;
    gMaskImage = nil; gMaskKey = nil;
}

// 选中的素材文件夹（支持 mp4 / gif / png）
static NSArray *DAOFolderMedia(void) {
    NSString *folder = DAOSelectedFolder();
    if (!folder.length) return nil;
    NSString *dir = [DAORootDir() stringByAppendingPathComponent:folder];
    NSArray *files = DAOMediaFilesIn(dir);
    return files.count ? files : nil;
}

static NSString *DAOFolderMediaPath(void) {
    NSArray *files = DAOFolderMedia();
    if (!files.count) return nil;
    NSString *folder = DAOSelectedFolder();
    return [[DAORootDir() stringByAppendingPathComponent:folder] stringByAppendingPathComponent:files.firstObject];
}

#pragma mark - 逐帧精灵

@interface DAOSpriteView : UIImageView
- (void)play:(NSArray<UIImage *> *)frames interval:(CGFloat)interval;
- (void)halt;
@end

@implementation DAOSpriteView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeScaleAspectFit;
        self.backgroundColor = UIColor.clearColor;
        self.layer.masksToBounds = NO;
    }
    return self;
}
- (void)play:(NSArray<UIImage *> *)frames interval:(CGFloat)interval {
    if (frames.count == 0) return;
    CGFloat d = MAX(0.01, interval) * frames.count;
    if (self.animationImages == frames && fabs(self.animationDuration - d) < 0.004) {
        if (!self.isAnimating) [self startAnimating];
        return;
    }
    [self stopAnimating];
    self.animationImages = frames;
    self.animationDuration = d;
    self.animationRepeatCount = 0;
    [self startAnimating];
}
- (void)halt {
    [self stopAnimating];
    self.animationImages = nil;
}
@end

static NSArray<UIImage *> *DAOGIFFrames(NSString *path);

@interface DAOMediaView : UIView
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) AVPlayer *player;
- (void)showPath:(NSString *)path;
- (void)halt;
@end

@implementation DAOMediaView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        _imageView = [[UIImageView alloc] initWithFrame:self.bounds];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.userInteractionEnabled = NO;
        _imageView.backgroundColor = UIColor.clearColor;
        [self addSubview:_imageView];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.imageView.frame = self.bounds;
    self.playerLayer.frame = self.bounds;
}
- (void)showPath:(NSString *)path {
    if (!path.length) { [self halt]; return; }
    NSString *ext = path.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"mp4"] || [ext isEqualToString:@"mov"]) {
        self.imageView.hidden = YES;
        [self.imageView stopAnimating];
        if (!self.player) {
            self.player = [AVPlayer playerWithURL:[NSURL fileURLWithPath:path]];
            self.player.muted = YES;
            self.player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
            self.playerLayer = [AVPlayerLayer playerLayerWithPlayer:self.player];
            self.playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
            [self.layer addSublayer:self.playerLayer];
            self.playerLayer.frame = self.bounds;
        }
        if (self.player.currentItem == nil ||
            ![self.player.currentItem.asset isKindOfClass:[AVURLAsset class]] ||
            ![[(AVURLAsset *)self.player.currentItem.asset URL].path isEqualToString:path]) {
            AVPlayerItem *item = [AVPlayerItem playerItemWithURL:[NSURL fileURLWithPath:path]];
            [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(loop:)
                                                         name:AVPlayerItemDidPlayToEndTimeNotification object:item];
            [self.player replaceCurrentItemWithPlayerItem:item];
        }
        [self.player play];
        return;
    }
    [self halt];
    UIImage *img = nil;
    if ([ext isEqualToString:@"gif"]) {
        NSArray<UIImage *> *frames = DAOGIFFrames(path);
        if (frames.count > 1) {
            self.imageView.animationImages = frames;
            self.imageView.animationDuration = MAX(0.03, DAODouble(@"islandgv_active_frame_interval", 0.1, 0.01, 0.2)) * frames.count;
            self.imageView.animationRepeatCount = 0;
            [self.imageView startAnimating];
        } else {
            img = frames.firstObject;
        }
    } else {
        img = DAODecodeImage(path);
    }
    if (img) self.imageView.image = img;
    self.imageView.hidden = NO;
}
- (void)loop:(NSNotification *)note { (void)note; [self.player seekToTime:CMTimeMake(0, 1)]; [self.player play]; }
- (void)halt {
    [self.player pause];
    self.playerLayer.hidden = YES;
    [self.imageView stopAnimating];
    self.imageView.animationImages = nil;
    self.imageView.hidden = YES;
}
@end

static NSArray<UIImage *> *DAOGIFFrames(NSString *path) {
    NSMutableArray<UIImage *> *out = [NSMutableArray array];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
    if (!src) return out;
    size_t n = CGImageSourceGetCount(src);
    CGFloat maxEdge = DAODouble(@"islandgv_active_decode_max_edge", 220.0, 160.0, 320.0);
    for (size_t i = 0; i < n; i++) {
        NSDictionary *opts = @{ (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(maxEdge * 3.0),
                                (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES };
        CGImageRef g = CGImageSourceCreateThumbnailAtIndex(src, i, (__bridge CFDictionaryRef)opts);
        if (g) { [out addObject:[UIImage imageWithCGImage:g scale:3.0 orientation:UIImageOrientationUp]]; CGImageRelease(g); }
    }
    CFRelease(src);
    return out;
}

#pragma mark - 灵动光圈

static UIColor *DAOColorFromHex(NSString *hex, UIColor *fallback) {
    if (!hex.length) return fallback;
    unsigned int v = 0;
    NSScanner *sc = [NSScanner scannerWithString:[hex stringByReplacingOccurrencesOfString:@"#" withString:@""]];
    if (![sc scanHexInt:&v]) return fallback;
    return [UIColor colorWithRed:((v >> 16) & 0xFF) / 255.0
                           green:((v >> 8) & 0xFF) / 255.0
                            blue:(v & 0xFF) / 255.0 alpha:1.0];
}

static UIImage *DAOParticleImage(NSInteger style) {
    NSString *symbol = style == 0 ? @"star.fill" : (style == 1 ? @"circle.fill" : (style == 2 ? @"drop.fill" : @"snow"));
    UIImage *img = [UIImage systemImageNamed:symbol];
    if (!img) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(12, 12), NO, 0);
        [[UIColor whiteColor] setFill];
        [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, 12, 12)] fill];
        img = UIGraphicsGetImageFromCurrentImageContext();
        UIGraphicsEndImageContext();
    }
    return img;
}

@interface DAOApertureView : UIView
@property (nonatomic, strong) CAShapeLayer *ring;
@property (nonatomic, strong) CAShapeLayer *maskShape;
@property (nonatomic, strong) CAGradientLayer *rainbow;
@property (nonatomic, strong) CAEmitterLayer *emitter;
- (void)applyRect:(CGRect)rect active:(BOOL)active;
- (void)shutdown;
@end

@implementation DAOApertureView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.backgroundColor = UIColor.clearColor;
        self.layer.masksToBounds = NO;

        _ring = [CAShapeLayer layer];
        _ring.fillColor = UIColor.clearColor.CGColor;
        _ring.lineCap = kCALineCapRound;
        _ring.masksToBounds = NO;
        [self.layer addSublayer:_ring];

        _maskShape = [CAShapeLayer layer];
        _maskShape.fillColor = UIColor.clearColor.CGColor;
        _maskShape.strokeColor = UIColor.whiteColor.CGColor;
        _maskShape.lineCap = kCALineCapRound;
        _maskShape.masksToBounds = NO;

        _rainbow = [CAGradientLayer layer];
        _rainbow.type = kCAGradientLayerConic;
        _rainbow.startPoint = CGPointMake(0.5, 0.5);
        _rainbow.endPoint = CGPointMake(0.5, 0.0);
        _rainbow.colors = @[ (__bridge id)UIColor.redColor.CGColor,
                             (__bridge id)UIColor.systemOrangeColor.CGColor,
                             (__bridge id)UIColor.systemYellowColor.CGColor,
                             (__bridge id)UIColor.systemGreenColor.CGColor,
                             (__bridge id)UIColor.systemBlueColor.CGColor,
                             (__bridge id)UIColor.systemPurpleColor.CGColor,
                             (__bridge id)UIColor.redColor.CGColor ];
        _rainbow.hidden = YES;
        _rainbow.mask = _maskShape;
        [self.layer addSublayer:_rainbow];

        _emitter = [CAEmitterLayer layer];
        _emitter.emitterShape = kCAEmitterLayerRectangle;
        _emitter.renderMode = kCAEmitterLayerAdditive;
        _emitter.hidden = YES;
        [self.layer addSublayer:_emitter];
    }
    return self;
}

static void DAOSetAnim(CALayer *layer, NSString *key, NSString *path, id from, id to, CFTimeInterval dur, BOOL repeat) {
    if ([layer animationForKey:key]) return;
    CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:path];
    a.fromValue = from; a.toValue = to;
    a.duration = dur;
    a.repeatCount = repeat ? HUGE_VALF : 1;
    a.removedOnCompletion = NO;
    a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    [layer addAnimation:a forKey:key];
}

- (void)applyRect:(CGRect)rect active:(BOOL)active {
    if (!active || rect.size.width < 8 || rect.size.height < 8) {
        self.hidden = YES;
        [self shutdown];
        return;
    }
    self.hidden = NO;

    CGFloat thickness = DAODouble(@"aperture_thickness", 3.5, 1.0, 10.0);
    NSInteger style   = (NSInteger)DAODouble(@"aperture_style", 0, 0, 4);
    UIColor *color    = DAOColorFromHex(DAOString(@"aperture_color"), UIColor.systemBlueColor);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    // 视图自身就摆在岛的屏幕矩形上，子图层坐标一律用「本地坐标」（原点 0,0），
    // 这样无需任何平移换算 —— 以前按屏幕绝对坐标画路径再平移 14pt，导致整圈
    // 偏移了一个岛的坐标量（表现为光圈跑到右上角）。
    // 另外留出 pad：描边有一半线宽在路径外侧，不留边会被图层边界裁掉。
    CGFloat pad = thickness * 2.0 + 6.0;
    self.frame = CGRectInset(rect, -pad, -pad);
    self.bounds = CGRectMake(0, 0, rect.size.width + pad * 2.0, rect.size.height + pad * 2.0);
    self.ring.frame = self.bounds;
    self.maskShape.frame = self.bounds;
    self.rainbow.frame = self.bounds;
    self.emitter.frame = self.bounds;

    CGRect local = CGRectMake(pad, pad, rect.size.width, rect.size.height);
    CGRect ringRect = CGRectInset(local, -(thickness / 2.0), -(thickness / 2.0));
    CGFloat radius = MIN(ringRect.size.height, ringRect.size.width) / 2.0;
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:ringRect cornerRadius:radius];

    self.ring.path = path.CGPath;
    self.maskShape.path = path.CGPath;

    self.ring.lineWidth = thickness;
    self.maskShape.lineWidth = thickness;
    self.ring.lineDashPattern = nil;
    self.ring.strokeColor = (style == 1) ? UIColor.clearColor.CGColor : color.CGColor;
    self.ring.shadowPath = self.ring.path;
    [CATransaction commit];

    BOOL shadowOn = DAOBool(@"aperture_shadow_style", NO);
    if (shadowOn) {
        CGFloat spread = DAODouble(@"aperture_shadow_spread", 5.0, 0.0, 10.0);
        self.ring.shadowColor = (style == 1 ? UIColor.whiteColor : color).CGColor;
        self.ring.shadowRadius = spread;
        self.ring.shadowOpacity = DAODouble(@"aperture_shadow_opacity", 0.5, 0.0, 1.0);
        self.ring.shadowOffset = CGSizeMake(0, DAODouble(@"aperture_shadow_vertical_offset", 4.5, 0.0, 5.0));
        CGFloat rate = DAODouble(@"aperture_shadow_flash_rate", 10.0, 0.2, 10.0);
        if (rate < 9.9) DAOSetAnim(self.ring, @"dao.flash", @"shadowOpacity", @(self.ring.shadowOpacity), @0.0, 1.0 / rate, YES);
    } else {
        self.ring.shadowOpacity = 0.0;
        self.ring.shadowRadius = 0.0;
        [self.ring removeAnimationForKey:@"dao.flash"];
    }

    // 五种样式：0 纯色 / 1 彩虹环 / 2 彩虹流星 / 3 七色舞台灯 / 4 三段跑马灯
    if (style != 4) [self.ring removeAnimationForKey:@"dao.marquee"];
    if (style == 0) {
        self.rainbow.hidden = YES;
        [self.rainbow removeAnimationForKey:@"dao.rainbow.rotate"];
        [self.rainbow removeAnimationForKey:@"dao.stage"];
        self.ring.lineDashPattern = nil;
    } else if (style == 1) {
        self.rainbow.hidden = NO;
        self.rainbow.opacity = 1.0;
        [self.rainbow removeAnimationForKey:@"dao.stage"];
        self.rainbow.colors = @[ (__bridge id)UIColor.redColor.CGColor,
                                 (__bridge id)UIColor.systemOrangeColor.CGColor,
                                 (__bridge id)UIColor.systemYellowColor.CGColor,
                                 (__bridge id)UIColor.systemGreenColor.CGColor,
                                 (__bridge id)UIColor.systemBlueColor.CGColor,
                                 (__bridge id)UIColor.systemPurpleColor.CGColor,
                                 (__bridge id)UIColor.redColor.CGColor ];
        DAOSetAnim(self.rainbow, @"dao.rainbow.rotate", @"transform.rotation.z", @0, @(M_PI * 2), 4.0, YES);
        self.ring.lineDashPattern = nil;
    } else if (style == 2) {
        // 流星：一条亮尾绕圈，尾部用透明渐变收尾
        self.rainbow.hidden = NO;
        self.rainbow.opacity = 1.0;
        [self.rainbow removeAnimationForKey:@"dao.stage"];
        self.rainbow.colors = @[ (__bridge id)[UIColor colorWithRed:1 green:1 blue:1 alpha:0.0].CGColor,
                                 (__bridge id)[UIColor colorWithRed:1 green:1 blue:1 alpha:0.05].CGColor,
                                 (__bridge id)color.CGColor,
                                 (__bridge id)[UIColor whiteColor].CGColor ];
        DAOSetAnim(self.rainbow, @"dao.rainbow.rotate", @"transform.rotation.z", @0, @(M_PI * 2), 1.1, YES);
        self.ring.lineDashPattern = nil;
    } else if (style == 3) {
        self.rainbow.hidden = NO;
        [self.rainbow removeAnimationForKey:@"dao.rainbow.rotate"];
        self.rainbow.colors = @[ (__bridge id)UIColor.redColor.CGColor,
                                 (__bridge id)UIColor.systemOrangeColor.CGColor,
                                 (__bridge id)UIColor.systemYellowColor.CGColor,
                                 (__bridge id)UIColor.systemGreenColor.CGColor,
                                 (__bridge id)UIColor.systemBlueColor.CGColor,
                                 (__bridge id)UIColor.systemPurpleColor.CGColor,
                                 (__bridge id)UIColor.systemPinkColor.CGColor ];
        DAOSetAnim(self.rainbow, @"dao.stage", @"opacity", @1.0, @0.25, 0.22, NO);
        self.ring.lineDashPattern = nil;
    } else {
        self.rainbow.hidden = YES;
        [self.rainbow removeAnimationForKey:@"dao.rainbow.rotate"];
        [self.rainbow removeAnimationForKey:@"dao.stage"];
        self.ring.strokeColor = color.CGColor;
        self.ring.lineDashPattern = @[ @(thickness * 2.4), @(thickness * 1.6) ];
        DAOSetAnim(self.ring, @"dao.marquee", @"lineDashPhase", @0, @(thickness * 4.0), 0.9, YES);
    }

    // 背景特效：星空 / 气泡 / 雨滴 / 雪花
    if (DAOBool(@"aperture_particle_enabled", NO)) {
        NSInteger ps = (NSInteger)DAODouble(@"aperture_particle_style", 0, 0, 3);
        self.emitter.hidden = NO;
        CGPoint local = CGPointMake(self.bounds.size.width / 2.0,
                                    ps == 2 ? 0.0 : self.bounds.size.height);
        self.emitter.emitterPosition = local;
        self.emitter.emitterSize = CGSizeMake(self.bounds.size.width, 6);
        if (!self.emitter.emitterCells.count || self.emitter.name.intValue != ps + 1) {
            self.emitter.name = @(ps + 1).stringValue;
            CAEmitterCell *cell = [CAEmitterCell emitterCell];
            cell.contents = (__bridge id)DAOParticleImage(ps).CGImage;
            cell.birthRate = ps == 2 ? 60 : 22;
            cell.lifetime = ps == 2 ? 1.2 : 4.0;
            cell.velocity = ps == 2 ? -220 : -40;
            cell.velocityRange = ps == 2 ? 60 : 22;
            cell.emissionRange = M_PI * 2.0;
            cell.yAcceleration = ps == 2 ? -260 : -8;
            cell.scale = ps == 0 ? 0.10 : (ps == 1 ? 0.16 : (ps == 2 ? 0.10 : 0.12));
            cell.scaleRange = 0.05;
            cell.alphaSpeed = ps == 2 ? 0.0 : -0.26;
            cell.spin = ps == 3 ? 0.6 : 0.0;
            cell.color = (style == 1 ? UIColor.whiteColor : color).CGColor;
            self.emitter.emitterCells = @[ cell ];
        }
        self.emitter.renderMode = kCAEmitterLayerAdditive;
    } else {
        self.emitter.hidden = YES;
    }
}

- (void)shutdown {
    [self.ring removeAllAnimations];
    [self.rainbow removeAllAnimations];
    self.emitter.emitterCells = nil;
    self.emitter.hidden = YES;
}
@end

#pragma mark - 视图扫描

static NSArray<UIWindow *> *DAOAllWindows(void) {
    NSMutableArray<UIWindow *> *out = [NSMutableArray array];
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
            if ([scene isKindOfClass:[UIWindowScene class]])
                [out addObjectsFromArray:((UIWindowScene *)scene).windows];
    } @catch (...) {}
    if (out.count == 0) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        [out addObjectsFromArray:UIApplication.sharedApplication.windows];
#pragma clang diagnostic pop
    }
    return out;
}

static CGRect DAOScreenRect(UIView *v) {
    if (!v || !v.window) return CGRectZero;
    CGRect r = CGRectZero;
    @try {
        r = [v convertRect:v.bounds toView:v.window];
        r = [v.window convertRect:r toWindow:nil];
    } @catch (...) { return CGRectZero; }
    return r;
}

static BOOL DAOOnScreen(CGRect r) {
    if (r.size.width < 1.0 || r.size.height < 1.0) return NO;
    CGRect s = [UIScreen mainScreen].bounds;
    return CGRectGetMinX(r) > -12 && CGRectGetMaxX(r) < s.size.width + 12
        && CGRectGetMinY(r) > -12 && CGRectGetMaxY(r) < s.size.height + 12;
}

static NSArray<UIView *> *DAOPills(void) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIWindow *w in DAOAllWindows()) {
        [stack addObject:w];
    }
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        NSString *cn = NSStringFromClass(v.class);
        if ([cn isEqualToString:@"SBSystemApertureContainerView"] || [cn isEqualToString:@"_SBSystemApertureContainerView"]) {
            if (v.window && !v.hidden && v.alpha > 0.01) {
                // 原版判定（反汇编 0x161d4）：identifier 非空 && bounds 宽>=30 高>=20
                CGSize b = v.bounds.size;
                if (b.width >= 30.0 && b.height >= 20.0) {
                    CGRect r = DAOScreenRect(v);
                    if (DAOOnScreen(r)) [out addObject:v];
                }
            }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return out;
}

// 录屏红点：SBRecordingIndicatorView / Window 里的那个小圆点（1.5~26pt）
static NSArray<UIView *> *DAORecordingDots(void) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIWindow *w in DAOAllWindows()) {
        [stack addObject:w];
    }
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        NSString *cn = NSStringFromClass(v.class);
        if ([cn containsString:@"RecordingIndicator"]) {
            CGSize b = v.bounds.size;
            CGFloat m = MAX(b.width, b.height);
            CGFloat n = MIN(b.width, b.height);
            if (m >= 1.5 && m <= 30.0 && n >= 1.0 && v.window && !v.hidden) {
                CGRect r = DAOScreenRect(v);
                if (DAOOnScreen(r)) [out addObject:v];
            }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return out;
}

// 选出属于这块岛的红点：屏幕矩形与岛矩形相交（±4pt 容差）
static UIView *DAODotInPill(UIView *pill) {
    CGRect pr = DAOScreenRect(pill);
    if (CGRectEqualToRect(pr, CGRectZero)) return nil;
    CGRect probe = CGRectInset(pr, -4, -4);
    UIView *best = nil; CGFloat bestArea = 0;
    for (UIView *dot in DAORecordingDots()) {
        CGRect dr = DAOScreenRect(dot);
        CGRect inter = CGRectIntersection(dr, probe);
        if (CGRectIsNull(inter) || CGRectIsEmpty(inter)) continue;
        CGFloat area = inter.size.width * inter.size.height;
        if (area > bestArea) { bestArea = area; best = dot; }
    }
    return best;
}

static const void *kDotAlpha = &kDotAlpha;
static NSMutableArray<UIView *> *gHiddenDots;

// 压掉原生红点（记下原 alpha，可还原）
static void DAOHideDot(UIView *dot) {
    if (!dot || objc_getAssociatedObject(dot, kDotAlpha)) return;
    objc_setAssociatedObject(dot, kDotAlpha, @(dot.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dot.alpha = 0.0;
    if (!gHiddenDots) gHiddenDots = [NSMutableArray array];
    [gHiddenDots addObject:dot];
}

static void DAORestoreDots(void) {
    for (UIView *d in gHiddenDots) {
        NSNumber *a = objc_getAssociatedObject(d, kDotAlpha);
        if (a) { d.alpha = a.doubleValue; objc_setAssociatedObject(d, kDotAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    [gHiddenDots removeAllObjects];
}

static BOOL DAOHasTag(UIView *pill, NSString *token, NSInteger depth) {
    if (!pill || depth < 0) return NO;
    NSString *ident = pill.accessibilityIdentifier;
    if ([ident isKindOfClass:[NSString class]] && [ident containsString:token]) return YES;
    for (UIView *s in pill.subviews) if (DAOHasTag(s, token, depth - 1)) return YES;
    return NO;
}

// 岛的主容器：展开态优先取「最宽的那个」，小岛态取「最小的那个」
static UIView *DAOMainPill(BOOL *expandedOut) {
    UIView *best = nil; CGFloat bestW = -1;
    UIView *compact = nil; CGFloat compactW = 1e9;
    for (UIView *p in DAOPills()) {
        CGRect r = DAOScreenRect(p);
        if (r.origin.y > 60) continue;                 // 只取状态栏那一条
        CGFloat w = r.size.width;
        if (w > bestW) { bestW = w; best = p; }
        if (w < compactW) { compactW = w; compact = p; }
    }
    UIView *chosen = best;
    BOOL expanded = best ? (bestW > DAOScreenRect(best).size.height * 2.0) : NO;
    if (!expanded && compact) chosen = compact;
    if (expandedOut) *expandedOut = expanded;
    return chosen;
}

#pragma mark - 原生元件隐藏 / 还原

static const void *kDAOAlpha = &kDAOAlpha;
static NSMutableArray<UIView *> *gHiddenViews;

static void DAOHideView(UIView *v) {
    if (!v || objc_getAssociatedObject(v, kDAOAlpha)) return;
    objc_setAssociatedObject(v, kDAOAlpha, @(v.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.alpha = 0.0;
    if (!gHiddenViews) gHiddenViews = [NSMutableArray array];
    [gHiddenViews addObject:v];
}

static void DAORestoreAll(void) {
    for (UIView *v in gHiddenViews) {
        NSNumber *a = objc_getAssociatedObject(v, kDAOAlpha);
        if (a) { v.alpha = a.doubleValue; objc_setAssociatedObject(v, kDAOAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    [gHiddenViews removeAllObjects];
}

// 系统岛的黑色背板是 MTMaterialView / _SBGainMapView；压掉它们才能只留素材
static void DAOHideBackdropIn(UIView *pill, BOOL withDot) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:pill];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        NSString *cn = NSStringFromClass(v.class);
        BOOL backdrop = [cn containsString:@"MTMaterialView"] || [cn containsString:@"GainMap"]
                     || [cn containsString:@"Backdrop"] || [cn containsString:@"Platter"];
        BOOL dot = withDot && [cn containsString:@"RecordingIndicator"];
        if (backdrop || dot) DAOHideView(v);
        for (UIView *s in v.subviews) [stack addObject:s];
    }
}

#pragma mark - 应用屏蔽

static NSString *DAOFrontmostBundle(void) {
    @try {
        Class c = objc_getClass("SBApplicationController");
        if (!c) return nil;
        id ctrl = ((id (*)(id, SEL))objc_msgSend)((id)c, sel_registerName("sharedInstance"));
        if (!ctrl) return nil;
        SEL sel = sel_registerName("frontmostApplication");
        if (![ctrl respondsToSelector:sel]) return nil;
        id app = ((id (*)(id, SEL))objc_msgSend)(ctrl, sel);
        SEL bid = sel_registerName("bundleIdentifier");
        if (app && [app respondsToSelector:bid])
            return ((id (*)(id, SEL))objc_msgSend)(app, bid);
    } @catch (...) {}
    return nil;
}

static BOOL DAOAppExcluded(void) {
    NSArray *list = DAOArray(@"islandgv_excluded_apps");
    if (!list.count) return NO;
    NSString *front = DAOFrontmostBundle();
    if (!front.length) return NO;
    return [list containsObject:front];
}

#pragma mark - 素材摆放

static DAOSpriteView *gLeftSprite, *gRightSprite;
static DAOMediaView *gLeftMedia, *gRightMedia;
static UIImageView *gSpinView;
static DAOApertureView *gAperture;
static NSString *gMediaPathLeft, *gMediaPathRight;

static DAOSpriteView *DAOSprite(BOOL left) {
    // 不建覆盖层：视图直接挂进岛容器
    if (!NSThread.isMainThread) return nil;
    __strong DAOSpriteView **slot = left ? &gLeftSprite : &gRightSprite;
    if (!*slot) {
        DAOSpriteView *v = [[DAOSpriteView alloc] initWithFrame:CGRectZero];
        v.hidden = YES;
        *slot = v;
    }
    return *slot;
}

static DAOMediaView *DAOMedia(BOOL left) {
    if (!NSThread.isMainThread) return nil;
    __strong DAOMediaView **slot = left ? &gLeftMedia : &gRightMedia;
    if (!*slot) {
        DAOMediaView *v = [[DAOMediaView alloc] initWithFrame:CGRectZero];
        v.hidden = YES;
        *slot = v;
    }
    return *slot;
}

static void DAOHideSprite(BOOL left) {
    __strong DAOSpriteView **s = left ? &gLeftSprite : &gRightSprite;
    __strong DAOMediaView **m = left ? &gLeftMedia : &gRightMedia;
    if (*s) { [(*s) halt]; (*s).hidden = YES; (*s).frame = CGRectZero; }
    if (*m) { [(*m) halt]; (*m).hidden = YES; (*m).frame = CGRectZero; }
}

static CGRect DAOSquare(CGPoint center, CGFloat side) {
    return CGRectMake(center.x - side / 2.0, center.y - side / 2.0, side, side);
}

// 左侧 = 写轮眼（录屏），右侧 = 跳舞（音乐）
// 结构照原版：视图直接 addSubview 到灵动岛容器里（原版叫 axsContainer），
// 用「岛内本地坐标」摆放 —— 不再用覆盖层窗口 + 屏幕坐标，那套会飘出岛外。
#pragma mark - 配置快照（原版 0x16694 的变更检测，阈值 0.0001）
//
// 原版在这里判断：album/dance 开关 + interval 与上一次完全一致时，
// 直接复用已有视图、只更新 frame，不拆不建。这是它流畅的根本原因。
// 我原来每次扫描都走一遍 play/halt，视图被反复重建 → 卡顿、闪烁。

typedef struct {
    BOOL album, dance, mask, captured;
    CGFloat interval, leftSize, rightSize, leftOff, rightOff, scale, alpha, maxEdge;
    BOOL valid;
} DAOConfigSnapshot;

static DAOConfigSnapshot gSnapshot;

static DAOConfigSnapshot DAOCurrentConfig(void) {
    DAOConfigSnapshot c;
    c.album    = DAOBool(@"islandgv_active_custom_album", NO);
    c.dance    = DAOBool(@"islandgv_active_custom_dance", NO);
    c.mask     = DAOBool(@"islandgv_active_enable_mask", YES);
    c.captured = [UIScreen mainScreen].isCaptured;
    c.interval = DAODouble(@"islandgv_active_frame_interval", 0.1, 0.01, 0.2);
    c.leftSize = DAODouble(@"islandgv_active_left_size", 0.9, 0.6, 2.0);
    c.rightSize= DAODouble(@"islandgv_active_right_size", 0.9, 0.6, 2.0);
    c.leftOff  = DAODouble(@"islandgv_active_left_offset", 1.5, -10.0, 10.0);
    c.rightOff = DAODouble(@"islandgv_active_right_offset", 1.5, -10.0, 10.0);
    c.scale    = DAODouble(@"islandgv_scale", 1.0, 0.5, 1.5);
    c.alpha    = DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0);
    c.maxEdge  = DAODouble(@"islandgv_active_decode_max_edge", 220.0, 160.0, 320.0);
    c.valid    = YES;
    return c;
}

static BOOL DAOConfigChanged(void) {
    if (!gSnapshot.valid) return YES;
    DAOConfigSnapshot c = DAOCurrentConfig();
    if (c.album != gSnapshot.album || c.dance != gSnapshot.dance ||
        c.mask != gSnapshot.mask || c.captured != gSnapshot.captured) return YES;
    // 浮点按原版的 1e-4 精度比较，避免拖滑块时每次微小抖动都重建
    if (fabs(c.interval  - gSnapshot.interval)  > 1e-4) return YES;
    if (fabs(c.leftSize  - gSnapshot.leftSize)  > 1e-4) return YES;
    if (fabs(c.rightSize - gSnapshot.rightSize) > 1e-4) return YES;
    if (fabs(c.leftOff   - gSnapshot.leftOff)   > 1e-4) return YES;
    if (fabs(c.rightOff  - gSnapshot.rightOff)  > 1e-4) return YES;
    if (fabs(c.scale     - gSnapshot.scale)     > 1e-4) return YES;
    if (fabs(c.alpha     - gSnapshot.alpha)     > 1e-4) return YES;
    if (fabs(c.maxEdge   - gSnapshot.maxEdge)   > 1e-4) return YES;
    return NO;
}

static void DAOReparent(UIView *v, UIView *host) {
    if (!v || !host) return;
    if (v.superview != host) {
        [v removeFromSuperview];
        [host addSubview:v];
    }
    [host bringSubviewToFront:v];
}

static BOOL DAOPlaceSide(BOOL left, UIView *pill, CGRect pillRect,
                         CGFloat sideFactor, CGFloat offset, CGFloat scale, CGFloat alpha) {
    if (!pill) { DAOHideSprite(left); return NO; }
    CGRect pb = pill.bounds;
    if (pb.size.height < 8 || pb.size.width < 8) { DAOHideSprite(left); return NO; }

    CGFloat interval = DAODouble(@"islandgv_active_frame_interval", 0.1, 0.01, 0.2);
    CGFloat h = pb.size.height;

    // 尺寸：以岛高为基准，原版默认 0.90x
    CGFloat side = h * MAX(0.1, sideFactor) * MAX(0.4, scale);
    side = MIN(side, h * 1.10);

    // 圆心：优先用红点在岛内的真实中心；没有红点就贴该侧端点圆心
    CGPoint center;
    UIView *dot = left ? DAODotInPill(pill) : nil;
    if (dot && dot.window) {
        CGRect local = CGRectZero;
        @try { local = [dot convertRect:dot.bounds toView:pill]; } @catch (...) {}
        if (local.size.width > 0.5 && local.size.height > 0.5) {
            center = CGPointMake(CGRectGetMidX(local) + offset, CGRectGetMidY(local));
            side = MAX(side, MAX(local.size.width, local.size.height) * 1.30);
            side = MIN(side, h * 1.25);
            DAOHideDot(dot);
        } else {
            center = left ? CGPointMake(h / 2.0 + offset, h / 2.0)
                          : CGPointMake(pb.size.width - h / 2.0 - offset, h / 2.0);
        }
    } else {
        center = left ? CGPointMake(h / 2.0 + offset, h / 2.0)
                      : CGPointMake(pb.size.width - h / 2.0 - offset, h / 2.0);
    }

    // 夹在岛内，避免整块跑出去
    CGFloat half = side / 2.0;
    center.x = MAX(half - h * 0.5, MIN(pb.size.width - half + h * 0.5, center.x));
    center.y = MAX(half - h * 0.5, MIN(pb.size.height - half + h * 0.5, center.y));
    side = MIN(side, MAX(pb.size.width, pb.size.height) * 1.2);
    half = side / 2.0;
    CGRect frame = CGRectMake(center.x - half, center.y - half, side, side);

    // 1) 选中的素材文件夹（mp4 / gif / png）优先
    NSString *mediaPath = DAOFolderMediaPath();
    __strong NSString **lastPath = left ? &gMediaPathLeft : &gMediaPathRight;
    if (mediaPath.length) {
        __strong DAOSpriteView **sp = left ? &gLeftSprite : &gRightSprite;
        if (*sp && (*sp).superview) { [(*sp) halt]; (*sp).hidden = YES; }
        DAOMediaView *mv = DAOMedia(left);
        if (!mv) return NO;
        DAOReparent(mv, pill);
        if (!CGRectEqualToRect(mv.frame, frame)) [CATransaction setDisableActions:YES];
        mv.frame = frame;
        mv.hidden = NO;
        mv.alpha = alpha;
        if (![*lastPath isEqualToString:mediaPath]) {
            [mv showPath:mediaPath];
            *lastPath = mediaPath;
        }
        return YES;
    }

    // 2) 帧率素材 PNG 序列
    {
        __strong DAOMediaView **mv = left ? &gLeftMedia : &gRightMedia;
        if (*mv) { [(*mv) halt]; (*mv).hidden = YES; [(*mv) removeFromSuperview]; }
        *lastPath = nil;
    }
    NSArray<UIImage *> *frames = DAOLoadFrames(left ? 1 : 0);
    if (!frames.count) { DAOHideSprite(left); return NO; }
    DAOSpriteView *sp = DAOSprite(left);
    if (!sp) return NO;
    DAOReparent(sp, pill);
    sp.frame = frame;
    sp.hidden = NO;
    sp.alpha = alpha;
    [sp play:frames interval:interval];
    return YES;
}

static UIImageView *DAOArtworkInPill(UIView *pill, CGRect *visibleOut) {
    CGRect pr = DAOScreenRect(pill);
    if (CGRectEqualToRect(pr, CGRectZero)) return nil;
    UIImageView *best = nil; CGRect bestVis = CGRectZero; CGFloat bestScore = -1;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:pill];
    while (stack.count) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([v isKindOfClass:[UIImageView class]]) {
            UIImageView *iv = (UIImageView *)v;
            if (iv.image) {
                CGRect vis = CGRectIntersection(DAOScreenRect(iv), pr);
                if (vis.size.height >= 14 && vis.size.width >= 14) {
                    CGFloat sq = 1.0 - fabs(vis.size.width - vis.size.height) / MAX(vis.size.width, vis.size.height);
                    BOOL art = [NSStringFromClass(v.class).lowercaseString containsString:@"artwork"];
                    CGFloat score = sq * 2.0 + (art ? 1.5 : 0.0);
                    if (score > bestScore) { bestScore = score; best = iv; bestVis = vis; }
                }
            }
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    if (best && visibleOut) *visibleOut = bestVis;
    return best;
}

static const void *kArtAlpha = &kArtAlpha;
static NSMutableArray<UIImageView *> *gHiddenArtwork;

// 圆形旋转封面：原封面常是整屏大图，直接转会偏心 → 在覆盖层里重建
static void DAOPlaceSpin(UIView *pill) {
    if (!DAOBool(@"islandgv_active_enable_mask", YES)) {
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
        return;
    }
    if (!pill || !DAOHasTag(pill, @"NowPlaying", 5)) {
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
        return;
    }
    CGRect vis = CGRectZero;
    UIImageView *art = DAOArtworkInPill(pill, &vis);
    if (!art || vis.size.height < 16) {
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
        return;
    }
    CGFloat diameter = MIN(vis.size.height, vis.size.width);
    CGRect frame = DAOSquare(CGPointMake(CGRectGetMidX(vis), CGRectGetMidY(vis)), diameter);

    if (!gSpinView) {
        gSpinView = [[UIImageView alloc] initWithFrame:CGRectZero];
        gSpinView.userInteractionEnabled = NO;
        gSpinView.contentMode = UIViewContentModeScaleAspectFill;
        gSpinView.backgroundColor = UIColor.clearColor;
        gSpinView.layer.masksToBounds = YES;
    }
    if (gSpinView.superview != pill) {
        [gSpinView removeFromSuperview];
        [pill addSubview:gSpinView];
    }
    [pill bringSubviewToFront:gSpinView];
    if (gSpinView.image != art.image) gSpinView.image = art.image;
    gSpinView.layer.cornerRadius = diameter / 2.0;
    gSpinView.layer.mask = nil;

    UIImage *mask = DAOMaskImage();
    if (mask && mask.CGImage) {
        CALayer *m = [CALayer layer];
        m.frame = CGRectMake(0, 0, diameter, diameter);
        m.contentsGravity = kCAGravityResize;
        m.contents = (__bridge id)mask.CGImage;
        gSpinView.layer.cornerRadius = 0;
        gSpinView.layer.mask = m;
    }
    if (!CGRectEqualToRect(gSpinView.frame, frame)) {
        [UIView performWithoutAnimation:^{ gSpinView.frame = frame; }];
    }
    gSpinView.hidden = NO;

    if (![gSpinView.layer animationForKey:@"dao.rot"]) {
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        a.fromValue = @0; a.toValue = @(M_PI * 2);
        a.duration = 6.0;
        a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
        a.removedOnCompletion = NO;
        [gSpinView.layer addAnimation:a forKey:@"dao.rot"];
    }
    if (!objc_getAssociatedObject(art, kArtAlpha)) {
        objc_setAssociatedObject(art, kArtAlpha, @(art.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        art.alpha = 0.0;
        if (!gHiddenArtwork) gHiddenArtwork = [NSMutableArray array];
        [gHiddenArtwork addObject:art];
    }
}

static void DAORestoreArtwork(void) {
    for (UIImageView *iv in gHiddenArtwork) {
        NSNumber *a = objc_getAssociatedObject(iv, kArtAlpha);
        if (a) { iv.alpha = a.doubleValue; objc_setAssociatedObject(iv, kArtAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    [gHiddenArtwork removeAllObjects];
}

#pragma mark - 主扫描

static void DAOAttachAperture(UIView *pill, BOOL expanded) {
    if (!pill || !DAOBool(@"aperture_enabled", NO)) {
        if (gAperture) [gAperture applyRect:CGRectZero active:NO];
        return;
    }
    BOOL permanent = DAOBool(@"aperture_permanent", NO);
    if (!permanent && !expanded && !DAOAnyOn()) {
        if (gAperture) [gAperture applyRect:CGRectZero active:NO];
        return;
    }
    if (!pill.superview && !pill.window) return;
    if (!gAperture) {
        gAperture = [[DAOApertureView alloc] initWithFrame:CGRectZero];
        gAperture.userInteractionEnabled = NO;
    }
    if (gAperture.superview != pill.superview) {
        [gAperture removeFromSuperview];
        [pill.superview addSubview:gAperture];
    }
    // 挂进 superview 后坐标空间变了：把岛的屏幕矩形换算到该视图本地坐标
    CGRect pr = DAOScreenRect(pill);
    CGRect local = pr;
    @try { local = [pill.superview convertRect:pr fromView:nil]; } @catch (...) {}
    [gAperture applyRect:local active:YES];
}

static BOOL DAORefreshGeometryOnly(UIView *pill, CGRect pr, BOOL modeOn, BOOL expanded);

// 配置没变时走的轻量路径：只把已有视图的 frame 跟着岛更新，
// 不调用 play/halt、不 addSubview/removeFromSuperview —— 这是原版的流畅来源。
static BOOL DAORefreshGeometryOnly(UIView *pill, CGRect pr, BOOL modeOn, BOOL expanded) {
    if (!pill || !modeOn) return NO;
    CGRect pb = pill.bounds;
    if (pb.size.height < 8) return NO;

    CGFloat scale = DAODouble(@"islandgv_scale", 1.0, 0.5, 1.5);
    CGFloat alpha = DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0);
    CGFloat h = pb.size.height;

    struct { BOOL left; BOOL on; CGFloat size; CGFloat off; } sides[2] = {
        { YES, DAOBool(@"islandgv_active_custom_album", NO),
              DAODouble(@"islandgv_active_left_size", 0.9, 0.6, 2.0),
              DAODouble(@"islandgv_active_left_offset", 1.5, -10.0, 10.0) },
        { NO,  DAOBool(@"islandgv_active_custom_dance", NO),
              DAODouble(@"islandgv_active_right_size", 0.9, 0.6, 2.0),
              DAODouble(@"islandgv_active_right_offset", 1.5, -10.0, 10.0) },
    };

    for (int i = 0; i < 2; i++) {
        BOOL left = sides[i].left;
        DAOSpriteView *sp = left ? gLeftSprite : gRightSprite;
        if (!sp || sp.hidden || !sp.superview) continue;
        if (!sides[i].on) continue;
        CGFloat side = MIN(h * MAX(0.1, sides[i].size) * MAX(0.4, scale), h * 1.10);
        CGFloat off = left ? sides[i].off : -sides[i].off;
        CGFloat cx = left ? (h / 2.0 + off) : (pb.size.width - h / 2.0 + off);
        CGFloat half = side / 2.0;
        cx = MAX(half - h * 0.5, MIN(pb.size.width - half + h * 0.5, cx));
        CGRect f = CGRectMake(cx - half, h / 2.0 - half, side, side);
        if (!CGRectEqualToRect(sp.frame, f)) {
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            sp.frame = f;
            [CATransaction commit];
        }
        sp.alpha = alpha;
    }
    return YES;
}

static void DAOScan(BOOL verbose) {
    if (!DAOAnyOn() && !DAOBool(@"aperture_enabled", NO)) {
        DAOHideSprite(YES); DAOHideSprite(NO);
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
        if (gAperture) [gAperture applyRect:CGRectZero active:NO];
        DAORestoreArtwork();
        DAORestoreDots();
        DAORestoreAll();
        return;
    }
    if (DAOAppExcluded()) {
        DAOHideSprite(YES); DAOHideSprite(NO);
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
        if (gAperture) [gAperture applyRect:CGRectZero active:NO];
        DAORestoreArtwork();
        DAORestoreDots();
        DAORestoreAll();
        return;
    }

    BOOL expanded = NO;
    UIView *pill = DAOMainPill(&expanded);
    if (!pill) {
        DAOHideSprite(YES); DAOHideSprite(NO);
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
        if (gAperture) [gAperture applyRect:CGRectZero active:NO];
        DAORestoreAll();
        return;
    }
    CGRect pr = DAOScreenRect(pill);
    CGFloat alpha = DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0);
    CGFloat scale = DAODouble(@"islandgv_scale", 1.0, 0.5, 1.5);

    BOOL modeOn = expanded ? DAOExpandedOn() : DAOPillOn();

    // 快速路径：配置没变 → 只更新几何，绝不重建视图（对齐原版 0x16694 变更门控）
    BOOL changed = DAOConfigChanged();
    if (!changed && modeOn) {
        BOOL fast = DAORefreshGeometryOnly(pill, pr, modeOn, expanded);
        if (fast) {
            // 录屏压背板 / 光圈仍需每帧维护（它们不涉及视图重建）
            BOOL capturedNow = [UIScreen mainScreen].isCaptured;
            if (DAOBool(@"islandgv_dnl_enabled", NO) && capturedNow) DAOHideBackdropIn(pill, YES);
            @try { DAOAttachAperture(pill, expanded); } @catch (...) {}
            return;
        }
    }

    // 门控：左侧只在「正在录屏」或岛里确实有录屏元素时出现；
    // 右侧只在岛里确实有正在播放的音乐元素时出现。
    // 原版靠 SAUIElementView 的生命周期驱动，不会在空岛/滑动 App 时乱冒。
    BOOL captured = [UIScreen mainScreen].isCaptured;
    BOOL hasRecording = captured || DAOHasTag(pill, @"ScreenRecording", 5) || DAODotInPill(pill) != nil;
    BOOL hasNowPlaying = DAOHasTag(pill, @"NowPlaying", 5);

    if (modeOn) {
        BOOL leftOn = DAOBool(@"islandgv_active_custom_album", NO) && hasRecording;
        BOOL rightOn = DAOBool(@"islandgv_active_custom_dance", NO) && hasNowPlaying;
        CGFloat lSize = DAODouble(@"islandgv_active_left_size", 0.9, 0.6, 2.0);
        CGFloat rSize = DAODouble(@"islandgv_active_right_size", 0.9, 0.6, 2.0);
        CGFloat lOff = DAODouble(@"islandgv_active_left_offset", 1.5, -10.0, 10.0);
        CGFloat rOff = DAODouble(@"islandgv_active_right_offset", 1.5, -10.0, 10.0);
        if (leftOn) {
            DAOPlaceSide(YES, pill, pr, lSize, lOff, scale, alpha);
        } else {
            DAOHideSprite(YES);
            DAORestoreDots();          // 关掉左侧动画就把原生红点还给系统
        }
        if (rightOn) DAOPlaceSide(NO, pill, pr, rSize, -rOff, scale, alpha); else DAOHideSprite(NO);
    } else {
        DAOHideSprite(YES); DAOHideSprite(NO);
    }

    // 录屏隐藏原生岛：只在录屏时压黑底 + 压红点
    if (DAOBool(@"islandgv_dnl_enabled", NO) && captured && modeOn) {
        DAOHideBackdropIn(pill, YES);
    } else {
        DAORestoreAll();
    }
    // 禁用岛阴影模糊：常驻移除材质
    if (DAOBool(@"islandgv_dnl_shadow_disabled", NO)) DAOHideBackdropIn(pill, NO);

    @try { DAOPlaceSpin(pill); } @catch (...) {}
    @try { DAOAttachAperture(pill, expanded); } @catch (...) {}

    gSnapshot = DAOCurrentConfig();
    if (verbose) {
        UIView *dbgDot = DAODotInPill(pill);
        DAOLog(@"scan pill=%@ expanded=%d mode=%d dot=%@ eye=%@ dance=%@",
               NSStringFromCGRect(pr), expanded, modeOn,
               dbgDot ? NSStringFromCGRect(DAOScreenRect(dbgDot)) : @"none",
               (gLeftSprite && !gLeftSprite.hidden) ? NSStringFromCGRect(gLeftSprite.frame) : @"-",
               (gRightSprite && !gRightSprite.hidden) ? NSStringFromCGRect(gRightSprite.frame) : @"-");
        for (UIView *d in DAORecordingDots())
            DAOLog(@"  dot %@ %@ alpha=%.2f", NSStringFromClass(d.class),
                   NSStringFromCGRect(DAOScreenRect(d)), d.alpha);
        for (UIView *p in DAOPills())
            DAOLog(@"  pill id=%@ %@", p.accessibilityIdentifier ?: @"-",
                   NSStringFromCGRect(DAOScreenRect(p)));
    }
}

#pragma mark - 扫描节流

static NSTimeInterval gLastScan = -1e9;
static BOOL gScanQueued = NO;

static void DAOScanSoon(double delay, BOOL verbose) {
    if (gScanQueued) return;
    gScanQueued = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gScanQueued = NO;
        NSTimeInterval now = CACurrentMediaTime();
        double minGap = DAOPowerSaving() ? 0.35 : 0.02;
        if (now - gLastScan < minGap) return;      // 省电模式下降频
        gLastScan = now;
        @try { DAOScan(verbose); } @catch (...) {}
    });
}

static void DAOPurge(void) {
    DAOHideSprite(YES); DAOHideSprite(NO);
    DAORestoreDots();
    if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; }
    if (gAperture) [gAperture applyRect:CGRectZero active:NO];
    DAORestoreArtwork();
    DAORestoreAll();
}

#pragma mark - Hooks

%hook SBSystemApertureContainerView

// 原版在这里只做两件事：捕获容器尺寸变化 → 重排素材；被移除 → 立刻清理。
- (void)setBounds:(CGRect)bounds {
    %orig;
    if (!DAOAnyOn() && !DAOBool(@"aperture_enabled", NO)) return;
    @try {
        CGSize sz = bounds.size;
        if (sz.width < 18 || sz.width > 340 || sz.height < 16 || sz.height > 96) return;
    } @catch (...) {}
    DAOScanSoon(0.0, NO);
}

- (void)removeFromSuperview {
    %orig;
    @try { DAOScanSoon(0.05, NO); } @catch (...) {}
}

%end

// 核心：元素视图。内容进入 / 尺寸变化 / 移除，都从这里驱动，
// 不再扫窗口找红点 —— 那才是「没录屏也冒素材」的根源。
%hook SAUIElementView

- (void)didAddSubview:(UIView *)subview {
    %orig;
    if (!DAOAnyOn()) return;
    DAOScanSoon(0.0, NO);
}

- (void)setBounds:(CGRect)bounds {
    %orig;
    if (!DAOAnyOn()) return;
    DAOScanSoon(0.0, NO);
}

- (void)removeFromSuperview {
    %orig;
    @try { DAOScanSoon(0.05, NO); } @catch (...) {}
}

%end

%hook SBSystemApertureController

- (id)systemApertureViewController:(id)vc containsAnyContent:(BOOL)content {
    id r = %orig;
    if (DAOAnyOn()) DAOScanSoon(0.0, NO);
    (void)vc; (void)content;
    return r;
}

%end

#pragma mark - 通知

static void DAOObserve(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIScreenCapturedDidChangeNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        DAOLog(@"capture -> %d", [UIScreen mainScreen].isCaptured);
        DAOScanSoon(0.08, YES);
        DAOScanSoon(0.20, NO);
        DAOScanSoon(0.35, NO);
        DAOScanSoon(0.60, NO);
        DAOScanSoon(0.95, NO);
    }];
    for (NSString *name in @[ @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                              @"_MRMediaRemoteNowPlayingInfoDidChange",
                              @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                              @"SBMediaControllerNowPlayingInfoDidChangeNotification" ]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil
                                                           queue:[NSOperationQueue mainQueue]
                                                      usingBlock:^(__unused NSNotification *n) {
            DAOScanSoon(0.06, NO);
        }];
    }
    [[NSNotificationCenter defaultCenter] addObserverForName:NSProcessInfoPowerStateDidChangeNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        DAOScanSoon(0.10, NO);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        DAOScanSoon(0.25, NO);
    }];
    [[NSNotificationCenter defaultCenter] addObserverForName:@"SBFrontmostApplicationDidChangeNotification"
                                                      object:nil queue:[NSOperationQueue mainQueue]
                                                  usingBlock:^(__unused NSNotification *n) {
        DAOScanSoon(0.15, NO);
    }];
}

#pragma mark - 设置变更

static NSInteger gApplyTicket = 0;

static void DAOApplyNow(void) {
    DAOFlush();
    DAOClearMediaCache();
    gMediaPathLeft = nil; gMediaPathRight = nil;
    DAOLog(@"settings changed");
    @try { DAOPurge(); } @catch (...) {}
    DAOScan(NO);
}

static void DAOApplySettings(void) {
    NSInteger t = ++gApplyTicket;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.28 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (t != gApplyTicket) return;
        @try { DAOApplyNow(); } @catch (...) {}
    });
}

#pragma mark - ctor

%ctor {
    @autoreleasepool {
        DAOLog(@"===== 动态岛(ios16dao复刻) v%@ loaded pid=%d =====", DAOVersion, getpid());
        int token = 0;
        notify_register_dispatch(DAONotify, &token, dispatch_get_main_queue(), ^(__unused int t) {
            DAOApplySettings();
        });
        DAOObserve();
        DAOScanSoon(1.2, NO);
    }
}