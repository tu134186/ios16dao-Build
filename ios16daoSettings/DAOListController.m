// 动态岛 设置主控制器 —— 与原版 ios16daoSettings 的 41 个条目一一对应。
#import "DAOListController.h"
#import "DAOAppListController.h"
#import <CoreFoundation/CoreFoundation.h>
#import <spawn.h>
#import <stdlib.h>
#import <string.h>

static NSString *const kDomain = @"com.minis.ios16dao";
static CFStringRef const kNotify = CFSTR("com.minis.ios16dao/changed");
static NSString *const kRoot   = @"/var/mobile/ios16dao";
static NSString *const kFrameDir = @"帧率素材";

static id DAOPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                       (__bridge CFStringRef)kDomain));
}

static void DAOPost(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDomain);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kNotify, NULL, NULL, YES);
}

static void DAOSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kDomain);
    DAOPost();
}

static void DAORemove(NSString *key) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)kDomain);
    DAOPost();
}

static BOOL DAOIsDir(NSString *p) {
    BOOL d = NO;
    return [[NSFileManager defaultManager] fileExistsAtPath:p isDirectory:&d] && d;
}

// 素材文件夹：/var/mobile/ios16dao 下的子目录（帧率素材不算）
static NSArray<NSString *> *DAOFolders(void) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    for (NSString *n in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:kRoot error:NULL]) {
        if ([n hasPrefix:@"."] || [n isEqualToString:kFrameDir]) continue;
        if (DAOIsDir([kRoot stringByAppendingPathComponent:n])) [out addObject:n];
    }
    [out sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [a localizedStandardCompare:b];
    }];
    return out;
}

@implementation DAOListController

#pragma mark - 关键：显式加载 Root.plist（PreferenceLoader 不会自动加载）

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *loaded = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (loaded.count == 0) {
            PSSpecifier *err = [PSSpecifier preferenceSpecifierNamed:@"设置加载失败（Root.plist 未读取）"
                                                              target:self set:nil get:nil
                                                            detail:nil cell:PSStaticTextCell edit:nil];
            loaded = @[err];
        }
        _specifiers = [loaded mutableCopy];
        for (PSSpecifier *spec in _specifiers) {
            if ([spec propertyForKey:@"action"]) [spec setTarget:self];
            // 阴影相关的 4 行只在「显示光圈阴影」打开时才有意义
            NSString *sid = [spec propertyForKey:@"id"];
            if ([sid hasPrefix:@"shadow_row_"]) {
                BOOL on = [DAOPref(@"aperture_shadow_style") boolValue];
                if (!on) [spec setProperty:@0 forKey:@"height"];
            }
        }
    }
    return _specifiers;
}

#pragma mark - 行内说明刷新

- (void)refreshDynamicRows {
    BOOL shadowOn = [DAOPref(@"aperture_shadow_style") boolValue];
    NSArray *apps = DAOPref(@"islandgv_excluded_apps");
    id folder = DAOPref(@"islandgv_folder");
    for (PSSpecifier *spec in self.specifiers) {
        NSString *sid = [spec propertyForKey:@"id"];
        NSString *key = [spec propertyForKey:@"key"];
        if ([sid hasPrefix:@"shadow_row_"]) {
            [spec setProperty:(shadowOn ? @44 : @0) forKey:@"height"];
        }
        if ([key isEqualToString:@"islandgv_excluded_apps"]) {
            NSUInteger n = [apps isKindOfClass:[NSArray class]] ? [apps count] : 0;
            [spec setProperty:(n ? [NSString stringWithFormat:@"应用上岛屏蔽（已选 %lu 个）", (unsigned long)n]
                                 : @"应用上岛屏蔽")
                       forKey:@"label"];
        }
        if ([key isEqualToString:@"islandgv_folder"]) {
            [spec setProperty:([folder isKindOfClass:[NSString class]] && [folder length])
                                  ? [NSString stringWithFormat:@"当前：%@", folder]
                                  : @"未选择（使用 帧率素材）"
                       forKey:@"label"];
        }
    }
    [self reloadSpecifiers];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshDynamicRows];
}

#pragma mark - 选择素材文件夹

- (void)pickFolder:(PSSpecifier *)specifier {
    (void)specifier;
    NSArray<NSString *> *folders = DAOFolders();
    if (folders.count == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无可用文件夹"
                                                                   message:@"请在 /var/mobile/ios16dao/ 素材目录中创建文件夹并放入媒体文件"
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"选择素材文件夹"
                                                                   message:@"素材支持 png、gif、mp4，建议使用 mp4"
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSString *current = DAOPref(@"islandgv_folder");
    for (NSString *name in folders) {
        NSString *label = [name isEqualToString:current] ? [name stringByAppendingString:@"  ✓"] : name;
        [sheet addAction:[UIAlertAction actionWithTitle:label style:UIAlertActionStyleDefault
                                               handler:^(__unused UIAlertAction *act) {
            DAOSet(@"islandgv_folder", name);
            [self refreshDynamicRows];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"不使用文件夹" style:UIAlertActionStyleDestructive
                                           handler:^(__unused UIAlertAction *act) {
        DAORemove(@"islandgv_folder");
        [self refreshDynamicRows];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView = self.view;
    sheet.popoverPresentationController.sourceRect =
        CGRectMake(CGRectGetMidX(self.view.bounds), CGRectGetMaxY(self.view.bounds) - 60, 1, 1);
    [self presentViewController:sheet animated:YES completion:nil];
}

#pragma mark - 打开素材目录

- (void)openGIFDir:(PSSpecifier *)specifier {
    (void)specifier;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:kRoot]) {
        [fm createDirectoryAtPath:[kRoot stringByAppendingPathComponent:kFrameDir]
      withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *sub in @[@"eye", @"dance", @"mask"]) {
            [fm createDirectoryAtPath:[[kRoot stringByAppendingPathComponent:kFrameDir]
                                       stringByAppendingPathComponent:sub]
          withIntermediateDirectories:YES attributes:nil error:NULL];
        }
    }
    NSArray<NSString *> *urls = @[ [@"filza://view" stringByAppendingString:kRoot],
                                   [@"filza://" stringByAppendingString:kRoot] ];
    for (NSString *u in urls) {
        NSURL *url = [NSURL URLWithString:u];
        if ([[UIApplication sharedApplication] canOpenURL:url]) {
            [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
            return;
        }
    }
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"无法打开 Filza"
                                                               message:@"请确认已安装 Filza，素材目录为 /var/mobile/ios16dao/"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 功能说明

- (void)showFeatureInfo:(PSSpecifier *)specifier {
    (void)specifier;
    NSString *text =
    @"【启用动态岛功能】\n总开关，开启后在灵动岛（已展开状态）展示自定义素材文件。\n\n"
     "【启用小岛总开关】\n开启后在常态药丸状态（小岛）展示自定义素材。\n\n"
     "【录屏隐藏原生岛】\n录制屏幕时尝试隐藏系统自带的动态岛，仅保留插件渲染的素材。\n\n"
     "【禁用岛阴影模糊】\n移除系统背景材质，解决部分场景背景叠加问题。注意：开启此项可能导致动画生硬或与其他美化插件冲突。\n\n"
     "【应用上岛屏蔽】\n选择特定 App，进入这些 App 时禁用插件特效，避免干扰操作（如全屏游戏）。\n\n"
     "【启用省电模式】\n降低渲染检查频率，减少电量消耗及设备发热。\n\n"
     "【素材比例/透明度】\n调整素材显示的不透明度以及整体缩放大小。\n\n"
     "【灵动写轮眼&跳舞动画】\n"
     "启用左侧动画：/var/mobile/ios16dao/帧率素材/eye/replay1.png~replay999.png；\n"
     "启用右侧动画：/var/mobile/ios16dao/帧率素材/dance/replay1.png~replay999.png；\n"
     "启用旋转蒙版：/var/mobile/ios16dao/帧率素材/mask/Mask.png。";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"插件功能详细说明"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"明白了" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 注销

- (void)respring:(PSSpecifier *)specifier {
    (void)specifier;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"注销设备生效"
                                                               message:@"该选项修改后需点击注销生效才能完全应用，是否立即注销？"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"注销" style:UIAlertActionStyleDestructive
                                       handler:^(__unused UIAlertAction *act) {
        [self doRespring];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)doRespring {
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"重启中"
                                                                  message:@"正在重启，请稍候"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:wait animated:YES completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        for (NSString *path in @[@"/var/jb/usr/bin/killall", @"/usr/bin/killall", @"/usr/bin/killall9"]) {
            if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
            pid_t pid = 0;
            char exe[256];
            strncpy(exe, path.UTF8String, sizeof(exe) - 1);
            exe[sizeof(exe) - 1] = '\0';
            char *argv[] = { exe, (char *)"SpringBoard", NULL };
            posix_spawn(&pid, exe, NULL, NULL, argv, NULL);
            return;
        }
        UIAlertController *fail = [UIAlertController alertControllerWithTitle:@"重启可能失败"
                                                                      message:@"如果 SpringBoard 没有自动重启，请手动重启设备或使用其他方式重启 SpringBoard。"
                                                               preferredStyle:UIAlertControllerStyleAlert];
        [fail addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:fail animated:YES completion:nil];
    });
}

#pragma mark - 应用屏蔽

- (void)openAppSelection:(PSSpecifier *)specifier {
    (void)specifier;
    DAOAppListController *vc = [[DAOAppListController alloc] init];
    [self.navigationController pushViewController:vc animated:YES];
}

#pragma mark - 恢复默认参数

- (void)restoreActiveDefaults:(PSSpecifier *)specifier {
    (void)specifier;
    for (NSString *key in @[ @"islandgv_active_frame_interval", @"islandgv_active_left_size",
                             @"islandgv_active_right_size", @"islandgv_active_left_offset",
                             @"islandgv_active_right_offset", @"islandgv_active_decode_max_edge" ]) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, NULL, (__bridge CFStringRef)kDomain);
    }
    DAOPost();
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已恢复"
                                                               message:@"跳舞动画参数已恢复为默认值。"
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好的" style:UIAlertActionStyleDefault
                                      handler:^(__unused UIAlertAction *act) { [self reloadSpecifiers]; }]];
    [self presentViewController:a animated:YES completion:nil];
}

#pragma mark - 关于

- (void)openSileoRepo {
    NSURL *url = [NSURL URLWithString:@"sileo://source/"];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)openTelegramChannel {
    NSURL *url = [NSURL URLWithString:@"tg://"];
    if (url) [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

@end