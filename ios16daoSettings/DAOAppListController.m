// 应用上岛屏蔽：列出已安装 App，勾选后进入这些 App 时插件特效全部停用（全屏游戏等场景）。
#import "DAOAppListController.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <CoreFoundation/CoreFoundation.h>

static NSString *const kDAODomain2 = @"com.minis.ios16dao";
static CFStringRef const kDAONotify2 = CFSTR("com.minis.ios16dao/changed");

@interface DAOAppListController () <UISearchResultsUpdating>
@property (nonatomic, strong) NSArray<NSDictionary *> *allApps;
@property (nonatomic, strong) NSMutableArray<NSString *> *selected;
@property (nonatomic, strong) NSArray<NSDictionary *> *filtered;
@property (nonatomic, strong) UISearchController *search;
@end

@implementation DAOAppListController

- (instancetype)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"应用上岛屏蔽";

    id v = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("islandgv_excluded_apps"),
                                                       (__bridge CFStringRef)kDAODomain2));
    self.selected = [v isKindOfClass:[NSArray class]] ? [v mutableCopy] : [NSMutableArray array];

    NSMutableArray<NSDictionary *> *apps = [NSMutableArray array];
    @try {
        Class ws = objc_getClass("LSApplicationWorkspace");
        id workspace = ((id (*)(id, SEL))objc_msgSend)((id)ws, sel_registerName("defaultWorkspace"));
        SEL allSel = sel_registerName("allApplications");
        if ([workspace respondsToSelector:allSel]) {
            for (id app in ((id (*)(id, SEL))objc_msgSend)(workspace, allSel)) {
                NSString *bid = nil;
                SEL bidSel = sel_registerName("bundleIdentifier");
                SEL idSel = sel_registerName("applicationIdentifier");
                if ([app respondsToSelector:bidSel]) bid = ((id (*)(id, SEL))objc_msgSend)(app, bidSel);
                else if ([app respondsToSelector:idSel]) bid = ((id (*)(id, SEL))objc_msgSend)(app, idSel);
                if (!bid.length) continue;
                if ([bid hasPrefix:@"com.apple."]) continue;
                NSString *name = nil;
                SEL nameSel = sel_registerName("localizedName");
                if ([app respondsToSelector:nameSel]) name = ((id (*)(id, SEL))objc_msgSend)(app, nameSel);
                if (!name.length) name = bid;
                [apps addObject:@{ @"id": bid, @"name": name }];
            }
        }
    } @catch (...) {}

    [apps sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [a[@"name"] localizedStandardCompare:b[@"name"]];
    }];
    self.allApps = apps;
    self.filtered = apps;

    self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.search.searchResultsUpdater = self;
    self.search.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.search;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;

    if (apps.count == 0) {
        UILabel *empty = [[UILabel alloc] init];
        empty.text = @"无法打开应用列表\n请先安装 AltList (com.opa334.altlist)";
        empty.numberOfLines = 0;
        empty.textAlignment = NSTextAlignmentCenter;
        empty.textColor = [UIColor secondaryLabelColor];
        self.tableView.backgroundView = empty;
    }
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    NSString *q = searchController.searchBar.text.lowercaseString;
    if (!q.length) self.filtered = self.allApps;
    else {
        NSPredicate *p = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *d, __unused id b) {
            return [d[@"name"] lowercaseString].length && [[d[@"name"] lowercaseString] containsString:q];
        }];
        self.filtered = [self.allApps filteredArrayUsingPredicate:p];
    }
    [self.tableView reloadData];
}

- (void)save {
    CFPreferencesSetAppValue(CFSTR("islandgv_excluded_apps"),
                             (__bridge CFPropertyListRef)[self.selected copy],
                             (__bridge CFStringRef)kDAODomain2);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kDAODomain2);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         kDAONotify2, NULL, NULL, YES);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self save];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; (void)section;
    return (NSInteger)self.filtered.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cid = @"dao.app";
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cid];
    if (!cell) cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *d = self.filtered[indexPath.row];
    cell.textLabel.text = d[@"name"];
    cell.detailTextLabel.text = d[@"id"];
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.detailTextLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    cell.accessoryType = [self.selected containsObject:d[@"id"]] ? UITableViewCellAccessoryCheckmark
                                                                : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NSDictionary *d = self.filtered[indexPath.row];
    NSString *bid = d[@"id"];
    if ([self.selected containsObject:bid]) [self.selected removeObject:bid];
    else [self.selected addObject:bid];
    [self save];
    [tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationNone];
}

@end