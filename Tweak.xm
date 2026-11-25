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

static NSString *const DAOVersion  = @"2.0.0";
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

// 逐帧精灵：用 CADisplayLink 每帧改 image，而不是 UIImageView.animationImages。
// 依据：原版 dylib 里有 DisplayLinkHandler / AXSApertureDisplayLinkProxy /
// stageLightsTick: / displayLinkFired: / preferredFramesPerSecond —— 它就是用
// CADisplayLink 驱动画面的。animationImages 在 duration 很短（0.01s×24帧）时
// 会因 CoreAnimation 时序问题直接空白，这就是「调速到最快素材消失」的根因。
@interface DAOSpriteView : UIImageView
@property (nonatomic, strong) NSArray<UIImage *> *frames;
@property (nonatomic, assign) CGFloat interval;      // 每帧秒数
@property (nonatomic, assign) NSUInteger cursor;
@property (nonatomic, assign) CFTimeInterval startedAt;
@property (nonatomic, weak) UIView *hostView;   // 挂载宿主（元素内部的视图）
@property (nonatomic, weak) UIView *anchorView; // 对齐目标：红点 / 专辑封面
@property (nonatomic, assign) CGFloat side;     // 边长
@property (nonatomic, assign) CGFloat xOffset;
- (void)playFrames:(NSArray<UIImage *> *)frames interval:(CGFloat)interval;
- (void)halt;
@end

static NSMutableArray<DAOSpriteView *> *gAllSprites;
static CADisplayLink *gFrameLink;

// 跟随灵动岛的形变：容器在 morph 动画中用 bounds 会「落后一拍」，
// 必须读 presentationLayer 的当前尺寸，素材才能和系统岛严丝合缝地一起放大缩小。
static void DAOSyncSpriteFrame(DAOSpriteView *sp) {
    UIView *host = sp.hostView;
    if (!host || sp.superview != host || !host.window) return;
    if (sp.side < 6.0) return;

    // 容器尺寸一律读 presentation：系统 morph 动画进行到哪，素材就跟到哪。
    CALayer *hl = (CALayer *)host.layer.presentationLayer ?: host.layer;
    CGSize hb = hl ? hl.bounds.size : host.bounds.size;
    if (hb.width < 8 || hb.height < 8) return;

    CGPoint c = CGPointZero;
    BOOL ok = NO;
    UIView *anchor = sp.anchorView;
    if (anchor && anchor.superview && anchor.window) {
        @try {
            CALayer *al = (CALayer *)anchor.layer.presentationLayer ?: anchor.layer;
            CGPoint local = CGPointMake(CGRectGetMidX(al.bounds), CGRectGetMidY(al.bounds));
            c = [al convertPoint:local toLayer:hl];
            ok = isfinite(c.x) && isfinite(c.y);
        } @catch (...) {}
    }
    if (!ok) {
        // 没有锚点：贴容器端点（原版 0x167b4 的做法）
        c = CGPointMake(sp.xOffset + sp.side / 2.0, hb.height / 2.0);
    }
    c.x += sp.xOffset;
    CGRect f = CGRectMake(c.x - sp.side / 2.0, c.y - sp.side / 2.0, sp.side, sp.side);
    if (!CGRectEqualToRect(sp.frame, f)) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        sp.frame = f;
        [CATransaction commit];
    }
}

static void DAOTickFrames(CADisplayLink *link) {
    CFTimeInterval now = link.timestamp;
    for (DAOSpriteView *sp in gAllSprites) {
        DAOSyncSpriteFrame(sp);
        NSArray<UIImage *> *fr = sp.frames;
        if (!fr.count || sp.hidden || sp.interval <= 0.0) continue;
        NSUInteger idx = (NSUInteger)((now - sp.startedAt) / sp.interval);
        idx %= fr.count;
        if (idx != sp.cursor) {
            sp.cursor = idx;
            sp.image = fr[idx];
        }
    }
}

@interface DAOFrameTicker : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation DAOFrameTicker
- (void)tick:(CADisplayLink *)link { DAOTickFrames(link); }
@end

static DAOFrameTicker *gTicker;

static void DAOEnsureFrameLink(void) {
    if (!gAllSprites) gAllSprites = [NSMutableArray array];
    if (gFrameLink) return;
    if (!gTicker) gTicker = [DAOFrameTicker new];
    gFrameLink = [CADisplayLink displayLinkWithTarget:gTicker selector:@selector(tick:)];
    if (@available(iOS 15.0, *)) {
        gFrameLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        gFrameLink.preferredFramesPerSecond = 60;
#pragma clang diagnostic pop
    }
    [gFrameLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

@implementation DAOSpriteView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.contentMode = UIViewContentModeScaleAspectFit;
        self.backgroundColor = UIColor.clearColor;
        self.layer.masksToBounds = NO;
        DAOEnsureFrameLink();
        [gAllSprites addObject:self];
    }
    return self;
}
- (void)playFrames:(NSArray<UIImage *> *)frames interval:(CGFloat)interval {
    if (frames.count == 0) return;
    if (self.frames != frames) {
        self.frames = frames;
        self.cursor = NSUIntegerMax;
        self.startedAt = CACurrentMediaTime();
        self.image = frames.firstObject;
    }
    CGFloat iv = MAX(0.004, interval);      // 最快 250fps，实际由 displaylink 限到 60
    if (fabs(self.interval - iv) > 0.0005) {
        // 速度变了：按当前位置换算成新的起点，画面不跳、不空白
        if (self.interval > 0 && self.frames.count) {
            NSUInteger cur = (self.cursor == NSUIntegerMax) ? 0 : self.cursor;
            self.startedAt = CACurrentMediaTime() - (CFTimeInterval)cur * iv;
        } else {
            self.startedAt = CACurrentMediaTime();
        }
        self.interval = iv;
    }
}
- (void)halt {
    // 只停止推进，不清 frames：再次显示时立刻能接上，不会黑一下
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

static const void *kDotAlpha = &kDotAlpha;
static NSMutableArray<UIView *> *gHiddenDots;

static void DAORestoreDots(void) {
    for (UIView *d in gHiddenDots) {
        NSNumber *a = objc_getAssociatedObject(d, kDotAlpha);
        if (a) { d.alpha = a.doubleValue; objc_setAssociatedObject(d, kDotAlpha, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    }
    [gHiddenDots removeAllObjects];
}

// 容器的 accessibilityIdentifier 是组合串，实测格式：
//   jindo-container-view:1,client-identifier:com.apple.replaykitangel,
//   element-identifier:systemApertureElementIdentifierScreenRecording
// 所以必须逐个容器按自己的 identifier 分类 —— 不能「取最宽的那个」，
// 因为录屏和时钟/音乐可以同时各有一个容器（日志 817219872.6 就是这样）。
static BOOL DAOHasTag(UIView *pill, NSString *token, NSInteger depth);
static UIImageView *DAOArtworkInPill(UIView *pill, CGRect *visibleOut);
static UIView *DAONativeRecordingIndicator(void);
static UIView *DAOProvidedContainer(UIView *element, NSInteger depth);

static UIView *DAOPillForElement(NSString *token, BOOL *found) {
    if (found) *found = NO;
    UIView *best = nil; CGRect bestRect = CGRectZero;
    for (UIView *p in DAOPills()) {
        NSString *ident = p.accessibilityIdentifier;
        if ([ident isKindOfClass:[NSString class]] && [ident containsString:@"axsContainer"]) continue;
        BOOL hit = NO;
        if ([ident isKindOfClass:[NSString class]] && ident.length &&
            [ident containsString:token]) hit = YES;
        if (!hit && DAOHasTag(p, token, 6)) hit = YES;
        if (!hit) continue;
        if (found) *found = YES;
        CGRect r = DAOScreenRect(p);
        if (!best || r.size.width * r.size.height < bestRect.size.width * bestRect.size.height) {
            // 同种元素有多个副本时取「最小」的：真正的紧凑岛，而不是被放大的 morph 态
            best = p; bestRect = r;
        }
    }
    return best;
}

// 音乐岛：系统在音乐播放时容器 identifier 里并没有 "NowPlaying"（实测日志只有
// jindo-container-view:N），所以改用「容器内存在方形封面图」来判定，
// 这也正好对应原版 IOS16DAOActiveAlbumView 的 artworkView。
// 在 SAUIElementView 元素里找带封面的那个，返回它所在的容器。
// 独立岛（音乐分离岛）刚出现时，容器可能还没被系统登记，但元素已经有了。
static UIView *DAOElementPillWithArtwork(UIView *exclude) {
    UIView *best = nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIWindow *w in DAOAllWindows()) [stack addObject:w];
    NSInteger guard = 0;
    while (stack.count && guard++ < 4000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        if ([NSStringFromClass(v.class) isEqualToString:@"SAUIElementView"] && v.window && !v.hidden) {
            if (!(exclude && v == exclude)) {
                CGRect vis = CGRectZero;
                if (DAOArtworkInPill(v, &vis)) {
                    // 返回它最近的 SBSystemApertureContainerView，没有就用元素本身
                    UIView *p = v;
                    for (int i = 0; p && i < 8; i++, p = p.superview) {
                        if ([NSStringFromClass(p.class) containsString:@"SBSystemApertureContainerView"]) break;
                    }
                    if (p && p.window) best = p;
                }
            }
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    return best;
}

static UIView *DAOPillWithArtwork(UIView *exclude) {
    UIView *best = nil; CGFloat bestScore = -1;
    for (UIView *p in DAOPills()) {
        if (exclude && p == exclude) continue;
        NSString *ident = p.accessibilityIdentifier;
        if ([ident isKindOfClass:[NSString class]] &&
            ([ident containsString:@"axsContainer"] || [ident containsString:@"ScreenRecording"])) continue;
        CGRect vis = CGRectZero;
        if (!DAOArtworkInPill(p, &vis)) continue;
        if (vis.size.width < 10.0 || vis.size.height < 10.0) continue;
        CGFloat score = vis.size.width * vis.size.height;
        if (score > bestScore) { bestScore = score; best = p; }
    }
    return best;
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
    if (!v) return;
    if (objc_getAssociatedObject(v, kDAOAlpha)) {
        // 已经被压过：系统可能又把 alpha 改回来（背板重建），重新压一次
        if (v.alpha > 0.01) v.alpha = 0.0;
        return;
    }
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
    if (*s) { [(*s) halt]; (*s).hidden = YES; (*s).anchorView = nil; }
    if (*m) { [(*m) halt]; (*m).hidden = YES; }
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

// 挂载：宿主固定为灵动岛容器（容器一定在窗口里、不会被小 portal 裁掉），
// 圆心则由 anchor（红点/封面）的 presentation 中心决定。
// 之前把精灵挂到「往上找的大宿主」，那层常常是离屏 portal 叶子，导致素材算出了
// 位置却看不见 —— 日志里 eye={33,33} 有值但屏幕上没有，就是这个原因。
static BOOL DAOMountSprite(BOOL left, UIView *pill, UIView *anchor,
                           CGFloat side, CGFloat offset, CGFloat alpha) {
    DAOSpriteView *sp = DAOSprite(left);
    if (!sp || !pill || !pill.window) return NO;
    if (anchor && !anchor.superview) anchor = nil;

    side = MAX(6.0, MIN(side, 40.0));
    DAOEnsureFrameLink();
    if (sp.superview != pill) {
        [sp removeFromSuperview];
        [pill addSubview:sp];
    }
    [pill bringSubviewToFront:sp];
    sp.hostView   = pill;
    sp.anchorView = anchor;
    sp.side       = side;
    sp.xOffset    = offset;
    sp.hidden     = NO;
    sp.alpha      = alpha;
    DAOSyncSpriteFrame(sp);      // 立刻落一帧
    return YES;
}

static BOOL DAOPlaceSide(BOOL left, UIView *pill, CGRect pillRect,
                         CGFloat sideFactor, CGFloat offset, CGFloat scale, CGFloat alpha) {
    if (!pill) { DAOHideSprite(left); return NO; }
    CGRect pb = pill.bounds;
    CGFloat W = pb.size.width, H = pb.size.height;
    if (W < 8 || H < 8) { DAOHideSprite(left); return NO; }

    // 尺寸：原版 0x167b4 —— side = MIN(size * 岛高, 40.0)
    CGFloat side = MIN(sideFactor * H, 40.0);
    if (scale != 1.0) side = MIN(side * scale, 40.0);
    if (side < 6.0) { DAOHideSprite(left); return NO; }

    // ── 锚点选择（这是「独立岛挂不上」的根因所在）─────────────────
    //   左（录屏）：系统红点 SBRecordingIndicatorView 的实际位置
    //   右（音乐）：岛内专辑封面 UIImageView 的实际位置
    // 挂载点选「锚点向上的就近大视图」，圆心跟锚点 —— 与 RecordingSharingan 6.20
    // 在真机上验证过的做法一致（addSubview 到元素内部 + 用宿主本地坐标）。
    UIView *anchor = nil;
    BOOL haveAnchor = NO;
    if (left) {
        UIView *dot = DAONativeRecordingIndicator();
        if (dot && dot.window && dot.superview) { anchor = dot; haveAnchor = YES; }
    } else {
        CGRect artVis = CGRectZero;
        UIImageView *art = DAOArtworkInPill(pill, &artVis);
        if (art && art.window && art.superview) {
            anchor = art;
            haveAnchor = YES;
            // 封面在屏幕上被裁成圆：用可见直径作为下限，保证能盖住
            if (artVis.size.height > 0) side = MIN(40.0, MAX(side, artVis.size.height * 1.02));
        }
    }
    if (haveAnchor) {
        return DAOMountSprite(left, pill, anchor, side, offset, alpha);
    }

    // 没有锚点（红点还没生成 / 封面还没出来）：优先用元素内部的 provided container，
    // 它就在岛里、会跟着 morph 一起动；实在没有才退回容器端点。
    UIView *provided = DAOProvidedContainer(pill, 6);
    if (provided && provided.window) {
        CGFloat hh = pill.bounds.size.height;
        return DAOMountSprite(left, pill, provided, side, offset, alpha);
        (void)hh;
    }

    CGFloat x = left ? offset : (W - side - offset);
    CGFloat y = (H - side) / 2.0;
    CGRect frame = CGRectMake(x, y, side, side);

    // 帧间隔：原版 islandgv_active_frame_interval（0.01~0.2s，是「每帧时长」不是 fps）
    CGFloat interval = DAODouble(@"islandgv_active_frame_interval", 0.1, 0.01, 0.2);

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
    if (!CGRectEqualToRect(sp.frame, frame)) {
        CGFloat dw = fabs(sp.frame.size.width - frame.size.width);
        CGFloat dy = fabs(CGRectGetMidY(sp.frame) - CGRectGetMidY(frame));
        BOOL bigJump = (dw > 8.0 || dy > 8.0);
        if (sp.hidden || bigJump) {
            // 首次出现 / 尺寸突变：直接落位（免得看到从旧位置滑过来）
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            sp.frame = frame;
            [CATransaction commit];
        } else {
            // 小范围跟随岛形变：短动画过渡，视觉上跟手
            [UIView animateWithDuration:0.16
                                  delay:0
                                options:UIViewAnimationOptionBeginFromCurrentState |
                                        UIViewAnimationOptionCurveEaseOut |
                                        UIViewAnimationOptionAllowUserInteraction
                             animations:^{ sp.frame = frame; }
                             completion:nil];
        }
    }
    sp.hidden = NO;
    sp.alpha = alpha;
    if (sp.startedAt <= 0) sp.startedAt = CACurrentMediaTime();
    [sp playFrames:frames interval:interval];
    return YES;
}

#pragma mark - 原生录屏红点捕获（移植自 RecordingSharingan 6.20 已验证实现）
//
// 关键思路：素材不再按容器 bounds 自己算 frame，而是挂到「系统红点自己的
// superview」里、圆心对准红点中心。这样系统的 morph 动画天然带着素材一起走，
// 不会慢一拍；暂停录屏时红点元素仍在，素材也不会消失。

static __weak UIView *gDAOCapturedDot;

#pragma mark - 官方元素结构挂载（依据 iOS 16.5 SystemApertureUI 头文件）
//
// iOS 16.5 的 SystemApertureUI 导出的真实结构：
//   SAUIElementView
//     .contentView            内容视图
//     .minimalTransformView   _SAUIProvidedViewContainerView  最小态
//     .leadingTransformView   _SAUIProvidedViewContainerView  左端点
//     .trailingTransformView  _SAUIProvidedViewContainerView  右端点
//        └ .providedView      App 提供的内容（真正该挂的地方）
//        └ .portalView        _SAUIPortalView
//
// Apple 自己在系统里就是这么放 App 内容的。把素材做成 providedView 的子视图，
// 放大/缩小/换边/动画全部由系统接管 —— 这才是「像原装一样」的唯一做法。
// 之前我在容器外面手算 bounds，永远跟不上系统的 morph。

static NSString *DAOElementIdentity(UIView *elementView) {
    NSMutableString *out = [NSMutableString string];
    id prov = nil;
    @try { prov = [elementView valueForKey:@"elementViewProvider"]; } @catch (...) {}
    for (NSString *k in @[@"clientIdentifier", @"elementIdentifier", @"identifier", @"elementDescription"]) {
        NSString *v = nil;
        @try { v = [prov valueForKey:k]; } @catch (...) {}
        if (![v isKindOfClass:[NSString class]]) {
            @try { v = [elementView valueForKey:k]; } @catch (...) {}
        }
        if ([v isKindOfClass:[NSString class]] && v.length) [out appendFormat:@"%@ ", v];
    }
    return out;
}

// 取元素当前「可见」的那个 transform 视图里的 providedView
static UIView *DAOElementContentView(UIView *elementView) {
    if (!elementView) return nil;
    UIView *best = nil; CGFloat bestArea = 0;
    for (NSString *key in @[@"leadingTransformView", @"trailingTransformView", @"minimalTransformView"]) {
        UIView *tv = nil;
        @try { tv = [elementView valueForKey:key]; } @catch (...) {}
        if (!tv || tv.hidden || !tv.window) continue;
        CGRect r = DAOScreenRect(tv);
        if (r.size.width < 4 || r.size.height < 4) continue;
        CGFloat area = r.size.width * r.size.height;
        CGFloat side = MIN(r.size.width, r.size.height) / MAX(r.size.width, r.size.height);
        // 端点视图应该是接近方形或窄长的胶囊；太扁的（整屏 morph 中间态）降权
        CGFloat score = area * (side < 0.12 ? 0.2 : 1.0);
        if (score > bestArea) { bestArea = score; best = tv; }
    }
    UIView *target = best;
    if (target) {
        UIView *pv = nil;
        @try { pv = [target valueForKey:@"providedView"]; } @catch (...) {}
        if (pv && pv.window && pv.bounds.size.width >= 4) return pv;
        return target;
    }
    UIView *cv = nil;
    @try { cv = [elementView valueForKey:@"contentView"]; } @catch (...) {}
    if (cv && cv.window) return cv;
    return nil;
}

// 把精灵挂成 contentView 的子视图：位置交给系统，尺寸随宿主自适应
static BOOL DAOMountIntoElement(UIView *elementView, BOOL left, CGFloat ratio, CGFloat offset, CGFloat alpha) {
    DAOSpriteView *sp = DAOSprite(left);
    UIView *host = DAOElementContentView(elementView);
    if (!sp || !host || !host.window) return NO;

    DAOEnsureFrameLink();
    if (sp.superview != host) {
        [sp removeFromSuperview];
        [host addSubview:sp];
    }
    [host bringSubviewToFront:sp];

    // 不做任何逐帧定位：自适应蒙版让系统改尺寸时它自己跟着变
    sp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    sp.hostView   = host;
    sp.anchorView = nil;
    sp.side       = 0;                // 0 = 不自算 frame，用 bounds 铺满
    sp.xOffset    = 0;

    CGRect b = host.bounds;
    CGFloat side = MIN(b.size.width, b.size.height);
    side = MIN(40.0, MAX(side * MAX(0.1, ratio) * MAX(0.4, 1.0), 6.0));
    side = MIN(side, 40.0);
    CGFloat inset = MAX(0.0, offset);
    CGRect f = CGRectMake((b.size.width - side) / 2.0 + (left ? inset : -inset),
                          (b.size.height - side) / 2.0, side, side);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    sp.frame = f;
    [CATransaction commit];

    sp.hidden = NO;
    sp.alpha = alpha;
    return YES;
}

static NSArray<UIView *> *DAOElementViews(void) {
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray array];
    for (UIWindow *w in DAOAllWindows()) [stack addObject:w];
    NSInteger guard = 0;
    Class cls = NSClassFromString(@"SAUIElementView");
    while (stack.count && guard++ < 6000) {
        UIView *v = stack.lastObject; [stack removeLastObject];
        BOOL match = cls ? [v isKindOfClass:cls]
                         : [NSStringFromClass(v.class) isEqualToString:@"SAUIElementView"];
        if (match && v.window && !v.hidden && v.alpha > 0.01) [out addObject:v];
        for (UIView *sub in v.subviews) if (sub) [stack addObject:sub];
    }
    return out;
}

static BOOL DAOLooksLikeIndicator(UIView *v) {
    if (!v) return NO;
    Class cls = NSClassFromString(@"SBRecordingIndicatorView");
    if (cls) { if (![v isKindOfClass:cls]) return NO; }
    else if (![NSStringFromClass(v.class) isEqualToString:@"SBRecordingIndicatorView"]) return NO;

    CGFloat w = CGRectGetWidth(v.bounds), h = CGRectGetHeight(v.bounds);
    // 真机确认：有效红点约 5.67x5.67，0x0 是占位实例
    if (!(w >= 3.0 && h >= 3.0 && w <= 12.0 && h <= 12.0)) return NO;
    if (!v.superview) return NO;

    Class winCls = NSClassFromString(@"SBRecordingIndicatorWindow");
    if (winCls) return [v.window isKindOfClass:winCls];
    return [NSStringFromClass(v.window.class) isEqualToString:@"SBRecordingIndicatorWindow"];
}

static UIView *DAONativeRecordingIndicator(void) {
    Class cls = NSClassFromString(@"SBRecordingIndicatorView");
    Class winCls = NSClassFromString(@"SBRecordingIndicatorWindow");
    UIView *best = nil;
    for (UIWindow *w in DAOAllWindows()) {
        BOOL isRecWin = winCls ? [w isKindOfClass:winCls]
                               : [NSStringFromClass(w.class) isEqualToString:@"SBRecordingIndicatorWindow"];
        if (!isRecWin) continue;
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
        NSInteger guard = 0;
        while (stack.count && guard++ < 220) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            BOOL match = cls ? [v isKindOfClass:cls]
                             : [NSStringFromClass(v.class) isEqualToString:@"SBRecordingIndicatorView"];
            if (match && DAOLooksLikeIndicator(v) && !best) best = v;
            for (UIView *sub in [v.subviews copy]) if (sub) [stack addObject:sub];
        }
    }
    if (DAOLooksLikeIndicator(gDAOCapturedDot)) return gDAOCapturedDot;
    if (best) gDAOCapturedDot = best;
    return best;
}

// 兜底宿主：元素内部的 _SAUIProvidedViewContainerView（原版也是挂在这一层里）
static UIView *DAOProvidedContainer(UIView *element, NSInteger depth) {
    if (!element) return nil;
    Class c = NSClassFromString(@"_SAUIProvidedViewContainerView");
    if (c && [element isKindOfClass:c]) return element;
    if (depth <= 0) return nil;
    for (UIView *sub in [element.subviews copy]) {
        UIView *found = DAOProvidedContainer(sub, depth - 1);
        if (found) return found;
    }
    return nil;
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
                if (vis.size.height >= 10 && vis.size.width >= 10) {
                    // 必须是近似方形：封面是被容器裁出来的一个圆。
                    // 录屏元素那张图是 172x36.67（宽高比 4.69），必须排除。
                    CGFloat ratio = vis.size.width / MAX(1.0, vis.size.height);
                    if (ratio < 0.65 || ratio > 1.55) continue;
                    // 也不能大于容器高度太多
                    if (vis.size.width > pr.size.height * 1.35) continue;
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
static void DAOPurge(void);

// 配置没变时走的轻量路径：只把已有视图的 frame 跟着岛更新，
// 不调用 play/halt、不 addSubview/removeFromSuperview —— 这是原版的流畅来源。
static BOOL DAORefreshGeometryOnly(UIView *pill, CGRect pr, BOOL modeOn, BOOL expanded) {
    if (!pill || !modeOn) return NO;
    CGRect pb = pill.bounds;
    if (pb.size.height < 8) return NO;

    CGFloat scale = DAODouble(@"islandgv_scale", 1.0, 0.5, 1.5);
    CGFloat alpha = DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0);

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
        // 精灵不在屏上（被 Purge 藏起 / 换了宿主）→ 让调用方走完整重建，
        // 否则「藏起来之后永远不再显示」。
        if (!sp || sp.hidden || !sp.superview || !sp.window) {
            if (sides[i].on) return NO;
            continue;
        }
        if (!sides[i].on) continue;
        // 只更新参数；位置由 displaylink 每帧按锚点（红点/封面）的 presentation
        // 自动跟随，系统 morph 时素材天然同步，不会落后一拍。
        CGFloat hh = pill.bounds.size.height;
        CGFloat sd = MIN(sides[i].size * hh, 40.0);
        if (scale != 1.0) sd = MIN(sd * scale, 40.0);
        sp.side    = MAX(6.0, sd);
        sp.xOffset = sides[i].off;
        sp.alpha   = alpha;
    }
    return YES;
}

static void DAOScan(BOOL verbose) {
    // 统一清理路径
    #define DAO_CLEAR_ALL() do { \
        DAOHideSprite(YES); DAOHideSprite(NO); \
        if (gSpinView) { [gSpinView.layer removeAnimationForKey:@"dao.rot"]; gSpinView.hidden = YES; } \
        if (gAperture) [gAperture applyRect:CGRectZero active:NO]; \
        DAORestoreArtwork(); DAORestoreDots(); DAORestoreAll(); \
    } while (0)

    if (!DAOAnyOn() && !DAOBool(@"aperture_enabled", NO)) { DAOPurge(); return; }
    if (DAOAppExcluded()) { DAOPurge(); return; }

    // ── 关键：按元素各自找容器 ─────────────────────────────────
    // 日志证据（817219872.6）：录屏容器 36.66pt 在 x=285，时钟容器 163pt 在 x=114，
    // 同时存在。以前我「取最宽」→ 素材被塞进时钟容器，位置当然全错。
    BOOL captured = [UIScreen mainScreen].isCaptured;

    // ── 优先走官方元素结构 ───────────────────────────────────────
    // 每个 SAUIElementView 自带 leading/trailing/minimal 三个 providedView 容器，
    // 把素材挂进当前可见的那个，系统会自己负责缩放和换边。
    {
        NSArray<UIView *> *els = DAOElementViews();
        UIView *recEl = nil, *musEl = nil;
        for (UIView *el in els) {
            NSString *ident = DAOElementIdentity(el);
            NSString *low = ident.lowercaseString;
            if ([low containsString:@"screenrecording"] || [low containsString:@"replaykit"]) {
                if (!recEl) recEl = el;
            } else {
                CGRect vis = CGRectZero;
                if (DAOArtworkInPill(el, &vis) && !musEl) musEl = el;
            }
        }
        BOOL modeOnEl = DAOExpandedOn() || DAOPillOn();
        CGFloat alphaEl = DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0);
        BOOL leftOn  = modeOnEl && DAOBool(@"islandgv_active_custom_album", NO) && recEl;
        BOOL rightOn = modeOnEl && DAOBool(@"islandgv_active_custom_dance", NO) && musEl;
        if (leftOn || rightOn) {
            BOOL okL = leftOn ? DAOMountIntoElement(recEl, YES,
                        DAODouble(@"islandgv_active_left_size", 0.9, 0.6, 2.0),
                        DAODouble(@"islandgv_active_left_offset", 1.5, -10.0, 10.0), alphaEl) : NO;
            BOOL okR = rightOn ? DAOMountIntoElement(musEl, NO,
                        DAODouble(@"islandgv_active_right_size", 0.9, 0.6, 2.0),
                        DAODouble(@"islandgv_active_right_offset", 1.5, -10.0, 10.0), alphaEl) : NO;
            if (!leftOn) DAOHideSprite(YES);
            if (!rightOn) DAOHideSprite(NO);
            if (okL || okR) {
                NSArray<UIImage *> *frL = okL ? DAOLoadFrames(1) : nil;
                NSArray<UIImage *> *frR = okR ? DAOLoadFrames(0) : nil;
                CGFloat iv = DAODouble(@"islandgv_active_frame_interval", 0.1, 0.01, 0.2);
                if (frL.count) [gLeftSprite playFrames:frL interval:iv];
                if (frR.count) [gRightSprite playFrames:frR interval:iv];
                gSnapshot = DAOCurrentConfig();
                if (verbose) {
                    DAOLog(@"element mount rec=%@ music=%@ eye=%@ dance=%@",
                           recEl ? DAOElementIdentity(recEl) : @"-",
                           musEl ? DAOElementIdentity(musEl) : @"-",
                           (gLeftSprite && !gLeftSprite.hidden) ? NSStringFromCGRect(gLeftSprite.frame) : @"-",
                           (gRightSprite && !gRightSprite.hidden) ? NSStringFromCGRect(gRightSprite.frame) : @"-");
                }
                // 光圈仍按容器矩形走（它描的是岛的轮廓，不是元素内容）
                @try {
                    UIView *ap = recEl ?: musEl;
                    if (ap) DAOAttachAperture(ap, YES);
                } @catch (...) {}
                return;
            }
        }
    }

    // 录屏容器：只看「元素是否还在」+「尺寸是否正常」。
    // 不能用 isCaptured 做硬门控 —— 暂停录屏时 isCaptured 立刻变 NO，
    // 但录屏元素仍然挂在岛上（这正是「暂停后素材消失」的原因）。
    // 真正区分「暂停」和「结束」的是元素本身：
    //   暂停 → 元素在，容器仍是正常的 172x36.67
    //   结束 → 元素被移除，中间会短暂处于 407x84 的 morph 态
    UIView *recPill = DAOPillForElement(@"ScreenRecording", NULL);
    if (recPill) {
        // morph 中间态：整屏宽度 + 超过 60pt 高。用比值不行 ——
        // 正常宽录屏岛 172x36.67 比值 4.69，morph 态 407x84 比值 4.85，几乎一样。
        CGRect rr = DAOScreenRect(recPill);
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        if (rr.size.height > 60.0 && rr.size.width > sw * 0.85) recPill = nil;
    }
    if (!recPill && captured) {
        BOOL exp = NO; UIView *only = DAOMainPill(&exp);
        if (only && DAOPills().count == 1) recPill = only;
    }

    // 音乐岛：先按「岛内有方形封面」找容器；找不到再退一步，
    // 直接在 SAUIElementView 里找带封面的那个（独立岛分离时容器可能还没就绪）。
    UIView *musicPill = DAOPillWithArtwork(recPill);
    if (!musicPill) {
        musicPill = DAOElementPillWithArtwork(recPill);
    }
    if (musicPill) {
        CGRect mr = DAOScreenRect(musicPill);
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        if (mr.size.height > 60.0 && mr.size.width > sw * 0.85) musicPill = nil;
    }

    UIView *hostPill = recPill ?: musicPill;
    if (!hostPill) { DAO_CLEAR_ALL(); return; }

    BOOL expanded = NO;
    { CGRect r = DAOScreenRect(hostPill); expanded = (r.size.width > r.size.height * 2.0); }
    CGFloat alpha = DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0);
    CGFloat scale = DAODouble(@"islandgv_scale", 1.0, 0.5, 1.5);
    BOOL modeOn = expanded ? DAOExpandedOn() : DAOPillOn();

    // 变更门控：配置没变 → 只更新几何，不重建（原版 0x16694，阈值 1e-4）
    if (modeOn && !DAOConfigChanged()) {
        if (recPill && DAOBool(@"islandgv_active_custom_album", NO))
            DAORefreshGeometryOnly(recPill, DAOScreenRect(recPill), YES, expanded);
        if (musicPill && DAOBool(@"islandgv_active_custom_dance", NO))
            DAORefreshGeometryOnly(musicPill, DAOScreenRect(musicPill), YES, expanded);
        if (DAOBool(@"islandgv_dnl_enabled", NO) && [UIScreen mainScreen].isCaptured)
            DAOHideBackdropIn(recPill, YES);
        @try { DAOAttachAperture(hostPill, expanded); } @catch (...) {}
        return;
    }

    // 左侧（写轮眼）：只挂到录屏容器
    BOOL leftOn = modeOn && DAOBool(@"islandgv_active_custom_album", NO) && (recPill != nil);
    if (leftOn) {
        CGFloat lSize = DAODouble(@"islandgv_active_left_size", 0.9, 0.6, 2.0);
        CGFloat lOff  = DAODouble(@"islandgv_active_left_offset", 1.5, -10.0, 10.0);
        DAOPlaceSide(YES, recPill, DAOScreenRect(recPill), lSize, lOff, scale, alpha);
    } else {
        DAOHideSprite(YES);
    }

    // 右侧（跳舞）：只挂到音乐容器
    BOOL rightOn = modeOn && DAOBool(@"islandgv_active_custom_dance", NO) && (musicPill != nil);
    if (rightOn) {
        CGFloat rSize = DAODouble(@"islandgv_active_right_size", 0.9, 0.6, 2.0);
        CGFloat rOff  = DAODouble(@"islandgv_active_right_offset", 1.5, -10.0, 10.0);
        DAOPlaceSide(NO, musicPill, DAOScreenRect(musicPill), rSize, rOff, scale, alpha);
    } else {
        DAOHideSprite(NO);
    }

    // 录屏隐藏原生岛（原版走 setShadowStyle: 那条路，这里先压背板）
    if (DAOBool(@"islandgv_dnl_enabled", NO) && captured && recPill) DAOHideBackdropIn(recPill, YES);
    else DAORestoreAll();
    if (DAOBool(@"islandgv_dnl_shadow_disabled", NO) && hostPill) DAOHideBackdropIn(hostPill, NO);

    if (musicPill) @try { DAOPlaceSpin(musicPill); } @catch (...) {}
    @try { DAOAttachAperture(hostPill, expanded); } @catch (...) {}

    gSnapshot = DAOCurrentConfig();

    if (verbose) {
        DAOLog(@"scan rec=%@ music=%@ expanded=%d mode=%d eye=%@ dance=%@",
               recPill ? NSStringFromCGRect(DAOScreenRect(recPill)) : @"-",
               musicPill ? NSStringFromCGRect(DAOScreenRect(musicPill)) : @"-",
               expanded, modeOn,
               (gLeftSprite && !gLeftSprite.hidden) ? NSStringFromCGRect(gLeftSprite.frame) : @"-",
               (gRightSprite && !gRightSprite.hidden) ? NSStringFromCGRect(gRightSprite.frame) : @"-");
        for (UIView *p in DAOPills()) {
            CGRect art = CGRectZero;
            UIImageView *iv = DAOArtworkInPill(p, &art);
            DAOLog(@"  pill id=%@ %@ art=%@ %@",
                   p.accessibilityIdentifier ?: @"-",
                   NSStringFromCGRect(DAOScreenRect(p)),
                   iv ? NSStringFromClass(iv.class) : @"none",
                   iv ? NSStringFromCGRect(art) : @"-");
        }
    }
    #undef DAO_CLEAR_ALL
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
// 系统红点每次布局/换宿主/改尺寸都重同步一次。
// 这是 RecordingSharingan 6.20 里最关键的一组 hook：素材能「一直挂住、跟着岛动」，
// 靠的就是在这些时机重新对齐，而不是等我们的定时器去轮询。
%hook SBRecordingIndicatorView

- (void)layoutSubviews {
    %orig;
    if (!DAOAnyOn()) return;
    DAOScanSoon(0.0, NO);
}

- (void)didMoveToSuperview {
    %orig;
    if (!DAOAnyOn()) return;
    DAOScanSoon(0.0, NO);
}

- (void)didMoveToWindow {
    %orig;
    if (!DAOAnyOn()) return;
    DAOScanSoon(0.0, NO);
}

- (void)setFrame:(CGRect)frame {
    %orig;
    if (!DAOAnyOn() || [UIScreen mainScreen].isCaptured == NO) return;
    // 红点位置变了（含 morph 动画每帧）→ 立刻把素材圆心上移过去
    @try {
        DAOSpriteView *sp = gLeftSprite;
        if (sp && sp.anchorView == (UIView *)self && sp.superview == sp.hostView) {
            DAOSyncSpriteFrame(sp);
        }
    } @catch (...) {}
}

%end

%hook SAUIElementView

- (void)layoutSubviews {
    %orig;
    if (!DAOAnyOn()) return;
    DAOScanSoon(0.0, NO);
}

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
        DAOScanSoon(0.20, YES);
        DAOScanSoon(0.35, YES);
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
    CGFloat newEdge = DAODouble(@"islandgv_active_decode_max_edge", 220.0, 160.0, 320.0);
    NSString *newFolder = DAOSelectedFolder() ?: @"";
    static CGFloat sLastEdge = -1;
    static NSString *sLastFolder;
    BOOL mediaChanged = (fabs(newEdge - sLastEdge) > 0.5) ||
                        ![newFolder isEqualToString:(sLastFolder ?: @"")];
    sLastEdge = newEdge;
    sLastFolder = newFolder;
    DAOFlush();
    if (mediaChanged) {
        DAOClearMediaCache();
        gMediaPathLeft = nil; gMediaPathRight = nil;
    }
    DAOLog(@"settings changed (mediaChanged=%d) | 总:%d 小岛:%d 录屏隐藏:%d 禁阴影:%d 省电:%d "
           "左:%d(%.2f,%+.1f) 右:%d(%.2f,%+.1f) 蒙版:%d 速度:%.2fs 清晰度:%.0f 透明度:%.2f 比例:%.2f "
           "光圈:%d 常驻:%d 粗:%.1f 样式:%d 色:%@ 阴影:%d 粒子:%d/%d 屏蔽:%lu",
           mediaChanged,
           DAOExpandedOn(), DAOPillOn(),
           DAOBool(@"islandgv_dnl_enabled", NO), DAOBool(@"islandgv_dnl_shadow_disabled", NO),
           DAOPowerSaving(),
           DAOBool(@"islandgv_active_custom_album", NO),
           DAODouble(@"islandgv_active_left_size", 0.9, 0.6, 2.0),
           DAODouble(@"islandgv_active_left_offset", 1.5, -10.0, 10.0),
           DAOBool(@"islandgv_active_custom_dance", NO),
           DAODouble(@"islandgv_active_right_size", 0.9, 0.6, 2.0),
           DAODouble(@"islandgv_active_right_offset", 1.5, -10.0, 10.0),
           DAOBool(@"islandgv_active_enable_mask", YES),
           DAODouble(@"islandgv_active_frame_interval", 0.1, 0.01, 0.2),
           DAODouble(@"islandgv_active_decode_max_edge", 220.0, 160.0, 320.0),
           DAODouble(@"islandgv_alpha", 1.0, 0.0, 1.0),
           DAODouble(@"islandgv_scale", 1.0, 0.5, 1.5),
           DAOBool(@"aperture_enabled", NO), DAOBool(@"aperture_permanent", NO),
           DAODouble(@"aperture_thickness", 3.5, 1.0, 10.0),
           (int)DAODouble(@"aperture_style", 0, 0, 4),
           DAOString(@"aperture_color") ?: @"(默认)",
           DAOBool(@"aperture_shadow_style", NO),
           DAOBool(@"aperture_particle_enabled", NO),
           (int)DAODouble(@"aperture_particle_style", 0, 0, 3),
           (unsigned long)(DAOArray(@"islandgv_excluded_apps").count));
    // 不在这里 Purge：Purge 会把精灵藏起来，而下面的快速路径又不会重新显示它，
    // 结果就是「改任意一个设置 → 素材消失」。让 DAOScan 自己按需重建。
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